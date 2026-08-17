// CrunchTextureDecoder.mm
//
// See CrunchTextureDecoder.h for what this is and, importantly, what it
// deliberately does NOT do (no hand-rolled CRN bitstream parsing).
//
// Gated on __has_include so this project keeps building even on a run
// where the "Fetch crn_decomp.h" build.yml step hasn't dropped
// inc/crn_decomp.h in yet - same "optional dependency, gate on
// __has_include, don't hard-fail the whole build over one missing
// vendor file" posture this project's README describes for the old
// libogg/libvorbis gate on BankTransplant.m (now removed, but the
// pattern is exactly this).
//
// This file MUST be compiled as Objective-C++ (.mm) - crn_decomp.h is
// C++ (namespaces, the crnd_unpack_context typedef, etc.), so it can't
// be #imported from a plain .m file. build.yml compiles this file as
// its own object (clang -x objective-c++) and links it with -lc++ into
// the same dylib the rest of the .m files build into, since clang's
// single-invocation-on-*.m trick can't mix a .mm source into that same
// command the way it can mix multiple .m files.

#import "CrunchTextureDecoder.h"

NSString * const CrunchTextureDecoderErrorDomain = @"CrunchTextureDecoderErrorDomain";

#if __has_include("crn_decomp.h")
#define CRUNCH_TEXTURE_DECODER_AVAILABLE 1
#include "crn_decomp.h"
#else
#define CRUNCH_TEXTURE_DECODER_AVAILABLE 0
#endif

static NSError *CTDError(CrunchTextureDecoderErrorCode code, NSString *message) {
    return [NSError errorWithDomain:CrunchTextureDecoderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation CrunchTextureDecoder

+ (nullable NSData *)decodeDXT5CrunchedToRawDXT5:(NSData *)sourceBytes
                                            width:(int32_t)width
                                           height:(int32_t)height
                                            error:(NSError **)error {
#if !CRUNCH_TEXTURE_DECODER_AVAILABLE
    if (error) *error = CTDError(CrunchTextureDecoderErrorLibraryUnavailable,
        @"inc/crn_decomp.h isn't vendored into this target yet - see CrunchTextureDecoder.h's top comment "
         "(grab it from https://github.com/BinomialLLC/crunch, inc/crn_decomp.h, and add it + this .mm to the build)");
    return nil;
#else
    if (width <= 0 || height <= 0 || sourceBytes.length == 0) {
        if (error) *error = CTDError(CrunchTextureDecoderErrorUnpackBeginFailed, @"invalid width/height or empty source data");
        return nil;
    }

    // crnd_unpack_begin() decompresses the stream's own decoder tables
    // and endpoint/selector palettes - once per object, not once per
    // mip (see crn_decomp.h's own doc comment on crnd_unpack_begin).
    // No crnd_set_memory_callbacks() call needed first - the library's
    // default alloc/free/realloc hooks are backed by plain malloc()/
    // free() unless overridden, which is fine for this one-shot,
    // single-threaded-per-call usage.
    crnd::crnd_unpack_context context = crnd::crnd_unpack_begin(sourceBytes.bytes, (crnd::uint32)sourceBytes.length);
    if (!context) {
        if (error) *error = CTDError(CrunchTextureDecoderErrorUnpackBeginFailed,
            @"crnd_unpack_begin rejected this object's bytes - not a valid/complete CRN stream");
        return nil;
    }

    // Same base-mip-level block math t2pd_base_level_size already uses
    // for plain (non-crunched) DXT5 in Texture2DPixelDecoder.m - crunch
    // decompresses BACK to exactly this shape, that's the whole point.
    uint32_t blocksWide = (uint32_t)((width + 3) / 4);
    uint32_t blocksHigh = (uint32_t)((height + 3) / 4);
    uint32_t rowPitchBytes = blocksWide * 16u; // 16 bytes/block for DXT5/BC3
    uint32_t dstSizeBytes = rowPitchBytes * blocksHigh;

    NSMutableData *out = [NSMutableData dataWithLength:dstSizeBytes];
    void *dstPtr = out.mutableBytes;
    // crnd_unpack_level takes an ARRAY of destination pointers (one per
    // cubemap face) - a plain 2D Texture2D is always a single face, so
    // this is always a 1-element array. level_index 0 is always the
    // base/largest level (see CrunchTextureDecoder.h's top comment on
    // why only level 0 is ever requested here).
    void *faces[1] = { dstPtr };
    BOOL ok = crnd::crnd_unpack_level(context, faces, dstSizeBytes, rowPitchBytes, 0);
    crnd::crnd_unpack_end(context);

    if (!ok) {
        if (error) *error = CTDError(CrunchTextureDecoderErrorUnpackLevelFailed,
            [NSString stringWithFormat:@"crnd_unpack_level failed for %dx%d (declared by Texture2DFields, may disagree with what the crunch stream itself encodes)", width, height]);
        return nil;
    }

    return out;
#endif
}

@end
