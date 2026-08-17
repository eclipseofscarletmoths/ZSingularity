// TextureAtlasTransplant.m
//
// See TextureAtlasTransplant.h for the design. Cache discovery/CAB
// indexing below deliberately mirrors BundleTransplant.m's own
// bt2_find_all_data_files/bt2_build_cab_index rather than calling into
// it - those are file-local statics, not exposed API, and duplicating
// ~20 lines here is simpler than restructuring BundleTransplant.m just
// to share them.

#import "TextureAtlasTransplant.h"
#import "UnityBundleCAB.h"
#import "SerializedObjectTable.h"
#import "BundleTransplant.h" // for +unityCacheSharedDirectory only
#import "Texture2DFields.h"
#import "Texture2DPixelDecoder.h"
#import "RawPixelPacker.h"
#import "ZTweakLog.h"

NSString * const TextureAtlasTransplantErrorDomain = @"TextureAtlasTransplantErrorDomain";

// Unity persistent class IDs - see https://docs.unity3d.com/Manual/ClassIDReference.html.
// Per this project's own findings (see this file's header comment and
// TextureAtlasTransplant.h's top note), these are the only two object
// types that actually differ between a PC mod and its iOS target -
// everything else with a differing PathID is skipped now rather than
// blindly byte-copied, since a whole-object copy is only safe when the
// two platforms serialize that type identically (confirmed true for
// TextAsset - see BundleTransplant.m's README note - and NOT true for
// Texture2D, see Texture2DFields.h's top comment).
static const int32_t kTAT2ClassIDTexture2D = 28;
static const int32_t kTAT2ClassIDTextAsset = 49;

static NSError *TATError(TextureAtlasTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TextureAtlasTransplantErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - cache discovery (mirrors BundleTransplant.m - see top note)

static NSArray<NSString *> *tat_find_all_data_files(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *relPath in walker) {
        if (![relPath.lastPathComponent isEqualToString:@"__data"]) continue;
        [found addObject:[root stringByAppendingPathComponent:relPath]];
    }
    return found;
}

static NSArray<NSString *> *tat_find_cached_paths_for_cab(NSString *cab, NSString *cacheDir) {
    NSArray<NSString *> *dataPaths = tat_find_all_data_files(cacheDir);
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (NSString *path in dataPaths) {
        NSError *cabErr = nil;
        NSString *foundCAB = [UnityBundleCAB primaryCABForBundleAtPath:path error:&cabErr];
        if (foundCAB && [foundCAB isEqualToString:cab]) {
            [matches addObject:path];
        }
    }
    return matches;
}

#pragma mark - StreamingInfo detection (generic - see .h "THE ONE EXCEPTION")

// Layout confirmed against real files (see /areas/120f-tweak.md): inside
// a streamed object's own bytes, [u64 offset][u32 size][u32 pathLen]
// ["archive:/..." pathLen bytes] appear contiguously, in that order,
// somewhere before the object's end. Detected by finding that ASCII
// path's own length-prefix pattern rather than assuming a fixed offset
// from the object's start, since the preceding fields (name string,
// per-format flags) vary in length object to object - see
// TextureAtlasTransplant.h's top comment on why this isn't gated on the
// object being specifically a Texture2D.
//
// Returns YES and fills *outOffsetFieldPos (the byte position, relative
// to objectBytes' own start, of the 8-byte offset field - size/pathLen/path
// immediately follow it) if found.
//
// FIXED 2026-08-17 (see overview.md Entry 3): this used to return i-12,
// which only reserves 8 (offset) + 4 bytes before the text - i.e. it
// treated the path's own u32 length prefix (declaredLen, read from
// base[i-4..i-1]) as if it were also StreamingInfo's separate u32 size
// field, double-counting one 4-byte slot for two different fields. The
// real layout is offset(8) + size(4) + pathLen(4) = 16 bytes before the
// text, confirmed by hand against real Texture2D object bytes pulled from
// Dumps.zip (offset field's own u64 landed on a plausible .resS byte
// offset, and the size field 8 bytes later matched that same object's
// independently-parsed m_CompleteImageSize exactly, only when using i-16 -
// i-12 landed 4 bytes into the middle of the size field instead). This was
// silently poisoning streamDataPositionConfirmed for every streamed
// object, which in turn made every TAT2VersionProfile - correct or not -
// fail Texture2DFields.m's cross-check, which is why
// +detectVersionProfile:... was finding zero surviving candidates on real
// device runs even though the leading-field profile itself was mostly
// fine. Not a version-dependent bug - this is wrong on every build.
static BOOL tat_find_stream_data_offset_field(NSData *objectBytes, NSUInteger *outOffsetFieldPos) {
    static const char *kNeedle = "archive:/";
    NSUInteger needleLen = strlen(kNeedle);
    const uint8_t *base = (const uint8_t *)objectBytes.bytes;
    NSUInteger len = objectBytes.length;
    if (len < needleLen + 4) return NO;

    for (NSUInteger i = 0; i + needleLen <= len; i++) {
        if (memcmp(base + i, kNeedle, needleLen) != 0) continue;
        // i is the start of the ASCII path text. The 4 bytes immediately
        // before it should be its own little-endian length prefix,
        // matching how far the string actually runs (plus it must fit -
        // NUL-free within this object, not necessarily NUL-terminated
        // since Unity string fields are length-prefixed, not
        // C-terminated).
        if (i < 16) continue; // need 8 (offset) + 4 (size) bytes before the 4-byte length prefix too
        uint32_t declaredLen = (uint32_t)base[i-4] | ((uint32_t)base[i-3] << 8) | ((uint32_t)base[i-2] << 16) | ((uint32_t)base[i-1] << 24);
        if (declaredLen == 0 || i + declaredLen > len) continue;
        if (declaredLen < needleLen) continue;
        // Plausible match - offset field is 16 bytes before the path text starts (8 for offset, 4 for size, 4 for the path's own length prefix).
        *outOffsetFieldPos = i - 16;
        return YES;
    }
    return NO;
}

static void tat_write_u64_le(NSMutableData *data, NSUInteger pos, uint64_t v) {
    uint8_t *p = (uint8_t *)data.mutableBytes + pos;
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static uint64_t tat_read_u64_le(NSData *data, NSUInteger pos) {
    const uint8_t *p = (const uint8_t *)data.bytes + pos;
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static uint32_t tat_read_u32_le(NSData *data, NSUInteger pos) {
    const uint8_t *p = (const uint8_t *)data.bytes + pos;
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void tat_write_u32_le(NSMutableData *data, NSUInteger pos, uint32_t v) {
    uint8_t *p = (uint8_t *)data.mutableBytes + pos;
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

#pragma mark - version profile resolution (see Texture2DFields.h)

// Per this project's own finding (documented in overview.md): the
// profile only describes fields shared by every Texture2D object in
// one Unity build, so it needs solving once per distinct build, not
// per object or per bundle. Cached by archive.unityVersion so repeat
// calls within the same run (many bundles, same game build) skip
// re-detecting - see UnityBundleCAB.h, which already preserves this
// string through a rebuild.
static NSMutableDictionary<NSString *, NSValue *> *tat_profileCache;

// How many streamed Texture2D samples to gather before giving up and
// falling back to kTAT2ProfileDefault - see Texture2DFields.h's
// +detectVersionProfile:...: doc on why more samples disambiguate
// better. 10 keeps startup cost trivial (512 candidates x 10 parses
// is nothing) while still being enough to rule out spurious
// width/height-only passes in practice.
static const NSUInteger kTATProfileDetectionSampleTarget = 10;

// Resolves (and caches) the real TAT2VersionProfile for moddedArchive's
// own Unity build, using moddedTable's already-resolved classIDs to
// find sample Texture2D objects. Falls back to kTAT2ProfileDefault
// (logged loudly) if unityVersion is missing/unrecognized or detection
// is inconclusive - see Texture2DFields.h.
static TAT2VersionProfile tat_resolve_profile(UnityBundleArchive *moddedArchive,
                                               NSData *moddedCABData,
                                               SerializedObjectTable *moddedTable,
                                               NSData * _Nullable moddedResSData) {
    NSString *versionKey = moddedArchive.unityVersion.length > 0 ? moddedArchive.unityVersion : @"(unknown unityVersion)";

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tat_profileCache = [NSMutableDictionary dictionary];
    });

    NSValue *cached = tat_profileCache[versionKey];
    if (cached) {
        TAT2VersionProfile profile;
        [cached getValue:&profile];
        return profile;
    }

    NSMutableArray<NSData *> *samples = [NSMutableArray array];
    NSMutableArray<NSNumber *> *samplePositions = [NSMutableArray array];
    for (SerializedObject *obj in moddedTable.objects) {
        if (samples.count >= kTATProfileDetectionSampleTarget) break;
        if (!obj.classIDResolved || obj.classID != kTAT2ClassIDTexture2D) continue;
        NSData *bytes = [moddedCABData subdataWithRange:NSMakeRange((NSUInteger)(moddedTable.dataOffset + obj.byteStart), obj.byteSize)];
        NSUInteger streamPos = NSNotFound;
        if (moddedResSData) {
            tat_find_stream_data_offset_field(bytes, &streamPos); // leaves streamPos untouched (still NSNotFound) if it returns NO
        }
        [samples addObject:bytes];
        [samplePositions addObject:@(streamPos)];
    }

    TAT2VersionProfile detected;
    TAT2VersionProfile resolved;
    if ([Texture2DHeader detectVersionProfile:&detected fromObjectSamples:samples streamDataOffsetFieldPositions:samplePositions]) {
        resolved = detected;
        ZLog(@"[TextureAtlasTransplant] unityVersion %@: detected TAT2VersionProfile from %lu Texture2D sample(s)", versionKey, (unsigned long)samples.count);
    } else {
        resolved = kTAT2ProfileDefault;
        ZLog(@"[TextureAtlasTransplant] unityVersion %@: profile detection inconclusive (%lu sample(s) available) - falling back to kTAT2ProfileDefault; expect Texture2D header parse failures if this build's layout differs",
             versionKey, (unsigned long)samples.count);
    }

    NSValue *boxed = [NSValue valueWithBytes:&resolved objCType:@encode(TAT2VersionProfile)];
    tat_profileCache[versionKey] = boxed;
    return resolved;
}

#pragma mark - node lookup helpers

static UnityBundleNode *tat_find_node(UnityBundleArchive *archive, NSString *path) {
    for (UnityBundleNode *n in archive.nodes) {
        if ([n.path isEqualToString:path]) return n;
    }
    return nil;
}

static NSData *tat_node_slice(UnityBundleArchive *archive, UnityBundleNode *node) {
    return [archive.data subdataWithRange:NSMakeRange((NSUInteger)node.offset, (NSUInteger)node.size)];
}

#pragma mark - new-object encoding (see .h "3) New-object encoding")

// Outcome of one tat_build_new_object_payload call - mirrors the
// existing texture2DHeaderParseFailed/texture2DFormatUnsupported split
// on TextureAtlasTransplantResult, but for objectsAdded* counters
// instead, since a new-object failure is counted separately (see .h).
typedef NS_ENUM(NSInteger, TATNewObjectOutcome) {
    TATNewObjectOK = 0,
    TATNewObjectHeaderParseFailed,
    TATNewObjectFormatUnsupported,
};

// Builds the object bytes to append for one modded PathID target has no
// counterpart for at all. TextAsset: verbatim copy of modded's bytes,
// same StreamingInfo repoint-into-target's-.resS the existing diff path
// already does for TextAsset. Texture2D: same decode/re-pack pipeline
// tat_transplant_one's diff path uses, but patched onto a copy of
// MODDED's own bytes (there is no target template - see .h's item 3) -
// streamed into target's .resS if target has one at all (file-level
// convention, since there's no existing per-object precedent for a
// brand-new object to match), inline otherwise.
static NSData *tat_build_new_object_payload(SerializedObject *moddedObj,
                                             NSData *moddedBytes,
                                             NSData * _Nullable moddedResSData,
                                             BOOL targetHasResS,
                                             NSString * _Nullable targetResSArchivePath, // e.g. "archive:/CAB-xxx/CAB-xxx.resS" - target's OWN, used to build a correct StreamingInfo.path for a newly-streamed object (see below)
                                             NSMutableData *targetResSData,
                                             TAT2VersionProfile profile, // resolved once per Unity build - see tat_resolve_profile
                                             TATNewObjectOutcome *outOutcome) {
    *outOutcome = TATNewObjectOK;

    if (moddedObj.classID == kTAT2ClassIDTextAsset) {
        NSUInteger streamFieldPos;
        NSMutableData *payload = [moddedBytes mutableCopy];
        if (moddedResSData && tat_find_stream_data_offset_field(moddedBytes, &streamFieldPos)) {
            uint64_t moddedOffset = tat_read_u64_le(moddedBytes, streamFieldPos);
            uint32_t streamSize = tat_read_u32_le(moddedBytes, streamFieldPos + 8);
            if (moddedOffset + streamSize <= moddedResSData.length) {
                NSData *bytes = [moddedResSData subdataWithRange:NSMakeRange((NSUInteger)moddedOffset, streamSize)];
                uint64_t newOffset = targetResSData.length;
                [targetResSData appendData:bytes];
                tat_write_u64_le(payload, streamFieldPos, newOffset);
            }
        }
        return payload;
    }

    // kTAT2ClassIDTexture2D from here on.
    NSUInteger moddedStreamFieldPos;
    BOOL moddedStreams = moddedResSData && tat_find_stream_data_offset_field(moddedBytes, &moddedStreamFieldPos);
    NSError *headerErr = nil;
    Texture2DHeader *moddedHeader = [Texture2DHeader parseHeaderInObjectBytes:moddedBytes
                                                                        profile:profile
                                                     streamDataOffsetFieldPos:moddedStreams ? moddedStreamFieldPos : NSNotFound
                                                                          error:&headerErr];
    if (!moddedHeader) {
        ZLog(@"[TextureAtlasTransplant] new pathID %lld: Texture2D header parse failed (%@) - skipping", (long long)moddedObj.pathID, headerErr.localizedDescription);
        *outOutcome = TATNewObjectHeaderParseFailed;
        return nil;
    }

    NSData *moddedPixelBytes = nil;
    if (moddedStreams) {
        uint64_t moddedOffset = tat_read_u64_le(moddedBytes, moddedStreamFieldPos);
        uint32_t streamSize = tat_read_u32_le(moddedBytes, moddedStreamFieldPos + 8);
        if (moddedOffset + streamSize <= moddedResSData.length) {
            moddedPixelBytes = [moddedResSData subdataWithRange:NSMakeRange((NSUInteger)moddedOffset, streamSize)];
        }
    } else if (moddedHeader.imageDataLength > 0) {
        moddedPixelBytes = [moddedBytes subdataWithRange:NSMakeRange(moddedHeader.imageDataOffset, moddedHeader.imageDataLength)];
    }
    if (!moddedPixelBytes) {
        ZLog(@"[TextureAtlasTransplant] new pathID %lld: couldn't locate modded Texture2D's own pixel bytes - skipping", (long long)moddedObj.pathID);
        *outOutcome = TATNewObjectFormatUnsupported;
        return nil;
    }

    NSError *decodeErr = nil;
    NSData *rgba32 = [Texture2DPixelDecoder decodeToRGBA32FromRawFormat:moddedHeader.rawFormat
                                                              sourceBytes:moddedPixelBytes
                                                                    width:moddedHeader.width
                                                                   height:moddedHeader.height
                                                                    error:&decodeErr];
    if (!rgba32) {
        ZLog(@"[TextureAtlasTransplant] new pathID %lld: Texture2D format %d not decodable (%@) - skipping", (long long)moddedObj.pathID, moddedHeader.rawFormat, decodeErr.localizedDescription);
        *outOutcome = TATNewObjectFormatUnsupported;
        return nil;
    }

    TAT2PackedFormat packedFormat;
    NSData *packed = [RawPixelPacker packRGBA32Pixels:rgba32 width:moddedHeader.width height:moddedHeader.height outFormat:&packedFormat];
    if (!packed) {
        ZLog(@"[TextureAtlasTransplant] new pathID %lld: RawPixelPacker rejected %dx%d - skipping", (long long)moddedObj.pathID, moddedHeader.width, moddedHeader.height);
        *outOutcome = TATNewObjectFormatUnsupported;
        return nil;
    }

    NSMutableData *newObjectBytes;
    if (targetHasResS) {
        // File-level convention (no per-object target precedent exists
        // for a brand-new object) - see .h item 3. StreamingInfo is
        // ALWAYS rebuilt fresh here (never modded's own raw tail, even
        // when modded itself streamed) because its path text encodes
        // MODDED's own CAB identity - reusing it verbatim would point
        // target's runtime loader at an archive it doesn't have. Only
        // the numeric offset/size need to be right for
        // tat_find_stream_data_offset_field's own (path-agnostic)
        // detection to work again later; Unity's real loader also needs
        // the path text itself correct, hence rebuilding it against
        // targetResSArchivePath rather than skipping that part as
        // "cosmetic."
        NSUInteger oldArrayEnd = moddedHeader.imageDataOffset + moddedHeader.imageDataLength;
        NSMutableData *rebuilt = [[moddedBytes subdataWithRange:NSMakeRange(0, moddedHeader.imageDataLengthFieldOffset)] mutableCopy];
        [rebuilt increaseLengthBy:4]; // image data length prefix -> 0 (pixels live in .resS now)
        tat_write_u32_le(rebuilt, moddedHeader.imageDataLengthFieldOffset, 0);
        uint64_t newOffset = targetResSData.length;
        [targetResSData appendData:packed];
        NSData *pathBytes = [targetResSArchivePath dataUsingEncoding:NSUTF8StringEncoding];
        [rebuilt increaseLengthBy:8]; // StreamData.offset
        tat_write_u64_le(rebuilt, rebuilt.length - 8, newOffset);
        [rebuilt increaseLengthBy:4]; // StreamData.size
        tat_write_u32_le(rebuilt, rebuilt.length - 4, (uint32_t)packed.length);
        [rebuilt increaseLengthBy:4]; // path length prefix
        tat_write_u32_le(rebuilt, rebuilt.length - 4, (uint32_t)pathBytes.length);
        [rebuilt appendData:pathBytes];
        NSUInteger pad = (4 - (rebuilt.length % 4)) % 4;
        static const uint8_t kZeros[4] = {0, 0, 0, 0};
        if (pad) [rebuilt appendBytes:kZeros length:pad];
        (void)oldArrayEnd; // unused on this branch (target's array is always truncated to empty, not sliced) - kept named for symmetry with the inline branch below
        newObjectBytes = rebuilt;
    } else {
        NSUInteger oldArrayEnd = moddedHeader.imageDataOffset + moddedHeader.imageDataLength;
        NSUInteger oldAlignedEnd = (oldArrayEnd + 3) & ~(NSUInteger)3;
        NSData *trailing = (oldAlignedEnd < moddedBytes.length)
            ? [moddedBytes subdataWithRange:NSMakeRange(oldAlignedEnd, moddedBytes.length - oldAlignedEnd)]
            : [NSData data];
        NSMutableData *rebuilt = [[moddedBytes subdataWithRange:NSMakeRange(0, moddedHeader.imageDataLengthFieldOffset)] mutableCopy];
        [rebuilt increaseLengthBy:4];
        tat_write_u32_le(rebuilt, moddedHeader.imageDataLengthFieldOffset, (uint32_t)packed.length);
        [rebuilt appendData:packed];
        NSUInteger pad = (4 - (rebuilt.length % 4)) % 4;
        static const uint8_t kZeros[4] = {0, 0, 0, 0};
        if (pad) [rebuilt appendBytes:kZeros length:pad];
        // If modded ITSELF streamed, its trailing StreamingInfo bytes
        // (now stale/unused since this new object is going inline) are
        // deliberately dropped rather than carried over - trailing here
        // only ever meant "whatever came after the inline array", which
        // for a streamed modded object is nothing of the sort.
        if (!moddedStreams) [rebuilt appendData:trailing];
        newObjectBytes = rebuilt;
    }

    [moddedHeader patchWidth:moddedHeader.width
                       height:moddedHeader.height
            completeImageSize:(int32_t)packed.length
                       format:(int32_t)packedFormat
                     mipCount:1
                inObjectBytes:newObjectBytes];

    ZLog(@"[TextureAtlasTransplant] new pathID %lld: Texture2D %dx%d format %d re-encoded -> format %d (%lu bytes, streamed=%d)",
         (long long)moddedObj.pathID, moddedHeader.width, moddedHeader.height, moddedHeader.rawFormat,
         packedFormat, (unsigned long)packed.length, targetHasResS);
    return newObjectBytes;
}

#pragma mark - the actual per-bundle transplant

// Reassembles `archive` into a fresh UnityBundleArchive, substituting
// `newCABData`/`newResSData` for whichever of archive.nodes matches
// cabNodePath/resSNodePath (nil resSNodeData/path if there's no .resS
// node to substitute), and leaving every other node's bytes untouched.
// Building a whole new concatenated buffer (rather than shifting bytes
// in place within the existing one) sidesteps having to re-derive every
// OTHER node's offset by hand when the patched node(s) grow - appending
// in original node order and recording each node's actual new offset
// as it's appended keeps that bookkeeping trivial and correct by
// construction instead.
static UnityBundleArchive *tat_rebuild_archive(UnityBundleArchive *archive,
                                                NSString *cabNodePath, NSData *newCABData,
                                                NSString * _Nullable resSNodePath, NSData * _Nullable newResSData) {
    NSMutableData *newData = [NSMutableData data];
    NSMutableArray<UnityBundleNode *> *newNodes = [NSMutableArray array];

    for (UnityBundleNode *node in archive.nodes) {
        NSData *bytes;
        if ([node.path isEqualToString:cabNodePath]) {
            bytes = newCABData;
        } else if (resSNodePath && [node.path isEqualToString:resSNodePath]) {
            bytes = newResSData;
        } else {
            bytes = tat_node_slice(archive, node);
        }
        UnityBundleNode *newNode = [UnityBundleNode new];
        newNode.path = node.path;
        newNode.offset = (int64_t)newData.length;
        newNode.size = (int64_t)bytes.length;
        [newData appendData:bytes];
        [newNodes addObject:newNode];
    }

    UnityBundleArchive *out = [UnityBundleArchive new];
    out.unityVersion = archive.unityVersion;
    out.unityRevision = archive.unityRevision;
    out.data = newData;
    out.nodes = newNodes;
    return out;
}

static TextureAtlasTransplantResult *tat_transplant_one(NSString *cachedPath,
                                                          NSString *cab,
                                                          UnityBundleArchive *moddedArchive,
                                                          NSData *moddedCABData,
                                                          SerializedObjectTable *moddedTable,
                                                          TAT2VersionProfile profile, // resolved once per Unity build - see tat_resolve_profile
                                                          NSString *backupDir) {
    TextureAtlasTransplantResult *result = [TextureAtlasTransplantResult new];
    result.cachedPath = cachedPath;

    // Backup first, same timing as every other Transplant class - see
    // this file's header note.
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:backupDir]) {
        NSError *dirErr = nil;
        if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            result.error = TATError(TextureAtlasTransplantErrorBackupFailed, dirErr.localizedDescription ?: @"couldn't create backup directory");
            return result;
        }
    }
    NSString *cacheDir = [BundleTransplant unityCacheSharedDirectory];
    NSString *relPath = [cachedPath hasPrefix:cacheDir] ? [cachedPath substringFromIndex:cacheDir.length] : cachedPath;
    if ([relPath hasPrefix:@"/"]) relPath = [relPath substringFromIndex:1];
    // Same flattening BundleTransplant.h's own backups use (see its
    // bt2_backup_path_for_data_path) - "/" -> "%2F" so a nested relative
    // path collapses to one flat filename, reversible for restore.
    NSString *encodedRel = [[relPath stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"] stringByAppendingString:@".atlasbak"];
    NSString *backupPath = [backupDir stringByAppendingPathComponent:encodedRel];
    if (![fm fileExistsAtPath:backupPath]) {
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:cachedPath toPath:backupPath error:&copyErr]) {
            result.error = TATError(TextureAtlasTransplantErrorBackupFailed, copyErr.localizedDescription ?: @"backup copy failed");
            return result;
        }
    }

    NSError *readErr = nil;
    UnityBundleArchive *targetArchive = [UnityBundleCAB decompressedArchiveAtPath:cachedPath error:&readErr];
    if (!targetArchive) {
        result.error = readErr ?: TATError(TextureAtlasTransplantErrorModdedCABFailed, @"couldn't decompress target archive");
        return result;
    }

    UnityBundleNode *targetCABNode = targetArchive.nodes.firstObject; // node 0 is always the archive's own identity - see UnityBundleCAB.h
    if (!targetCABNode) {
        result.error = TATError(TextureAtlasTransplantErrorModdedCABFailed, @"target archive has no nodes");
        return result;
    }
    NSString *resSNodePath = [cab stringByAppendingString:@".resS"];
    UnityBundleNode *targetResSNode = tat_find_node(targetArchive, resSNodePath);
    UnityBundleNode *moddedResSNode = tat_find_node(moddedArchive, resSNodePath);

    NSMutableData *targetCABData = [tat_node_slice(targetArchive, targetCABNode) mutableCopy];
    NSMutableData *targetResSData = targetResSNode ? [tat_node_slice(targetArchive, targetResSNode) mutableCopy] : [NSMutableData data];
    NSData *moddedResSData = moddedResSNode ? tat_node_slice(moddedArchive, moddedResSNode) : nil;

    NSError *tableErr = nil;
    SerializedObjectTable *targetTable = [SerializedObjectTable tableForSerializedFileNodeData:targetCABData error:&tableErr];
    if (!targetTable) {
        result.error = tableErr ?: TATError(TextureAtlasTransplantErrorModdedTableFailed, @"couldn't locate target's object table");
        return result;
    }
    if (!targetTable.typesResolved) {
        result.error = TATError(TextureAtlasTransplantErrorModdedTableFailed, @"couldn't resolve target bundle's Unity class IDs (m_Types) - see Verbose log");
        return result;
    }

    NSString *targetResSArchivePath = targetResSNode ? [NSString stringWithFormat:@"archive:/%@/%@", cab, resSNodePath] : nil;
    NSMutableArray<SerializedObject *> *pendingNewObjects = [NSMutableArray array];
    NSMutableArray<NSData *> *pendingNewPayloads = [NSMutableArray array];

    for (SerializedObject *moddedObj in moddedTable.objects) {
      @autoreleasepool {
        // Entry 5 fix: every iteration through this loop can decode a
        // full-resolution RGBA32 scratch buffer (Texture2DPixelDecoder)
        // and re-pack it (RawPixelPacker) - both autoreleased NSData.
        // With no pool here, none of that is freed until
        // tat_transplant_one itself returns, so a bundle with hundreds
        // of large textures keeps every single decode/pack scratch
        // buffer alive simultaneously on top of targetCABData/
        // targetResSData. Draining per-object keeps only the current
        // object's scratch buffers resident. See overview.md Entry 4/5.
        SerializedObject *targetObj = [targetTable objectWithPathID:moddedObj.pathID];
        if (!targetObj) {
            if (!moddedObj.classIDResolved || (moddedObj.classID != kTAT2ClassIDTexture2D && moddedObj.classID != kTAT2ClassIDTextAsset)) {
                result.objectsSkippedWrongType++;
                continue; // same type filter as the diff path below - see .h "1) Type filtering"
            }
            NSData *moddedBytes = [moddedCABData subdataWithRange:NSMakeRange((NSUInteger)(moddedTable.dataOffset + moddedObj.byteStart), moddedObj.byteSize)];
            TATNewObjectOutcome outcome;
            NSData *payload = tat_build_new_object_payload(moddedObj, moddedBytes, moddedResSData,
                                                             targetResSNode != nil, targetResSArchivePath,
                                                             targetResSData, profile, &outcome);
            if (!payload) {
                if (outcome == TATNewObjectHeaderParseFailed) result.objectsAddedTexture2DHeaderParseFailed++;
                else result.objectsAddedTexture2DFormatUnsupported++;
                result.objectsSkippedNotInTarget++;
                continue;
            }
            SerializedObject *newEntry = [SerializedObject new];
            newEntry.pathID = moddedObj.pathID;
            // NOTE: still modded's own raw typeID (an index into MODDED's
            // m_Types array), written as-is into TARGET's table by
            // -insertObjects:... Now that classID is resolved, this
            // could instead look up TARGET's own type index for
            // moddedObj.classID (via a reverse map this file doesn't
            // build) - not done here since this pass only covers
            // resolving classID at parse time, but it's the same
            // index-vs-file mistake this file's top note describes,
            // just in the one path classID resolution doesn't reach yet.
            newEntry.typeID = moddedObj.typeID;
            [pendingNewObjects addObject:newEntry];
            [pendingNewPayloads addObject:payload];
            continue;
        }
        // Type filter - see kTAT2ClassIDTexture2D/kTAT2ClassIDTextAsset's
        // comment above. Filtering on moddedObj.classID alone (not also
        // checking targetObj.classID) is deliberate: a PathID shared
        // across a stock/mod pair is always the same underlying asset,
        // just re-serialized - this project has never seen a PathID
        // change class between the two (same assumption
        // TextureAtlasTransplant.h's top comment already makes for
        // PathID identity generally) - and moddedTable.typesResolved is
        // already required (checked in +transplantFromModdedBundleAtURL:)
        // so moddedObj.classIDResolved is trustworthy here.
        if (!moddedObj.classIDResolved || (moddedObj.classID != kTAT2ClassIDTexture2D && moddedObj.classID != kTAT2ClassIDTextAsset)) {
            result.objectsSkippedWrongType++;
            continue;
        }
        result.objectsInspected++;

        NSData *moddedBytes = [moddedCABData subdataWithRange:NSMakeRange((NSUInteger)(moddedTable.dataOffset + moddedObj.byteStart), moddedObj.byteSize)];
        NSData *targetBytes = [targetCABData subdataWithRange:NSMakeRange((NSUInteger)(targetTable.dataOffset + targetObj.byteStart), targetObj.byteSize)];
        if ([moddedBytes isEqualToData:targetBytes]) continue; // identical - nothing to do

        if (moddedObj.classID == kTAT2ClassIDTexture2D) {
            // Parse both sides' headers before touching anything - (a)
            // confirms the resolved profile (see tat_resolve_profile)
            // against this pair, (b) gives
            // modded's declared format/dimensions for the decode step
            // below, and (c) gives target's own field offsets/streaming
            // shape for the patch step, which is NOT assumed to match
            // modded's (a streamed PC object and an inline iOS object
            // sharing a PathID is unremarkable - each platform's own
            // importer settings decide that independently).
            NSUInteger moddedStreamFieldPos;
            BOOL moddedStreams = moddedResSData && tat_find_stream_data_offset_field(moddedBytes, &moddedStreamFieldPos);
            NSError *moddedHeaderErr = nil;
            Texture2DHeader *moddedHeader = [Texture2DHeader parseHeaderInObjectBytes:moddedBytes
                                                                                profile:profile
                                                             streamDataOffsetFieldPos:moddedStreams ? moddedStreamFieldPos : NSNotFound
                                                                                  error:&moddedHeaderErr];
            NSUInteger targetStreamFieldPos;
            BOOL targetStreams = targetResSNode && tat_find_stream_data_offset_field(targetBytes, &targetStreamFieldPos);
            NSError *targetHeaderErr = nil;
            Texture2DHeader *targetHeader = [Texture2DHeader parseHeaderInObjectBytes:targetBytes
                                                                                profile:profile
                                                             streamDataOffsetFieldPos:targetStreams ? targetStreamFieldPos : NSNotFound
                                                                                  error:&targetHeaderErr];
            if (!moddedHeader || !targetHeader) {
                result.texture2DHeaderParseFailed++;
                ZLog(@"[TextureAtlasTransplant] pathID %lld: Texture2D header parse failed (modded: %@, target: %@) - skipping (resolved profile for this Unity version didn't fit this object)",
                     (long long)moddedObj.pathID, moddedHeaderErr.localizedDescription, targetHeaderErr.localizedDescription);
                continue;
            }

            // Locate modded's own base-mip pixel bytes, wherever they
            // actually live (its .resS range, or its own inline
            // imageData array) - this is independent of where TARGET's
            // pixels live, which is handled separately below.
            NSData *moddedPixelBytes = nil;
            if (moddedStreams) {
                uint64_t moddedOffset = tat_read_u64_le(moddedBytes, moddedStreamFieldPos);
                uint32_t streamSize = tat_read_u32_le(moddedBytes, moddedStreamFieldPos + 8);
                if (moddedOffset + streamSize <= moddedResSData.length) {
                    moddedPixelBytes = [moddedResSData subdataWithRange:NSMakeRange((NSUInteger)moddedOffset, streamSize)];
                }
            } else if (moddedHeader.imageDataLength > 0) {
                moddedPixelBytes = [moddedBytes subdataWithRange:NSMakeRange(moddedHeader.imageDataOffset, moddedHeader.imageDataLength)];
            }
            if (!moddedPixelBytes) {
                result.texture2DFormatUnsupported++;
                ZLog(@"[TextureAtlasTransplant] pathID %lld: couldn't locate modded Texture2D's own pixel bytes (streamed=%d) - skipping",
                     (long long)moddedObj.pathID, moddedStreams);
                continue;
            }

            NSError *decodeErr = nil;
            NSData *rgba32 = [Texture2DPixelDecoder decodeToRGBA32FromRawFormat:moddedHeader.rawFormat
                                                                      sourceBytes:moddedPixelBytes
                                                                            width:moddedHeader.width
                                                                           height:moddedHeader.height
                                                                            error:&decodeErr];
            if (!rgba32) {
                // Most notably DXT5Crunched (29) - see
                // Texture2DPixelDecoder.h's top comment on why that one
                // is refused rather than guessed at. Target is left
                // completely untouched, same as any other skip here.
                result.texture2DFormatUnsupported++;
                ZLog(@"[TextureAtlasTransplant] pathID %lld: Texture2D format %d not decodable (%@) - skipping",
                     (long long)moddedObj.pathID, moddedHeader.rawFormat, decodeErr.localizedDescription);
                continue;
            }

            TAT2PackedFormat packedFormat;
            NSData *packed = [RawPixelPacker packRGBA32Pixels:rgba32 width:moddedHeader.width height:moddedHeader.height outFormat:&packedFormat];
            if (!packed) {
                ZLog(@"[TextureAtlasTransplant] pathID %lld: RawPixelPacker rejected %dx%d - skipping", (long long)moddedObj.pathID, moddedHeader.width, moddedHeader.height);
                continue;
            }

            // Rebuild TARGET's own object bytes around the new payload
            // - everything about the object other than the five header
            // fields and the pixel bytes themselves (name, flags,
            // GLTextureSettings, platform blob, ...) travels through
            // untouched, same "whole-object copy, PathID does the
            // work" philosophy as every other transplant in this file.
            NSMutableData *newObjectBytes;
            if (targetStreams) {
                // Target streams via its own .resS - append the new
                // payload there (same accumulation array the verbatim
                // TextAsset path below uses) and repoint BOTH
                // StreamData fields: offset (grew) and size (this
                // project's packed output is essentially never the
                // same byte count as target's old ASTC data, unlike
                // the verbatim-copy path where the appended length and
                // the declared size always agree by construction).
                newObjectBytes = [targetBytes mutableCopy];
                uint64_t newOffset = targetResSData.length;
                [targetResSData appendData:packed];
                tat_write_u64_le(newObjectBytes, targetStreamFieldPos, newOffset);
                tat_write_u32_le(newObjectBytes, targetStreamFieldPos + 8, (uint32_t)packed.length);
            } else {
                // Target's pixels are its own inline imageData array -
                // rebuild around a differently-sized one. Nothing
                // before the array's length prefix moves (that's where
                // -patchWidth:...: below writes, all fixed-size fields
                // unaffected by the array's own length changing), so
                // slicing target's own prefix verbatim and reassembling
                // is enough - see Texture2DFields.h's own doc on
                // -patchWidth:...: for why this ordering is safe.
                NSUInteger oldArrayEnd = targetHeader.imageDataOffset + targetHeader.imageDataLength;
                NSUInteger oldAlignedEnd = (oldArrayEnd + 3) & ~(NSUInteger)3;
                NSData *trailing = (oldAlignedEnd < targetBytes.length)
                    ? [targetBytes subdataWithRange:NSMakeRange(oldAlignedEnd, targetBytes.length - oldAlignedEnd)]
                    : [NSData data];

                NSMutableData *rebuilt = [[targetBytes subdataWithRange:NSMakeRange(0, targetHeader.imageDataLengthFieldOffset)] mutableCopy];
                [rebuilt increaseLengthBy:4]; // placeholder for the length prefix, filled in below
                tat_write_u32_le(rebuilt, targetHeader.imageDataLengthFieldOffset, (uint32_t)packed.length);
                [rebuilt appendData:packed];
                NSUInteger pad = (4 - (rebuilt.length % 4)) % 4;
                static const uint8_t kZeros[4] = {0, 0, 0, 0};
                if (pad) [rebuilt appendBytes:kZeros length:pad];
                [rebuilt appendData:trailing];
                newObjectBytes = rebuilt;
            }

            [targetHeader patchWidth:moddedHeader.width
                               height:moddedHeader.height
                    completeImageSize:(int32_t)packed.length
                               format:(int32_t)packedFormat
                             mipCount:1
                        inObjectBytes:newObjectBytes];

            int64_t newByteStart = targetCABData.length;
            [targetCABData appendData:newObjectBytes];
            NSError *patchErr = nil;
            if (![targetTable patchObject:targetObj newByteStart:newByteStart newByteSize:(uint32_t)newObjectBytes.length inNodeData:targetCABData error:&patchErr]) {
                ZLog(@"[TextureAtlasTransplant] failed to patch table entry for pathID %lld: %@", (long long)moddedObj.pathID, patchErr.localizedDescription);
                continue;
            }
            result.objectsTransplanted++;
            ZLog(@"[TextureAtlasTransplant] pathID %lld: Texture2D %dx%d format %d re-encoded -> format %d (%lu bytes, streamed=%d)",
                 (long long)moddedObj.pathID, moddedHeader.width, moddedHeader.height, moddedHeader.rawFormat,
                 packedFormat, (unsigned long)packed.length, targetStreams);
            continue;
        }

        // typeID == kTAT2ClassIDTextAsset from here on - identical bytes
        // on both platforms (see this file's header note), so the
        // existing verbatim copy is exactly right, unchanged.
        NSUInteger streamFieldPos;
        NSMutableData *payload = [moddedBytes mutableCopy];
        if (moddedResSData && tat_find_stream_data_offset_field(moddedBytes, &streamFieldPos)) {
            uint64_t moddedOffset = tat_read_u64_le(moddedBytes, streamFieldPos);
            uint32_t streamSize = tat_read_u32_le(moddedBytes, streamFieldPos + 8);
            if (moddedOffset + streamSize <= moddedResSData.length) {
                NSData *pixelBytes = [moddedResSData subdataWithRange:NSMakeRange((NSUInteger)moddedOffset, streamSize)];
                uint64_t newOffset = targetResSData.length;
                [targetResSData appendData:pixelBytes];
                tat_write_u64_le(payload, streamFieldPos, newOffset);
            } else {
                ZLog(@"[TextureAtlasTransplant] pathID %lld looked streamed but its StreamData range didn't fit modded's .resS - copying inline as-is", (long long)moddedObj.pathID);
            }
        }

        int64_t newByteStart = targetCABData.length;
        [targetCABData appendData:payload];
        NSError *patchErr = nil;
        if (![targetTable patchObject:targetObj newByteStart:newByteStart newByteSize:(uint32_t)payload.length inNodeData:targetCABData error:&patchErr]) {
            ZLog(@"[TextureAtlasTransplant] failed to patch table entry for pathID %lld: %@", (long long)moddedObj.pathID, patchErr.localizedDescription);
            continue;
        }
        result.objectsTransplanted++;
      } // @autoreleasepool
    }

    if (pendingNewObjects.count > 0) {
        NSError *insertErr = nil;
        if ([targetTable insertObjects:pendingNewObjects payloads:pendingNewPayloads inNodeData:targetCABData error:&insertErr]) {
            result.objectsAdded += pendingNewObjects.count;
            result.objectsTransplanted += pendingNewObjects.count;
        } else {
            // Verify failed or the count field couldn't be located -
            // see SerializedObjectTable.h's -insertObjects:... doc.
            // targetCABData is guaranteed untouched by that method on
            // failure, so every diffed swap collected above is still
            // safe to write out below; only the additions are dropped.
            BOOL collision = (insertErr.code == SOTErrorInsertVerifyFailed);
            for (NSUInteger i = 0; i < pendingNewObjects.count; i++) {
                if (collision) result.objectsAddedPathIDCollision++;
                result.objectsSkippedNotInTarget++;
            }
            ZLog(@"[TextureAtlasTransplant] %@: couldn't add %lu new object(s): %@", cachedPath, (unsigned long)pendingNewObjects.count, insertErr.localizedDescription);
        }
    }

    if (result.objectsTransplanted == 0) {
        return result; // nothing actually changed - don't touch the file
    }

    UnityBundleArchive *rebuilt = tat_rebuild_archive(targetArchive, targetCABNode.path, targetCABData,
                                                       targetResSNode ? resSNodePath : nil,
                                                       targetResSNode ? targetResSData : nil);

    // Entry 5 fix: tat_rebuild_archive already copied every byte of
    // targetCABData/targetResSData into rebuilt.data (see its
    // appendData: loop over archive.nodes) - neither is read again
    // below. Dropping these references here lets ARC free the two
    // largest buffers in this function (up to ~bundle-size each)
    // before +writeArchive:toPath: runs, instead of keeping them
    // resident alongside rebuilt.data (and, previously, alongside
    // writeArchive's own internal full-size copy - see
    // UnityBundleCAB.m's Entry 5 fix) all the way to the write.
    targetCABData = nil;
    targetResSData = nil;

    NSError *writeErr = nil;
    if (![UnityBundleCAB writeArchive:rebuilt toPath:cachedPath error:&writeErr]) {
        result.error = writeErr ?: TATError(TextureAtlasTransplantErrorWriteFailed, @"write failed");
        return result;
    }

    ZLog(@"[TextureAtlasTransplant] %@: transplanted %ld/%ld objects (%ld not present in target, %ld skipped wrong type, %ld Texture2D header parse failed, %ld Texture2D format unsupported)",
          cachedPath, (long)result.objectsTransplanted, (long)result.objectsInspected, (long)result.objectsSkippedNotInTarget,
          (long)result.objectsSkippedWrongType, (long)result.texture2DHeaderParseFailed, (long)result.texture2DFormatUnsupported);
    return result;
}

#pragma mark - public API

@implementation TextureAtlasTransplantResult
@end

@implementation TextureAtlasTransplant

+ (NSString *)atlasBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityAtlasBackups"];
}

+ (nullable NSArray<TextureAtlasTransplantResult *> *)transplantFromModdedBundleAtURL:(NSURL *)moddedURL error:(NSError **)error {
    BOOL accessing = [moddedURL startAccessingSecurityScopedResource];
    UnityBundleArchive *moddedArchive = [UnityBundleCAB decompressedArchiveAtPath:moddedURL.path error:error];
    if (accessing) [moddedURL stopAccessingSecurityScopedResource];
    if (!moddedArchive) {
        if (error && !*error) *error = TATError(TextureAtlasTransplantErrorCantReadModded, @"couldn't read/decompress modded bundle");
        return nil;
    }

    UnityBundleNode *moddedCABNode = moddedArchive.nodes.firstObject;
    if (!moddedCABNode) {
        if (error) *error = TATError(TextureAtlasTransplantErrorModdedCABFailed, @"modded archive has no nodes");
        return nil;
    }
    NSString *cab = moddedCABNode.path;
    NSData *moddedCABData = tat_node_slice(moddedArchive, moddedCABNode);

    NSError *tableErr = nil;
    SerializedObjectTable *moddedTable = [SerializedObjectTable tableForSerializedFileNodeData:moddedCABData error:&tableErr];
    if (!moddedTable) {
        if (error) *error = tableErr ?: TATError(TextureAtlasTransplantErrorModdedTableFailed, @"couldn't locate modded file's object table");
        return nil;
    }
    if (!moddedTable.typesResolved) {
        // Every object's classIDResolved is NO in this case - proceeding
        // would silently skip every Texture2D/TextAsset as "wrong type"
        // again (see this file's top note on why that's exactly the bug
        // this project hit). Fail loudly here instead - see Verbose log
        // for why the m_Types walk didn't cross-validate.
        if (error) *error = TATError(TextureAtlasTransplantErrorModdedTableFailed, @"couldn't resolve modded bundle's Unity class IDs (m_Types) - see Verbose log");
        return nil;
    }

    NSString *cacheDir = [BundleTransplant unityCacheSharedDirectory];
    if (![NSFileManager.defaultManager fileExistsAtPath:cacheDir]) {
        if (error) *error = TATError(TextureAtlasTransplantErrorNoCacheDirectory, @"Library/UnityCache/Shared doesn't exist yet");
        return nil;
    }

    // Resolved once per modded bundle (cached per unityVersion, so
    // repeat mod installs against the same game build skip
    // re-detection entirely) - see tat_resolve_profile. Needs
    // moddedResSData for the streamDataPositionConfirmed cross-check,
    // same .resS node every match below would otherwise look up
    // individually since it only depends on moddedArchive/cab, not on
    // which cached target bundle is being patched.
    NSString *moddedResSNodePath = [cab stringByAppendingString:@".resS"];
    UnityBundleNode *moddedResSNode = tat_find_node(moddedArchive, moddedResSNodePath);
    NSData *moddedResSData = moddedResSNode ? tat_node_slice(moddedArchive, moddedResSNode) : nil;
    TAT2VersionProfile profile = tat_resolve_profile(moddedArchive, moddedCABData, moddedTable, moddedResSData);

    NSArray<NSString *> *matches = tat_find_cached_paths_for_cab(cab, cacheDir);
    NSString *backupDir = [self atlasBackupDirectory];

    NSMutableArray<TextureAtlasTransplantResult *> *results = [NSMutableArray array];
    for (NSString *cachedPath in matches) {
        [results addObject:tat_transplant_one(cachedPath, cab, moddedArchive, moddedCABData, moddedTable, profile, backupDir)];
    }
    return results;
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    NSString *backupDir = [self atlasBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:backupDir]) return 0;

    NSString *cacheDir = [BundleTransplant unityCacheSharedDirectory];
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: TATError(TextureAtlasTransplantErrorBackupFailed, @"couldn't list backup directory");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *encodedRel in entries) {
        if (![encodedRel hasSuffix:@".atlasbak"]) continue;
        NSString *flat = [encodedRel substringToIndex:encodedRel.length - @".atlasbak".length];
        NSString *relPath = [flat stringByReplacingOccurrencesOfString:@"%2F" withString:@"/"];
        NSString *targetPath = [cacheDir stringByAppendingPathComponent:relPath];
        NSString *backupPath = [backupDir stringByAppendingPathComponent:encodedRel];
        NSError *copyErr = nil;
        [fm removeItemAtPath:targetPath error:nil];
        if ([fm copyItemAtPath:backupPath toPath:targetPath error:&copyErr]) {
            restored++;
        } else {
            ZLog(@"[TextureAtlasTransplant] restore: couldn't restore %@: %@", targetPath, copyErr.localizedDescription);
        }
    }
    return restored;
}

+ (NSInteger)restoreBackedUpBundlesForCAB:(NSString *)cab error:(NSError **)error {
    NSString *backupDir = [self atlasBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:backupDir]) return 0;

    NSString *cacheDir = [BundleTransplant unityCacheSharedDirectory];
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: TATError(TextureAtlasTransplantErrorBackupFailed, @"couldn't list backup directory");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *encodedRel in entries) {
        if (![encodedRel hasSuffix:@".atlasbak"]) continue;
        NSString *backupPath = [backupDir stringByAppendingPathComponent:encodedRel];

        // The backup is untouched stock bytes, so reading its CAB gives
        // the same identity the modded file was matched against at
        // transplant time - no need to touch the live (possibly
        // already object-patched) __data to find out which entries
        // belong to this CAB.
        NSError *cabErr = nil;
        NSString *entryCAB = [UnityBundleCAB primaryCABForBundleAtPath:backupPath error:&cabErr];
        if (!entryCAB || ![entryCAB isEqualToString:cab]) continue;

        NSString *flat = [encodedRel substringToIndex:encodedRel.length - @".atlasbak".length];
        NSString *relPath = [flat stringByReplacingOccurrencesOfString:@"%2F" withString:@"/"];
        NSString *targetPath = [cacheDir stringByAppendingPathComponent:relPath];

        NSError *copyErr = nil;
        [fm removeItemAtPath:targetPath error:nil];
        if ([fm copyItemAtPath:backupPath toPath:targetPath error:&copyErr]) {
            restored++;
        } else {
            ZLog(@"[TextureAtlasTransplant] restore: couldn't restore %@: %@", targetPath, copyErr.localizedDescription);
        }
    }
    return restored;
}

@end
