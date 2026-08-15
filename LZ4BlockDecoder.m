// LZ4BlockDecoder.m
//
// See LZ4BlockDecoder.h. Straight implementation of the format described
// in lz4_Block_format.md (the reference doc for the on-disk block layout,
// not the .lz4 frame format): a stream of [token][literal-length-extra]
// [literals][offset16][match-length-extra] sequences, token's high nibble
// = literal run length (0-14, or 15 meaning "read more"), low nibble =
// match length minus 4 (same 0-14/15-means-more encoding), offset is a
// little-endian 2-byte back-reference distance.
//
// Every read/write below is bounds-checked against both the input's
// remaining bytes and the output's remaining capacity before it happens -
// this is parsing untrusted (or at least unverified) data pulled out of a
// live game's cache, so a malformed/truncated block should fail cleanly
// (return -1) rather than read or write past either buffer.

#import "LZ4BlockDecoder.h"
#include <string.h>

// Reads the "add more to this length" extra-byte run that follows a
// literal-length or match-length nibble of 15. Each byte 0-254 terminates
// the run and adds its own value; a byte of 255 adds 255 and continues.
// *srcPos is advanced past every byte consumed. Returns -1 (leaving
// *srcPos in an unspecified but never-past-srcEnd state) if the run would
// read off the end of the input before terminating.
static int lz4_read_length_extra(const uint8_t *src, size_t srcSize, size_t *srcPos, size_t *lengthInOut) {
    uint8_t b;
    do {
        if (*srcPos >= srcSize) return -1;
        b = src[(*srcPos)++];
        // Overflow guard: UnityFS blocks-info is at most a few hundred KB
        // uncompressed in any real bundle, so a length run that's already
        // grown absurd means corrupt/hostile input, not a legitimate block -
        // bail rather than let this wrap.
        if (*lengthInOut > (SIZE_MAX - 255)) return -1;
        *lengthInOut += b;
    } while (b == 255);
    return 0;
}

int LZ4BlockDecompress(const uint8_t *src, size_t srcSize,
                        uint8_t *dst, size_t dstCapacity) {
    if (!src || !dst) return -1;
    if (srcSize == 0) return dstCapacity == 0 ? 0 : -1;

    size_t srcPos = 0;
    size_t dstPos = 0;

    for (;;) {
        if (srcPos >= srcSize) {
            // Ran out of input outside of a sequence boundary (e.g. right
            // after a match) without ever reaching a final literal-only
            // sequence - malformed.
            return -1;
        }

        uint8_t token = src[srcPos++];
        size_t literalLen = (token >> 4) & 0x0F;
        if (literalLen == 15) {
            if (lz4_read_length_extra(src, srcSize, &srcPos, &literalLen) != 0) return -1;
        }

        if (literalLen > srcSize - srcPos) return -1;      // literals would overrun input
        if (literalLen > dstCapacity - dstPos) return -1;  // literals would overrun output
        if (literalLen > 0) {
            memcpy(dst + dstPos, src + srcPos, literalLen);
            srcPos += literalLen;
            dstPos += literalLen;
        }

        // A block is allowed to end right after a literal run (the final
        // sequence of every block has no match part) - reaching exactly
        // the end of input here is success, not an error.
        if (srcPos == srcSize) {
            return dstPos == dstCapacity ? (int)dstPos : -1;
        }
        // Any other point where input is exhausted mid-sequence is still
        // malformed, so fall through to the match-offset read, which will
        // itself bounds-check and fail cleanly.

        if (srcSize - srcPos < 2) return -1;
        uint16_t offset = (uint16_t)(src[srcPos] | (src[srcPos + 1] << 8));
        srcPos += 2;
        if (offset == 0 || offset > dstPos) return -1; // back-reference before the start of output

        size_t matchLen = token & 0x0F;
        if (matchLen == 15) {
            if (lz4_read_length_extra(src, srcSize, &srcPos, &matchLen) != 0) return -1;
        }
        matchLen += 4; // LZ4's minimum match length

        if (matchLen > dstCapacity - dstPos) return -1; // match would overrun output

        // Copied byte-by-byte (not memcpy/memmove) because offset < matchLen
        // is a normal, intentional pattern in LZ4 (run-length-style
        // back-references that read bytes the same copy is still writing) -
        // memcpy's behavior on overlapping regions is undefined for that
        // case, so this has to progress one byte at a time to be correct.
        size_t matchSrc = dstPos - offset;
        for (size_t i = 0; i < matchLen; i++) {
            dst[dstPos + i] = dst[matchSrc + i];
        }
        dstPos += matchLen;
    }
}
