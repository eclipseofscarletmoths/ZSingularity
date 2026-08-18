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

+ (nullable UnityBundleArchive *)retargetedArchiveFromDesktopBundleAtPath:(NSString *)desktopBundlePath
                                                            targetPlatform:(int32_t)targetPlatform
                                                                    result:(PlatformBundleRetargetResult * _Nullable * _Nullable)outResult
                                                                     error:(NSError **)error {
    NSError *archiveErr = nil;
    UnityBundleArchive *archive = [UnityBundleCAB decompressedArchiveAtPath:desktopBundlePath error:&archiveErr];
    if (!archive) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorArchiveReadFailed, archiveErr.localizedDescription ?: @"couldn't read/decompress archive");
        return nil;
    }

    NSError *cabErr = nil;
    NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:desktopBundlePath error:&cabErr];
    UnityBundleNode *cabNode = cab ? pbr_find_node(archive, cab) : nil;
    if (!cabNode) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorNoCABNode, @"couldn't locate this archive's own primary CAB node");
        return nil;
    }

    // .resS is only ever a SOURCE of existing pixel bytes here (a
    // streamed object being converted to inline) - see this file's top
    // comment on why nothing is ever written back into it.
    NSString *resSNodePath = [cab stringByAppendingString:@".resS"];
    UnityBundleNode *resSNode = pbr_find_node(archive, resSNodePath);
    NSData *resSData = resSNode ? pbr_node_slice(archive, resSNode) : nil;

    NSMutableData *cabData = [pbr_node_slice(archive, cabNode) mutableCopy];

    NSError *tableErr = nil;
    SerializedObjectTable *table = [SerializedObjectTable tableForSerializedFileNodeData:cabData error:&tableErr];
    if (!table) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorTableParseFailed, tableErr.localizedDescription ?: @"couldn't parse this bundle's object table");
        return nil;
    }
    if (!table.typesResolved) {
        // Refuse rather than guess which typeID index means Texture2D -
        // same posture SerializedObjectTable.h's own top comment already
        // takes for -insertObjects:...'s count-field lookup.
        if (error) *error = PBRError(PlatformBundleRetargetErrorTypesUnresolved, @"m_Types walk didn't resolve for this bundle - can't identify Texture2D objects by real classID, refusing rather than guessing by typeID");
        return nil;
    }
    if (!table.targetPlatformFieldOffsetKnown) {
        if (error) *error = PBRError(PlatformBundleRetargetErrorTargetPlatformFieldUnknown, @"m_TargetPlatform's offset wasn't resolved for this bundle");
        return nil;
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
    NSMutableArray<NSData *> *samples = [NSMutableArray array];
    NSMutableArray<NSNumber *> *samplePositions = [NSMutableArray array];
    static const NSUInteger kSampleTarget = 10;
    for (SerializedObject *obj in table.objects) {
        if (!obj.classIDResolved || obj.classID != kPBRClassIDTexture2D) continue;
        if (samples.count >= kSampleTarget) break;
        NSData *bytes = [cabData subdataWithRange:NSMakeRange((NSUInteger)(table.dataOffset + obj.byteStart), obj.byteSize)];
        NSUInteger streamPos = NSNotFound;
        if (resSData) pbr_find_stream_data_offset_field(bytes, &streamPos);
        [samples addObject:bytes];
        [samplePositions addObject:@(streamPos)];
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
    for (SerializedObject *obj in table.objects) {
        if (!obj.classIDResolved || obj.classID != kPBRClassIDTexture2D) continue;
        result->_texture2DCount++;

        NSData *objBytesConst = [cabData subdataWithRange:NSMakeRange((NSUInteger)(table.dataOffset + obj.byteStart), obj.byteSize)];
        NSUInteger streamFieldPos = NSNotFound;
        BOOL streams = resSData && pbr_find_stream_data_offset_field(objBytesConst, &streamFieldPos);

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
            if (off + size <= resSData.length) {
                pixelBytes = [resSData subdataWithRange:NSMakeRange((NSUInteger)off, size)];
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
            return nil;
        }
        result->_texture2DRetargeted++;
    }

    if (outResult) *outResult = result;

    // Single-node rebuild (only cabData changed) - same
    // append-in-original-order-and-record-new-offsets approach
    // TextureAtlasTransplant.m's tat_rebuild_archive uses, just inlined
    // here since only one node ever needs substituting in this file
    // (see top comment on why .resS is never written to).
    NSMutableData *newData = [NSMutableData data];
    NSMutableArray<UnityBundleNode *> *newNodes = [NSMutableArray array];
    for (UnityBundleNode *node in archive.nodes) {
        NSData *bytes = [node.path isEqualToString:cab] ? cabData : pbr_node_slice(archive, node);
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

    ZLog(@"[PlatformBundleRetarget] %@: retargeted %ld/%ld Texture2D object(s) (%ld already packed, %ld header parse failed, %ld format unsupported), m_TargetPlatform -> %d",
         cab, (long)result->_texture2DRetargeted, (long)result->_texture2DCount,
         (long)result->_texture2DAlreadyPacked, (long)result->_texture2DHeaderParseFailed, (long)result->_texture2DFormatUnsupported,
         targetPlatform);

    return out;
}

@end
