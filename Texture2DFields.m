// Texture2DFields.m
//
// See Texture2DFields.h for the field-order/validation design. Byte
// reads here are little-endian, same as SerializedObjectTable.m's own
// object-table entries and TextureAtlasTransplant.m's StreamingInfo
// fields - these are all inside the OBJECT DATA region, not the
// SerializedFile header (which is big-endian - see
// SerializedObjectTable.m's top comment on that split).

#import "Texture2DFields.h"
#import "ZTweakLog.h"

NSString * const Texture2DFieldsErrorDomain = @"Texture2DFieldsErrorDomain";

// GLTextureSettings' own size, and the m_ImageCount/m_TextureDimension/
// m_LightmapFormat/m_ColorSpace run around it, are NOT in
// TAT2VersionProfile (see Texture2DFields.h - the profile only covers
// fields that come BEFORE m_Width/m_TextureFormat, which is all a
// caller needs to locate and patch those). This fixed 24-byte figure is
// filterMode(4) + aniso(4) + mipBias(4) + wrapU/V/W(4*3=12) - the
// modern (2017.x+) three-axis wrap layout, not the older single
// wrapMode int. If -parseHeaderInObjectBytes:... starts failing its own
// validation on real data, THIS constant (not just the profile) is the
// next thing to check by hand against a hexdump - a single-axis
// wrapMode game would be 12 bytes short of this.
static const NSUInteger kGLTextureSettingsSize = 24;
// m_ImageCount(4) + m_TextureDimension(4) + m_LightmapFormat(4) + m_ColorSpace(4), around the GLTextureSettings block.
static const NSUInteger kImageCountThroughColorSpaceSize = 16;

#pragma mark - read/write helpers (little-endian, object-relative offsets)

static uint32_t t2f_read_u32_le(NSData *data, NSUInteger pos) {
    const uint8_t *p = (const uint8_t *)data.bytes + pos;
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static int32_t t2f_read_i32_le(NSData *data, NSUInteger pos) {
    return (int32_t)t2f_read_u32_le(data, pos);
}
static void t2f_write_i32_le(NSMutableData *data, NSUInteger pos, int32_t v) {
    uint8_t *p = (uint8_t *)data.mutableBytes + pos;
    uint32_t uv = (uint32_t)v;
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(uv >> (8 * i));
}
static NSUInteger t2f_align4(NSUInteger pos) {
    return (pos + 3) & ~(NSUInteger)3;
}

#pragma mark - version profile

const TAT2VersionProfile kTAT2ProfileDefault = {
    .hasForcedFallbackFormat     = YES,
    .hasDownscaleFallback        = YES,
    .hasIsAlphaChannelOptional   = YES,
    .hasMipsStripped             = YES,
    .hasMipCountAsInt            = YES,
    .hasIsPreProcessed           = YES,
    .hasIgnoreMipmapLimit        = YES,
    .hasStreamingMipmaps         = YES,
    .hasStreamingMipmapsPriority = YES,
    .hasPlatformBlob             = YES,
};

#pragma mark - Texture2DHeader

@implementation Texture2DHeader

+ (nullable instancetype)parseHeaderInObjectBytes:(NSData *)objectBytes
                                           profile:(TAT2VersionProfile)profile
                        streamDataOffsetFieldPos:(NSUInteger)streamDataOffsetFieldPos
                                             error:(NSError **)error {
    NSUInteger len = objectBytes.length;

    // Bounds-checked read cursor - every step below either advances pos
    // or bails via this same "not enough bytes left" path, so a
    // too-short object (wrong profile assumed way more fields than
    // actually exist) fails cleanly instead of reading past the end.
    NSUInteger pos = 0;
    #define T2F_NEED(n) do { if (pos + (n) > len) { \
        if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"object too short for assumed profile - wrong TAT2VersionProfile for this Unity version"}]; \
        return nil; \
    } } while (0)

    // m_Name: u32 length prefix + that many bytes, then 4-byte align -
    // this part of Texture2D's layout (it's the first field of every
    // NamedObject subclass) is NOT version-conditional, unlike
    // everything after it.
    T2F_NEED(4);
    uint32_t nameLen = t2f_read_u32_le(objectBytes, pos);
    pos += 4;
    T2F_NEED(nameLen);
    pos += nameLen;
    pos = t2f_align4(pos);

    if (profile.hasForcedFallbackFormat) { T2F_NEED(4); pos += 4; }
    if (profile.hasDownscaleFallback)      { T2F_NEED(1); pos += 1; }
    if (profile.hasIsAlphaChannelOptional) { T2F_NEED(1); pos += 1; }
    pos = t2f_align4(pos); // Unity aligns after a bool run, before the next int field (m_Width)

    T2F_NEED(4); NSUInteger widthOffset = pos; int32_t width = t2f_read_i32_le(objectBytes, pos); pos += 4;
    T2F_NEED(4); NSUInteger heightOffset = pos; int32_t height = t2f_read_i32_le(objectBytes, pos); pos += 4;
    T2F_NEED(4); NSUInteger completeImageSizeOffset = pos; int32_t completeImageSize = t2f_read_i32_le(objectBytes, pos); pos += 4;
    if (profile.hasMipsStripped) { T2F_NEED(4); pos += 4; }

    T2F_NEED(4); NSUInteger formatOffset = pos; int32_t rawFormat = t2f_read_i32_le(objectBytes, pos); pos += 4;

    if (!profile.hasMipCountAsInt) {
        // Pre-2017.3 bool m_MipMap layout - not supported, see Texture2DFields.h.
        if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"profile.hasMipCountAsInt == NO (pre-2017.3 bool m_MipMap) is not supported"}];
        return nil;
    }
    T2F_NEED(4); NSUInteger mipCountOffset = pos; int32_t mipCount = t2f_read_i32_le(objectBytes, pos); pos += 4;

    if (profile.hasIsPreProcessed)    { T2F_NEED(1); pos += 1; }
    if (profile.hasIgnoreMipmapLimit) { T2F_NEED(1); pos += 1; }
    if (profile.hasStreamingMipmaps)  { T2F_NEED(1); pos += 1; }
    pos = t2f_align4(pos);
    if (profile.hasStreamingMipmapsPriority) { T2F_NEED(4); pos += 4; }

    // m_ImageCount / m_TextureDimension / GLTextureSettings / m_LightmapFormat / m_ColorSpace -
    // fixed-size, not version-conditional in this project's target range - see kGLTextureSettingsSize's comment.
    T2F_NEED(kImageCountThroughColorSpaceSize + kGLTextureSettingsSize);
    pos += kImageCountThroughColorSpaceSize + kGLTextureSettingsSize;

    if (profile.hasPlatformBlob) {
        T2F_NEED(4);
        uint32_t blobLen = t2f_read_u32_le(objectBytes, pos);
        pos += 4;
        T2F_NEED(blobLen);
        pos += blobLen;
        pos = t2f_align4(pos);
    }

    // Inline image-data byte array.
    T2F_NEED(4);
    NSUInteger imageDataLengthFieldOffset = pos;
    uint32_t imageDataLength = t2f_read_u32_le(objectBytes, pos);
    pos += 4;
    T2F_NEED(imageDataLength);
    NSUInteger imageDataOffset = pos;
    pos += imageDataLength;
    pos = t2f_align4(pos);

    // --- validation - see Texture2DFields.h top comment on why this isn't optional ---
    if (width < 1 || width > 8192 || height < 1 || height > 8192) {
        if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"parsed width/height (%d x %d) outside plausible range - wrong TAT2VersionProfile for this Unity version", width, height]}];
        return nil;
    }
    // Generous known-format allowlist - real files may use others this
    // project hasn't catalogued (e.g. ETC2 variants), so this is a
    // sanity bound, not a hard claim of support - see TAT2TextureFormat.
    static const int32_t kPlausibleFormats[] = {1,2,3,4,5,7,9,10,11,12,13,14,15,17,18,19,20,22,24,25,29,34,35,41,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69};
    BOOL formatPlausible = NO;
    for (size_t i = 0; i < sizeof(kPlausibleFormats)/sizeof(kPlausibleFormats[0]); i++) {
        if (kPlausibleFormats[i] == rawFormat) { formatPlausible = YES; break; }
    }
    if (!formatPlausible) {
        if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"parsed m_TextureFormat (%d) isn't a known TextureFormat value - wrong TAT2VersionProfile for this Unity version", rawFormat]}];
        return nil;
    }

    BOOL streamConfirmed = NO;
    if (streamDataOffsetFieldPos != NSNotFound) {
        streamConfirmed = (streamDataOffsetFieldPos == pos);
        if (!streamConfirmed) {
            ZLog(@"[Texture2DFields] parsed header end (%lu) doesn't match independently-found StreamingInfo position (%lu) - profile is very likely wrong for this object",
                 (unsigned long)pos, (unsigned long)streamDataOffsetFieldPos);
            if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey: @"computed header end doesn't match tat_find_stream_data_offset_field's independently-found StreamingInfo position - wrong TAT2VersionProfile for this Unity version"}];
            return nil;
        }
    }
    // If streamDataOffsetFieldPos == NSNotFound (object doesn't stream -
    // pixels are the inline imageData array itself), there's nothing
    // independent left to cross-check against; width/height/format
    // plausibility above is the only guard for that case.

    #undef T2F_NEED

    Texture2DHeader *h = [Texture2DHeader new];
    h->_width = width;
    h->_height = height;
    h->_completeImageSize = completeImageSize;
    h->_rawFormat = rawFormat;
    h->_mipCount = mipCount;
    h->_widthOffset = widthOffset;
    h->_heightOffset = heightOffset;
    h->_completeImageSizeOffset = completeImageSizeOffset;
    h->_formatOffset = formatOffset;
    h->_mipCountOffset = mipCountOffset;
    h->_imageDataLengthFieldOffset = imageDataLengthFieldOffset;
    h->_imageDataOffset = imageDataOffset;
    h->_imageDataLength = imageDataLength;
    h->_streamDataPositionConfirmed = streamConfirmed;
    return h;
}

- (void)patchWidth:(int32_t)width
            height:(int32_t)height
 completeImageSize:(int32_t)completeImageSize
            format:(int32_t)format
          mipCount:(int32_t)mipCount
     inObjectBytes:(NSMutableData *)objectBytes {
    t2f_write_i32_le(objectBytes, self.widthOffset, width);
    t2f_write_i32_le(objectBytes, self.heightOffset, height);
    t2f_write_i32_le(objectBytes, self.completeImageSizeOffset, completeImageSize);
    t2f_write_i32_le(objectBytes, self.formatOffset, format);
    t2f_write_i32_le(objectBytes, self.mipCountOffset, mipCount);
}

@end
