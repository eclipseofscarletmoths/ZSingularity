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

static BOOL ubc_parse_header(UBCCursor *c, UBCHeader *out, NSString **outUnityVersion, NSString **outUnityRevision, NSError **error) {
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
    (void)formatVersion; // no longer branched on - see padding fix below
    if (outUnityVersion) *outUnityVersion = unityVersion;
    if (outUnityRevision) *outUnityRevision = unityRevision;

    // Bit 6 (0x40) is BlocksAndDirectoryInfoCombined - unrelated to
    // location, and set on essentially every modern bundle. Bit 7 (0x80)
    // is the actual "stored at EOF" flag (BlocksInfoAtTheEnd). These were
    // previously swapped here (and in the header doc above), which meant
    // this evaluated to YES almost unconditionally - working only by
    // coincidence on bundles where bit 0x80 also happened to be set, and
    // silently misreading every bundle where it wasn't (confirmed against
    // real __data_modded [0xc3, bit 0x80 set] vs __data_unmodded [0x243,
    // bit 0x80 NOT set] - only the latter was affected).
    BOOL blocksInfoAtEnd = (flags & 0x80) != 0;

    // Stream alignment to a 16-byte boundary (from file start, not
    // relative to the header) - UNCONDITIONAL, not gated on flags bit 9
    // (0x200) as this used to be. That gating was itself a previous fix
    // (see git history/comments this replaced) for a real bug where a
    // 4-byte target did nothing on an already-4-aligned header - but
    // gating the 16-byte fix on bit 9 turned out to be its own bug,
    // caught by checking a bundle with bit 9 CLEAR: its blocks-info
    // decompression read block_count as 0 (impossible for a real
    // archive with data in it - see below) when read from the
    // unaligned position 44, and a sane, size-consistent block_count
    // when read from 48 instead - i.e. this file needed the same
    // alignment despite bit 9 not asking for it. Confirmed against
    // three independent real archives (two different flag combinations
    // with bit 9 SET, one with it CLEAR) that the unconditional version
    // below is what every one of them actually needs, both for where
    // inline blocks-info starts and (see
    // ubc_decompress_data_blocks below) for where the data blocks that
    // follow it start. Only applies when blocksInfo is NOT at EOF -
    // when it's stored at EOF instead, its location comes from the
    // archive's total size, not this stream position, so there is
    // nothing to align here (though the data blocks that precede it in
    // that case still get their own alignment - see
    // ubc_decompress_data_blocks).
    if (!blocksInfoAtEnd) {
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
    if (!ubc_parse_header(&c, &header, NULL, NULL, error)) return nil;

    NSData *blocksInfo = ubc_extract_blocks_info(fileData, &header, error);
    if (!blocksInfo) return nil;

    return ubc_parse_node_paths(blocksInfo, error);
}

#pragma mark - Full data-block decompression (offset/size, not just names)

// Same blocks-info structure ubc_parse_node_paths walks, but keeping the
// per-block usize/csize/flags (needed to actually decompress the DATA
// blocks that follow blocks-info in the file, not just skip over their
// header entries) and the nodes' offset/size (needed so callers can slice
// `data` per-node, not just identify which node is which by name).
typedef struct { uint32_t uSize, cSize; uint16_t bFlags; } UBCBlockEntry;

static BOOL ubc_parse_blocks_info_full(NSData *blocksInfo,
                                        NSMutableArray<NSValue *> *outBlocks, // boxed UBCBlockEntry
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
        (void)nFlags;
        UnityBundleNode *node = [UnityBundleNode new];
        node.path = path; node.offset = nOffset; node.size = nSize;
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

// Decompresses every DATA block (the payload that follows blocks-info in
// the file - the actual node bytes, as opposed to the directory
// metadata ubc_extract_blocks_info above already handles) into one
// contiguous buffer, in block order.
static NSData *ubc_decompress_data_blocks(NSData *fileData,
                                           const UBCHeader *header,
                                           NSArray<NSValue *> *blocks,
                                           NSError **error) {
    // Data blocks are stored right after this archive's own header (never
    // at EOF regardless of where blocks-info itself lives - blocks-info's
    // own EOF placement is a separate, independent choice from where the
    // data blocks are), 16-byte aligned from file start the same
    // UNCONDITIONAL way ubc_parse_header now aligns blocks-info's own
    // start (see the comment there for the evidence this isn't gated on
    // flags bit 9). Checked against all three real archives this project
    // has on hand: when blocks-info is inline (bit 7 clear), data starts
    // 16-byte-aligned right after it; when blocks-info is stored at EOF
    // instead (bit 7 set), data starts 16-byte-aligned right after the
    // header instead, since there's no inline blocks-info bytes to skip
    // past first - both landed on byte 48 in every sample seen so far
    // (headerEndPos 44, next 16-byte boundary), which is why this was
    // easy to miss as "no alignment needed" if you only ever tested
    // already-16-aligned headers.
    size_t dataStart = header->headerEndPos;
    if (!header->blocksInfoAtEnd) {
        dataStart += header->compressedBlocksInfoSize;
    }
    {
        size_t rem = dataStart % 16;
        if (rem != 0) dataStart += (16 - rem);
    }

    NSMutableData *out = [NSMutableData data];
    size_t cursor = dataStart;
    size_t fileSize = fileData.length;
    const uint8_t *base = (const uint8_t *)fileData.bytes;

    for (NSValue *v in blocks) {
        UBCBlockEntry be; [v getValue:&be];
        if (cursor > fileSize || be.cSize > fileSize - cursor) {
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
            return nil;
        }
        const uint8_t *blockBytes = base + cursor;
        uint8_t compType = (uint8_t)(be.bFlags & 0x3F);
        switch (compType) {
            case 0: {
                size_t n = MIN(be.cSize, be.uSize);
                [out appendBytes:blockBytes length:n];
                break;
            }
            case 2:
            case 3: {
                NSMutableData *chunk = [NSMutableData dataWithLength:be.uSize];
                if (be.uSize > 0) {
                    int written = LZ4BlockDecompress(blockBytes, be.cSize, (uint8_t *)chunk.mutableBytes, be.uSize);
                    if (written < 0 || (uint32_t)written != be.uSize) {
                        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorDecompressFailed userInfo:nil];
                        return nil;
                    }
                }
                [out appendData:chunk];
                break;
            }
            default:
                if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorUnsupportedCompression userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Data block uses compression type %u (not none/LZ4/LZ4HC) - unsupported, see UnityBundleCAB.h", compType]
                }];
                return nil;
        }
        cursor += be.cSize;
    }
    return out;
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

#pragma mark - Public API

@implementation UnityBundleNode
@end

@implementation UnityBundleArchive
@end

@implementation UnityBundleCAB

+ (nullable NSString *)primaryCABForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSArray<NSString *> *paths = ubc_all_node_paths(path, error);
    return paths.firstObject; // ubc_parse_node_paths already guarantees non-empty on success
}

+ (nullable NSArray<NSString *> *)allNodePathsForBundleAtPath:(NSString *)path error:(NSError **)error {
    return ubc_all_node_paths(path, error);
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

    NSData *decompressed = ubc_decompress_data_blocks(fileData, &header, blocks, error);
    if (!decompressed) return nil;

    UnityBundleArchive *archive = [UnityBundleArchive new];
    archive.unityVersion = unityVersion;
    archive.unityRevision = unityRevision;
    archive.data = decompressed;
    archive.nodes = nodes;
    return archive;
}

+ (BOOL)writeArchive:(UnityBundleArchive *)archive toPath:(NSString *)path error:(NSError **)error {
    // 1) blocks-info blob: 16-byte hash (zero - not verified on read, so
    //    not worth computing on write either), one block entry covering
    //    the whole of archive.data uncompressed, then the node table
    //    verbatim (same offsets/sizes/paths - this doesn't add, remove,
    //    or reorder nodes, only what's already inside archive.data).
    NSMutableData *blocksInfo = [NSMutableData data];
    uint8_t zeroHash[16] = {0};
    [blocksInfo appendBytes:zeroHash length:16];
    ubc_append_u32_be(blocksInfo, 1); // block count
    ubc_append_u32_be(blocksInfo, (uint32_t)archive.data.length); // uncompressed size
    ubc_append_u32_be(blocksInfo, (uint32_t)archive.data.length); // compressed size (== uncompressed, type none)
    ubc_append_u16_be(blocksInfo, 0); // compression type 0 (none), no other flags
    ubc_append_u32_be(blocksInfo, (uint32_t)archive.nodes.count);
    for (UnityBundleNode *node in archive.nodes) {
        ubc_append_i64_be(blocksInfo, node.offset);
        ubc_append_i64_be(blocksInfo, node.size);
        ubc_append_u32_be(blocksInfo, 4); // node flags - 4 (kSerializedFile-ish) on every real sample seen; not verified beyond that
        ubc_append_cstring(blocksInfo, node.path);
    }

    // 2) fixed header, blocks-info stored inline (bit 7 clear) - flags =
    //    combined(0x40) only; compression type 0 in the low bits is
    //    already 0 so nothing to OR in there. No bit 9: this is a fresh
    //    write, header always ends already 16-byte aligned (see below),
    //    so there's genuinely nothing to pad - bit 9's real trigger
    //    condition isn't confirmed (see the read-side comment), so this
    //    just doesn't claim it either way rather than setting a flag
    //    whose meaning here isn't verified.
    NSMutableData *out = [NSMutableData data];
    [out appendData:[@"UnityFS\0" dataUsingEncoding:NSUTF8StringEncoding]];
    ubc_append_u32_be(out, 8); // format version - copying the one every real sample has used so far
    ubc_append_cstring(out, archive.unityVersion ?: @"5.x.x");
    ubc_append_cstring(out, archive.unityRevision ?: @"0.0.0");

    // total archive size gets backpatched once we know the final length
    NSUInteger totalSizeFieldOffset = out.length;
    ubc_append_i64_be(out, 0);

    ubc_append_u32_be(out, (uint32_t)blocksInfo.length); // compressed == uncompressed, type none
    ubc_append_u32_be(out, (uint32_t)blocksInfo.length);
    ubc_append_u32_be(out, 0x40); // flags: combined bit only

    // Header is 8("UnityFS\0")+4+len(unityVersion)+1+len(unityRevision)+1+8+4+4+4.
    // Every real sample this project has seen puts this at exactly 44
    // bytes for "5.x.x\0"/"0.0.0\0", which is already 16-byte aligned -
    // but pad explicitly rather than assume, since a longer/different
    // version string would change that.
    {
        size_t rem = out.length % 16;
        if (rem != 0) {
            NSMutableData *pad = [NSMutableData dataWithLength:16 - rem];
            [out appendData:pad];
        }
    }

    [out appendData:blocksInfo];
    // Data blocks also 16-byte align from this point per the read-side
    // finding - true here too since blocksInfo.length isn't generally a
    // multiple of 16.
    {
        size_t rem = out.length % 16;
        if (rem != 0) {
            NSMutableData *pad = [NSMutableData dataWithLength:16 - rem];
            [out appendData:pad];
        }
    }

    // Entry 5 fix: this used to be `[out appendData:archive.data]`
    // followed by one `-writeToFile:...` call. archive.data is already
    // a full-bundle-size buffer (rebuilt by tat_rebuild_archive) by the
    // time it gets here - appendData: made a THIRD full-size copy
    // (after targetCABData/targetResSData and tat_rebuild_archive's own
    // newData) alive at the exact peak of the whole transplant, right
    // before the write NSData itself would materialize a fourth copy
    // internally for -writeToFile:. See overview.md Entry 4/5. `out` at
    // this point is only the small header+blocksInfo portion (tens of
    // bytes), so instead we know the total size arithmetically (no need
    // to concatenate to measure it), backpatch that, then stream `out`
    // and archive.data to a temp file as two separate writes and swap
    // it into place - same atomicity `NSDataWritingAtomic` gave us,
    // without ever holding both in one buffer.
    int64_t totalSize = (int64_t)(out.length + archive.data.length);
    uint8_t sizeBytes[8];
    for (int i = 0; i < 8; i++) sizeBytes[i] = (uint8_t)((uint64_t)totalSize >> (8 * (7 - i)));
    [out replaceBytesInRange:NSMakeRange(totalSizeFieldOffset, 8) withBytes:sizeBytes];

    NSString *tmpPath = [path stringByAppendingString:@".zsingularity-tmp"];
    [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil]; // stale leftover from a prior crashed/killed write, if any

    if (![NSFileManager.defaultManager createFileAtPath:tmpPath contents:nil attributes:nil]) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        return NO;
    }
    NSError *handleErr = nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:tmpPath] error:&handleErr];
    if (!fh) {
        if (error) *error = handleErr ?: [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:nil];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        return NO;
    }

    @try {
        [fh writeData:out];          // small: header + blocksInfo, already fully in memory
        [fh writeData:archive.data]; // large: written straight from the caller's existing buffer, no extra copy made here
        [fh closeFile];
    } @catch (NSException *exc) {
        [fh closeFile];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"write failed"}];
        return NO;
    }

    // Atomic swap - matches NSDataWritingAtomic's guarantee that a
    // reader never sees a partially-written file at `path`.
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

@end
