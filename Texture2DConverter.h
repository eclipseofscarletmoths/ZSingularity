// Texture2DConverter.h
//
// Layer C of the Texture2D retarget pipeline rework (see Rework.txt,
// project root - "Layer C - Pixel converter"). Sits between the Layer
// A+B glue (BundleTexture2DEnumerator.h - locates and schema-parses
// every Texture2D object in a bundle) and the not-yet-built Layer D
// (the disk-backed bundle writer that will patch objects and produce
// a new UnityFS bundle). This file answers exactly two questions per
// enumerated Texture2D object:
//
//   1. Does this object's m_TextureFormat need to change at all?
//      (conversionDecisionForRawFormat: - Rework.txt's Layer C table)
//   2. If yes, what are its RGBA32 bytes?
//      (-convertObjectsInEnumerator:handler: - calls
//      -[BundleTexture2DEnumerator sourcePixelBytesForObject:error:]
//      to resolve the still-encoded source bytes, then
//      +[Texture2DPixelDecoder decodeToRGBA32FromRawFormat:...] to
//      decode them - that method already routes DXT5Crunched (29)
//      through CrunchTextureDecoder internally before falling into its
//      own DXT5 block-decode path, so this file does not call
//      CrunchTextureDecoder directly; see Texture2DPixelDecoder.m's
//      own DXT5Crunched branch)
//
// CONVERSION TABLE (Rework.txt, Layer C):
//
//   RGBA32 (4)          -> leave unchanged
//   ASTC RGBA 4x4 (48)  -> leave unchanged
//   ASTC RGBA 6x6 (50)  -> leave unchanged
//   DXT1 (10)           -> decode -> RGBA32
//   DXT5 (12)           -> decode -> RGBA32
//   DXT5Crunched (29)   -> Crunch decode -> DXT5 -> RGBA32 (handled
//                          inside Texture2DPixelDecoder, see above)
//   RGB24 (3)           -> decode -> RGBA32
//   anything else       -> fail closed, object left unchanged (in
//                          practice unreachable here - Texture2DSchema
//                          already rejects any object whose
//                          m_TextureFormat isn't one of these seven at
//                          parse time, so an enumerated object with a
//                          non-nil .info can only ever carry one of
//                          them; kept as a defensive decision case
//                          rather than an assert, per this project's
//                          own "fail closed, don't trust an invariant
//                          you didn't just check" posture elsewhere)
//
// MEMORY POSTURE (Rework.txt, Layer C "Decoder requirements" + "the
// important memory rule"): -convertObjectsInEnumerator:handler: below
// processes exactly one Texture2D object at a time, inside its own
// @autoreleasepool, and hands each result to `handler` SYNCHRONOUSLY
// before moving to the next object. It never builds an NSArray of
// results and never holds more than one object's source bytes and one
// object's decoded RGBA32 bytes alive at once - see Rework.txt: "Do
// not keep an NSArray<NSData *> of converted textures." THE HANDLER
// BLOCK MUST NOT retain result.rgba32Data past its own invocation
// (e.g. by appending it to an array) - Layer D's job (not built yet)
// is to consume each result immediately: write RGBA32 bytes straight
// to a disk-backed .resS staging file (or hold exactly the one most
// recent buffer if inlining), then let it go. This file provides the
// per-texture decode step only; it does not write anything to disk
// itself.
//
// SCOPE - WHAT THIS FILE DOES NOT DO: patch any object's bytes in
// place, touch m_TargetPlatform, stage a .resS file, or write a new
// bundle. Every ZSTexture2DConversionResult below is purely in-memory,
// one object's worth at a time, for Layer D to consume. See
// Rework.txt's "Layer D - Disk-backed bundle writer" for what comes
// next.

#import <Foundation/Foundation.h>

@class BundleTexture2DEnumerator;
@class ZSTexture2DEnumeratedObject;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const Texture2DConverterErrorDomain;

typedef NS_ENUM(NSInteger, Texture2DConverterErrorCode) {
    // -sourcePixelBytesForObject:error: failed - see the wrapped
    // underlying error (BundleTexture2DEnumeratorErrorDomain).
    Texture2DConverterErrorSourceBytesUnavailable = 1,

    // +[Texture2DPixelDecoder decodeToRGBA32FromRawFormat:...] failed
    // - see the wrapped underlying error
    // (Texture2DPixelDecoderErrorDomain/CrunchTextureDecoderErrorDomain).
    Texture2DConverterErrorDecodeFailed,

    // The decoder returned data, but its length isn't exactly
    // width * height * 4 - this project's own cheap self-check (see
    // this file's header note on Texture2DSchema's "self-verifying,
    // not self-correcting" philosophy) before ever handing the bytes
    // to a caller. Distinct from Rework.txt's later, separate
    // "Validation strategy" (reparsing the rebuilt OBJECT/SerializedFile
    // after Layer D writes it) - this check only concerns the decoded
    // pixel buffer itself, immediately after decode, before Layer D
    // exists to write anything.
    Texture2DConverterErrorUnexpectedByteCount,

    // conversionDecisionForRawFormat: returned
    // ZSTexture2DConversionUnsupported - see this header's top comment
    // on why this is expected to be unreachable for anything
    // Texture2DSchema already parsed, kept as a fail-closed guard
    // rather than an assert.
    Texture2DConverterErrorUnsupportedFormat,
};

// What Rework.txt's Layer C conversion table says about one raw
// m_TextureFormat value.
typedef NS_ENUM(NSInteger, ZSTexture2DConversionDecision) {
    ZSTexture2DConversionNotNeeded = 0,  // format in {4, 48, 50} - already iOS-native, object's pixel bytes are left exactly as-is
    ZSTexture2DConversionRequired,        // format in {3, 10, 12, 29} - must be decoded to RGBA32
    ZSTexture2DConversionUnsupported,     // anything else - fail closed, see this header's top comment on why this should not occur in practice
};

// One object's conversion outcome, handed to the caller-supplied
// handler block by -convertObjectsInEnumerator:handler: below. See
// this header's MEMORY POSTURE note: the handler must not retain
// .rgba32Data past its own invocation.
@interface ZSTexture2DConversionResult : NSObject

@property (nonatomic, strong) ZSTexture2DEnumeratedObject *object; // the enumerated object this result is for - carries pathID/tableEntry/info, everything a Layer D patch step will need
@property (nonatomic, assign) ZSTexture2DConversionDecision decision;

// Populated iff decision == ZSTexture2DConversionRequired AND error
// is nil - tightly-packed, row-major RGBA32, exactly
// object.info.width * object.info.height * 4 bytes (see
// Texture2DConverterErrorUnexpectedByteCount above). nil for
// ZSTexture2DConversionNotNeeded (nothing to convert - Layer D keeps
// the object's existing pixel bytes untouched) and for any decision
// where .error is set.
@property (nonatomic, strong, nullable) NSData *rgba32Data;

// Mirrors object.info.width/height for convenience - same values,
// just avoids a caller reaching back into .info for the one thing
// it's most likely to need alongside rgba32Data (e.g. computing the
// new m_CompleteImageSize = width * height * 4 per Rework.txt's patch
// policy).
@property (nonatomic, assign) int32_t width;
@property (nonatomic, assign) int32_t height;

// Set (Texture2DConverterErrorDomain) iff this object's conversion
// could not be completed - source bytes unavailable, decode failure,
// unexpected output size, or unsupported format. .rgba32Data is nil
// whenever this is set. A per-object failure here does not stop
// -convertObjectsInEnumerator:handler: from continuing to the next
// object - same "report per item" posture BundleTexture2DEnumerator.h
// already uses one layer down.
@property (nonatomic, strong, nullable) NSError *error;

@end

typedef void (^ZSTexture2DConversionHandler)(ZSTexture2DConversionResult *result);

@interface Texture2DConverter : NSObject

// Rework.txt's Layer C conversion table, as a pure function of the
// raw m_TextureFormat value - see this header's top comment for the
// table itself. Does not touch any object/bytes; a caller can use
// this on its own (e.g. for a dry-run count of how many textures in a
// bundle actually need re-encoding) without going through
// -convertObjectsInEnumerator:handler: at all.
+ (ZSTexture2DConversionDecision)conversionDecisionForRawFormat:(int32_t)rawFormat;

// Walks every ZSTexture2DEnumeratedObject in `enumerator.texture2DObjects`
// that parsed successfully (.info != nil - an object whose .parseError
// is already set has nothing for this layer to convert; Layer B/the
// enumerator has already reported that failure) and, for each one:
//
//   1. Looks up conversionDecisionForRawFormat:(object.info.textureFormat).
//   2. If ZSTexture2DConversionNotNeeded: calls `handler` with a
//      result carrying that decision and nil rgba32Data/error. Cheap -
//      no source bytes are resolved, no decode happens.
//   3. If ZSTexture2DConversionRequired: inside its own
//      @autoreleasepool, resolves this object's source pixel bytes via
//      [enumerator sourcePixelBytesForObject:object error:...], decodes
//      them via +[Texture2DPixelDecoder decodeToRGBA32FromRawFormat:...]
//      (routing DXT5Crunched through CrunchTextureDecoder internally -
//      see this header's top comment), verifies the decoded length is
//      exactly width * height * 4, and calls `handler` with the result
//      (either populated rgba32Data, or .error set - see this header's
//      error codes). Both the resolved source bytes and the decoded
//      RGBA32 buffer are released when the autorelease pool drains at
//      the end of this iteration, i.e. immediately after `handler`
//      returns - see this header's MEMORY POSTURE note.
//   4. If ZSTexture2DConversionUnsupported: calls `handler` with
//      .error set to Texture2DConverterErrorUnsupportedFormat - see
//      this header's top comment on why this is expected unreachable.
//
// `handler` is called synchronously, once per successfully-parsed
// Texture2D object, in `enumerator.texture2DObjects` order. This
// method itself returns only after every object has been handed to
// `handler`.
+ (void)convertObjectsInEnumerator:(BundleTexture2DEnumerator *)enumerator
                            handler:(ZSTexture2DConversionHandler)handler;

@end

NS_ASSUME_NONNULL_END
