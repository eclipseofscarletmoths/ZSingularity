// Texture2DPixelDecoder.h
//
// The missing link between Texture2DFields.h (locates a Texture2D
// object's header/pixel bytes) and RawPixelPacker.h (re-encodes RGBA32
// into the cheap 16-bit formats this project targets - see that
// header's top comment): this decodes a PC mod's SOURCE pixel bytes
// (whatever m_TextureFormat it declares) into plain RGBA32 so
// RawPixelPacker has something uniform to work from, regardless of
// which of the handful of formats Limbus Company's PC mods actually
// ship in.
//
// FORMAT COVERAGE - see this project's own texture2d_summary survey
// (bundle_info.json: DXT1/DXT5/RGBA32/RGB24/DXT5Crunched, in that
// rough frequency order for a typical mod bundle):
//   - RGBA32, RGB24: no decode needed beyond a straight copy /
//     alpha=255 fill - included here for uniformity so every caller
//     goes through one function regardless of source format.
//   - DXT1 (BC1), DXT5 (BC3): decoded in full below. Both are the
//     standard, openly-documented S3TC/BC block layout (this is a
//     public interoperability format, the same kind of "decode per
//     published spec" work as a PNG or JPEG reader - not anyone's
//     proprietary asset) - see the .m for the exact bit layout this
//     implements.
//   - DXT5Crunched: Unity's "crunch" codec is a SEPARATE, much more
//     involved compression layer bolted on top of a DXT5 payload
//     (its own entropy coding / codebook scheme, not just "DXT5 with
//     extra steps") - this project has no verified from-scratch
//     implementation of it and isn't guessing at one. Handled now via
//     CrunchTextureDecoder.h (a vendored reference transcoder, NOT a
//     hand-rolled bitstream parser - see that header's top comment for
//     why): this class decompresses crunch -> standard DXT5 block bytes
//     first, then falls straight into the same BC1/BC3 block-decode
//     path below that already handles plain DXT5, no separate pixel
//     math needed. Still refuses (Texture2DPixelDecoderErrorUnsupportedFormat)
//     if CrunchTextureDecoder itself reports its library dependency
//     isn't vendored into the build yet, or Texture2DPixelDecoderErrorTruncatedData/
//     a wrapped error if the crunch stream itself doesn't decompress -
//     either way TextureAtlasTransplant.m's existing texture2DFormatUnsupported
//     counter still catches it, no caller-side change needed there.
//   - RGBA ASTC 6x6 (iOS stock's own format) and anything else not
//     listed above: also refused, same reasoning - this project has no
//     need to ever decode FROM those, only skip objects that show up
//     in that shape unexpectedly.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const Texture2DPixelDecoderErrorDomain;

typedef NS_ENUM(NSInteger, Texture2DPixelDecoderErrorCode) {
    Texture2DPixelDecoderErrorUnsupportedFormat = 1, // see this header's top comment - ASTC/anything unlisted, or DXT5Crunched (29) specifically when CrunchTextureDecoder's vendored dependency isn't in the build yet
    Texture2DPixelDecoderErrorTruncatedData,          // fewer bytes than this format/width/height needs for even the base mip level
    Texture2DPixelDecoderErrorInvalidDimensions,
};

@interface Texture2DPixelDecoder : NSObject

// Decodes `sourceBytes` (a Texture2D object's own pixel bytes - the
// inline imageData array or the streamed .resS range, whichever
// TextureAtlasTransplant.m already resolved - starting at the base mip
// level, which Unity always stores first) from `rawFormat` (a raw
// m_TextureFormat value - same numbering as TAT2TextureFormat in
// Texture2DFields.h) into tightly-packed, row-major RGBA32 - the exact
// input convention RawPixelPacker.h documents.
//
// If sourceBytes holds more than one mip level concatenated
// (mipCount > 1 - this project always re-encodes to a single base
// level, see RawPixelPacker.h's own top comment on why), only the
// leading bytes for the base level are read; anything past that
// (smaller mips) is ignored, not an error.
//
// Returns nil for any format this class doesn't decode (see this
// header's top comment) - check `error.code` against
// Texture2DPixelDecoderErrorUnsupportedFormat to distinguish that from
// an actual malformed-input failure.
+ (nullable NSData *)decodeToRGBA32FromRawFormat:(int32_t)rawFormat
                                      sourceBytes:(NSData *)sourceBytes
                                            width:(int32_t)width
                                           height:(int32_t)height
                                            error:(NSError **)error;

// Same decoder, but consumes a caller-owned byte span directly. This avoids
// `subdataWithRange:` copies for large streamed/inline texture payloads; the
// decoder only allocates its RGBA32 destination (plus any format-specific
// scratch required by DXT5Crunched).
+ (nullable NSData *)decodeToRGBA32FromRawFormat:(int32_t)rawFormat
                                      sourceBytes:(const void *)sourceBytes
                                      sourceLength:(NSUInteger)sourceLength
                                            width:(int32_t)width
                                           height:(int32_t)height
                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
