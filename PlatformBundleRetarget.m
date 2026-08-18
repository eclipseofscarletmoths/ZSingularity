// PlatformBundleRetarget.m
//
// See PlatformBundleRetarget.h for the design. The per-object rebuild
// below (steps: locate pixel bytes -> decode -> RawPixelPacker ->
// patchWidth:height:...:inObjectBytes: -> append+repoint) is the SAME
// sequence TextureAtlasTransplant.m's tat_transplant_one already uses
// for an existing shared PathID whose content changed size - this file
// duplicates the handful of small helpers that logic depends on
// (u32/u64 LE read/write, node lookup/slice) rather than exporting them
// from that file, same "~20 duplicated lines is simpler than
// restructuring" call TextureAtlasTransplant.m's own top comment
// already made about BundleTransplant.m.
//
// ONE IMPORTANT SIMPLIFICATION VS. TextureAtlasTransplant.m: this file
// NEVER keeps a retargeted Texture2D streamed via .resS, even if the
// source object was. TextureAtlasTransplant.m has to preserve target's
// existing streamed/inline shape because target is a real mobile bundle
// something else already depends on being laid out a specific way; here
// there is no such constraint - the object is being rebuilt from
// scratch, RawPixelPacker's output is small (16-bit packed, single mip,
// see that header), and always going inline means never touching the
// .resS node or its own byte length at all. The tradeoff: any pixel
// bytes the retargeted object used to occupy in .resS are simply
// orphaned (dead space, never read again, no cleanup attempted) rather
// than reclaimed - same "append new, don't compact old" posture
// SerializedObjectTable.h's -insertObjects:... and
// -patchObject:...:'s own doc already accept for the CAB node itself.

#import "PlatformBundleRetarget.h"
#import "UnityBundleCAB.h"
#import "SerializedObjectTable.h"
#import "Texture2DFields.h"
#import "Texture2DPixelDecoder.h"
#import "RawPixelPacker.h"
#import "ZTweakLog.h"

NSString * const PlatformBundleRetargetErrorDomain = @"PlatformBundleRetargetErrorDomain";

static const int32_t kPBRClassIDTexture2D = 28;

// The two formats RawPixelPacker.h can ever produce - see that header.
// A Texture2D already in one of these is almost certainly the output of
// an earlier retarget pass over the same bundle; re-running the decoder
// on it isn't supported (Texture2DPixelDecoder.h doesn't claim these as
// decodable source formats - they were never a real Unity platform's
// stock format, only this project's own output) and isn't needed either
// way, so it's counted and left untouched rather than attempted.
static BOOL pbr_format_is_already_packed(int32_t rawFormat) {
    return rawFormat == TAT2PackedFormatRGB565 || rawFormat == TAT2PackedFormatARGB4444;
}

static NSError *PBRError(PlatformBundleRetargetErrorCode code, NSString *message) {
    return [NSError errorWithDomain:PlatformBundleRetargetErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - small helpers (see this file's top comment on duplication)

static void pbr_write_u32_le(NSMutableData *data, NSUInteger pos, uint32_t v) {
    uint8_t *p = (uint8_t *)data.mutableBytes + pos;
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static UnityBundleNode *pbr_find_node(UnityBundleArchive *archive, NSString *path) {
    for (UnityBundleNode *n in archive.nodes) {
        if ([n.path isEqualToString:path]) return n;
    }
    return nil;
}

static NSData *pbr_node_slice(UnityBundleArchive *archive, UnityBundleNode *node) {
    return [archive.data subdataWithRange:NSMakeRange((NSUInteger)node.offset, (NSUInteger)node.size)];
}

// Same StreamingInfo "archive:/...resS" pattern-match
// TextureAtlasTransplant.m's tat_find_stream_data_offset_field uses
// (see that function's own top comment for the i-16 vs i-12 field-math
// bug this project already hit and fixed once) - duplicated here only
// to LOCATE a streamed source object's existing pixel bytes for
// decoding; this file never writes a new StreamingInfo (see this file's
// top comment on always going inline).
static BOOL pbr_find_stream_data_offset_field(NSData *objectBytes, NSUInteger *outOffsetFieldPos) {
    static const char *kNeedle = "archive:/";
    NSUInteger needleLen = strlen(kNeedle);
    const uint8_t *base = (const uint8_t *)objectBytes.bytes;
    NSUInteger len = objectBytes.length;
    if (len < needleLen + 4) return NO;

    for (NSUInteger i = 0; i + needleLen <= len; i++) {
        if (memcmp(base + i, kNeedle, needleLen) != 0) continue;
        if (i < 16) continue;
        uint32_t declaredLen = (uint32_t)base[i-4] | ((uint32_t)base[i-3] << 8) | ((uint32_t)base[i-2] << 16) | ((uint32_t)base[i-1] << 24);
        if (declaredLen == 0 || i + declaredLen > len) continue;
        if (declaredLen < needleLen) continue;
        *outOffsetFieldPos = i - 16;
        return YES;
    }
    return NO;
}

static uint64_t pbr_read_u64_le(NSData *data, NSUInteger pos) {
    const uint8_t *p = (const uint8_t *)data.bytes + pos;
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static uint32_t pbr_read_u32_le(NSData *data, NSUInteger pos) {
    const uint8_t *p = (const uint8_t *)data.bytes + pos;
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

@implementation PlatformBundleRetargetResult {
@public
    NSString *_cab;
    NSInteger _texture2DCount;
    NSInteger _texture2DRetargeted;
    NSInteger _texture2DAlreadyPacked;
    NSInteger _texture2DHeaderParseFailed;
    NSInteger _texture2DFormatUnsupported;
}
- (NSString *)cab { return _cab; }
- (NSInteger)texture2DCount { return _texture2DCount; }
- (NSInteger)texture2DRetargeted { return _texture2DRetargeted; }
- (NSInteger)texture2DAlreadyPacked { return _texture2DAlreadyPacked; }
- (NSInteger)texture2DHeaderParseFailed { return _texture2DHeaderParseFailed; }
- (NSInteger)texture2DFormatUnsupported { return _texture2DFormatUnsupported; }
@end

@implementation PlatformBundleRetarget

+ (BOOL)retargetDesktopBundleAtPath:(NSString *)desktopBundlePath
                      targetPlatform:(int32_t)targetPlatform
                              toPath:(NSString *)outPath
                              result:(PlatformBundleRetargetResult * _Nullable * _Nullable)outResult
                               error:(NSError **)error {
    NSError *archiveErr = nil;
    UnityBundleArchive *archive = [UnityBundleCAB decompressedArchiveAtPath:desktopBundlePath error:&archiveErr];
    if (!archive) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorArchiveReadFailed, archiveErr.localizedDescription ?: @"couldn't read/decompress archive");
        return NO;
    }

    NSError *cabErr = nil;
    NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:desktopBundlePath error:&cabErr];
    UnityBundleNode *cabNode = cab ? pbr_find_node(archive, cab) : nil;
    if (!cabNode) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorNoCABNode, @"couldn't locate this archive's own primary CAB node");
        return NO;
    }

    // .resS is only ever a SOURCE of existing pixel bytes here (a
    // streamed object being converted to inline) - see this file's top
    // comment on why nothing is ever written back into it. Unlike an
    // earlier version of this function, this does NOT eagerly copy the
    // whole .resS node into its own buffer up front - resSNode/archive
    // are kept instead, and each object's pixel bytes are sliced
    // straight out of archive.data (still the OS-mapped/decompressed
    // buffer from decompressedArchiveAtPath:error:) only when that
    // object actually needs them, in the per-object loop below. For a
    // bundle with hundreds of streamed textures, a multi-hundred-MB
    // .resS node no longer has to be resident as a second full copy for
    // the entire duration of the retarget just so a handful of bytes at
    // a time can be read out of it.
    NSString *resSNodePath = [cab stringByAppendingString:@".resS"];
    UnityBundleNode *resSNode = pbr_find_node(archive, resSNodePath);

    NSMutableData *cabData = [pbr_node_slice(archive, cabNode) mutableCopy];

    NSError *tableErr = nil;
    SerializedObjectTable *table = [SerializedObjectTable tableForSerializedFileNodeData:cabData error:&tableErr];
    if (!table) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorTableParseFailed, tableErr.localizedDescription ?: @"couldn't parse this bundle's object table");
        return NO;
    }
    if (!table.typesResolved) {
        // Refuse rather than guess which typeID index means Texture2D -
        // same posture SerializedObjectTable.h's own top comment already
        // takes for -insertObjects:...'s count-field lookup.
        if (error) *error = PBRError(PlatformBundleRetargetErrorTypesUnresolved, @"m_Types walk didn't resolve for this bundle - can't identify Texture2D objects by real classID, refusing rather than guessing by typeID");
        return NO;
    }
    if (!table.targetPlatformFieldOffsetKnown) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorTargetPlatformFieldUnknown, @"m_TargetPlatform's offset wasn't resolved for this bundle");
        return NO;
    }

    PlatformBundleRetargetResult *result = [PlatformBundleRetargetResult new];
    result->_cab = cab;

    // Step 1: the SerializedFile header's own m_TargetPlatform - a
    // single in-place int32 write, no size change, nothing downstream
    // shifts.
    pbr_write_u32_le(cabData, (NSUInteger)table.targetPlatformFieldOffset, (uint32_t)targetPlatform);

    // Step 2: profile detection against THIS bundle's own Texture2D
    // samples - see this file's .h top comment for why this is stronger
    // ground than TextureAtlasTransplant.m's original hardcoded-default
    // bug (overview.md's root-cause entry): there is no cross-file
    // "modded vs. target" agreement question here, only "does this
    // Unity build's own layout self-validate against its own objects."
    //
    // FIXED 2026-08-18 (see overview.md Entry 12): this used to take the
    // first kSampleTarget Texture2D objects in table order, full stop -
    // it never preferred objects where pbr_find_stream_data_offset_field
    // actually succeeds, even though Texture2DFields.h's own doc comment
    // on +detectVersionProfile:... says callers "should prefer at least
    // 5-10 streamed objects" specifically because a non-streaming sample
    // only exercises detectVersionProfile:'s WEAK width/height/format
    // plausibility check, not the strong streamDataPositionConfirmed
    // cross-check. If a bundle's first kSampleTarget objects in table
    // order happen to be small non-streamed textures (common - small UI
    // sprites often have their pixel data inline rather than externally
    // streamed), detection was silently running on the weak check alone
    // for all 10 samples, which - per +detectVersionProfile:'s own
    // degeneracy warning - lets through far more than the usual ~45/512
    // wrong-but-plausible candidates. This is exactly what real device
    // logs showed: profile "detection" succeeding, then every
    // large/streamed modded texture (evaluated later, once the wrong
    // profile is already locked in) failing streamDataPositionConfirmed
    // by a small constant delta - a missing/miscounted field the WRONG
    // profile doesn't account for, not an offset-finder bug (both
    // pbr_find_stream_data_offset_field here and
    // tat_find_stream_data_offset_field in TextureAtlasTransplant.m
    // already carry Entry 3's correct 16-byte StreamingInfo layout fix,
    // confirmed again this session by hand-decoding several DIAG dumps -
    // offset/size/pathLen all read as plausible values once you're past
    // the independently-found position).
    //
    // Fix: two-pass collection. Prefer objects where
    // pbr_find_stream_data_offset_field succeeds (so detection actually
    // exercises the strong check) up to kSampleTarget; only top up with
    // non-streaming objects if the bundle doesn't have enough streamed
    // Texture2D objects to fill the target.
    NSMutableArray<NSData *> *samples = [NSMutableArray array];
    NSMutableArray<NSNumber *> *samplePositions = [NSMutableArray array];
    NSMutableArray<NSData *> *fallbackSamples = [NSMutableArray array];
    NSMutableArray<NSNumber *> *fallbackSamplePositions = [NSMutableArray array];
    static const NSUInteger kSampleTarget = 10;
    for (SerializedObject *obj in table.objects) {
        if (!obj.classIDResolved || obj.classID != kPBRClassIDTexture2D) continue;
        if (samples.count >= kSampleTarget) break;
        NSData *bytes = [cabData subdataWithRange:NSMakeRange((NSUInteger)(table.dataOffset + obj.byteStart), obj.byteSize)];
        NSUInteger streamPos = NSNotFound;
        BOOL streams = resSNode && pbr_find_stream_data_offset_field(bytes, &streamPos);
        if (streams) {
            [samples addObject:bytes];
            [samplePositions addObject:@(streamPos)];
        } else if (fallbackSamples.count < kSampleTarget) {
            [fallbackSamples addObject:bytes];
            [fallbackSamplePositions addObject:@(NSNotFound)];
        }
    }
    NSUInteger streamedSampleCount = samples.count;
    while (samples.count < kSampleTarget && fallbackSamples.count > 0) {
        [samples addObject:fallbackSamples.firstObject];
        [samplePositions addObject:fallbackSamplePositions.firstObject];
        [fallbackSamples removeObjectAtIndex:0];
        [fallbackSamplePositions removeObjectAtIndex:0];
    }
    if (streamedSampleCount == 0) {
        ZLog(@"[PlatformBundleRetarget] %@: no streamed Texture2D samples found for detection (%lu non-streaming sample(s) used instead) - detection is running on width/height/format plausibility only, results are weaker than usual",
             cab, (unsigned long)samples.count);
    }

    TAT2VersionProfile profile;
    if (![Texture2DHeader detectVersionProfile:&profile fromObjectSamples:samples streamDataOffsetFieldPositions:samplePositions]) {
        profile = kTAT2ProfileDefault;
        ZLog(@"[PlatformBundleRetarget] %@: profile detection inconclusive (%lu Texture2D sample(s)) - falling back to kTAT2ProfileDefault; expect per-object parse failures below if this build's layout differs",
             cab, (unsigned long)samples.count);
    } else {
        ZLog(@"[PlatformBundleRetarget] %@: detected TAT2VersionProfile from %lu Texture2D sample(s)", cab, (unsigned long)samples.count);
    }

    // Step 3: walk every Texture2D and rebuild it in place.
    //
    // MEMORY FIX (this session, see overview.md): every iteration used to
    // leave its Texture2DPixelDecoder/RawPixelPacker scratch buffers
    // (roughly width*height*4 bytes each for the RGBA32 intermediate
    // alone) autoreleased but undrained until this whole function
    // returned - for "hundreds of images" in one bundle, all of those
    // stayed resident simultaneously, on top of cabData itself. Wrapping
    // the loop body in its own @autoreleasepool drains each object's
    // scratch memory the moment that object is done, the same fix
    // Entry 4/5 already applied to TextureAtlasTransplant.m's equivalent
    // loop - this file just never got it since it was written afterward.
    for (SerializedObject *obj in table.objects) {
        @autoreleasepool {
        if (!obj.classIDResolved || obj.classID != kPBRClassIDTexture2D) continue;
        result->_texture2DCount++;

        NSData *objBytesConst = [cabData subdataWithRange:NSMakeRange((NSUInteger)(table.dataOffset + obj.byteStart), obj.byteSize)];
        NSUInteger streamFieldPos = NSNotFound;
        BOOL streams = resSNode && pbr_find_stream_data_offset_field(objBytesConst, &streamFieldPos);

        NSError *headerErr = nil;
        Texture2DHeader *header = [Texture2DHeader parseHeaderInObjectBytes:objBytesConst
                                                                      profile:profile
                                                    streamDataOffsetFieldPos:streams ? streamFieldPos : NSNotFound
                                                                        error:&headerErr];
        if (!header) {
            result->_texture2DHeaderParseFailed++;
            ZLog(@"[PlatformBundleRetarget] pathID %lld: Texture2D header parse failed (%@) - skipping, left as-is",
                 (long long)obj.pathID, headerErr.localizedDescription);
            continue;
        }

        if (pbr_format_is_already_packed(header.rawFormat)) {
            result->_texture2DAlreadyPacked++;
            continue;
        }

        NSData *pixelBytes = nil;
        if (streams) {
            uint64_t off = pbr_read_u64_le(objBytesConst, streamFieldPos);
            uint32_t size = pbr_read_u32_le(objBytesConst, streamFieldPos + 8);
            // Sliced straight out of archive.data (the decompressed
            // source buffer) for just this one object's window, instead
            // of out of a pre-copied whole-.resS buffer - see the
            // resSNode comment above.
            if ((int64_t)off + size <= resSNode.size) {
                pixelBytes = [archive.data subdataWithRange:NSMakeRange((NSUInteger)(resSNode.offset + (int64_t)off), size)];
            }
        } else if (header.imageDataLength > 0) {
            pixelBytes = [objBytesConst subdataWithRange:NSMakeRange(header.imageDataOffset, header.imageDataLength)];
        }
        if (!pixelBytes) {
            result->_texture2DFormatUnsupported++;
            ZLog(@"[PlatformBundleRetarget] pathID %lld: couldn't locate this object's own pixel bytes (streamed=%d) - skipping",
                 (long long)obj.pathID, streams);
            continue;
        }

        NSError *decodeErr = nil;
        NSData *rgba32 = [Texture2DPixelDecoder decodeToRGBA32FromRawFormat:header.rawFormat
                                                                  sourceBytes:pixelBytes
                                                                        width:header.width
                                                                       height:header.height
                                                                        error:&decodeErr];
        if (!rgba32) {
            result->_texture2DFormatUnsupported++;
            ZLog(@"[PlatformBundleRetarget] pathID %lld: format %d not decodable (%@) - skipping, left as-is",
                 (long long)obj.pathID, header.rawFormat, decodeErr.localizedDescription);
            continue;
        }

        TAT2PackedFormat packedFormat;
        NSData *packed = [RawPixelPacker packRGBA32Pixels:rgba32 width:header.width height:header.height outFormat:&packedFormat];
        if (!packed) {
            ZLog(@"[PlatformBundleRetarget] pathID %lld: RawPixelPacker rejected %dx%d - skipping, left as-is", (long long)obj.pathID, header.width, header.height);
            continue;
        }

        // Rebuild this object's own bytes around the new (always inline
        // now, see top comment) payload. Everything before the image
        // data length prefix is untouched bytes from objBytesConst
        // itself - there is no separate "target" template here, the
        // object is its own template, same as
        // TextureAtlasTransplant.m's inline-rebuild branch but sourced
        // from one object instead of two.
        NSMutableData *rebuilt = [[objBytesConst subdataWithRange:NSMakeRange(0, header.imageDataLengthFieldOffset)] mutableCopy];
        [rebuilt increaseLengthBy:4]; // length-prefix placeholder, filled below
        pbr_write_u32_le(rebuilt, header.imageDataLengthFieldOffset, (uint32_t)packed.length);
        [rebuilt appendData:packed];
        NSUInteger pad = (4 - (rebuilt.length % 4)) % 4;
        static const uint8_t kZeros[4] = {0, 0, 0, 0};
        if (pad) [rebuilt appendBytes:kZeros length:pad];
        // Deliberately nothing appended after this even if `streams` was
        // YES for the source object - dropping m_StreamData entirely
        // (going inline) means whatever used to follow it in this
        // object's own byte range doesn't exist for Texture2D at all
        // (StreamingInfo is the last field when present - see
        // Texture2DFields.h's struct comment), so there is no trailing
        // region to preserve the way the inline branch above has to.

        [header patchWidth:header.width
                     height:header.height
          completeImageSize:(int32_t)packed.length
                      format:(int32_t)packedFormat
                    mipCount:1
               inObjectBytes:rebuilt];

        int64_t newByteStart = (int64_t)cabData.length - table.dataOffset;
        [cabData appendData:rebuilt];
        NSError *patchErr = nil;
        if (![table patchObject:obj newByteStart:newByteStart newByteSize:(uint32_t)rebuilt.length inNodeData:cabData error:&patchErr]) {
            ZLog(@"[PlatformBundleRetarget] pathID %lld: table patch failed (%@) - object bytes were appended but not repointed, this object is now effectively lost from the table; treating as a hard failure",
                 (long long)obj.pathID, patchErr.localizedDescription);
            if (error) *error = patchErr;
            return NO;
        }
        result->_texture2DRetargeted++;
        } // @autoreleasepool
    }

    if (outResult) *outResult = result;

    // Final write: stream straight to outPath instead of building one
    // more full-bundle-size buffer first (an earlier version of this
    // function built `newData` here by re-copying cabData's bytes AND
    // every other node's bytes into a second combined buffer, which sat
    // alongside cabData - already grown by every retargeted texture in
    // the bundle - right at the moment of peak memory use; see
    // overview.md). `newNodes` below only needs final offset/size per
    // entry, which is known from lengths alone; the actual bytes are
    // fetched by +writeArchiveStreamingToPath:...: one node at a time,
    // written straight to disk, and released before the next node is
    // even requested. cabData (already resident, already grown) is
    // handed back as-is when its node comes up rather than copied again;
    // every OTHER node is sliced fresh from archive.data on demand
    // rather than pre-copied - this is the "let the disk do the work"
    // option the earlier all-in-memory approach didn't have.
    NSMutableArray<UnityBundleNode *> *newNodes = [NSMutableArray array];
    int64_t runningOffset = 0;
    for (UnityBundleNode *node in archive.nodes) {
        int64_t size = [node.path isEqualToString:cab] ? (int64_t)cabData.length : node.size;
        UnityBundleNode *newNode = [UnityBundleNode new];
        newNode.path = node.path;
        newNode.offset = runningOffset;
        newNode.size = size;
        runningOffset += size;
        [newNodes addObject:newNode];
    }

    NSError *writeErr = nil;
    BOOL wrote = [UnityBundleCAB writeArchiveStreamingToPath:outPath
                                                 unityVersion:archive.unityVersion
                                                unityRevision:archive.unityRevision
                                                        nodes:newNodes
                                              nodeDataAtIndex:^NSData * _Nullable(NSUInteger idx) {
        UnityBundleNode *srcNode = archive.nodes[idx];
        if ([srcNode.path isEqualToString:cab]) return cabData;
        return pbr_node_slice(archive, srcNode);
    }
                                                        error:&writeErr];
    cabData = nil; // no longer needed once the write loop above has consumed it
    if (!wrote) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorArchiveWriteFailed, writeErr.localizedDescription ?: @"couldn't write retargeted archive");
        return NO;
    }

    ZLog(@"[PlatformBundleRetarget] %@: retargeted %ld/%ld Texture2D object(s) (%ld already packed, %ld header parse failed, %ld format unsupported), m_TargetPlatform -> %d",
         cab, (long)result->_texture2DRetargeted, (long)result->_texture2DCount,
         (long)result->_texture2DAlreadyPacked, (long)result->_texture2DHeaderParseFailed, (long)result->_texture2DFormatUnsupported,
         targetPlatform);

    return YES;
}

@end
