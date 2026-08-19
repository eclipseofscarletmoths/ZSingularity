// Texture2DSchema.m
//
// See Texture2DSchema.h for the schema itself and why it's fixed rather
// than detected. One convention worth calling out since
// SerializedObjectTable.m's own top comment flags the opposite case for
// its file: every multi-byte field walked here (m_Width, m_TextureFormat,
// StreamingInfo.offset, ...) is LITTLE-endian - this is all inside a
// SerializedFile's OBJECT DATA region, same as SerializedObjectTable's
// own object-table entries (pathID/byteStart/byteSize/typeID), not its
// big-endian structural HEADER. Getting this backwards would produce
// plausible-looking-but-wrong numbers, not a loud failure - same trap
// that file's comment warns about.

#import "Texture2DSchema.h"
#import "Texture2DFields.h"
#import "ZTweakLog.h"
#include <stdint.h>

NSString * const Texture2DSchemaErrorDomain = @"Texture2DSchemaErrorDomain";

const int32_t kZSTexture2DMaxDimension = 8192;
const int32_t kZSTexture2DMaxMipCount = 14;

// GLTextureSettings is opaque to this parser - Rework.txt's schema
// dump only needed its total size (24 bytes) to skip past it correctly,
// not its internal field layout, since nothing inside it is read or
// patched by this pipeline.
static const NSUInteger kGLTextureSettingsSize = 24;

#pragma mark - bounds-checked LE readers

static uint32_t t2s_read_u32_le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static int32_t t2s_read_i32_le(const uint8_t *p) {
    return (int32_t)t2s_read_u32_le(p);
}
static uint64_t t2s_read_u64_le(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static inline NSUInteger t2s_align4(NSUInteger p) {
    return (p + 3) & ~(NSUInteger)3;
}

static NSError *t2s_error(Texture2DSchemaErrorCode code, NSString *reason) {
    return [NSError errorWithDomain:Texture2DSchemaErrorDomain
                                code:code
                            userInfo:reason ? @{NSLocalizedDescriptionKey: reason} : nil];
}

// Every one of these advances *p itself and returns NO (without
// touching *p further) the moment the read would run past `len` - same
// bounds-checked-cursor posture SerializedObjectTable.m's sot_cur_*
// helpers use for its own variable-position walk (the Types array).
static BOOL t2s_read_u32(const uint8_t *base, NSUInteger len, NSUInteger *p, uint32_t *out) {
    if (*p + 4 > len) return NO;
    *out = t2s_read_u32_le(base + *p);
    *p += 4;
    return YES;
}
static BOOL t2s_read_i32(const uint8_t *base, NSUInteger len, NSUInteger *p, int32_t *out) {
    uint32_t u;
    if (!t2s_read_u32(base, len, p, &u)) return NO;
    *out = (int32_t)u;
    return YES;
}
static BOOL t2s_read_u64(const uint8_t *base, NSUInteger len, NSUInteger *p, uint64_t *out) {
    if (*p + 8 > len) return NO;
    *out = t2s_read_u64_le(base + *p);
    *p += 8;
    return YES;
}
static BOOL t2s_skip(NSUInteger len, NSUInteger *p, NSUInteger n) {
    if (*p + n > len) return NO;
    *p += n;
    return YES;
}
static BOOL t2s_align(NSUInteger len, NSUInteger *p) {
    NSUInteger aligned = t2s_align4(*p);
    if (aligned > len) return NO; // only the alignment padding itself is out of bounds - distinct from a real field read failing
    *p = aligned;
    return YES;
}
// Length-prefixed byte array / string, Unity's standard serialized-string
// shape: uint32 LE length, then that many raw bytes (NOT NUL-terminated).
// Does not align - callers that need align4 after a string (every one in
// this schema does) call t2s_align separately, matching the schema's own
// per-field "align4" annotations in Rework.txt rather than baking
// alignment into this shared helper.
static BOOL t2s_read_lp_string(const uint8_t *base, NSUInteger len, NSUInteger *p, NSString **outStr) {
    uint32_t strLen;
    if (!t2s_read_u32(base, len, p, &strLen)) return NO;
    if (*p + strLen > len) return NO;
    if (outStr) {
        *outStr = [[NSString alloc] initWithBytes:base + *p length:strLen encoding:NSUTF8StringEncoding];
        if (!*outStr) *outStr = @""; // non-UTF8 bytes in a name field shouldn't hard-fail the whole parse
    }
    *p += strLen;
    return YES;
}
#pragma mark - schema walk

static BOOL zs_parse_texture2d(const uint8_t *base, NSUInteger len, ZSTexture2DInfo *out, NSError **error) {
    NSUInteger p = 0;

    // m_Name
    NSString *name = nil;
    if (!t2s_read_lp_string(base, len, &p, &name)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_Name ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_Name ran past object end");
        return NO;
    }

    // m_IsAlphaChannelOptional (bool)
    if (!t2s_skip(len, &p, 1)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_IsAlphaChannelOptional ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_IsAlphaChannelOptional ran past object end");
        return NO;
    }

    // m_Width / m_Height / m_CompleteImageSize
    int32_t width, height, completeImageSize;
    if (!t2s_read_i32(base, len, &p, &width)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_Width ran past object end");
        return NO;
    }
    if (!t2s_read_i32(base, len, &p, &height)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_Height ran past object end");
        return NO;
    }
    NSUInteger completeImageSizeOffset = p;
    if (!t2s_read_i32(base, len, &p, &completeImageSize)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_CompleteImageSize ran past object end");
        return NO;
    }

    // m_MipsStripped - skipped, not needed downstream
    if (!t2s_skip(len, &p, 4)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_MipsStripped ran past object end");
        return NO;
    }

    // m_TextureFormat
    NSUInteger formatOffset = p;
    int32_t textureFormat;
    if (!t2s_read_i32(base, len, &p, &textureFormat)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_TextureFormat ran past object end");
        return NO;
    }

    // m_MipCount
    NSUInteger mipCountOffset = p;
    int32_t mipCount;
    if (!t2s_read_i32(base, len, &p, &mipCount)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_MipCount ran past object end");
        return NO;
    }

    // m_IsReadable / m_IsPreProcessed / m_IgnoreMipmapLimit (3 bools)
    if (!t2s_skip(len, &p, 3)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_IsReadable/m_IsPreProcessed/m_IgnoreMipmapLimit ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_IgnoreMipmapLimit ran past object end");
        return NO;
    }

    // m_MipmapLimitGroupName
    if (!t2s_read_lp_string(base, len, &p, NULL)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_MipmapLimitGroupName ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_MipmapLimitGroupName ran past object end");
        return NO;
    }

    // m_StreamingMipmaps (bool)
    if (!t2s_skip(len, &p, 1)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_StreamingMipmaps ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_StreamingMipmaps ran past object end");
        return NO;
    }

    // m_StreamingMipmapsPriority
    if (!t2s_skip(len, &p, 4)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_StreamingMipmapsPriority ran past object end");
        return NO;
    }

    // m_ImageCount + m_TextureDimension (two int32s)
    if (!t2s_skip(len, &p, 8)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_ImageCount/m_TextureDimension ran past object end");
        return NO;
    }

    // m_TextureSettings (GLTextureSettings, opaque)
    if (!t2s_skip(len, &p, kGLTextureSettingsSize)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_TextureSettings ran past object end");
        return NO;
    }

    // m_LightmapFormat + m_ColorSpace (two int32s)
    if (!t2s_skip(len, &p, 8)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_LightmapFormat/m_ColorSpace ran past object end");
        return NO;
    }

    // m_PlatformBlob
    uint32_t blobLen;
    if (!t2s_read_u32(base, len, &p, &blobLen)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_PlatformBlob length ran past object end");
        return NO;
    }
    if (!t2s_skip(len, &p, blobLen)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_PlatformBlob contents ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_PlatformBlob ran past object end");
        return NO;
    }

    // image data
    NSUInteger imageDataLengthFieldOffset = p;
    uint32_t imageDataLength;
    if (!t2s_read_u32(base, len, &p, &imageDataLength)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"image data length ran past object end");
        return NO;
    }
    NSUInteger imageDataOffset = p;
    if (!t2s_skip(len, &p, imageDataLength)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"image data contents ran past object end");
        return NO;
    }
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after image data ran past object end");
        return NO;
    }

    // m_StreamData - ALWAYS the final field, but still align4 after it
    // (see this file's header comment / Texture2DSchemaErrorTrailingData
    // below).
    NSUInteger streamDataOffset = p;
    uint64_t streamOffset;
    uint32_t streamSize;
    if (!t2s_read_u64(base, len, &p, &streamOffset)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_StreamData.offset ran past object end");
        return NO;
    }
    if (!t2s_read_u32(base, len, &p, &streamSize)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_StreamData.size ran past object end");
        return NO;
    }
    NSString *streamPath = nil;
    if (!t2s_read_lp_string(base, len, &p, &streamPath)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"m_StreamData.path ran past object end");
        return NO;
    }

    // Even though m_StreamData.path is the object's last field, the
    // object as a whole is still 4-byte aligned (same as every other
    // string/byte-array field in this schema) - the object's total size
    // is only guaranteed a multiple of 4 once this final padding is
    // accounted for. Streamed textures almost always have a non-4-aligned
    // path length (the "archive:/CAB-.../CAB-....resS" paths), which is
    // exactly what was landing the cursor 1 byte short and tripping
    // Texture2DSchemaErrorTrailingData below for those objects; inline
    // (pathLen == 0) objects were unaffected since 0 is already aligned.
    if (!t2s_align(len, &p)) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"align4 after m_StreamData.path ran past object end");
        return NO;
    }

    // m_StreamData must consume EXACTLY to the object's end - this is
    // the schema's strongest self-check (see this file's top comment).
    if (p != len) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTrailingData,
            [NSString stringWithFormat:@"parsed to offset %lu but object is %lu bytes - schema does not match this object",
                (unsigned long)p, (unsigned long)len]);
        return NO;
    }

    // --- Validation (Texture2DSchema.h's own reader-validation contract) ---

    if (width <= 0 || height <= 0 || width > kZSTexture2DMaxDimension || height > kZSTexture2DMaxDimension) {
        if (error) *error = t2s_error(Texture2DSchemaErrorInvalidDimensions,
            [NSString stringWithFormat:@"width=%d height=%d out of [1, %d]", width, height, kZSTexture2DMaxDimension]);
        return NO;
    }

    if (mipCount <= 0 || mipCount > kZSTexture2DMaxMipCount) {
        if (error) *error = t2s_error(Texture2DSchemaErrorInvalidMipCount,
            [NSString stringWithFormat:@"mipCount=%d out of [1, %d]", mipCount, kZSTexture2DMaxMipCount]);
        return NO;
    }

    switch ((TAT2TextureFormat)textureFormat) {
        case TAT2TextureFormatRGB24:
        case TAT2TextureFormatRGBA32:
        case TAT2TextureFormatDXT1:
        case TAT2TextureFormatDXT5:
        case TAT2TextureFormatDXT5Crunched:
        case TAT2TextureFormatRGBAASTC4x4:
        case TAT2TextureFormatRGBAASTC6x6:
            break;
        default:
            if (error) *error = t2s_error(Texture2DSchemaErrorUnsupportedFormat,
                [NSString stringWithFormat:@"m_TextureFormat=%d is outside this build's confirmed corpus (3,4,10,12,29,48,50)", textureFormat]);
            return NO;
    }

    BOOL hasInlineImageData = imageDataLength > 0;
    BOOL hasStreamData = streamSize > 0;
    if (hasInlineImageData == hasStreamData) {
        // Either both empty (no pixel data at all) or both non-empty
        // (two homes for the same pixels) - see Texture2DSchemaErrorInconsistentPixelData's doc.
        if (error) *error = t2s_error(Texture2DSchemaErrorInconsistentPixelData,
            [NSString stringWithFormat:@"imageDataLength=%u streamSize=%u - expected exactly one non-zero", imageDataLength, streamSize]);
        return NO;
    }
    if (hasStreamData && streamPath.length == 0) {
        if (error) *error = t2s_error(Texture2DSchemaErrorInconsistentPixelData,
            @"m_StreamData.size is non-zero but m_StreamData.path is empty");
        return NO;
    }

    out.name = name ?: @"";
    out.width = width;
    out.height = height;
    out.completeImageSize = completeImageSize;
    out.textureFormat = textureFormat;
    out.mipCount = mipCount;
    out.formatOffset = formatOffset;
    out.completeImageSizeOffset = completeImageSizeOffset;
    out.mipCountOffset = mipCountOffset;
    out.imageDataLengthFieldOffset = imageDataLengthFieldOffset;
    out.imageDataOffset = imageDataOffset;
    out.imageDataLength = imageDataLength;
    out.streamDataOffset = streamDataOffset;
    out.streamOffset = streamOffset;
    out.streamSize = streamSize;
    out.streamPath = hasStreamData ? streamPath : nil;
    out.hasInlineImageData = hasInlineImageData;
    out.hasStreamData = hasStreamData;
    out.objectLength = len;

    return YES;
}

@implementation ZSTexture2DInfo
@end

@implementation Texture2DSchema

+ (nullable ZSTexture2DInfo *)parseObjectBytes:(NSData *)objectBytes error:(NSError **)error {
    if (objectBytes.length == 0) {
        if (error) *error = t2s_error(Texture2DSchemaErrorTruncated, @"empty object");
        return nil;
    }

    ZSTexture2DInfo *info = [ZSTexture2DInfo new];
    NSError *localError = nil;
    if (!zs_parse_texture2d((const uint8_t *)objectBytes.bytes, objectBytes.length, info, &localError)) {
        if (error) *error = localError;
        return nil;
    }
    return info;
}

@end
