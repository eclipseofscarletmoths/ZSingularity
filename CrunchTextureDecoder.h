// CrunchTextureDecoder.h
//
// Closes the one gap Texture2DPixelDecoder.h's own top comment flagged:
// DXT5Crunched (m_TextureFormat 29). Unity's "crunch" codec bolts a
// SEPARATE entropy-coded container (static Huffman tables + endpoint/
// selector codebooks) on top of a DXT5 payload - it is NOT "DXT5 with
// extra steps," and this project's own stated policy (see
// Texture2DPixelDecoder.h) is to refuse rather than guess at a format
// whose failure mode is silently scrambled pixels, not a loud error.
//
// SO THIS DOES NOT HAND-ROLL A CRN BITSTREAM PARSER. It vendors the
// actual reference transcoder instead: inc/crn_decomp.h from
// https://github.com/BinomialLLC/crunch (Rich Geldreich / Binomial LLC;
// public-domain / zlib-style license, credit required - see that
// repo's license.txt). This is the same decoder AssetStudio, UABE, and
// UnityPy all trace back to for exactly this scenario (Unity embeds a
// texture's crunched bytes as a bare .CRN payload - no extra Unity
// wrapper - for the DXT-based crunch formats specifically; that's only
// true for DXT1Crunched(28)/DXT5Crunched(29). The ETC_RGB4Crunched(41)/
// ETC2_RGBA8Crunched(43) formats use Unity's OWN forked header variant
// instead and are NOT handled by this module - not needed here since
// this project's own bundle_info.json texture2d_summary survey shows
// only DXT1/DXT5/RGBA32/RGB24/DXT5Crunched in Limbus Company's PC mod
// bundles, no ETC crunch at all).
//
// VENDORING STEP: inc/crn_decomp.h AND inc/crnlib.h (the latter just for
// a handful of basic CRN-related typedefs crn_decomp.h itself pulls in
// via #include "crnlib.h", despite crn_decomp.h's own top comment
// calling itself fully stand-alone - it isn't quite) are fetched fresh
// from that repo by the "Fetch crn_decomp.h" step in
// .github/workflows/build.yml right before the compile step, rather
// than being checked into this repo by hand - they're third-party files
// with their own license header that belong staying an untouched,
// always-current pull from upstream, not reproduced/paraphrased inside
// project-authored source. A local build just needs both files dropped
// at inc/crn_decomp.h and inc/crnlib.h next to this one (single file,
// header+impl in one - see crn_decomp.h's own top comment on the
// CRND_HEADER_FILE_ONLY/CRND_INCLUDE_CRND_H macros, neither of which
// this project needs to define; a plain #include gets both the
// declarations and the implementation).
//
// WHY THIS ONLY EVER TARGETS THE BASE MIP LEVEL: same reasoning as
// Texture2DPixelDecoder.h - this project always re-encodes to a
// single base level regardless of what the source shipped, so only
// crnd_unpack_level's level_index 0 is ever unpacked here.
//
// NOT YET CONFIRMED AGAINST A REAL DXT5Crunched SAMPLE END TO END (no
// compiler/test harness available while writing this) - refuses
// rather than guesses, but flag what hasn't been proven yet. The
// row_pitch/dst_size math
// below (blocksWide/blocksHigh * 16 bytes/DXT5-block) is the same
// formula t2pd_base_level_size already uses for plain DXT5, so a wrong
// WIDTH/HEIGHT here fails the same way (crnd_unpack_level returning
// false) rather than silently misdecoding - but the crnd_unpack_level
// call's own array-of-faces argument convention should be confirmed
// against one real crunched Texture2D dump before trusting broadly.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const CrunchTextureDecoderErrorDomain;

typedef NS_ENUM(NSInteger, CrunchTextureDecoderErrorCode) {
    CrunchTextureDecoderErrorLibraryUnavailable = 1, // inc/crn_decomp.h wasn't vendored in at build time - see this header's top comment
    CrunchTextureDecoderErrorUnpackBeginFailed,       // crnd_unpack_begin rejected sourceBytes (malformed/truncated CRN payload)
    CrunchTextureDecoderErrorUnpackLevelFailed,       // crnd_unpack_level rejected the base level (bad width/height vs. what the stream actually encodes)
};

@interface CrunchTextureDecoder : NSObject

// Transcodes `sourceBytes` (a Texture2D object's own DXT5Crunched pixel
// bytes - same "inline imageData array or resolved .resS range, base
// mip level only" convention Texture2DPixelDecoder.h documents) into
// standard, uncompressed BC3/DXT5 block bytes at `width`x`height` -
// i.e. the exact byte layout Texture2DPixelDecoder's own DXT5 branch
// already knows how to block-decode into RGBA32. This function does
// NOT produce RGBA32 itself - callers hand its output straight to
// Texture2DPixelDecoder's existing DXT5 path, no new pixel-format
// knowledge needed there beyond "crunch is a decompression step in
// front of DXT5, not a different block format."
//
// Returns nil (with CrunchTextureDecoderErrorLibraryUnavailable) if
// this file was built without inc/crn_decomp.h vendored in - see this
// header's top comment. That's a build-time condition, not a per-file
// one, so a caller seeing it repeatedly means the vendoring step itself
// is still outstanding, not that any particular mod is bad.
+ (nullable NSData *)decodeDXT5CrunchedToRawDXT5:(NSData *)sourceBytes
                                            width:(int32_t)width
                                           height:(int32_t)height
                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
