// Texture2DConverter.m
//
// See Texture2DConverter.h for scope/architecture notes.

#import "Texture2DConverter.h"
#import "BundleTexture2DEnumerator.h"
#import "Texture2DSchema.h"
#import "Texture2DFields.h"
#import "Texture2DPixelDecoder.h"
#import "ZTweakLog.h"

NSString * const Texture2DConverterErrorDomain = @"Texture2DConverterErrorDomain";

static NSError *tc_error(Texture2DConverterErrorCode code, NSString *reason, NSError * _Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (reason) info[NSLocalizedDescriptionKey] = reason;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:Texture2DConverterErrorDomain code:code userInfo:info];
}

@implementation ZSTexture2DConversionResult
@end

@implementation Texture2DConverter

+ (ZSTexture2DConversionDecision)conversionDecisionForRawFormat:(int32_t)rawFormat {
    switch ((TAT2TextureFormat)rawFormat) {
        case TAT2TextureFormatRGBA32:
        case TAT2TextureFormatRGBAASTC4x4:
        case TAT2TextureFormatRGBAASTC6x6:
            return ZSTexture2DConversionNotNeeded;

        case TAT2TextureFormatRGB24:
        case TAT2TextureFormatDXT1:
        case TAT2TextureFormatDXT5:
        case TAT2TextureFormatDXT5Crunched:
            return ZSTexture2DConversionRequired;

        default:
            // See this class's header top comment - Texture2DSchema
            // already rejects any object whose m_TextureFormat isn't
            // one of the seven cases above at parse time, so a
            // successfully-parsed enumerated object should never reach
            // this branch. Kept as a fail-closed guard rather than an
            // assert.
            return ZSTexture2DConversionUnsupported;
    }
}

+ (void)convertObjectsInEnumerator:(BundleTexture2DEnumerator *)enumerator
                            handler:(ZSTexture2DConversionHandler)handler {
    for (ZSTexture2DEnumeratedObject *object in enumerator.texture2DObjects) {
        ZSTexture2DInfo *info = object.info;
        if (!info) {
            // Already reported by the enumerator itself
            // (object.parseError) - nothing for this layer to convert.
            continue;
        }

        ZSTexture2DConversionDecision decision = [self conversionDecisionForRawFormat:info.textureFormat];

        if (decision == ZSTexture2DConversionNotNeeded) {
            ZSTexture2DConversionResult *result = [ZSTexture2DConversionResult new];
            result.object = object;
            result.decision = decision;
            result.width = info.width;
            result.height = info.height;
            handler(result);
            continue;
        }

        if (decision == ZSTexture2DConversionUnsupported) {
            ZSTexture2DConversionResult *result = [ZSTexture2DConversionResult new];
            result.object = object;
            result.decision = decision;
            result.width = info.width;
            result.height = info.height;
            result.error = tc_error(Texture2DConverterErrorUnsupportedFormat,
                [NSString stringWithFormat:@"pathID %lld: m_TextureFormat=%d has no Layer C conversion rule", object.pathID, info.textureFormat],
                nil);
            handler(result);
            continue;
        }

        // ZSTexture2DConversionRequired - decode exactly one texture,
        // then let everything below drain with the pool. See this
        // class's header MEMORY POSTURE note: `handler` runs INSIDE
        // this pool, before the source bytes / decoded buffer are
        // released.
        @autoreleasepool {
            ZSTexture2DConversionResult *result = [ZSTexture2DConversionResult new];
            result.object = object;
            result.decision = decision;
            result.width = info.width;
            result.height = info.height;

            NSError *sourceError = nil;
            NSData *sourceBytes = [enumerator sourcePixelBytesForObject:object error:&sourceError];
            if (!sourceBytes) {
                result.error = tc_error(Texture2DConverterErrorSourceBytesUnavailable,
                    [NSString stringWithFormat:@"pathID %lld: couldn't resolve source pixel bytes", object.pathID],
                    sourceError);
                handler(result);
                continue;
            }

            NSError *decodeError = nil;
            NSData *rgba32 = [Texture2DPixelDecoder decodeToRGBA32FromRawFormat:info.textureFormat
                                                                      sourceBytes:sourceBytes
                                                                            width:info.width
                                                                           height:info.height
                                                                            error:&decodeError];
            if (!rgba32) {
                result.error = tc_error(Texture2DConverterErrorDecodeFailed,
                    [NSString stringWithFormat:@"pathID %lld: decode from format %d failed", object.pathID, info.textureFormat],
                    decodeError);
                handler(result);
                continue;
            }

            NSUInteger expectedLength = (NSUInteger)info.width * (NSUInteger)info.height * 4;
            if (rgba32.length != expectedLength) {
                // Self-check before this ever reaches a caller - see
                // this class's header note on Texture2DSchemaErrorTrailingData's
                // "self-verifying, not self-correcting" philosophy applying
                // here too. A decoder returning the wrong length is a
                // decoder bug, not something a later Layer D patch step
                // should silently paper over with a mismatched
                // m_CompleteImageSize.
                result.error = tc_error(Texture2DConverterErrorUnexpectedByteCount,
                    [NSString stringWithFormat:@"pathID %lld: decoded %lu bytes, expected %lu (%d x %d x 4)",
                        object.pathID, (unsigned long)rgba32.length, (unsigned long)expectedLength, info.width, info.height],
                    nil);
                handler(result);
                continue;
            }

            result.rgba32Data = rgba32;
            handler(result);
        }
    }
}

@end
