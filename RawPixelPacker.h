// RawPixelPacker.h
//
// The chosen encode target (see project chat log, not filed anywhere
// else in-repo): 16-bit packed pixel formats, NOT block compression.
// RGB565/ARGB4444 are per-pixel precision truncation - a shift and a
// table lookup per pixel, no block search/optimization loop - which is
// what makes this "cheap" in the sense the whole Texture2D transplant
// effort cares about (see TextureAtlasTransplant.h's top comment on why
// full ASTC re-encode was ruled out). Half the memory of RGBA32, at a
// real but usually-tolerable quality cost (banding on smooth gradients,
// 16 alpha levels when alpha is used at all).
//
// WHY ARGB4444 (TextureFormat 2) AND NOT RGBA4444 (TextureFormat 13):
// these are NOT the same bit layout despite the similar name - Unity
// ships both as distinct TextureFormat values on purpose. ARGB4444's
// on-disk byte order is confirmed by a real, citable source (an
// AssetsTools.NET decoder bug report - see the .m). RGBA4444's is not -
// this project has no equivalently confirmed source for it, and
// getting a 4-bit nibble order wrong silently scrambles color/alpha
// per pixel rather than failing to parse. ARGB4444 does exactly the
// same job (4 bits/channel, alpha included) at the same memory cost, so
// there's no reason to take the unconfirmed path when a confirmed one
// exists. If a real Texture2DFields dump ever nails down RGBA4444's
// actual layout, switching is a one-function change here - nothing
// downstream cares which 4-bit format was used, only that
// +packRGBA32Pixels:... reports the right TextureFormat value back.
//
// INPUT CONVENTION: rgba32 is assumed 4 bytes/pixel, R,G,B,A order,
// row-major, tightly packed (no row padding) - this is the same
// convention any future DXT/crunch decoder feeding into this should
// produce. This project has NOT independently confirmed Unity's own
// on-disk RGBA32 byte order against a real dump either (see
// Texture2DFields.h's top comment on what has vs. hasn't been verified
// this way) - if that turns out to be ABGR or another order instead,
// this file's math doesn't change, only which byte a decoder hands it
// as R vs B.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Unity TextureFormat values this file can produce - see this header's
// top comment for why ARGB4444 and not RGBA4444.
typedef NS_ENUM(int32_t, TAT2PackedFormat) {
    TAT2PackedFormatRGB565   = 7,
    TAT2PackedFormatARGB4444 = 2,
};

@interface RawPixelPacker : NSObject

// Packs `rgba32` (must be exactly width*height*4 bytes - see this
// header's top comment on the input convention) into RGB565 if every
// pixel's alpha byte is 255, or ARGB4444 otherwise (this is a per-image
// decision, not per-pixel - a texture with even one non-opaque pixel
// gets ARGB4444 throughout, since Unity has no format that's "565 with
// one exception"). Writes the chosen format to *outFormat. Returns nil
// (and leaves *outFormat untouched) only if rgba32.length doesn't match
// width*height*4.
//
// Output is tightly packed (2 bytes/pixel, row-major, no row padding) -
// same "no stride padding" assumption this project makes about Unity's
// own uncompressed texture byte arrays (see this header's top comment).
// Caller is responsible for everything downstream of the bytes
// themselves: writing them into the object's image-data array or
// resS payload, and patching format/completeImageSize/width/height/
// mipCount via Texture2DHeader - this class only packs pixels.
+ (nullable NSData *)packRGBA32Pixels:(NSData *)rgba32
                                 width:(int32_t)width
                                height:(int32_t)height
                            outFormat:(TAT2PackedFormat *)outFormat;

@end

NS_ASSUME_NONNULL_END
