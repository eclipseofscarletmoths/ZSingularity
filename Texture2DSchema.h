// Texture2DSchema.h
//
// Layer B of the Texture2D retarget pipeline rework (see Rework.txt,
// project root - "New architecture" - and Texture2DFields.h's own note
// on why this replaces the deleted profile-guessing machinery). A
// SINGLE fixed parser for exactly one known build:
//
//   Limbus Company, Unity 6000.3.12f1
//
// No candidate profiles, no runtime schema detection, no fuzzy search
// for m_TextureFormat. Rework.txt's own byte-level survey of 691 real
// Texture2D dumps from this exact build is the source of the field
// list below; the two fields the old (deleted) parser force-assumed
// present - m_VTOnly, m_AlphaIsTransparency - are NOT in that schema,
// which is the entire explanation for the +4 cursor drift the old
// implementation kept working around instead of fixing at the root.
//
// SCHEMA (see Rework.txt for the full annotated version):
//
//   m_Name                       serialized string (len-prefixed, align4)
//   m_IsAlphaChannelOptional     bool, align4
//   m_Width                      int32
//   m_Height                     int32
//   m_CompleteImageSize          int32
//   m_MipsStripped               int32  (skipped - not needed downstream)
//   m_TextureFormat              int32
//   m_MipCount                   int32
//   m_IsReadable/                3 bytes, align4
//   m_IsPreProcessed/
//   m_IgnoreMipmapLimit
//   m_MipmapLimitGroupName       serialized string, align4
//   m_StreamingMipmaps           bool, align4
//   m_StreamingMipmapsPriority   int32
//   m_ImageCount                 int32
//   m_TextureDimension           int32
//   m_TextureSettings            24 bytes (GLTextureSettings - opaque here)
//   m_LightmapFormat             int32
//   m_ColorSpace                 int32
//   m_PlatformBlob               byte array (len-prefixed), align4
//   image data                   byte array (len-prefixed), align4
//   m_StreamData                 StreamingInfo - ALWAYS the final field,
//                                 align4 (see note below):
//                                   offset  uint64
//                                   size    uint32
//                                   pathLen uint32
//                                   path    pathLen bytes
//
// This is deliberately a STRUCTURAL parser, not a content-scanning one:
// every field's byte offset is a fixed consequence of the fields before
// it, so m_TextureFormat's offset is derived, never searched for - see
// Rework.txt's "Why fuzzy neighboring-byte search is the wrong fix" for
// why a bounded search around the expected value would be a strictly
// worse parser even though it can appear to "fix" the same symptom.
//
// Being the object's last field doesn't exempt m_StreamData.path from
// alignment: the object as a whole is still 4-byte aligned, so the
// cursor is aligned once more after the path bytes, same as after every
// other string/byte-array field in this schema. Streamed textures'
// "archive:/CAB-.../CAB-....resS" paths are almost never a multiple of
// 4 bytes long, so skipping this align4 previously left the cursor 1
// byte short for most streamed objects (inline objects, with pathLen
// == 0, were unaffected).
//
// m_StreamData is required to be the object's last field: after that
// final alignment, the cursor must land EXACTLY on the object's end.
// Any leftover or missing bytes there means this schema doesn't match
// what was actually parsed (wrong object range from the caller, or a
// build this schema doesn't apply to) and the whole parse is rejected
// rather than silently accepted - see Texture2DSchemaErrorTrailingData
// below.
//
// WHAT THIS FILE DOES NOT DO: decode pixels (Texture2DPixelDecoder.h /
// CrunchTextureDecoder.h - Layer C), read bytes out of a bundle/archive
// (BundleTexture2DEnumerator.h - Layer A+B glue), or patch/rewrite an
// object's bytes (not built yet - the next step after enumeration, per
// Rework.txt's patch policy). This is read-only, single-object,
// zero-I/O: NSData in, ZSTexture2DInfo out.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const Texture2DSchemaErrorDomain;

typedef NS_ENUM(NSInteger, Texture2DSchemaErrorCode) {
    // A fixed-position or length-prefixed field read past the end of
    // the object bytes handed in. Most commonly means the caller's
    // object byte range (from SerializedObjectTable) is wrong, NOT
    // that this specific object is malformed - a real truncation this
    // late in the schema, after m_Name/m_MipmapLimitGroupName have
    // already parsed as plausible strings, would be unusual.
    Texture2DSchemaErrorTruncated = 1,

    // m_Width/m_Height parsed but are <= 0, or exceed
    // kZSTexture2DMaxDimension - see the constant below. A structural
    // parse landing on plausible-looking-but-wrong offsets tends to
    // produce nonsense dimensions before it produces a crash, so this
    // check is one of the schema's own self-verification points, not
    // just a sanity nicety.
    Texture2DSchemaErrorInvalidDimensions,

    // m_MipCount parsed but is <= 0 or exceeds
    // kZSTexture2DMaxMipCount - see the constant below.
    Texture2DSchemaErrorInvalidMipCount,

    // m_TextureFormat parsed but isn't one of the seven values
    // Rework.txt's corpus survey confirmed for this build (see
    // TAT2TextureFormat in Texture2DFields.h). Deliberately a hard
    // parse failure, not a soft "unknown format" flag the caller might
    // forget to check - Rework.txt's whole point is that a structural
    // parser should be self-verifying, and an out-of-corpus format
    // value is exactly the kind of signal that means the cursor landed
    // somewhere it shouldn't have.
    Texture2DSchemaErrorUnsupportedFormat,

    // Exactly one of {inline image data, StreamingInfo} should carry
    // this object's pixel bytes. Both empty, or both non-empty (a
    // non-zero image-data length AND a non-zero StreamingInfo size),
    // means the parse likely drifted rather than that this object
    // genuinely has two homes for its pixels - see Rework.txt: "An
    // empty path/size is a valid non-streamed Texture2D," which
    // implies the converse (non-empty stream size) is expected to mean
    // NOT inline.
    Texture2DSchemaErrorInconsistentPixelData,

    // After m_StreamData.path, the cursor did not land exactly on the
    // object's end. m_StreamData is documented (Rework.txt) as always
    // the final serialized field - any slack here means this schema
    // does not describe the object that was actually handed in.
    Texture2DSchemaErrorTrailingData,
};

// Sanity bounds, not real Unity/hardware limits - wide enough to never
// reject a legitimate asset, narrow enough that a structural parse
// which drifted onto the wrong offsets is very likely to trip one of
// these before it trips anything else. 8192 comfortably covers every
// texture size a mobile gacha/VN title like this one would ship (this
// project has not seen anything close to it in the supplied corpus -
// Rework.txt's dump skews toward portrait character art and UI, not
// desktop-scale environment textures).
extern const int32_t kZSTexture2DMaxDimension;   // 8192
// 14 mips covers a base dimension up to 2^14 = 16384, one full stop
// past kZSTexture2DMaxDimension itself.
extern const int32_t kZSTexture2DMaxMipCount;    // 14

// Layer B's parse result - one Texture2D object's layout, exactly as
// Rework.txt's ZSTexture2DInfo describes it (plus mipCountOffset, which
// that struct sketch omitted but its own "Patch policy" section
// immediately goes on to reference - the retarget step needs it to
// write m_MipCount = 1 in place, same as it needs formatOffset/
// completeImageSizeOffset, so it's captured here rather than
// rediscovered later).
//
// Every *Offset field is relative to the start of the object bytes
// this was parsed FROM (the same NSData/byte span passed to
// +parseObjectBytes:error: below) - a caller patching an object in
// place needs to add that object's own absolute base position (e.g.
// SerializedObjectTable.dataOffset + SerializedObject.byteStart) to
// get a position inside the owning node's data, same convention
// SerializedObjectTable.h already uses for byteStart.
@interface ZSTexture2DInfo : NSObject

@property (nonatomic, copy) NSString *name;               // m_Name, decoded UTF8 - not used for pixel conversion, kept for logging/enumeration only

@property (nonatomic, assign) int32_t width;               // m_Width
@property (nonatomic, assign) int32_t height;               // m_Height
@property (nonatomic, assign) int32_t completeImageSize;   // m_CompleteImageSize (as originally parsed - a converted object's new value is computed by the caller, not written back into this struct)
@property (nonatomic, assign) int32_t textureFormat;        // m_TextureFormat, raw value - see TAT2TextureFormat in Texture2DFields.h
@property (nonatomic, assign) int32_t mipCount;             // m_MipCount

// Byte offsets of the fields a retarget/patch step needs to rewrite in
// place. See this class's own top comment for the "relative to the
// object's own start" convention.
@property (nonatomic, assign) NSUInteger formatOffset;              // m_TextureFormat's own 4 bytes
@property (nonatomic, assign) NSUInteger completeImageSizeOffset;   // m_CompleteImageSize's own 4 bytes
@property (nonatomic, assign) NSUInteger mipCountOffset;            // m_MipCount's own 4 bytes

// Inline image-data array, if present (see hasInlineImageData below).
@property (nonatomic, assign) NSUInteger imageDataLengthFieldOffset; // the array's own uint32 length prefix
@property (nonatomic, assign) NSUInteger imageDataOffset;            // first byte of the array's contents
@property (nonatomic, assign) uint32_t imageDataLength;              // same value as the length prefix, kept alongside the offset for convenience

// m_StreamData (StreamingInfo), if present (see hasStreamData below).
@property (nonatomic, assign) NSUInteger streamDataOffset;  // start of the whole StreamingInfo struct (offset/size/pathLen/path)
@property (nonatomic, assign) uint64_t streamOffset;         // StreamingInfo.offset - see BundleTexture2DEnumerator.h for how this is resolved against an actual archive
@property (nonatomic, assign) uint32_t streamSize;           // StreamingInfo.size
@property (nonatomic, copy, nullable) NSString *streamPath;  // StreamingInfo.path, decoded UTF8 - e.g. "archive:/CAB-.../CAB-....resS"

@property (nonatomic, assign) BOOL hasInlineImageData;  // imageDataLength > 0
@property (nonatomic, assign) BOOL hasStreamData;        // streamSize > 0 (see Texture2DSchemaErrorInconsistentPixelData - exactly one of these two is expected to be YES)

// Total length of the object bytes this was parsed from - i.e. the
// exact cursor position m_StreamData.path was required to end on. Kept
// for the post-write reparse/verification step Rework.txt's
// "Validation strategy" describes (not implemented by this class
// itself - this is a read-only, single-pass parser).
@property (nonatomic, assign) NSUInteger objectLength;

@end

@interface Texture2DSchema : NSObject

// Parses `objectBytes` (one Texture2D object's exact byte range - e.g.
// a subrange of a SerializedFile CAB node's data, sliced using a
// SerializedObject's byteStart/byteSize from SerializedObjectTable.h)
// as a Unity 6000.3.12f1 Texture2D per this file's fixed schema.
//
// Returns nil and fills `error` (Texture2DSchemaErrorDomain, one of the
// codes above) if the schema doesn't fit - out-of-bounds field, a
// dimension/mip-count/format value outside this build's known corpus,
// inconsistent inline/streamed pixel state, or leftover bytes after
// m_StreamData.path. This never guesses or falls back to a different
// layout - see this header's top comment.
+ (nullable ZSTexture2DInfo *)parseObjectBytes:(NSData *)objectBytes error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
