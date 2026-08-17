// RawPixelPacker.m
//
// See RawPixelPacker.h for format choice/byte-order sourcing.

#import "RawPixelPacker.h"

@implementation RawPixelPacker

// Rounded 8-bit -> N-bit downscale (N=5,6,4) - "* maxN + 127) / 255"
// rounds to nearest instead of truncating (>> (8-N)), which is just as
// cheap (one multiply/add/divide the compiler turns into a shift-ish
// sequence for these small constants) and measurably reduces banding
// over plain truncation for near-free cost - worth it given "cheap" is
// the whole point of picking this format family over block compression
// in the first place.
static inline uint8_t rp_round_to_bits(uint8_t component, int maxValue) {
    return (uint8_t)(((uint32_t)component * (uint32_t)maxValue + 127) / 255);
}

+ (nullable NSData *)packRGBA32Pixels:(NSData *)rgba32
                                 width:(int32_t)width
                                height:(int32_t)height
                            outFormat:(TAT2PackedFormat *)outFormat {
    if (width <= 0 || height <= 0) return nil;
    NSUInteger pixelCount = (NSUInteger)width * (NSUInteger)height;
    if (rgba32.length != pixelCount * 4) return nil;

    const uint8_t *src = (const uint8_t *)rgba32.bytes;

    // Single up-front pass to decide the format - see this file's
    // header on why this is a per-image, not per-pixel, decision.
    BOOL allOpaque = YES;
    for (NSUInteger i = 0; i < pixelCount; i++) {
        if (src[i * 4 + 3] != 0xFF) { allOpaque = NO; break; }
    }

    NSMutableData *out = [NSMutableData dataWithLength:pixelCount * 2];
    uint8_t *dst = (uint8_t *)out.mutableBytes;

    if (allOpaque) {
        for (NSUInteger i = 0; i < pixelCount; i++) {
            uint8_t r = rp_round_to_bits(src[i * 4 + 0], 31);
            uint8_t g = rp_round_to_bits(src[i * 4 + 1], 63);
            uint8_t b = rp_round_to_bits(src[i * 4 + 2], 31);
            uint16_t packed = (uint16_t)((r << 11) | (g << 5) | b);
            dst[i * 2 + 0] = (uint8_t)(packed & 0xFF);       // little-endian, matching every other u16/u32 field this project reads/writes (see SerializedObjectTable.m's top note)
            dst[i * 2 + 1] = (uint8_t)((packed >> 8) & 0xFF);
        }
        if (outFormat) *outFormat = TAT2PackedFormatRGB565;
    } else {
        for (NSUInteger i = 0; i < pixelCount; i++) {
            uint8_t r = rp_round_to_bits(src[i * 4 + 0], 15);
            uint8_t g = rp_round_to_bits(src[i * 4 + 1], 15);
            uint8_t b = rp_round_to_bits(src[i * 4 + 2], 15);
            uint8_t a = rp_round_to_bits(src[i * 4 + 3], 15);
            // Confirmed on-disk order for ARGB4444 - see this file's
            // header for the source: byte0 = (G<<4)|B, byte1 = (A<<4)|R.
            dst[i * 2 + 0] = (uint8_t)((g << 4) | b);
            dst[i * 2 + 1] = (uint8_t)((a << 4) | r);
        }
        if (outFormat) *outFormat = TAT2PackedFormatARGB4444;
    }

    return out;
}

@end
