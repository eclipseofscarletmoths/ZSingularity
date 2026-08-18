// Texture2DFields.h
//
// TextureAtlasTransplant.m's existing object-level diff/copy treats
// every object as an opaque blob - fine for TextAsset (identical bytes
// across platforms - see BundleTransplant.m's own README note) but not
// for Texture2D, where the SAME PathID's bytes differ across platforms
// on purpose: PC's are DXT/DXT5Crunched, iOS's are ASTC 6x6, and the
// object's own header fields (m_TextureFormat/m_Width/m_Height/
// m_MipCount/m_CompleteImageSize) declare which. A verbatim byte copy
// carries PC's header (and PC's compressed pixels) into an iOS bundle
// wholesale - Metal can't bind DXT at all, so the object doesn't just
// look wrong, texture creation fails outright.
//
// This file is ONLY the reader/writer for those header fields inside
// one already-located Texture2D object's own byte range (from
// SerializedObjectTable - see that header for how the object itself is
// found). It does not decode pixels - that's a separate module this
// plugs into once it exists. It also does not decide WHAT to write;
// callers (TextureAtlasTransplant.m) own that decision.
//
// This tweak targets Limbus Company's Unity 6000.3.12f1 build. The
// previous parser used a 2021/2022-era Texture2D profile. Unity 6's
// Texture2D layout includes m_VTOnly and m_AlphaIsTransparency after
// m_StreamingMipmapsPriority; together they add 4 bytes after alignment.
// The parser below follows that exact field order and uses structural
// validation against the object's own trailing StreamingInfo.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const Texture2DFieldsErrorDomain;

// Known m_TextureFormat values this project cares about - see the
// project's own notes (PC mods: RGB24/RGBA32/DXT1/DXT5/DXT5Crunched;
// iOS stock: RGBA ASTC 6x6 only). Anything else encountered is still
// reported (rawFormat on Texture2DHeader is unfiltered) but
// +decodeSupportedFormat: below only claims these four.
typedef NS_ENUM(int32_t, TAT2TextureFormat) {
    TAT2TextureFormatRGB24           = 3,
    TAT2TextureFormatRGBA32          = 4,
    TAT2TextureFormatDXT1            = 10,
    TAT2TextureFormatDXT5            = 12,
    TAT2TextureFormatRGBAASTC6x6     = 50,
    TAT2TextureFormatDXT5Crunched    = 29,
};

// Which version-conditional fields are present, in Unity's own
// serialization order, between m_Name and m_Width. See this header's
// top comment - kTAT2ProfileDefault is a best-guess starting point, not
// a confirmed one.
typedef struct {
    BOOL hasForcedFallbackFormat;     // int, 2017.3+
    BOOL hasDownscaleFallback;        // bool, 2017.3+
    BOOL hasIsAlphaChannelOptional;   // bool, 2020.2+
    // (m_Width, m_Height, m_CompleteImageSize always present here)
    BOOL hasMipsStripped;             // int, 2020.1+
    // (m_TextureFormat always present here)
    BOOL hasMipCountAsInt;            // 2017.3+: int m_MipCount. Pre-2017.3 used bool m_MipMap instead - NOT supported, this project has no pre-2017.3 sample and Limbus Company is not that old.
    // Unity 6000.3.12f1 has m_IsReadable, m_IsPreProcessed,
    // m_IgnoreMipmapLimit, then m_MipmapLimitGroupName before the
    // streaming fields. m_MipmapLimitGroupName is a real per-object
    // string field, so its length must be walked rather than assumed empty.
    //  NOT gated behind a profile flag on purpose - unlike everything
    //  else in this struct, these aren't version-conditional (they
    //  either exist for this whole build or they don't - no sample has
    //  ever shown them absent), so there is no "maybe absent" case to
    //  model. m_MipmapLimitGroupName is a real per-OBJECT content field
    //  (an artist-assignable label), not a build constant - it happens
    //  to be empty on the overwhelming majority of textures, which is
    //  exactly what let this go unnoticed for as long as it did: an
    //  empty string's length prefix coincidentally cost the same 4
    //  bytes older wrong profiles already landed on by chance. Any
    //  texture with a real (non-empty) group name assigned breaks that
    //  coincidence and needs this field actually parsed - see the .m.)
    BOOL hasIsPreProcessed;           // bool, long-standing
    BOOL hasIgnoreMipmapLimit;        // bool, present under this name or the older m_IgnoreMasterTextureLimit across the whole range this project targets
    BOOL hasStreamingMipmaps;         // bool, 2020.2+
    BOOL hasStreamingMipmapsPriority; // int, 2020.2+ (only meaningful if hasStreamingMipmaps)
    // Unity 6 (including 6000.3.12f1) serializes these two bools after
    // m_StreamingMipmapsPriority and before m_ImageCount.
    BOOL hasVTOnly;                   // bool, Unity 6 player Texture2D layout
    BOOL hasAlphaIsTransparency;      // bool, Unity 6 player Texture2D layout
    // (m_ImageCount, m_TextureDimension, GLTextureSettings block,
    //  m_LightmapFormat, m_ColorSpace always present here, fixed size -
    //  see the .m for their sizes)
    BOOL hasPlatformBlob;             // byte array (u32 len + bytes, aligned), 2020.1+
    // then: image data byte array (u32 len + bytes, aligned), then
    // m_StreamData (StreamingInfo) IF this object streams - detected
    // via tat_find_stream_data_offset_field, not via this profile.
} TAT2VersionProfile;

// Authoritative profile for Limbus Company's Unity 6000.3.12f1 build.
// The previous fallback was a Unity 2021/2022-era guess; in Unity 6,
// m_VTOnly and m_AlphaIsTransparency are serialized after
// m_StreamingMipmapsPriority. Omitting those fields produces the exact
// +4-byte cursor drift observed at the image-data/StreamingInfo boundary.
extern const TAT2VersionProfile kTAT2ProfileDefault;

// Everything this module can locate/patch about one Texture2D object's
// own bytes. All offsets are relative to the object's own byte range
// (i.e. objectBytes[0] is this object's first byte, same convention
// TextureAtlasTransplant.m already uses for moddedBytes/targetBytes -
// NOT relative to the owning node's dataOffset).
@interface Texture2DHeader : NSObject

@property (nonatomic, assign, readonly) int32_t width;
@property (nonatomic, assign, readonly) int32_t height;
@property (nonatomic, assign, readonly) int32_t completeImageSize;
@property (nonatomic, assign, readonly) int32_t rawFormat;   // unfiltered m_TextureFormat value - see TAT2TextureFormat for the known ones
@property (nonatomic, assign, readonly) int32_t mipCount;

// Byte offsets of each field above, for patching - see
// -patchWidth:height:completeImageSize:format:mipCount:inObjectBytes:.
@property (nonatomic, assign, readonly) NSUInteger widthOffset;
@property (nonatomic, assign, readonly) NSUInteger heightOffset;
@property (nonatomic, assign, readonly) NSUInteger completeImageSizeOffset;
@property (nonatomic, assign, readonly) NSUInteger formatOffset;
@property (nonatomic, assign, readonly) NSUInteger mipCountOffset;

// The inline image-data byte array (u32 length prefix + that many
// bytes) that sits after the fixed header fields and before
// m_StreamData (if any). imageDataLengthFieldOffset points at the u32
// length prefix itself; imageDataOffset/imageDataLength describe the
// bytes right after it. For a streamed object this array is normally
// empty (imageDataLength == 0) - the real pixels live in .resS,
// reached via TextureAtlasTransplant.m's existing
// tat_find_stream_data_offset_field, not through this array.
@property (nonatomic, assign, readonly) NSUInteger imageDataLengthFieldOffset;
@property (nonatomic, assign, readonly) NSUInteger imageDataOffset;
@property (nonatomic, assign, readonly) NSUInteger imageDataLength;

// YES if streamDataOffsetFieldPos (as found by
// tat_find_stream_data_offset_field, pass NSNotFound if the caller
// hasn't found one / this object doesn't stream) sits exactly where
// this parse expects m_StreamData to start (immediately after the
// image-data array, 4-byte aligned). This is the main cross-check that
// catches a wrong TAT2VersionProfile - see this header's top comment.
@property (nonatomic, assign, readonly) BOOL streamDataPositionConfirmed;

// Brute-force detection of the real TAT2VersionProfile for whatever
// Unity build produced sampleObjectBytes, instead of trusting
// kTAT2ProfileDefault's hardcoded guess - see this header's top
// comment ("WHY A VERSION PROFILE") for why the guess can't be
// trusted across Unity versions.
//
// Of the 12 fields in TAT2VersionProfile, hasMipCountAsInt, hasVTOnly, and hasAlphaIsTransparency are fixed
// YES (pre-2017.3 isn't supported - see that field's own comment), so
// there are at most 2^9 = 512 candidate profiles - cheap to try all
// of them.
//
// sampleObjectBytes / streamDataOffsetFieldPositions: parallel arrays,
// one entry per sample Texture2D object (its own byte range, same
// convention as +parseHeaderInObjectBytes:...'s objectBytes; and the
// NSNotFound-boxed-or-real position tat_find_stream_data_offset_field
// found for that same object, or a boxed NSNotFound if it doesn't
// stream). Pass as many samples as are available - callers should
// prefer at least 5-10 streamed objects, since a candidate profile
// that merely produces plausible width/height on ONE object can pass
// by chance, but streamDataPositionConfirmed agreeing across several
// independently-verified objects is a much stronger signal. Samples
// that don't stream (boxed NSNotFound) still contribute their
// width/height/format plausibility check, just not the strong
// cross-check.
//
// A candidate profile is accepted only if it parses EVERY sample
// successfully, and - for every sample that has a real (non-NSNotFound)
// stream position - the parse's streamDataPositionConfirmed is YES.
//
// Returns YES and fills *outProfile if EXACTLY ONE candidate profile
// survives that filter across all samples. Returns NO if zero
// candidates survive (samples don't agree with any single profile -
// possibly corrupt/mixed-build input) or more than one candidate
// survives (genuine ambiguity - typically means too few samples, or
// samples that happen not to exercise the fields that would
// distinguish the surviving candidates from each other; e.g. if none
// of the samples stream, hasStreamingMipmaps/-Priority can't be
// pinned down by width/height plausibility alone). Callers should log
// loudly and fall back to kTAT2ProfileDefault in either failure case,
// per this header's top comment, rather than silently picking one.
+ (BOOL)detectVersionProfile:(TAT2VersionProfile *)outProfile
            fromObjectSamples:(NSArray<NSData *> *)sampleObjectBytes
   streamDataOffsetFieldPositions:(NSArray<NSNumber *> *)streamDataOffsetFieldPositions;

// Parses objectBytes (one Texture2D object's own byte range - see this
// class's top comment on the offset convention) using `profile` for the
// version-conditional fields before m_Width. streamDataOffsetFieldPos:
// pass the value tat_find_stream_data_offset_field already found for
// this same objectBytes (or NSNotFound if it found none / this object
// doesn't stream) - used only for streamDataPositionConfirmed's
// cross-check, not for locating anything itself.
//
// Returns nil if: objectBytes is too short to hold the fixed fields
// this profile implies, OR width/height parse outside 1...8192, OR
// rawFormat parses outside a generous plausible int32 enum range, OR
// mipCount parses outside 1...14 (full mip chain for an 8192px
// texture), OR (when streamDataOffsetFieldPos != NSNotFound) the
// computed image-data array's end doesn't land exactly on
// streamDataOffsetFieldPos, OR (when streamDataOffsetFieldPos ==
// NSNotFound, i.e. the caller believes this object doesn't stream) the
// trailing m_StreamData (StreamingInfo) struct - offset(8)+size(4)+
// pathLen(4), always present even when unused - doesn't have pathLen==0
// and exactly consume the rest of objectBytes. Any of
// these means `profile` is wrong for this object, not that the object
// itself is malformed - see this header's top comment before loosening
// this check.
+ (nullable instancetype)parseHeaderInObjectBytes:(NSData *)objectBytes
                                           profile:(TAT2VersionProfile)profile
                        streamDataOffsetFieldPos:(NSUInteger)streamDataOffsetFieldPos
                                             error:(NSError **)error;

// In-place patch of the five fixed-size int32 fields this header
// located - does NOT touch imageData (that's a variable-length array;
// callers replace it themselves the same way
// TextureAtlasTransplant.m's tat_transplant_one already grows/appends
// payload, then re-run a fresh parse against the rebuilt bytes if they
// need updated array offsets afterward, since appending shifts nothing
// before the array but the array's own length prefix and bytes do move
// relative to nothing - only mipCount/format/width/height/
// completeImageSize live before it and are fixed-size, so this patch
// alone never invalidates imageDataOffset). objectBytes must be the
// exact same NSMutableData this header was parsed from - the offset
// properties are only meaningful against that buffer.
- (void)patchWidth:(int32_t)width
            height:(int32_t)height
 completeImageSize:(int32_t)completeImageSize
            format:(int32_t)format
          mipCount:(int32_t)mipCount
     inObjectBytes:(NSMutableData *)objectBytes;

@end

NS_ASSUME_NONNULL_END
