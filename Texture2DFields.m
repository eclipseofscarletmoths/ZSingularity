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

// Diagnostic-only. Renders `[before..after)` around both `pos` (where the
// walk actually landed) and `confirmedPos` (the independently-found
// StreamingInfo position) as a hex/ASCII dump, with both positions marked
// inline, so a streamDataPositionConfirmed failure can be root-caused from
// a single log line instead of guessing at profile flags again. Added
// specifically because the last ~10-15% of failures (see overview.md) show
// a small, CONSTANT delta (pos always a few bytes short of confirmedPos) on
// only a subset of objects in an otherwise-working profile - i.e. very
// likely one content-conditional field (m_MipmapLimitGroupName being
// non-empty for some objects, or a field this project's 9-flag profile
// doesn't model at all yet), not a wrong profile outright. Bounded to a
// small window and only called on the failure path, so this has no cost
// on the success path and can't itself leak more than a few dozen bytes
// per failing object into the log.
static NSString *t2f_hexdump_around(NSData *data, NSUInteger pos, NSUInteger confirmedPos) {
    NSUInteger lo = (pos > 16) ? pos - 16 : 0;
    NSUInteger hiFromPos = pos + 16;
    NSUInteger hiFromConfirmed = confirmedPos + 16;
    NSUInteger hi = MAX(hiFromPos, hiFromConfirmed);
    hi = MIN(hi, data.length);
    if (lo >= hi) return @"(window out of range)";

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = lo; i < hi; i += 8) {
        NSMutableString *hexPart = [NSMutableString string];
        NSMutableString *asciiPart = [NSMutableString string];
        for (NSUInteger j = i; j < MIN(i + 8, hi); j++) {
            uint8_t b = bytes[j];
            NSString *marker = @"";
            if (j == pos) marker = (j == confirmedPos) ? @"[PC]" : @"[P]";
            else if (j == confirmedPos) marker = @"[C]";
            [hexPart appendFormat:@"%@%02x ", marker, b];
            [asciiPart appendFormat:@"%c", (b >= 32 && b < 127) ? b : '.'];
        }
        NSString *paddedHex = hexPart.length < 56 ? [hexPart stringByPaddingToLength:56 withString:@" " startingAtIndex:0] : hexPart;
        [out appendFormat:@"\n  +%lu  %@ %@", (unsigned long)i, paddedHex, asciiPart];
    }
    return out;
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
    .hasVTOnly                   = YES,
    .hasAlphaIsTransparency     = YES,
    .hasPlatformBlob             = YES,
};

#pragma mark - Texture2DHeader

@implementation Texture2DHeader

#pragma mark version profile detection (see Texture2DFields.h)

+ (BOOL)detectVersionProfile:(TAT2VersionProfile *)outProfile
            fromObjectSamples:(NSArray<NSData *> *)sampleObjectBytes
   streamDataOffsetFieldPositions:(NSArray<NSNumber *> *)streamDataOffsetFieldPositions {
    if (sampleObjectBytes.count == 0 || sampleObjectBytes.count != streamDataOffsetFieldPositions.count) {
        return NO;
    }

    // IMPORTANT: don't require "exactly one candidate profile survives" -
    // that's the wrong bar. Unity 4-byte-aligns after every run of
    // single-byte bools in this layout (see Texture2DFields.m's
    // parseHeaderInObjectBytes:...), so e.g. hasDownscaleFallback=YES
    // alone, hasIsAlphaChannelOptional=YES alone, and both=YES all
    // consume 1-2 raw bytes that get rounded up to the SAME 4-byte
    // boundary - meaning those three different boolean combinations
    // land every subsequent field (width, height, ..., the image-data
    // array, m_StreamData) at the exact same byte offset. Empirically
    // (verified against synthetic objects while implementing this)
    // this degeneracy is large: ~45 of the 512 raw candidates survive
    // even 10 confirmed samples. Requiring a literal single survivor
    // would make this function fail almost always and silently defeat
    // the whole point of detection - falling back to
    // kTAT2ProfileDefault on every real build, including this one.
    //
    // The bar that actually matters: do the surviving candidates AGREE
    // on where they'd put every field this module reads/writes? If
    // every survivor computes identical offsets on every sample, they
    // are operationally interchangeable - it doesn't matter which one
    // gets returned, since callers only ever use the resulting
    // Texture2DHeader's offsets, never the profile's booleans directly.
    // So: group survivors by their resulting (widthOffset, heightOffset,
    // completeImageSizeOffset, formatOffset, mipCountOffset,
    // imageDataLengthFieldOffset, final-pos-after-imageData) tuple
    // across ALL samples, and require exactly one such GROUP, not one
    // profile.
    NSMutableDictionary<NSString *, NSValue *> *groups = [NSMutableDictionary dictionary]; // offsetKey -> one representative profile
    NSMutableDictionary<NSString *, NSNumber *> *groupCounts = [NSMutableDictionary dictionary];

    for (uint32_t mask = 0; mask < 512; mask++) {
        TAT2VersionProfile candidate = {
            .hasForcedFallbackFormat     = (mask & (1 << 0)) != 0,
            .hasDownscaleFallback        = (mask & (1 << 1)) != 0,
            .hasIsAlphaChannelOptional   = (mask & (1 << 2)) != 0,
            .hasMipsStripped             = (mask & (1 << 3)) != 0,
            .hasMipCountAsInt            = YES,
            .hasIsPreProcessed           = (mask & (1 << 4)) != 0,
            .hasIgnoreMipmapLimit        = (mask & (1 << 5)) != 0,
            .hasStreamingMipmaps         = (mask & (1 << 6)) != 0,
            .hasStreamingMipmapsPriority = (mask & (1 << 7)) != 0,
            // Unity 6000.3.12f1 fixed fields after StreamingMipmapsPriority.
            .hasVTOnly                   = YES,
            .hasAlphaIsTransparency     = YES,
            .hasPlatformBlob             = (mask & (1 << 8)) != 0,
        };

        NSMutableString *key = [NSMutableString string];
        BOOL candidateSurvives = YES;
        for (NSUInteger i = 0; i < sampleObjectBytes.count; i++) {
            NSData *bytes = sampleObjectBytes[i];
            NSUInteger streamPos = streamDataOffsetFieldPositions[i].unsignedIntegerValue; // boxed NSNotFound where absent
            NSError *err = nil;
            Texture2DHeader *h = [Texture2DHeader parseHeaderInObjectBytes:bytes
                                                                     profile:candidate
                                                  streamDataOffsetFieldPos:streamPos
                                                                       error:&err];
            if (!h) { candidateSurvives = NO; break; }
            if (streamPos != NSNotFound && !h.streamDataPositionConfirmed) { candidateSurvives = NO; break; }
            [key appendFormat:@"%lu,%lu,%lu,%lu,%lu,%lu,%lu|",
                (unsigned long)h.widthOffset, (unsigned long)h.heightOffset, (unsigned long)h.completeImageSizeOffset,
                (unsigned long)h.formatOffset, (unsigned long)h.mipCountOffset,
                (unsigned long)h.imageDataLengthFieldOffset, (unsigned long)(h.imageDataOffset + h.imageDataLength)];
        }
        if (!candidateSurvives) continue;

        if (!groups[key]) {
            NSValue *boxed = [NSValue valueWithBytes:&candidate objCType:@encode(TAT2VersionProfile)];
            groups[key] = boxed;
            groupCounts[key] = @1;
        } else {
            groupCounts[key] = @(groupCounts[key].unsignedIntegerValue + 1);
        }
    }

    if (groups.count != 1) {
        NSUInteger totalRawSurvivors = 0;
        for (NSNumber *n in groupCounts.allValues) totalRawSurvivors += n.unsignedIntegerValue;
        ZLog(@"[Texture2DFields] profile detection: %lu distinct offset-outcome(s) (%lu raw candidate profiles) survived %lu sample(s) - %@",
             (unsigned long)groups.count, (unsigned long)totalRawSurvivors, (unsigned long)sampleObjectBytes.count,
             groups.count == 0 ? @"none fit - samples may be corrupt or from a mixed/unsupported build" : @"genuinely ambiguous - need more/more-varied samples (ideally more streamed objects) to disambiguate");
        return NO;
    }

    [groups.allValues.firstObject getValue:outProfile];
    return YES;
}

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

    // Unity 6000.3.x serialized order:
    //   m_IsReadable
    //   m_IsPreProcessed
    //   m_IgnoreMipmapLimit
    //   m_MipmapLimitGroupName
    //   m_StreamingMipmaps
    //   m_StreamingMipmapsPriority
    //   m_VTOnly
    //   m_AlphaIsTransparency
    //
    // The previous parser treated m_MipmapLimitGroupName as if it
    // preceded m_IsPreProcessed/m_IgnoreMipmapLimit and omitted the two
    // Unity-6 bools after m_StreamingMipmapsPriority. The latter omission
    // is a fixed 4-byte drift after alignment and matches the device
    // log's repeated delta=+4 failures.
    T2F_NEED(1); pos += 1; // m_IsReadable
    if (profile.hasIsPreProcessed)    { T2F_NEED(1); pos += 1; }
    if (profile.hasIgnoreMipmapLimit) { T2F_NEED(1); pos += 1; }
    pos = t2f_align4(pos);

    T2F_NEED(4);
    uint32_t mipmapLimitGroupNameLen = t2f_read_u32_le(objectBytes, pos);
    pos += 4;
    T2F_NEED(mipmapLimitGroupNameLen);
    pos += mipmapLimitGroupNameLen;
    pos = t2f_align4(pos);

    if (profile.hasStreamingMipmaps)  { T2F_NEED(1); pos += 1; }
    pos = t2f_align4(pos);
    if (profile.hasStreamingMipmapsPriority) { T2F_NEED(4); pos += 4; }

    if (profile.hasVTOnly)             { T2F_NEED(1); pos += 1; }
    if (profile.hasAlphaIsTransparency){ T2F_NEED(1); pos += 1; }
    pos = t2f_align4(pos);

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
    // mipCount plausibility - added specifically to help
    // +detectVersionProfile:...: disambiguate. hasMipsStripped and
    // hasStreamingMipmapsPriority are both optional 4-byte int fields
    // that sit on either side of m_TextureFormat/m_MipCount - a
    // profile that gets ONE of them backwards still ends up reading
    // m_TextureFormat and m_MipCount from a position 4 bytes off, and
    // the format-plausibility check above is generous enough (~50
    // allowed values) that a wrong read sometimes still passes it by
    // chance. mipCount has a much tighter real range - a full mip
    // chain for the largest texture this project supports (8192px)
    // is floor(log2(8192))+1 = 14 levels - so this catches many of
    // those cases the format check alone misses. Confirmed via
    // simulation while implementing detection: adding this raised
    // detection's success rate from roughly half of random synthetic
    // trials to all of them once >= 5 streamed samples were available.
    if (mipCount < 1 || mipCount > 14) {
        if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"parsed m_MipCount (%d) outside plausible range 1...14 - wrong TAT2VersionProfile for this Unity version", mipCount]}];
        return nil;
    }

    BOOL streamConfirmed = NO;
    if (streamDataOffsetFieldPos != NSNotFound) {
        streamConfirmed = (streamDataOffsetFieldPos == pos);
        if (!streamConfirmed) {
            NSInteger delta = (NSInteger)streamDataOffsetFieldPos - (NSInteger)pos;
            ZLog(@"[Texture2DFields] parsed header end (%lu) doesn't match independently-found StreamingInfo position (%lu), delta=%ld - profile is very likely wrong for this object",
                 (unsigned long)pos, (unsigned long)streamDataOffsetFieldPos, (long)delta);
            // DIAGNOSTIC (see t2f_hexdump_around's comment): only fires on
            // the failure path, bounded to a small window. [P]/[C]/[PC]
            // mark the walked position, the confirmed position, and both
            // coinciding, respectively. Intended to be read by hand against
            // the known layout (mipmapLimitGroupNameLen, m_IsPreProcessed,
            // etc.) to identify which field the current profile is missing
            // for THIS object but not the majority - not to auto-correct
            // anything. Remove once the real field is identified and added
            // to TAT2VersionProfile properly.
            ZLog(@"[Texture2DFields] [DIAG] window around walked/confirmed positions (delta=%ld):%@",
                 (long)delta, t2f_hexdump_around(objectBytes, pos, streamDataOffsetFieldPos));
            if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey: @"computed header end doesn't match tat_find_stream_data_offset_field's independently-found StreamingInfo position - wrong TAT2VersionProfile for this Unity version"}];
            return nil;
        }
    } else {
        // NEW (see overview.md Entry 13): until now, a NON-streaming
        // object (caller found no "archive:/" needle - see
        // pbr_/tat_find_stream_data_offset_field) had NO cross-check at
        // all here - width/height/format/mipCount plausibility above was
        // the only guard, and real archive.zip data proved that's not
        // enough: pathID -6256345162963367343 (a 2048x2048 DXT5 Spine
        // atlas page, m_StreamData.size==0/path=="") passed every
        // plausibility check yet came out of this function with
        // imageDataLength==1 - which is exactly m_ColorSpace's own real
        // value (1) misread as a length prefix, i.e. `pos` was already 4
        // bytes short by the time it got here, silently, with nothing to
        // catch it. TextureAtlasTransplant.m's moddedHeader.imageDataLength
        // and PlatformBundleRetarget.m's header.imageDataLength both trust
        // this value directly with no bounds re-check of their own, so a
        // wrong-but-small value like this reads a near-empty pixel buffer
        // and fails downstream as a confusing "format N not decodable ...
        // only got 1" rather than the real "wrong profile" error.
        //
        // m_StreamData is a StreamingInfo struct - offset(u64,8) +
        // size(u32,4) + pathLen(u32,4) + path bytes - ALWAYS present as
        // the object's trailing field, even when unused (path=="",
        // size==0), same 16-byte-before-the-text layout
        // tat_find_stream_data_offset_field already established (see that
        // function's Entry 3 comment). Reaching this `else` branch means
        // the caller found no "archive:/" text anywhere in this object,
        // which is only possible if that trailing path really is empty -
        // so this struct, unconditionally, must consume EXACTLY the rest
        // of objectBytes with pathLen==0. If it doesn't, `pos` was wrong
        // before we ever got here, regardless of how plausible
        // width/height/format/mipCount looked.
        T2F_NEED(16);
        NSUInteger trailingStructStart = pos;
        NSUInteger trailingPos = pos + 12; // offset(8) + size(4), not otherwise validated here
        uint32_t trailingPathLen = t2f_read_u32_le(objectBytes, trailingPos);
        NSUInteger computedEnd = trailingPos + 4 + trailingPathLen;
        if (trailingPathLen != 0 || computedEnd != len) {
            ZLog(@"[Texture2DFields] non-streaming object: trailing StreamingInfo struct (assumed to start at %lu) doesn't exactly consume the rest of objectBytes (computed end %lu vs actual length %lu, trailing pathLen read as %u) - imageDataLength (%u) is very likely wrong for this object",
                 (unsigned long)trailingStructStart, (unsigned long)computedEnd, (unsigned long)len, trailingPathLen, imageDataLength);
            ZLog(@"[Texture2DFields] [DIAG] window around computed header end (no independent confirmed position - non-streaming object):%@",
                 t2f_hexdump_around(objectBytes, trailingStructStart, trailingStructStart));
            if (error) *error = [NSError errorWithDomain:Texture2DFieldsErrorDomain code:7 userInfo:@{NSLocalizedDescriptionKey: @"non-streaming object's trailing StreamingInfo struct doesn't exactly consume the rest of the object bytes - wrong TAT2VersionProfile (or misread imageDataLength) for this object"}];
            return nil;
        }
    }

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
