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
#include <stdlib.h>
#include <string.h>
#include <objc/runtime.h>

// lz4hc.h is vendored at build time (see build.yml's "Fetch LZ4 reference
// library" step) rather than committed to this repo, so it isn't present
// for local/IDE indexing - only for the actual CI compile. It transitively
// declares everything lz4.h does too. Only the encode side below uses it;
// LZ4BlockDecoder.m's hand-rolled decoder is deliberately left as-is (see
// that file's own header comment) since nothing has asked for it to change.
#import "lz4hc.h"

NSString * const UnityBundleCABErrorDomain = @"UnityBundleCABErrorDomain";
NSString * const UnityBundleCABLZMAPropertiesErrorKey = @"UnityBundleCABLZMAPropertiesErrorKey";

#pragma mark - LZMA properties header (detection/extraction only - no decoder)

// Redeclares the header's readonly properties as readwrite for this file
// only, so ubc_parse_lzma_properties below can populate a freshly-`new`'d
// instance via the property setters. Plain `props->_propertyByte = ...`
// ivar access (the original version of this code) does NOT work here even
// though this function lives in the same .m file as @implementation
// UBCLZMAProperties: auto-synthesized ivars (no explicit @synthesize/ivar
// declaration in the @interface) default to @private, and @private means
// private to the @implementation's own METHODS, not merely "this file" -
// a free-standing C function is neither, so the compiler rejected the
// direct ivar writes ("instance variable '_propertyByte' is private").
// Property setters go through the class's own generated method, which is
// exactly what @private is scoped to allow.
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

// Parses the 5-byte LZMA properties header (see UnityBundleCAB.h's comment
// on UBCLZMAProperties for the byte layout) from the START of `bytes` -
// i.e. the first 5 bytes of a raw LZMA stream, whether that stream is the
// whole compressed blocks-info blob or a single compressed data block.
// Returns nil if fewer than 5 bytes are available. This never fails on the
// property-byte math itself - every uint8_t value decodes to *some*
// lc/lp/pb triple (some combinations Unity's own bundles won't actually
// produce, but nothing here needs to reject those to do its job of
// reporting what the header literally says).
static UBCLZMAProperties *ubc_parse_lzma_properties(const uint8_t *bytes, size_t length) {
    if (length < 5) return nil;

    uint8_t propertyByte = bytes[0];
    uint32_t dictionarySize = (uint32_t)bytes[1] | ((uint32_t)bytes[2] << 8) |
                               ((uint32_t)bytes[3] << 16) | ((uint32_t)bytes[4] << 24); // LE, unlike everything else in this file

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

// Builds the NSError this file returns whenever a blob is accurately
// identified as LZMA (rather than genuinely failing to parse) - always
// carries the extracted UBCLZMAProperties under
// UnityBundleCABLZMAPropertiesErrorKey when parsing that header succeeded
// (it can still be nil if the LZMA-flagged blob was too short to even hold
// a 5-byte header - that's a malformed archive, not a "can't decode LZMA"
// situation, but this is still the most accurate code to surface it under).
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
    // ubc_decompress_data_blocks_to_temp_file below) for where the data blocks that
    // follow it start. Only applies when blocksInfo is NOT at EOF -
    // when it's stored at EOF instead, its location comes from the
    // archive's total size, not this stream position, so there is
    // nothing to align here (though the data blocks that precede it in
    // that case still get their own alignment - see
    // ubc_decompress_data_blocks_to_temp_file).
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
        case 1: { // LZMA - accurately detected and its properties header extracted, but not decompressed (see header note)
            UBCLZMAProperties *props = ubc_parse_lzma_properties(blobBytes, header->compressedBlocksInfoSize);
            ZLog(@"[UnityBundleCAB] blocks-info is LZMA-compressed: lc=%u lp=%u pb=%u dictionarySize=%u",
                 props.lc, props.lp, props.pb, props.dictionarySize);
            if (error) *error = ubc_lzma_detected_error(@"Bundle's blocks-info", props);
            return nil;
        }
        default: // LZHAM (4) / anything else - see header note
            if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorUnsupportedCompression userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Bundle uses compression type %u (not none/LZMA/LZ4/LZ4HC) - unsupported, see UnityBundleCAB.h", header->compressionType]
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

// Decompresses (or copies, for "none") exactly one DATA block into `fh`
// at the current write position, then advances `*cursor` past its
// COMPRESSED span in `fileData` - the per-block unit
// ubc_decompress_data_blocks_to_temp_file below calls once per block,
// inside its own @autoreleasepool, so at most one block's decompressed
// bytes (a few hundred KB to low single-digit MB on every real bundle
// this project has seen - Unity's own LZ4 chunking, not the archive
// total) are ever resident at once - never the whole bundle.
static BOOL ubc_write_one_data_block(NSFileHandle *fh, const uint8_t *base, size_t fileSize,
                                      size_t *cursor, UBCBlockEntry be, NSError **error) {
    if (*cursor > fileSize || be.cSize > fileSize - *cursor) {
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorMalformedBlocksInfo userInfo:nil];
        return NO;
    }
    const uint8_t *blockBytes = base + *cursor;
    uint8_t compType = (uint8_t)(be.bFlags & 0x3F);
    @try {
        switch (compType) {
            case 0: {
                size_t n = MIN(be.cSize, be.uSize);
                // No-copy wrapper straight over fileData's own (mapped)
                // bytes - writeData: reads through it once, nothing extra
                // is allocated for a stored-uncompressed block.
                [fh writeData:[NSData dataWithBytesNoCopy:(void *)blockBytes length:n freeWhenDone:NO]];
                break;
            }
            case 2:
            case 3: { // LZ4 / LZ4HC - same bitstream, see LZ4BlockDecoder.h
                NSMutableData *chunk = [NSMutableData dataWithLength:be.uSize];
                if (be.uSize > 0) {
                    int written = LZ4BlockDecompress(blockBytes, be.cSize, (uint8_t *)chunk.mutableBytes, be.uSize);
                    if (written < 0 || (uint32_t)written != be.uSize) {
                        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorDecompressFailed userInfo:nil];
                        return NO;
                    }
                }
                [fh writeData:chunk]; // this one block's decompressed bytes - released when this @autoreleasepool drains, not held for the rest of the archive
                break;
            }
            case 1: { // LZMA - accurately detected and its properties header extracted, but not decompressed (see header note)
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

// Decompresses every DATA block (the payload that follows blocks-info in
// the file - the actual node bytes, as opposed to the directory
// metadata ubc_extract_blocks_info above already handles) straight to a
// fresh temp file, in block order, one block at a time - never building
// a whole-bundle buffer in RAM. This is the "next-generation
// UnityBundleCAB API" Rework.txt calls for (see that file's "Bundle
// writer redesign" section and BundleTexture2DEnumerator.h's own MEMORY
// NOTE): the caller gets back a path it can memory-map instead of one
// concatenated NSData occupying real (anonymous, Jetsam-countable) RAM
// for the entire pipeline run.
static NSString *ubc_decompress_data_blocks_to_temp_file(NSData *fileData,
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

    size_t cursor = dataStart;
    size_t fileSize = fileData.length;
    const uint8_t *base = (const uint8_t *)fileData.bytes;

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
    for (NSValue *v in blocks) {
        @autoreleasepool {
            UBCBlockEntry be; [v getValue:&be];
            if (!ubc_write_one_data_block(fh, base, fileSize, &cursor, be, &blockError)) {
                ok = NO;
            }
        } // this block's bytes (if any were decompressed) are released here, before the next block is even read
        if (!ok) break;
    }

    [fh closeFile];
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = blockError;
        return nil;
    }
    return tmpPath;
}

// Ties a temp file's lifetime to a `UnityBundleArchive` instance via an
// associated object, so the file backing its memory-mapped `.data` gets
// deleted automatically once the archive (and everything holding a
// slice of its `.data`) is done and deallocated - no explicit cleanup
// call needed from any of this project's several callers (enumerator,
// retargeter, validator).
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

// Produces a standard raw LZ4 block via the real reference encoder
// (LZ4_compress_HC, from the vendored-at-build-time lz4hc.c - see
// build.yml's "Fetch LZ4 reference library" step and this file's #import
// above) rather than a hand-rolled matcher. UnityFS compression types 2
// (LZ4) and 3 (LZ4HC) use the same on-disk block bitstream; the archive
// flag records which compressor family produced it, which is why this
// still slots into the exact same "type 3" framing in
// ubc_write_lz4hc_archive below.
//
// This replaces a from-scratch greedy matcher that got the two-part
// end-of-block safety rule half right (5-byte literal tail, but not the
// 12-byte last-match-start margin real wildcopy()-based decoders rely on
// - see this function's git history for the bug that caused). The
// reference encoder has always implemented both correctly, so this isn't
// swapping one implementation for an equally-fallible one; it's retiring
// a redundant reimplementation of something already solved upstream.
static NSData *ubc_lz4hc_encode(NSData *input, NSError **error) {
    int srcSize = (int)input.length;
    if (srcSize == 0) return [NSData data];
    if ((NSUInteger)srcSize != input.length) { // truncated by the (int) cast above
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
    ubc_append_u16_be(blocksInfo, 3); // LZ4HC
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
    // 0x40 = BlocksAndDirectoryInfoCombined, 0x200 = BlockInfoNeedPaddingAtStart.
    // The 16-byte padding inserted below (before finalCompressedBlocksInfo)
    // is real - we always emit it - but until now this flags field never
    // said so. This app's own reader ignores the flag and aligns
    // unconditionally (see ubc_parse_header), so round-tripping through
    // ourselves always worked and masked this. A spec-following external
    // reader (AssetsTools.NET on the private repo) gates alignment on this
    // exact bit: without it set, it reads the compressed blocks-info blob
    // starting right after this field with no skip, ingesting our padding
    // as if it were LZ4 stream bytes - which is exactly the "not a
    // readable SerializedFile / AssetsFileInstance was null" failure
    // reported server-side.
    ubc_append_u32_be(out, 0x40 | 0x200 | 3); // combined + needsPaddingAtStart + LZ4HC

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
//
// See UnityBundleCAB.h's own comment on +targetPlatform:forBundleAtPath:
// error: for the format this walks. Unlike the UnityFS header above,
// only the fixed leading fields (through m_Endianess/m_Reserved, and
// the wider re-read for version >= 22) are guaranteed big-endian -
// everything after that point in the file is encoded per m_Endianess,
// which is why this needs its own little-endian u32 reader alongside
// the cursor's existing (always-big-endian) one.
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
    (void)metadataSize; (void)fileSize32; (void)dataOffset32; // not needed past here for target platform

    uint8_t endianess;
    if (version >= 9) {
        if (!ubc_read_u8(&c, &endianess)) return NO;
        if (!ubc_skip(&c, 3)) return NO; // m_Reserved
    } else {
        // Pre-9 files put the endianess byte at (m_FileSize -
        // m_MetadataSize) instead of right here - not worth chasing for
        // a field (m_TargetPlatform) that only exists from version 8
        // onward in the first place; every real bundle this project has
        // seen is far newer than either version anyway.
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

    // Metadata section starts here, encoded per `endianess` (0 = little,
    // matching every real bundle this project has seen so far; anything
    // else is treated as big-endian rather than guessed at further).
    if (version < 7) return NO; // no unityVersion string at this position yet
    NSString *unityVersion;
    if (!ubc_read_cstring(&c, &unityVersion)) return NO;

    if (version < 8) return NO; // m_TargetPlatform doesn't exist on this version

    uint32_t raw;
    BOOL ok = (endianess == 0) ? ubc_read_u32_le(&c, &raw) : ubc_read_u32_be(&c, &raw);
    if (!ok) return NO;

    if (outPlatform) *outPlatform = (int32_t)raw;
    return YES;
}

// name -> BuildTarget int, the common/well-documented subset of Unity's
// public BuildTarget enum. Deliberately not exhaustive - see
// +nameForTargetPlatform:'s own header comment.
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
    static const char kSig[] = "UnityFS"; // sizeof includes the trailing NUL, which the format also has on disk
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

// Shared by +isLZMACompressedBundleAtPath:isLZMA:error: and
// +lzmaPropertiesForBundleAtPath:error: below - reads just the header (no
// blocks-info decompression attempted) and, if compressionType is LZMA,
// also locates and parses that blob's 5-byte properties header. Returns NO
// only on a genuine parse failure (bad signature, truncated file, etc.) -
// a file that parses fine but isn't LZMA is still a YES, with
// `outIsLZMA` = NO and `outProps` left nil.
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
    return paths.firstObject; // ubc_parse_node_paths already guarantees non-empty on success
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

    UnityBundleNode *primary = archive.nodes.firstObject; // node[0] - see this header's own top comment on why
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

    // Decompressed straight to a temp file, one block at a time (see
    // ubc_decompress_data_blocks_to_temp_file) instead of one
    // NSMutableData growing to the whole bundle's decompressed size.
    // `.data` below is then a memory-MAPPED view of that file: every
    // downstream subdataWithRange: call (enumerator, converter,
    // retargeter, validator) faults in only the pages it actually
    // touches, and those pages are clean/file-backed, so the OS can
    // discard and re-fault them under memory pressure instead of Jetsam
    // treating them as unreclaimable anonymous memory. This is the one
    // piece of Rework.txt's architecture that hadn't landed yet - see
    // BundleTexture2DEnumerator.h's own MEMORY NOTE, now stale.
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
    // Deletes tmpPath once `archive` is deallocated - see
    // ubc_bind_temp_file_lifetime's own comment. Safe to unlink out from
    // under an active mmap (POSIX keeps mapped pages backed by the
    // inode until the mapping itself goes away), so this never races
    // against `.data` still being read.
    ubc_bind_temp_file_lifetime(archive, tmpPath);
    return archive;
}

// Shared by +writeArchive:toPath:error: and +writeArchiveStreamingToPath:...
// below - builds the small header+blocksInfo prefix (tens/low-hundreds of
// bytes: hash, one block entry covering totalDataLength, then the node
// table) and opens+returns a ready-to-append NSFileHandle at a
// ".zsingularity-tmp" sibling of `path`. Every multi-byte field here is
// computed from lengths the caller already knows (node.offset/size,
// totalDataLength) - nothing here ever needs the actual node BYTES, only
// their sizes, which is what lets the streaming variant avoid touching
// node data until the write loop itself.
static NSFileHandle *ubc_open_temp_and_write_prefix(NSString *path, NSString *unityVersion, NSString *unityRevision,
                                                     NSArray<UnityBundleNode *> *nodes, int64_t totalDataLength,
                                                     NSString **outTmpPath, NSError **error) {
    NSMutableData *blocksInfo = [NSMutableData data];
    uint8_t zeroHash[16] = {0};
    [blocksInfo appendBytes:zeroHash length:16];
    ubc_append_u32_be(blocksInfo, 1); // block count
    ubc_append_u32_be(blocksInfo, (uint32_t)totalDataLength); // uncompressed size
    ubc_append_u32_be(blocksInfo, (uint32_t)totalDataLength); // compressed size (== uncompressed, type none)
    ubc_append_u16_be(blocksInfo, 0); // compression type 0 (none), no other flags
    ubc_append_u32_be(blocksInfo, (uint32_t)nodes.count);
    for (UnityBundleNode *node in nodes) {
        ubc_append_i64_be(blocksInfo, node.offset);
        ubc_append_i64_be(blocksInfo, node.size);
        // Write back this node's OWN flags (0x04 = SerializedFile, 0x00 =
        // raw resource/.resS/.resource) - see UnityBundleCAB.h's doc on
        // UnityBundleNode.flags for why hardcoding 4 here was wrong for
        // any bundle with more than one node.
        ubc_append_u32_be(blocksInfo, node.flags);
        ubc_append_cstring(blocksInfo, node.path);
    }

    NSMutableData *out = [NSMutableData data];
    [out appendData:[@"UnityFS\0" dataUsingEncoding:NSUTF8StringEncoding]];
    ubc_append_u32_be(out, 8); // format version - copying the one every real sample has used so far
    ubc_append_cstring(out, unityVersion ?: @"5.x.x");
    ubc_append_cstring(out, unityRevision ?: @"0.0.0");

    NSUInteger totalSizeFieldOffset = out.length;
    ubc_append_i64_be(out, 0); // backpatched below

    ubc_append_u32_be(out, (uint32_t)blocksInfo.length); // compressed == uncompressed, type none
    ubc_append_u32_be(out, (uint32_t)blocksInfo.length);
    ubc_append_u32_be(out, 0x40); // flags: combined bit only

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
    [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil]; // stale leftover from a prior crashed/killed write, if any
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
        [fh writeData:out]; // small: header + blocksInfo, already fully in memory
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
    // Entry 5 fix (see that overview.md entry): this used to build a
    // SECOND full-bundle-size `out` buffer via `[out appendData:archive.data]`.
    // archive.data is already a full-bundle-size buffer by the time it
    // gets here, so `out` now stays small (header+blocksInfo only) and
    // archive.data is streamed straight to the temp file as its own
    // NSFileHandle write - no extra copy made here.
    NSString *tmpPath = nil;
    NSFileHandle *fh = ubc_open_temp_and_write_prefix(path, archive.unityVersion, archive.unityRevision,
                                                       archive.nodes, (int64_t)archive.data.length, &tmpPath, error);
    if (!fh) return NO;
    @try {
        [fh writeData:archive.data]; // large: written straight from the caller's existing buffer, no extra copy made here
    } @catch (NSException *exc) {
        [fh closeFile];
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = [NSError errorWithDomain:UnityBundleCABErrorDomain code:UnityBundleCABErrorCantReadFile userInfo:@{NSLocalizedDescriptionKey: exc.reason ?: @"write failed"}];
        return NO;
    }
    return ubc_finish_atomic_swap(fh, tmpPath, path, error);
}

// Same on-disk result as +writeArchive:toPath:error:, but never asks the
// caller for one concatenated `archive.data` buffer at all. `nodes` must
// already carry the FINAL offset/size each node will occupy (computable
// from lengths alone, before any bytes are touched); `nodeDataAtIndex` is
// called once per node, in order, and each NSData it returns is written
// straight to the file handle and released before the next call - so at
// most one node's bytes (plus whatever the caller's block itself is still
// holding onto, e.g. a rebuilt CAB node) is ever resident at once, instead
// of every node's bytes plus one more full-bundle copy of all of them
// concatenated. This is the "let the disk do the work" option: unchanged
// nodes can be handed back as a fresh small slice of an already
// memory-mapped source archive right when they're needed, rather than
// pre-copied into one giant buffer up front.
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
        } // bytes released here, before the next node is even fetched
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
