
#import "LZ4BlockDecoder.h"
#include <string.h>

static int lz4_read_length_extra(const uint8_t *src, size_t srcSize, size_t *srcPos, size_t *lengthInOut) {
    uint8_t b;
    do {
        if (*srcPos >= srcSize) return -1;
        b = src[(*srcPos)++];

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

            return -1;
        }

        uint8_t token = src[srcPos++];
        size_t literalLen = (token >> 4) & 0x0F;
        if (literalLen == 15) {
            if (lz4_read_length_extra(src, srcSize, &srcPos, &literalLen) != 0) return -1;
        }

        if (literalLen > srcSize - srcPos) return -1;
        if (literalLen > dstCapacity - dstPos) return -1;
        if (literalLen > 0) {
            memcpy(dst + dstPos, src + srcPos, literalLen);
            srcPos += literalLen;
            dstPos += literalLen;
        }

        if (srcPos == srcSize) {
            return dstPos == dstCapacity ? (int)dstPos : -1;
        }

        if (srcSize - srcPos < 2) return -1;
        uint16_t offset = (uint16_t)(src[srcPos] | (src[srcPos + 1] << 8));
        srcPos += 2;
        if (offset == 0 || offset > dstPos) return -1;

        size_t matchLen = token & 0x0F;
        if (matchLen == 15) {
            if (lz4_read_length_extra(src, srcSize, &srcPos, &matchLen) != 0) return -1;
        }
        matchLen += 4;

        if (matchLen > dstCapacity - dstPos) return -1;

        size_t matchSrc = dstPos - offset;
        for (size_t i = 0; i < matchLen; i++) {
            dst[dstPos + i] = dst[matchSrc + i];
        }
        dstPos += matchLen;
    }
}

