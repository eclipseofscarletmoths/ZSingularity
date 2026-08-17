// Texture2DPixelDecoder.m
//
// See Texture2DPixelDecoder.h for format coverage / what this
// deliberately does NOT attempt (DXT5Crunched, ASTC). DXT1/DXT5 block
// layout implemented here is the standard, publicly documented S3TC/BC
// bit layout (Khronos' GL_EXT_texture_compression_s3tc spec / the
// equivalent D3D BC1/BC3 documentation) - the same "decode per open
// spec" work as any PNG/JPEG reader, not anyone's proprietary content.

#import "Texture2DPixelDecoder.h"
#import "Texture2DFields.h" // for the TAT2TextureFormat raw values this switches on

NSString * const Texture2DPixelDecoderErrorDomain = @"Texture2DPixelDecoderErrorDomain";

// Not in TAT2TextureFormat (that enum only lists the ones
// Texture2DFields.h's own validation cares about) - RGB24 shows up in
// this project's own bundle_info.json texture2d_summary survey, so it
// gets a local constant here rather than pulling in an unrelated name.
static const int32_t kTAT2FormatRGB24 = 3;

static NSError *T2PDError(Texture2DPixelDecoderErrorCode code, NSString *message) {
    return [NSError errorWithDomain:Texture2DPixelDecoderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - RGB565 -> RGB888 (bit replication, same convention RawPixelPacker's inverse expects)

static inline void t2pd_unpack565(uint16_t c, uint8_t *r, uint8_t *g, uint8_t *b) {
    uint8_t r5 = (uint8_t)((c >> 11) & 0x1F);
    uint8_t g6 = (uint8_t)((c >> 5) & 0x3F);
    uint8_t b5 = (uint8_t)(c & 0x1F);
    *r = (uint8_t)((r5 << 3) | (r5 >> 2));
    *g = (uint8_t)((g6 << 2) | (g6 >> 4));
    *b = (uint8_t)((b5 << 3) | (b5 >> 2));
}

#pragma mark - BC1/BC3 block helpers

// Decodes one 4x4 BC1 (DXT1) block's 16 RGBA pixels. `forceOpaqueMode`
// is YES when called from BC3 (DXT5) context - per the S3TC/BC spec,
// DXT5's own color block is ALWAYS 4-color interpolation regardless of
// how color0/color1 compare numerically (DXT5 carries alpha in its
// separate alpha block, so BC1's punch-through-alpha 3-color mode,
// which exists purely to steal a color slot for transparency, never
// applies here) - only plain DXT1 honors the comparison.
static void t2pd_decode_bc1_block(const uint8_t *block, BOOL forceOpaqueMode, uint8_t outRGBA[16][4]) {
    uint16_t c0 = (uint16_t)(block[0] | (block[1] << 8));
    uint16_t c1 = (uint16_t)(block[2] | (block[3] << 8));
    uint32_t indices = (uint32_t)block[4] | ((uint32_t)block[5] << 8) | ((uint32_t)block[6] << 16) | ((uint32_t)block[7] << 24);

    uint8_t r0, g0, b0, r1, g1, b1;
    t2pd_unpack565(c0, &r0, &g0, &b0);
    t2pd_unpack565(c1, &r1, &g1, &b1);

    uint8_t colors[4][4]; // [index][R,G,B,A]
    colors[0][0] = r0; colors[0][1] = g0; colors[0][2] = b0; colors[0][3] = 255;
    colors[1][0] = r1; colors[1][1] = g1; colors[1][2] = b1; colors[1][3] = 255;

    BOOL fourColorMode = forceOpaqueMode || (c0 > c1);
    if (fourColorMode) {
        colors[2][0] = (uint8_t)((2 * (int)r0 + (int)r1) / 3);
        colors[2][1] = (uint8_t)((2 * (int)g0 + (int)g1) / 3);
        colors[2][2] = (uint8_t)((2 * (int)b0 + (int)b1) / 3);
        colors[2][3] = 255;
        colors[3][0] = (uint8_t)(((int)r0 + 2 * (int)r1) / 3);
        colors[3][1] = (uint8_t)(((int)g0 + 2 * (int)g1) / 3);
        colors[3][2] = (uint8_t)(((int)b0 + 2 * (int)b1) / 3);
        colors[3][3] = 255;
    } else {
        colors[2][0] = (uint8_t)(((int)r0 + (int)r1) / 2);
        colors[2][1] = (uint8_t)(((int)g0 + (int)g1) / 2);
        colors[2][2] = (uint8_t)(((int)b0 + (int)b1) / 2);
        colors[2][3] = 255;
        colors[3][0] = 0; colors[3][1] = 0; colors[3][2] = 0; colors[3][3] = 0; // punch-through transparent
    }

    for (int i = 0; i < 16; i++) {
        uint8_t code = (uint8_t)((indices >> (2 * i)) & 0x3);
        outRGBA[i][0] = colors[code][0];
        outRGBA[i][1] = colors[code][1];
        outRGBA[i][2] = colors[code][2];
        outRGBA[i][3] = colors[code][3];
    }
}

// Fills outAlpha[16] for one BC3 (DXT5) alpha block (the first 8 bytes
// of a DXT5 block, separate from the 8-byte BC1-shaped color block that
// follows it).
static void t2pd_decode_bc3_alpha_block(const uint8_t *block, uint8_t outAlpha[16]) {
    uint8_t a0 = block[0];
    uint8_t a1 = block[1];
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= ((uint64_t)block[2 + i]) << (8 * i); // 48-bit LE, 3 bits/pixel

    uint8_t alphas[8];
    alphas[0] = a0;
    alphas[1] = a1;
    if (a0 > a1) {
        alphas[2] = (uint8_t)((6 * (int)a0 + 1 * (int)a1) / 7);
        alphas[3] = (uint8_t)((5 * (int)a0 + 2 * (int)a1) / 7);
        alphas[4] = (uint8_t)((4 * (int)a0 + 3 * (int)a1) / 7);
        alphas[5] = (uint8_t)((3 * (int)a0 + 4 * (int)a1) / 7);
        alphas[6] = (uint8_t)((2 * (int)a0 + 5 * (int)a1) / 7);
        alphas[7] = (uint8_t)((1 * (int)a0 + 6 * (int)a1) / 7);
    } else {
        alphas[2] = (uint8_t)((4 * (int)a0 + 1 * (int)a1) / 5);
        alphas[3] = (uint8_t)((3 * (int)a0 + 2 * (int)a1) / 5);
        alphas[4] = (uint8_t)((2 * (int)a0 + 3 * (int)a1) / 5);
        alphas[5] = (uint8_t)((1 * (int)a0 + 4 * (int)a1) / 5);
        alphas[6] = 0;
        alphas[7] = 255;
    }

    for (int i = 0; i < 16; i++) {
        uint8_t code = (uint8_t)((bits >> (3 * i)) & 0x7);
        outAlpha[i] = alphas[code];
    }
}

#pragma mark - per-format base-mip-level byte size

static NSUInteger t2pd_base_level_size(int32_t rawFormat, int32_t width, int32_t height) {
    NSUInteger blocksWide = (NSUInteger)((width + 3) / 4);
    NSUInteger blocksHigh = (NSUInteger)((height + 3) / 4);
    switch (rawFormat) {
        case TAT2TextureFormatRGBA32: return (NSUInteger)width * (NSUInteger)height * 4;
        case kTAT2FormatRGB24:        return (NSUInteger)width * (NSUInteger)height * 3;
        case TAT2TextureFormatDXT1:   return blocksWide * blocksHigh * 8;
        case TAT2TextureFormatDXT5:   return blocksWide * blocksHigh * 16;
        default: return 0;
    }
}

@implementation Texture2DPixelDecoder

+ (nullable NSData *)decodeToRGBA32FromRawFormat:(int32_t)rawFormat
                                      sourceBytes:(NSData *)sourceBytes
                                            width:(int32_t)width
                                           height:(int32_t)height
                                            error:(NSError **)error {
    if (width <= 0 || height <= 0) {
        if (error) *error = T2PDError(Texture2DPixelDecoderErrorInvalidDimensions, @"width/height must be positive");
        return nil;
    }

    if (rawFormat != TAT2TextureFormatRGBA32 && rawFormat != kTAT2FormatRGB24 &&
        rawFormat != TAT2TextureFormatDXT1 && rawFormat != TAT2TextureFormatDXT5) {
        // Most notably DXT5Crunched (29) and RGBA ASTC 6x6 (50) - see
        // this class's header top comment on why those are refused
        // rather than guessed at.
        if (error) *error = T2PDError(Texture2DPixelDecoderErrorUnsupportedFormat,
            [NSString stringWithFormat:@"m_TextureFormat %d has no decoder in this project - see Texture2DPixelDecoder.h", rawFormat]);
        return nil;
    }

    NSUInteger neededBytes = t2pd_base_level_size(rawFormat, width, height);
    if (sourceBytes.length < neededBytes) {
        if (error) *error = T2PDError(Texture2DPixelDecoderErrorTruncatedData,
            [NSString stringWithFormat:@"format %d at %dx%d needs %lu bytes for its base mip level, only got %lu",
                rawFormat, width, height, (unsigned long)neededBytes, (unsigned long)sourceBytes.length]);
        return nil;
    }

    const uint8_t *src = (const uint8_t *)sourceBytes.bytes;
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4];
    uint8_t *dst = (uint8_t *)out.mutableBytes;

    if (rawFormat == TAT2TextureFormatRGBA32) {
        memcpy(dst, src, neededBytes);
        return out;
    }

    if (rawFormat == kTAT2FormatRGB24) {
        for (NSUInteger i = 0; i < (NSUInteger)width * (NSUInteger)height; i++) {
            dst[i * 4 + 0] = src[i * 3 + 0];
            dst[i * 4 + 1] = src[i * 3 + 1];
            dst[i * 4 + 2] = src[i * 3 + 2];
            dst[i * 4 + 3] = 255;
        }
        return out;
    }

    // DXT1 / DXT5 - block-decode, then scatter each block's 4x4 pixels
    // into the row-major output, clipping any padding past the real
    // width/height (Unity still allocates full 4x4 blocks for
    // non-multiple-of-4 dimensions).
    NSUInteger blocksWide = (NSUInteger)((width + 3) / 4);
    NSUInteger blocksHigh = (NSUInteger)((height + 3) / 4);
    NSUInteger bytesPerBlock = (rawFormat == TAT2TextureFormatDXT1) ? 8 : 16;

    for (NSUInteger by = 0; by < blocksHigh; by++) {
        for (NSUInteger bx = 0; bx < blocksWide; bx++) {
            const uint8_t *blockPtr = src + (by * blocksWide + bx) * bytesPerBlock;
            uint8_t rgba[16][4];
            uint8_t alpha[16];

            if (rawFormat == TAT2TextureFormatDXT1) {
                t2pd_decode_bc1_block(blockPtr, /*forceOpaqueMode=*/NO, rgba);
            } else {
                t2pd_decode_bc3_alpha_block(blockPtr, alpha);
                t2pd_decode_bc1_block(blockPtr + 8, /*forceOpaqueMode=*/YES, rgba);
                for (int i = 0; i < 16; i++) rgba[i][3] = alpha[i];
            }

            for (int py = 0; py < 4; py++) {
                NSUInteger imgY = by * 4 + (NSUInteger)py;
                if (imgY >= (NSUInteger)height) continue;
                for (int px = 0; px < 4; px++) {
                    NSUInteger imgX = bx * 4 + (NSUInteger)px;
                    if (imgX >= (NSUInteger)width) continue;
                    NSUInteger pixelIdx = py * 4 + px;
                    NSUInteger dstIdx = (imgY * (NSUInteger)width + imgX) * 4;
                    dst[dstIdx + 0] = rgba[pixelIdx][0];
                    dst[dstIdx + 1] = rgba[pixelIdx][1];
                    dst[dstIdx + 2] = rgba[pixelIdx][2];
                    dst[dstIdx + 3] = rgba[pixelIdx][3];
                }
            }
        }
    }

    return out;
}

@end
