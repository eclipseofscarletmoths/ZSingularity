
#import "UnityBundleCAB.h"
#import "LZ4BlockDecoder.h"
#import "ZTweakLog.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <objc/runtime.h>

#import "lz4hc.h"

NSString * const UnityBundleCABErrorDomain = @"UnityBundleCABErrorDomain";
NSString * const UnityBundleCABLZMAPropertiesErrorKey = @"UnityBundleCABLZMAPropertiesErrorKey";

#pragma mark - LZMA properties header (detection/extraction only - no decoder)

@interface UBCLZMAProperties ()
@property (nonatomic, assign, readwrite) uint8_t propertyByte;
@property (nonatomic, assign, readwrite) uint8_t lc;
@property (nonatomic, assign, readwrite) uint8_t lp;
@property (nonatomic, assign, readwrite) uint8_t pb;
@property (nonatomic, assign, readwrite) uint32_t dictionarySize;
@property (nonatomic, copy, readwrite) NSData *headerBytes;
@end

@implementation UBCLZMAProperties
@end

static UBCLZMAProperties *ubc_parse_lzma_properties(const uint8_t *bytes, size_t length) {
    if (length < 5) return nil;

    uint8_t propertyByte = bytes[0];
    uint32_t dictionarySize = (uint32_t)bytes[1] | ((uint32_t)bytes[2] << 8) |
                               ((uint32_t)bytes[3] << 16) | ((uint32_t)bytes[4] << 24);

    uint32_t d = propertyByte;
    uint8_t lc = (uint8_t)(d % 9);
    d /= 9;
    uint8_t lp = (uint8_t)(d % 5);
    uint8_t pb = (uint8_t)(d / 5);

    UBCLZMAProperties *props = [UBCLZMAProperties new];
    props.propertyByte = propertyByte;
    props.lc = lc;
    props.lp = lp;
    props.pb = pb;
    props.dictionarySize = dictionarySize;
    props.headerBytes = [NSData dataWithBytes:bytes length:5];
    return props;
}

static NSError *ubc_lzma_detected_error(NSString *what, UBCLZMAProperties * _Nullable props) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:
        @"%@ uses LZMA compression (type 1) - accurately detected and its properties header was extracted, "
         "but this project has no LZMA decoder, so it cannot be decompressed. See UnityBundleCAB.h.", what];
    if (props) userInfo[UnityBundleCABLZMAPropertiesErrorKey] = props;
    return [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorLZMADetected userInfo:userInfo];
}

#pragma mark - Bounds-checked cursor over an in-memory buffer

typedef struct {
    const uint8_t *base;
    size_t size;
    size_t pos;
} UBCCursor;

static BOOL ubc_need(UBCCursor *c, size_t n) {
    return n <= c->size - c->pos;
}

static BOOL ubc_read_u8(UBCCursor *c, uint8_t *out) {
    if (!ubc_need(c, 1)) return NO;
    *out = c->base[c->pos++];
    return YES;
}

static BOOL ubc_read_u16_be(UBCCursor *c, uint16_t *out) {
    if (!ubc_need(c, 2)) return NO;
    *out = (uint16_t)((c->base[c->pos] << 8) | c->base[c->pos + 1]);
    c->pos += 2;
    return YES;
}

static BOOL ubc_read_u32_be(UBCCursor *c, uint32_t *out) {
    if (!ubc_need(c, 4)) return NO;
    *out = ((uint32_t)c->base[c->pos] << 24) | ((uint32_t)c->base[c->pos + 1] << 16) |
           ((uint32_t)c->base[c->pos + 2] << 8) | (uint32_t)c->base[c->pos + 3];
    c->pos += 4;
    return YES;
}

static BOOL ubc_read_i64_be(UBCCursor *c, int64_t *out) {
    if (!ubc_need(c, 8)) return NO;
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | c->base[c->pos + i];
    c->pos += 8;
    *out = (int64_t)v;
    return YES;
}

static BOOL ubc_skip(UBCCursor *c, size_t n) {
    if (!ubc_need(c, n)) return NO;
    c->pos += n;
    return YES;
}

static BOOL ubc_read_cstring(UBCCursor *c, NSString **out) {
    size_t start = c->pos;
    while (c->pos < c->size && c->base[c->pos] != 0) c->pos++;
    if (c->pos >= c->size) return NO;
    NSString *s = [[NSString alloc] initWithBytes:c->base + start
                                             length:c->pos - start
                                           encoding:NSUTF8StringEncoding];
    c->pos += 1;
    if (!s) return NO;
    *out = s;
    return YES;
}

#pragma mark - Header + blocks-info parsing

typedef struct {
    uint32_t compressedBlocksInfoSize;
    uint32_t uncompressedBlocksInfoSize;
    uint8_t  compressionType;
    BOOL     blocksInfoAtEnd;
    BOOL     dataNeedsPaddingAtStart;
    size_t   headerEndPos;
} UBCHeader;

static BOOL ubc_parse_header(UBCCursor *c, UBCHeader *out, NSString **outUnityVersion, NSString **outUnityRevision, NSError **error) {
    static const char kSig[] = "UnityFS";
    if (!ubc_need(c, sizeof(kSig))) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorTooSmall userInfo:nil];
        return NO;
    }
    if (memcmp(c->base + c->pos, kSig, sizeof(kSig)) != 0) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorBadSignature userInfo:nil];
        return NO;
    }
    c->pos += sizeof(kSig);

    uint32_t formatVersion;
    NSString *unityVersion, *unityRevision;
    int64_t archiveSize;
    uint32_t compressedBlocksInfoSize, uncompressedBlocksInfoSize, flags;

    if (!ubc_read_u32_be(c, &formatVersion) ||
        !ubc_read_cstring(c, &unityVersion) ||
        !ubc_read_cstring(c, &unityRevision) ||
        !ubc_read_i64_be(c, &archiveSize) ||
        !ubc_read_u32_be(c, &compressedBlocksInfoSize) ||
        !ubc_read_u32_be(c, &uncompressedBlocksInfoSize) ||
        !ubc_read_u32_be(c, &flags)) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorTooSmall userInfo:nil];
        return NO;
    }
    (void)formatVersion;
    if (outUnityVersion) *outUnityVersion = unityVersion;
    if (outUnityRevision) *outUnityRevision = unityRevision;

    BOOL blocksInfoAtEnd = (flags & 0x80) != 0;

    BOOL dataNeedsPaddingAtStart = (flags & 0x200) != 0;

    {
        size_t rem = c->pos % 16;
        if (rem != 0) {
            if (!ubc_skip(c, 16 - rem)) {
                if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorTooSmall userInfo:nil];
                return NO;
            }
        }
    }

    out->compressedBlocksInfoSize = compressedBlocksInfoSize;
    out->uncompressedBlocksInfoSize = uncompressedBlocksInfoSize;
    out->compressionType = (uint8_t)(flags & 0x3F);
    out->blocksInfoAtEnd = blocksInfoAtEnd;
    out->dataNeedsPaddingAtStart = dataNeedsPaddingAtStart;
    out->headerEndPos = c->pos;
    return YES;
}

static NSData *ubc_extract_blocks_info(NSData *fileData, const UBCHeader *header, NSError **error) {
    size_t fileSize = fileData.length;
    size_t blobStart;
    if (header->blocksInfoAtEnd) {
        if (header->compressedBlocksInfoSize > fileSize) {
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
            return nil;
        }
        blobStart = fileSize - header->compressedBlocksInfoSize;
    } else {
        blobStart = header->headerEndPos;
    }
    if (blobStart > fileSize || header->compressedBlocksInfoSize > fileSize - blobStart) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
        return nil;
    }

    const uint8_t *blobBytes = (const uint8_t *)fileData.bytes + blobStart;

    switch (header->compressionType) {
        case 0: {
            if (header->compressedBlocksInfoSize != header->uncompressedBlocksInfoSize) {
                ZLog(@"[UnityBundleCAB] compression=none but compressed(%u) != uncompressed(%u) size - reading uncompressedSize bytes anyway",
                      header->compressedBlocksInfoSize, header->uncompressedBlocksInfoSize);
            }
            size_t n = MIN(header->compressedBlocksInfoSize, header->uncompressedBlocksInfoSize);
            return [NSData dataWithBytes:blobBytes length:n];
        }
        case 2:
        case 3: {
            NSMutableData *out = [NSMutableData dataWithLength:header->uncompressedBlocksInfoSize];
            if (header->uncompressedBlocksInfoSize > 0) {
                int written = LZ4BlockDecompress(blobBytes, header->compressedBlocksInfoSize,
                                                   (uint8_t *)out.mutableBytes, header->uncompressedBlocksInfoSize);
                if (written < 0 || (uint32_t)written != header->uncompressedBlocksInfoSize) {
                    if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorDecompressFailed userInfo:nil];
                    return nil;
                }
            }
            return out;
        }
        case 1: {
            UBCLZMAProperties *props = ubc_parse_lzma_properties(blobBytes, header->compressedBlocksInfoSize);
            ZLog(@"[UnityBundleCAB] blocks-info is LZMA-compressed: lc=%u lp=%u pb=%u dictionarySize=%u",
                 props.lc, props.lp, props.pb, props.dictionarySize);
            if (error) *error = ubc_lzma_detected_error(@"Bundle's blocks-info", props);
            return nil;
        }
        default:
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorUnsupportedCompression userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Bundle uses compression type %u (not none/LZMA/LZ4/LZ4HC) - unsupported, see UnityBundleCAB.h", header->compressionType]
            }];
            return nil;
    }
}

static NSArray<NSString *> *ubc_parse_node_paths(NSData *blocksInfo, NSError **error) {
    UBCCursor c = { .base = blocksInfo.bytes, .size = blocksInfo.length, .pos = 0 };

    if (!ubc_skip(&c, 16)) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
        return nil;
    }

    uint32_t blockCount;
    if (!ubc_read_u32_be(&c, &blockCount)) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
        return nil;
    }
    for (uint32_t i = 0; i < blockCount; i++) {
        uint32_t uSize, cSize; uint16_t bFlags;
        if (!ubc_read_u32_be(&c, &uSize) || !ubc_read_u32_be(&c, &cSize) || !ubc_read_u16_be(&c, &bFlags)) {
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
            return nil;
        }
    }

    uint32_t nodeCount;
    if (!ubc_read_u32_be(&c, &nodeCount)) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
        return nil;
    }

    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:nodeCount];
    for (uint32_t i = 0; i < nodeCount; i++) {
        int64_t nOffset, nSize; uint32_t nFlags; NSString *path;
        if (!ubc_read_i64_be(&c, &nOffset) || !ubc_read_i64_be(&c, &nSize) ||
            !ubc_read_u32_be(&c, &nFlags) || !ubc_read_cstring(&c, &path)) {
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
            return nil;
        }
        [paths addObject:path];
    }

    if (paths.count == 0) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorNoNodes userInfo:nil];
        return nil;
    }
    return paths;
}

static NSArray<NSString *> *ubc_all_node_paths(NSString *path, NSError **error) {
    NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!fileData) {
        if (error && !*error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return nil;
    }

    UBCCursor c = { .base = fileData.bytes, .size = fileData.length, .pos = 0 };
    UBCHeader header;
    if (!ubc_parse_header(&c, &header, NULL, NULL, error)) return nil;

    NSData *blocksInfo = ubc_extract_blocks_info(fileData, &header, error);
    if (!blocksInfo) return nil;

    return ubc_parse_node_paths(blocksInfo, error);
}

#pragma mark - Full data-block decompression (offset/size, not just names)

typedef struct { uint32_t uSize, cSize; uint16_t bFlags; } UBCBlockEntry;

static BOOL ubc_parse_blocks_info_full(NSData *blocksInfo,
                                        NSMutableArray<NSValue *> *outBlocks,
                                        NSMutableArray<UnityBundleNode *> *outNodes,
                                        NSError **error) {
    UBCCursor c = { .base = blocksInfo.bytes, .size = blocksInfo.length, .pos = 0 };
    if (!ubc_skip(&c, 16)) goto malformed;

    uint32_t blockCount;
    if (!ubc_read_u32_be(&c, &blockCount)) goto malformed;
    for (uint32_t i = 0; i < blockCount; i++) {
        UBCBlockEntry be;
        if (!ubc_read_u32_be(&c, &be.uSize) || !ubc_read_u32_be(&c, &be.cSize) || !ubc_read_u16_be(&c, &be.bFlags)) goto malformed;
        [outBlocks addObject:[NSValue valueWithBytes:&be objCType:@encode(UBCBlockEntry)]];
    }

    uint32_t nodeCount;
    if (!ubc_read_u32_be(&c, &nodeCount)) goto malformed;
    for (uint32_t i = 0; i < nodeCount; i++) {
        int64_t nOffset, nSize; uint32_t nFlags; NSString *path;
        if (!ubc_read_i64_be(&c, &nOffset) || !ubc_read_i64_be(&c, &nSize) ||
            !ubc_read_u32_be(&c, &nFlags) || !ubc_read_cstring(&c, &path)) goto malformed;
        UnityBundleNode *node = [UnityBundleNode new];
        node.path = path; node.offset = nOffset; node.size = nSize; node.flags = nFlags;
        [outNodes addObject:node];
    }
    if (outNodes.count == 0) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorNoNodes userInfo:nil];
        return NO;
    }
    return YES;

malformed:
    if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
    return NO;
}

static BOOL ubc_write_one_data_block(NSFileHandle *fh, const uint8_t *base, size_t fileSize,
                                      size_t *cursor, UBCBlockEntry be, NSUInteger blockIndex, NSError **error) {
    if (*cursor > fileSize || be.cSize > fileSize - *cursor) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Data block %lu runs past end of file: cursor=%zu, declared compressed size=%u, file size=%zu.",
                (unsigned long)blockIndex, *cursor, be.cSize, fileSize]
        }];
        return NO;
    }
    const uint8_t *blockBytes = base + *cursor;
    uint8_t compType = (uint8_t)(be.bFlags & 0x3F);
    @try {
        switch (compType) {
            case 0: {
                size_t n = MIN(be.cSize, be.uSize);

                [fh writeData:[NSData dataWithBytesNoCopy:(void *)blockBytes length:n freeWhenDone:NO]];
                break;
            }
            case 2:
            case 3: {
                NSMutableData *chunk = [NSMutableData dataWithLength:be.uSize];
                if (be.uSize > 0) {
                    int written = LZ4BlockDecompress(blockBytes, be.cSize, (uint8_t *)chunk.mutableBytes, be.uSize);
                    if (written < 0 || (uint32_t)written != be.uSize) {
                        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorDecompressFailed userInfo:nil];
                        return NO;
                    }
                }
                [fh writeData:chunk];
                break;
            }
            case 1: {
                UBCLZMAProperties *props = ubc_parse_lzma_properties(blockBytes, be.cSize);
                ZLog(@"[UnityBundleCAB] data block is LZMA-compressed: lc=%u lp=%u pb=%u dictionarySize=%u",
                     props.lc, props.lp, props.pb, props.dictionarySize);
                if (error) *error = ubc_lzma_detected_error(@"A data block", props);
                return NO;
            }
            default:
                if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorUnsupportedCompression userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Data block uses compression type %u (not none/LZMA/LZ4/LZ4HC) - unsupported, see UnityBundleCAB.h", compType]
                }];
                return NO;
        }
    } @catch (NSException *exc) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"write failed"}];
        return NO;
    }
    *cursor += be.cSize;
    return YES;
}

static NSString *ubc_decompress_data_blocks_to_temp_file(NSData *fileData,
                                                           const UBCHeader *header,
                                                           NSArray<NSValue *> *blocks,
                                                           NSError **error) {

    size_t dataStart = header->headerEndPos;
    if (!header->blocksInfoAtEnd) {
        dataStart += header->compressedBlocksInfoSize;
    }
    if (header->dataNeedsPaddingAtStart) {
        size_t rem = dataStart % 16;
        if (rem != 0) dataStart += (16 - rem);
    }

    size_t cursor = dataStart;
    size_t fileSize = fileData.length;
    const uint8_t *base = (const uint8_t *)fileData.bytes;

    size_t dataRegionEnd = header->blocksInfoAtEnd ? (fileSize - header->compressedBlocksInfoSize) : fileSize;
    int64_t declaredDataBytes = 0;
    for (NSValue *v in blocks) {
        UBCBlockEntry be; [v getValue:&be];
        declaredDataBytes += be.cSize;
    }
    int64_t dataRegionSlack = (int64_t)(dataRegionEnd - dataStart) - declaredDataBytes;
    ZLog(@"[UnityBundleCAB] blocksInfoAtEnd=%d dataStart=%zu dataRegionEnd=%zu dataRegionSize=%zu "
          "declaredDataBytes=%lld slack=%lld blockCount=%lu",
         header->blocksInfoAtEnd, dataStart, dataRegionEnd, dataRegionEnd - dataStart,
         (long long)declaredDataBytes, (long long)dataRegionSlack, (unsigned long)blocks.count);

    if (dataRegionEnd < dataStart || dataRegionSlack < 0 || dataRegionSlack >= 16) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Bundle's block table doesn't match its data region: blocks declare %lld bytes total, but the "
                 "data region (dataStart=%zu to %@=%zu) is %zu bytes (slack=%lld, expected 0-15 for alignment "
                 "padding). This bundle's layout doesn't match what this parser expects - see UnityBundleCAB.h.",
                (long long)declaredDataBytes, dataStart, header->blocksInfoAtEnd ? @"blocksInfoStart" : @"EOF",
                dataRegionEnd, dataRegionEnd - dataStart, (long long)dataRegionSlack]
        }];
        return nil;
    }

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"zsingularity-ubc-decompressed-%@", [[NSUUID UUID] UUIDString]]];
    if (![NSFileManager.defaultManager createFileAtPath:tmpPath contents:nil attributes:nil]) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return nil;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:tmpPath];
    if (!fh) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return nil;
    }

    BOOL ok = YES;
    NSError *blockError = nil;
    NSUInteger blockIndex = 0;
    for (NSValue *v in blocks) {
        @autoreleasepool {
            UBCBlockEntry be; [v getValue:&be];
            if (!ubc_write_one_data_block(fh, base, fileSize, &cursor, be, blockIndex, &blockError)) {
                ok = NO;
            }
        }
        if (!ok) break;
        blockIndex++;
    }

    [fh closeFile];
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = blockError;
        return nil;
    }
    return tmpPath;
}

static const void *kUBCTempFileCleanupKey = &kUBCTempFileCleanupKey;

@interface UBCTempFileCleanup : NSObject
@property (nonatomic, copy) NSString *path;
@end
@implementation UBCTempFileCleanup
- (void)dealloc {
    if (self.path) [NSFileManager.defaultManager removeItemAtPath:self.path error:nil];
}
@end

static void ubc_bind_temp_file_lifetime(UnityBundleArchive *archive, NSString *tmpPath) {
    UBCTempFileCleanup *cleanup = [UBCTempFileCleanup new];
    cleanup.path = tmpPath;
    objc_setAssociatedObject(archive, kUBCTempFileCleanupKey, cleanup, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Writing (compression none, blocks-info inline, single block)

static void ubc_append_u32_be(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    [d appendBytes:b length:4];
}
static void ubc_append_u16_be(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    [d appendBytes:b length:2];
}
static void ubc_append_i64_be(NSMutableData *d, int64_t v) {
    uint64_t u = (uint64_t)v;
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(u >> (8 * (7 - i)));
    [d appendBytes:b length:8];
}
static void ubc_append_cstring(NSMutableData *d, NSString *s) {
    [d appendData:[s dataUsingEncoding:NSUTF8StringEncoding]];
    uint8_t nul = 0;
    [d appendBytes:&nul length:1];
}

static NSData *ubc_lz4hc_encode(NSData *input, NSError **error) {
    int srcSize = (int)input.length;
    if (srcSize == 0) return [NSData data];
    if ((NSUInteger)srcSize != input.length) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain
                                                 code:UnityBundleCABErrorMalformedBlocksInfo
                                             userInfo:@{NSLocalizedDescriptionKey: @"Bundle data exceeds UnityFS's 32-bit block-size limit."}];
        return nil;
    }

    int bound = LZ4_compressBound(srcSize);
    if (bound <= 0) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain
                                                 code:UnityBundleCABErrorMalformedBlocksInfo
                                             userInfo:@{NSLocalizedDescriptionKey: @"Bundle data exceeds LZ4's supported input size."}];
        return nil;
    }

    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)bound];
    int written = LZ4_compress_HC((const char *)input.bytes, (char *)out.mutableBytes,
                                   srcSize, bound, LZ4HC_CLEVEL_DEFAULT);
    if (written <= 0) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain
                                                 code:UnityBundleCABErrorCantReadFile
                                             userInfo:@{NSLocalizedDescriptionKey: @"LZ4HC compression failed."}];
        return nil;
    }
    out.length = (NSUInteger)written;
    return out;
}

static BOOL ubc_write_lz4hc_archive(UnityBundleArchive *archive, NSData *compressedData,
                                     NSData **outData, NSError **error) {
    if (archive.data.length > UINT32_MAX || compressedData.length > UINT32_MAX ||
        archive.nodes.count > UINT32_MAX) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain
                                                 code:UnityBundleCABErrorMalformedBlocksInfo
                                             userInfo:@{NSLocalizedDescriptionKey: @"Bundle is too large for UnityFS's 32-bit size fields."}];
        return NO;
    }

    NSMutableData *blocksInfo = [NSMutableData data];
    uint8_t zeroHash[16] = {0};
    [blocksInfo appendBytes:zeroHash length:16];
    ubc_append_u32_be(blocksInfo, 1);
    ubc_append_u32_be(blocksInfo, (uint32_t)archive.data.length);
    ubc_append_u32_be(blocksInfo, (uint32_t)compressedData.length);
    ubc_append_u16_be(blocksInfo, 3);
    ubc_append_u32_be(blocksInfo, (uint32_t)archive.nodes.count);
    for (UnityBundleNode *node in archive.nodes) {
        ubc_append_i64_be(blocksInfo, node.offset);
        ubc_append_i64_be(blocksInfo, node.size);
        ubc_append_u32_be(blocksInfo, node.flags);
        ubc_append_cstring(blocksInfo, node.path);
    }

    NSData *finalCompressedBlocksInfo = ubc_lz4hc_encode(blocksInfo, error);
    if (!finalCompressedBlocksInfo) return NO;

    NSMutableData *out = [NSMutableData dataWithCapacity:64 + finalCompressedBlocksInfo.length + compressedData.length];
    [out appendData:[@"UnityFS\0" dataUsingEncoding:NSUTF8StringEncoding]];
    ubc_append_u32_be(out, 8);
    ubc_append_cstring(out, archive.unityVersion ?: @"5.x.x");
    ubc_append_cstring(out, archive.unityRevision ?: @"0.0.0");
    NSUInteger archiveSizeOffset = out.length;
    ubc_append_i64_be(out, 0);
    ubc_append_u32_be(out, (uint32_t)finalCompressedBlocksInfo.length);
    ubc_append_u32_be(out, (uint32_t)blocksInfo.length);

    ubc_append_u32_be(out, 0x40 | 0x200 | 3);

    while (out.length % 16 != 0) { uint8_t z = 0; [out appendBytes:&z length:1]; }
    [out appendData:finalCompressedBlocksInfo];
    while (out.length % 16 != 0) { uint8_t z = 0; [out appendBytes:&z length:1]; }
    [out appendData:compressedData];

    uint64_t archiveSize = out.length;
    uint8_t sizeBytes[8];
    for (int j = 0; j < 8; j++) sizeBytes[j] = (uint8_t)(archiveSize >> (8 * (7 - j)));
    [out replaceBytesInRange:NSMakeRange(archiveSizeOffset, 8) withBytes:sizeBytes];

    if (outData) *outData = out;
    return YES;
}

#pragma mark - SerializedFile header parsing (target platform only)

static BOOL ubc_read_u32_le(UBCCursor *c, uint32_t *out) {
    if (!ubc_need(c, 4)) return NO;
    *out = (uint32_t)c->base[c->pos] | ((uint32_t)c->base[c->pos + 1] << 8) |
           ((uint32_t)c->base[c->pos + 2] << 16) | ((uint32_t)c->base[c->pos + 3] << 24);
    c->pos += 4;
    return YES;
}

static BOOL ubc_read_serialized_file_target_platform(const uint8_t *base, size_t totalSize,
                                                       int64_t nodeOffset, int64_t nodeSize,
                                                       int32_t *outPlatform) {
    if (nodeOffset < 0 || nodeSize < 0 || (uint64_t)nodeOffset > (uint64_t)totalSize) return NO;
    size_t available = totalSize - (size_t)nodeOffset;
    size_t clippedSize = ((uint64_t)nodeSize <= (uint64_t)available) ? (size_t)nodeSize : available;
    UBCCursor c = { .base = base + nodeOffset, .size = clippedSize, .pos = 0 };

    uint32_t metadataSize, fileSize32, version, dataOffset32;
    if (!ubc_read_u32_be(&c, &metadataSize) ||
        !ubc_read_u32_be(&c, &fileSize32) ||
        !ubc_read_u32_be(&c, &version) ||
        !ubc_read_u32_be(&c, &dataOffset32)) {
        return NO;
    }
    (void)metadataSize; (void)fileSize32; (void)dataOffset32;

    uint8_t endianess;
    if (version >= 9) {
        if (!ubc_read_u8(&c, &endianess)) return NO;
        if (!ubc_skip(&c, 3)) return NO;
    } else {

        return NO;
    }

    if (version >= 22) {
        uint32_t metadataSize64;
        int64_t fileSize64, dataOffset64, unknown64;
        if (!ubc_read_u32_be(&c, &metadataSize64) ||
            !ubc_read_i64_be(&c, &fileSize64) ||
            !ubc_read_i64_be(&c, &dataOffset64) ||
            !ubc_read_i64_be(&c, &unknown64)) {
            return NO;
        }
        (void)metadataSize64; (void)fileSize64; (void)dataOffset64; (void)unknown64;
    }

    if (version < 7) return NO;
    NSString *unityVersion;
    if (!ubc_read_cstring(&c, &unityVersion)) return NO;

    if (version < 8) return NO;

    uint32_t raw;
    BOOL ok = (endianess == 0) ? ubc_read_u32_le(&c, &raw) : ubc_read_u32_be(&c, &raw);
    if (!ok) return NO;

    if (outPlatform) *outPlatform = (int32_t)raw;
    return YES;
}

static NSDictionary<NSNumber *, NSString *> *ubc_target_platform_names(void) {
    static NSDictionary<NSNumber *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @2:  @"StandaloneOSX",
            @5:  @"StandaloneWindows",
            @9:  @"iOS",
            @13: @"Android",
            @19: @"StandaloneWindows64",
            @20: @"WebGL",
            @21: @"WSAPlayer",
            @24: @"StandaloneLinux64",
            @31: @"PS4",
            @33: @"XboxOne",
            @37: @"tvOS",
            @38: @"Switch",
            @40: @"Stadia",
            @45: @"PS5",
        };
    });
    return names;
}

#pragma mark - Public API

@implementation UnityBundleNode
@end

@implementation UnityBundleArchive
@end

@implementation UnityBundleCAB

+ (BOOL)isUnityFSBundleAtPath:(NSString *)path {
    static const char kSig[] = "UnityFS";
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *sigData = [fh readDataOfLength:sizeof(kSig)];
    [fh closeFile];
    if (sigData.length < sizeof(kSig)) return NO;
    return memcmp(sigData.bytes, kSig, sizeof(kSig)) == 0;
}

+ (uint8_t)compressionTypeForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!fileData) return UINT8_MAX;
    UBCCursor c = { .base = fileData.bytes, .size = fileData.length, .pos = 0 };
    UBCHeader header;
    if (!ubc_parse_header(&c, &header, NULL, NULL, error)) return UINT8_MAX;
    return header.compressionType;
}

static BOOL ubc_detect_lzma(NSString *path, BOOL *outIsLZMA, UBCLZMAProperties **outProps, NSError **error) {
    NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!fileData) {
        if (error && !*error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return NO;
    }

    UBCCursor c = { .base = fileData.bytes, .size = fileData.length, .pos = 0 };
    UBCHeader header;
    if (!ubc_parse_header(&c, &header, NULL, NULL, error)) return NO;

    BOOL isLZMA = (header.compressionType == UnityBundleCABCompressionLZMA);
    if (outIsLZMA) *outIsLZMA = isLZMA;
    if (!isLZMA) {
        if (outProps) *outProps = nil;
        return YES;
    }

    size_t fileSize = fileData.length;
    size_t blobStart = header.blocksInfoAtEnd ? (fileSize - header.compressedBlocksInfoSize) : header.headerEndPos;
    if (blobStart > fileSize || header.compressedBlocksInfoSize > fileSize - blobStart) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
        return NO;
    }

    UBCLZMAProperties *props = ubc_parse_lzma_properties((const uint8_t *)fileData.bytes + blobStart, header.compressedBlocksInfoSize);
    if (outProps) *outProps = props;
    return YES;
}

+ (BOOL)isLZMACompressedBundleAtPath:(NSString *)path isLZMA:(BOOL *)outIsLZMA error:(NSError **)error {
    return ubc_detect_lzma(path, outIsLZMA, NULL, error);
}

+ (nullable UBCLZMAProperties *)lzmaPropertiesForBundleAtPath:(NSString *)path error:(NSError **)error {
    BOOL isLZMA = NO;
    UBCLZMAProperties *props = nil;
    if (!ubc_detect_lzma(path, &isLZMA, &props, error)) return nil;
    if (!isLZMA) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorUnsupportedCompression userInfo:@{
            NSLocalizedDescriptionKey: @"Bundle's blocks-info is not LZMA-compressed - nothing to extract a properties header from."
        }];
        return nil;
    }
    if (!props && error) {
        *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:@{
            NSLocalizedDescriptionKey: @"Bundle's blocks-info is flagged LZMA but is too short to hold a 5-byte properties header."
        }];
    }
    return props;
}

+ (nullable NSData *)LZ4HCDataForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSError *localError = nil;
    UnityBundleArchive *archive = [self decompressedArchiveAtPath:path error:&localError];
    if (!archive) {
        if (error) *error = localError;
        return nil;
    }

    NSData *compressedData = ubc_lz4hc_encode(archive.data, &localError);
    if (!compressedData) {
        if (error) *error = localError;
        return nil;
    }

    NSData *out = nil;
    if (!ubc_write_lz4hc_archive(archive, compressedData, &out, &localError)) {
        if (error) *error = localError;
        return nil;
    }
    return out;
}

+ (nullable NSString *)primaryCABForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSArray<NSString *> *paths = ubc_all_node_paths(path, error);
    return paths.firstObject;
}

+ (nullable NSArray<NSString *> *)allNodePathsForBundleAtPath:(NSString *)path error:(NSError **)error {
    return ubc_all_node_paths(path, error);
}

+ (BOOL)targetPlatform:(int32_t *)outPlatform forBundleAtPath:(NSString *)path error:(NSError **)error {
    NSError *localError = nil;
    UnityBundleArchive *archive = [self decompressedArchiveAtPath:path error:&localError];
    if (!archive) {
        if (error) *error = localError;
        return NO;
    }
    if (archive.nodes.count == 0) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorNoNodes userInfo:nil];
        return NO;
    }

    UnityBundleNode *primary = archive.nodes.firstObject;
    int32_t platform = 0;
    BOOL ok = ubc_read_serialized_file_target_platform((const uint8_t *)archive.data.bytes, archive.data.length,
                                                         primary.offset, primary.size, &platform);
    if (!ok) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain
                                                 code:UnityBundleCABErrorMalformedSerializedFileHeader
                                             userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read a target platform out of the bundle's primary SerializedFile header."}];
        return NO;
    }
    if (outPlatform) *outPlatform = platform;
    return YES;
}

+ (NSString *)nameForTargetPlatform:(int32_t)platform {
    return ubc_target_platform_names()[@(platform)] ?: @"Unknown";
}

+ (nullable UnityBundleArchive *)decompressedArchiveAtPath:(NSString *)path error:(NSError **)error {
    NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!fileData) {
        if (error && !*error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return nil;
    }

    UBCCursor c = { .base = fileData.bytes, .size = fileData.length, .pos = 0 };
    UBCHeader header;
    NSString *unityVersion, *unityRevision;
    if (!ubc_parse_header(&c, &header, &unityVersion, &unityRevision, error)) return nil;

    NSData *blocksInfo = ubc_extract_blocks_info(fileData, &header, error);
    if (!blocksInfo) return nil;

    NSMutableArray<NSValue *> *blocks = [NSMutableArray array];
    NSMutableArray<UnityBundleNode *> *nodes = [NSMutableArray array];
    if (!ubc_parse_blocks_info_full(blocksInfo, blocks, nodes, error)) return nil;

    NSString *tmpPath = ubc_decompress_data_blocks_to_temp_file(fileData, &header, blocks, error);
    if (!tmpPath) return nil;

    NSError *mapError = nil;
    NSData *decompressed = [NSData dataWithContentsOfFile:tmpPath options:NSDataReadingMappedIfSafe error:&mapError];
    if (!decompressed) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = mapError ?: [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return nil;
    }

    UnityBundleArchive *archive = [UnityBundleArchive new];
    archive.unityVersion = unityVersion;
    archive.unityRevision = unityRevision;
    archive.data = decompressed;
    archive.nodes = nodes;

    ubc_bind_temp_file_lifetime(archive, tmpPath);
    return archive;
}

static NSFileHandle *ubc_open_temp_and_write_prefix(NSString *path, NSString *unityVersion, NSString *unityRevision,
                                                     NSArray<UnityBundleNode *> *nodes, int64_t totalDataLength,
                                                     NSString **outTmpPath, NSError **error) {
    NSMutableData *blocksInfo = [NSMutableData data];
    uint8_t zeroHash[16] = {0};
    [blocksInfo appendBytes:zeroHash length:16];
    ubc_append_u32_be(blocksInfo, 1);
    ubc_append_u32_be(blocksInfo, (uint32_t)totalDataLength);
    ubc_append_u32_be(blocksInfo, (uint32_t)totalDataLength);
    ubc_append_u16_be(blocksInfo, 0);
    ubc_append_u32_be(blocksInfo, (uint32_t)nodes.count);
    for (UnityBundleNode *node in nodes) {
        ubc_append_i64_be(blocksInfo, node.offset);
        ubc_append_i64_be(blocksInfo, node.size);

        ubc_append_u32_be(blocksInfo, node.flags);
        ubc_append_cstring(blocksInfo, node.path);
    }

    NSMutableData *out = [NSMutableData data];
    [out appendData:[@"UnityFS\0" dataUsingEncoding:NSUTF8StringEncoding]];
    ubc_append_u32_be(out, 8);
    ubc_append_cstring(out, unityVersion ?: @"5.x.x");
    ubc_append_cstring(out, unityRevision ?: @"0.0.0");

    NSUInteger totalSizeFieldOffset = out.length;
    ubc_append_i64_be(out, 0);

    ubc_append_u32_be(out, (uint32_t)blocksInfo.length);
    ubc_append_u32_be(out, (uint32_t)blocksInfo.length);

    size_t headerEndPos = out.length + 4;
    {
        size_t rem = headerEndPos % 16;
        if (rem != 0) headerEndPos += (16 - rem);
    }
    BOOL dataNeedsPad = ((headerEndPos + blocksInfo.length) % 16) != 0;
    ubc_append_u32_be(out, dataNeedsPad ? (0x40 | 0x200) : 0x40);

    {
        size_t rem = out.length % 16;
        if (rem != 0) [out appendData:[NSMutableData dataWithLength:16 - rem]];
    }
    [out appendData:blocksInfo];
    {
        size_t rem = out.length % 16;
        if (rem != 0) [out appendData:[NSMutableData dataWithLength:16 - rem]];
    }

    int64_t totalSize = (int64_t)out.length + totalDataLength;
    uint8_t sizeBytes[8];
    for (int i = 0; i < 8; i++) sizeBytes[i] = (uint8_t)((uint64_t)totalSize >> (8 * (7 - i)));
    [out replaceBytesInRange:NSMakeRange(totalSizeFieldOffset, 8) withBytes:sizeBytes];

    NSString *tmpPath = [path stringByAppendingString:@".zsingularity-tmp"];
    [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
    if (![NSFileManager.defaultManager createFileAtPath:tmpPath contents:nil attributes:nil]) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return nil;
    }
    NSError *handleErr = nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:tmpPath] error:&handleErr];
    if (!fh) {
        if (error) *error = handleErr ?: [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        return nil;
    }
    @try {
        [fh writeData:out];
    } @catch (NSException *exc) {
        [fh closeFile];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"write failed"}];
        return nil;
    }
    if (outTmpPath) *outTmpPath = tmpPath;
    return fh;
}

static BOOL ubc_finish_atomic_swap(NSFileHandle *fh, NSString *tmpPath, NSString *path, NSError **error) {
    [fh closeFile];
    NSError *replaceErr = nil;
    NSURL *resultingURL = nil;
    if (![NSFileManager.defaultManager replaceItemAtURL:[NSURL fileURLWithPath:path]
                                           withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                                          backupItemName:nil
                                                 options:0
                                        resultingItemURL:&resultingURL
                                                   error:&replaceErr]) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = replaceErr ?: [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return NO;
    }
    return YES;
}

+ (BOOL)writeArchive:(UnityBundleArchive *)archive toPath:(NSString *)path error:(NSError **)error {

    NSString *tmpPath = nil;
    NSFileHandle *fh = ubc_open_temp_and_write_prefix(path, archive.unityVersion, archive.unityRevision,
                                                       archive.nodes, (int64_t)archive.data.length, &tmpPath, error);
    if (!fh) return NO;
    @try {
        [fh writeData:archive.data];
    } @catch (NSException *exc) {
        [fh closeFile];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"write failed"}];
        return NO;
    }
    return ubc_finish_atomic_swap(fh, tmpPath, path, error);
}

+ (BOOL)writeArchiveStreamingToPath:(NSString *)path
                        unityVersion:(nullable NSString *)unityVersion
                       unityRevision:(nullable NSString *)unityRevision
                               nodes:(NSArray<UnityBundleNode *> *)nodes
                     nodeDataAtIndex:(NSData * _Nullable (^)(NSUInteger index))nodeDataAtIndex
                               error:(NSError **)error {
    int64_t totalDataLength = 0;
    for (UnityBundleNode *node in nodes) totalDataLength += node.size;

    NSString *tmpPath = nil;
    NSFileHandle *fh = ubc_open_temp_and_write_prefix(path, unityVersion, unityRevision, nodes, totalDataLength, &tmpPath, error);
    if (!fh) return NO;

    for (NSUInteger i = 0; i < nodes.count; i++) {
        @autoreleasepool {
            NSData *bytes = nodeDataAtIndex(i);
            if (!bytes) {
                [fh closeFile];
                [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
                if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile
                                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"node %lu produced no data", (unsigned long)i]}];
                return NO;
            }
            @try {
                [fh writeData:bytes];
            } @catch (NSException *exc) {
                [fh closeFile];
                [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
                if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"write failed"}];
                return NO;
            }
        }
    }
    return ubc_finish_atomic_swap(fh, tmpPath, path, error);
}

+ (BOOL)writeArchiveStreamingToPath:(NSString *)path
                        unityVersion:(nullable NSString *)unityVersion
                       unityRevision:(nullable NSString *)unityRevision
                               nodes:(NSArray<UnityBundleNode *> *)nodes
                         cabNodePath:(NSString *)cabNodePath
                         baseCABData:(NSData *)baseCABData
                      appendFilePath:(nullable NSString *)appendFilePath
                        appendLength:(int64_t)appendLength
                     nodeDataAtIndex:(NSData * _Nullable (^)(NSUInteger index))nodeDataAtIndex
                               error:(NSError **)error {
    int64_t totalDataLength = 0;
    for (UnityBundleNode *node in nodes) totalDataLength += node.size;

    int64_t expectedCABSize = (int64_t)baseCABData.length + appendLength;
    for (UnityBundleNode *node in nodes) {
        if ([node.path isEqualToString:cabNodePath] && node.size != expectedCABSize) {
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{
                NSLocalizedDescriptionKey: @"CAB node size does not match baseCABData + appendLength"
            }];
            return NO;
        }
    }

    NSString *tmpPath = nil;
    NSFileHandle *fh = ubc_open_temp_and_write_prefix(path, unityVersion, unityRevision, nodes, totalDataLength, &tmpPath, error);
    if (!fh) return NO;

    @try {
        for (NSUInteger i = 0; i < nodes.count; i++) {
            @autoreleasepool {
                UnityBundleNode *node = nodes[i];
                if ([node.path isEqualToString:cabNodePath]) {
                    [fh writeData:baseCABData];

                    if (appendLength > 0) {
                        if (!appendFilePath.length) {
                            [NSException raise:@"UnityBundleCABMissingAppendFile" format:@"appendLength is %lld but appendFilePath is nil", (long long)appendLength];
                        }
                        NSFileHandle *appendFH = [NSFileHandle fileHandleForReadingAtPath:appendFilePath];
                        if (!appendFH) {
                            [NSException raise:@"UnityBundleCABAppendOpenFailed" format:@"could not open append file %@", appendFilePath];
                        }
                        @try {
                            const NSUInteger chunkSize = 8 * 1024 * 1024;
                            int64_t remaining = appendLength;
                            while (remaining > 0) {
                                NSUInteger want = (NSUInteger)MIN((int64_t)chunkSize, remaining);
                                NSData *chunk = [appendFH readDataOfLength:want];
                                if (chunk.length != want) {
                                    [NSException raise:@"UnityBundleCABAppendShortRead" format:@"append file ended early (%lu/%lu)", (unsigned long)chunk.length, (unsigned long)want];
                                }
                                [fh writeData:chunk];
                                remaining -= (int64_t)chunk.length;
                            }
                        } @finally {
                            [appendFH closeFile];
                        }
                    }
                } else {
                    NSData *bytes = nodeDataAtIndex(i);
                    if (!bytes) {
                        [NSException raise:@"UnityBundleCABNodeDataMissing" format:@"node %lu produced no data", (unsigned long)i];
                    }
                    [fh writeData:bytes];
                }
            }
        }
    } @catch (NSException *exc) {
        [fh closeFile];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain
                                                  code:UnityBundleCABErrorCantReadFile
                                              userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"streaming bundle write failed"}];
        return NO;
    }

    return ubc_finish_atomic_swap(fh, tmpPath, path, error);
}

@end

