// UnityBundleCAB.m
//
// See UnityBundleCAB.h for the format this walks and why it exists instead
// of a raw byte scan. Every multi-byte integer in a UnityFS header/
// blocks-info is big-endian (network byte order) - this is the one detail
// that differs from the archive's asset DATA, which is little-endian like
// everything else Unity writes. Getting that backwards is the single
// easiest way to silently misparse this format, so every read helper below
// is explicit about it.

#import "UnityBundleCAB.h"
#import "LZ4BlockDecoder.h"
#import "ZTweakLog.h"
#include <stdint.h>

NSString * const UnityBundleCABErrorDomain = @"UnityBundleCABErrorDomain";

#pragma mark - Bounds-checked cursor over an in-memory buffer

typedef struct {
    const uint8_t *base;
    size_t size;
    size_t pos;
} UBCCursor;

static BOOL ubc_need(UBCCursor *c, size_t n) {
    return n <= c->size - c->pos; // c->pos <= c->size is a loop invariant everywhere this is called, so no underflow
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

// Reads a NUL-terminated string. Bounded by the cursor's own remaining
// size, so a missing terminator fails cleanly instead of scanning past
// the buffer.
static BOOL ubc_read_cstring(UBCCursor *c, NSString **out) {
    size_t start = c->pos;
    while (c->pos < c->size && c->base[c->pos] != 0) c->pos++;
    if (c->pos >= c->size) return NO; // ran off the end without a NUL
    NSString *s = [[NSString alloc] initWithBytes:c->base + start
                                             length:c->pos - start
                                           encoding:NSUTF8StringEncoding];
    c->pos += 1; // consume the NUL
    if (!s) return NO;
    *out = s;
    return YES;
}

#pragma mark - Header + blocks-info parsing

// Everything above the compressed blocks-info blob, plus where to find
// that blob (either right after this header, or at the end of the file).
typedef struct {
    uint32_t compressedBlocksInfoSize;
    uint32_t uncompressedBlocksInfoSize;
    uint8_t  compressionType; // low 6 bits of flags
    BOOL     blocksInfoAtEnd; // bit 6 of flags
    size_t   headerEndPos;    // stream position immediately after the header (+ alignment)
} UBCHeader;

static BOOL ubc_parse_header(UBCCursor *c, UBCHeader *out, NSError **error) {
    static const char kSig[] = "UnityFS";
    if (!ubc_need(c, sizeof(kSig))) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorTooSmall userInfo:nil];
        return NO;
    }
    if (memcmp(c->base + c->pos, kSig, sizeof(kSig)) != 0) { // sizeof includes the trailing NUL, which the format also has
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

    BOOL blocksInfoAtEnd = (flags & 0x40) != 0;

    // Stream alignment: format version >= 7 pads the header up to a
    // 4-byte boundary before the blocks-info blob, but ONLY when that
    // blob immediately follows here - when it's stored at EOF instead,
    // its location is computed from the archive's total size, not from
    // this stream position, so there's nothing to align.
    if (formatVersion >= 7 && !blocksInfoAtEnd) {
        size_t rem = c->pos % 4;
        if (rem != 0) {
            if (!ubc_skip(c, 4 - rem)) {
                if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorTooSmall userInfo:nil];
                return NO;
            }
        }
    }

    out->compressedBlocksInfoSize = compressedBlocksInfoSize;
    out->uncompressedBlocksInfoSize = uncompressedBlocksInfoSize;
    out->compressionType = (uint8_t)(flags & 0x3F);
    out->blocksInfoAtEnd = blocksInfoAtEnd;
    out->headerEndPos = c->pos;
    return YES;
}

// Decompresses (or, for "none", just copies) the blocks-info blob per
// `header`, wherever in `fileData` it actually lives.
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
        case 0: { // none - compressed/uncompressed sizes should already match
            if (header->compressedBlocksInfoSize != header->uncompressedBlocksInfoSize) {
                ZLog(@"[UnityBundleCAB] compression=none but compressed(%u) != uncompressed(%u) size - reading uncompressedSize bytes anyway",
                      header->compressedBlocksInfoSize, header->uncompressedBlocksInfoSize);
            }
            size_t n = MIN(header->compressedBlocksInfoSize, header->uncompressedBlocksInfoSize);
            return [NSData dataWithBytes:blobBytes length:n];
        }
        case 2:   // LZ4
        case 3: { // LZ4HC - same bitstream as LZ4, see LZ4BlockDecoder.h
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
        default: // LZMA (1) / LZHAM (4) / anything else - see header note
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorUnsupportedCompression userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Bundle uses compression type %u (not none/LZ4/LZ4HC) - unsupported, see UnityBundleCAB.h", header->compressionType]
            }];
            return nil;
    }
}

// Parses the decompressed blocks-info blob and returns every directory
// node's path, in order.
static NSArray<NSString *> *ubc_parse_node_paths(NSData *blocksInfo, NSError **error) {
    UBCCursor c = { .base = blocksInfo.bytes, .size = blocksInfo.length, .pos = 0 };

    if (!ubc_skip(&c, 16)) { // uncompressed-data hash, unused here
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
    if (!ubc_parse_header(&c, &header, error)) return nil;

    NSData *blocksInfo = ubc_extract_blocks_info(fileData, &header, error);
    if (!blocksInfo) return nil;

    return ubc_parse_node_paths(blocksInfo, error);
}

#pragma mark - Public API

@implementation UnityBundleCAB

+ (nullable NSString *)primaryCABForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSArray<NSString *> *paths = ubc_all_node_paths(path, error);
    return paths.firstObject; // ubc_parse_node_paths already guarantees non-empty on success
}

+ (nullable NSArray<NSString *> *)allNodePathsForBundleAtPath:(NSString *)path error:(NSError **)error {
    return ubc_all_node_paths(path, error);
}

@end
