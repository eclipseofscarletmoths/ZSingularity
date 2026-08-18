// Texture2DFields.h
//
// REWORK NOTE (see Rework.txt in the project root): everything that
// used to live in this pair of files - TAT2VersionProfile, the 512-
// candidate +detectVersionProfile:fromObjectSamples:..., and the
// Texture2DHeader parse/patch class built on top of it - is deleted.
// That machinery existed to guess which Unity Texture2D field layout
// a build used; the target build is fixed and known
// (Limbus Company, Unity 6000.3.12f1), so guessing was never the
// right tool, and Rework.txt's own byte-level survey of 691 real
// Texture2D dumps from that exact build showed the guess was ALSO
// wrong (two fields it forced - m_VTOnly/m_AlphaIsTransparency - do
// not exist in any of the 691 samples; that's the whole story behind
// the recurring +4 cursor drift this project kept working around
// instead of fixing at the root).
//
// What replaces it is a fixed, single-schema structural parser for
// exactly that build - no profile struct, no candidate search, no
// runtime detection. That parser (Layer B in Rework.txt's new
// architecture) has not been written yet; this file is intentionally
// just the one piece of the old implementation still valid to build
// it on top of.
//
// The one thing kept here: the m_TextureFormat value space itself.
// This is data, not pipeline logic - Rework.txt's corpus survey
// confirms these are the only formats Limbus Company's Texture2D
// objects actually use, and Texture2DPixelDecoder.h's DXT1/DXT5/
// RGB24 decoders (kept - see Rework.txt "What should remain") switch
// on these values regardless of how the object around them gets
// parsed.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Confirmed m_TextureFormat values in this project's Texture2D
// corpus (Rework.txt: 691/691 sampled objects are one of these seven).
// RGBA32/ASTC 4x4/ASTC 6x6 are iOS-native and never re-encoded; the
// rest (RGB24, DXT1, DXT5, DXT5Crunched) are re-encode-to-RGBA32
// sources for the retarget pipeline.
typedef NS_ENUM(int32_t, TAT2TextureFormat) {
    TAT2TextureFormatRGB24           = 3,
    TAT2TextureFormatRGBA32          = 4,
    TAT2TextureFormatDXT1            = 10,
    TAT2TextureFormatDXT5            = 12,
    TAT2TextureFormatDXT5Crunched    = 29,
    TAT2TextureFormatRGBAASTC4x4     = 48,
    TAT2TextureFormatRGBAASTC6x6     = 50,
};

NS_ASSUME_NONNULL_END
