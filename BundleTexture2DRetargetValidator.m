// BundleTexture2DRetargetValidator.m
//
// See BundleTexture2DRetargetValidator.h for the architecture. This file
// deliberately contains NO Texture2D/SerializedFile parsing logic of its
// own - every byte it looks at goes through BundleTexture2DEnumerator /
// Texture2DSchema / SerializedObjectTable, same as every earlier layer.
// This file's only job is to run those a second time (against the
// rebuilt bundle) and compare.

#import "BundleTexture2DRetargetValidator.h"
#import "BundleTexture2DRetargeter.h"
#import "BundleTexture2DEnumerator.h"
#import "SerializedObjectTable.h"
#import "Texture2DSchema.h"
#import "ZTweakLog.h"

NSString * const BundleTexture2DRetargetValidatorErrorDomain = @"BundleTexture2DRetargetValidatorErrorDomain";

static NSError *btrv_error(BundleTexture2DRetargetValidatorErrorCode code, NSString *reason, NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (reason) info[NSLocalizedDescriptionKey] = reason;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:BundleTexture2DRetargetValidatorErrorDomain code:code userInfo:info];
}

@implementation ZSTexture2DRetargetValidationIssue
@end

@implementation ZSTexture2DRetargetValidationReport
@end

@implementation BundleTexture2DRetargetValidator

+ (nullable ZSTexture2DRetargetValidationReport *)validateRetargetedBundleAtPath:(NSString *)destinationPath
                                                             originalBundleAtPath:(NSString *)originalPath
                                                                          summary:(ZSTexture2DRetargetSummary *)summary
                                                                            error:(NSError **)error {
    NSError *origErr = nil;
    BundleTexture2DEnumerator *origEnum = [BundleTexture2DEnumerator enumeratorForBundleAtPath:originalPath error:&origErr];
    if (!origEnum) {
        if (error) *error = btrv_error(BundleTexture2DRetargetValidatorErrorOriginalEnumerationFailed,
                                        @"could not re-enumerate the original bundle", origErr);
        return nil;
    }

    NSError *destErr = nil;
    BundleTexture2DEnumerator *destEnum = [BundleTexture2DEnumerator enumeratorForBundleAtPath:destinationPath error:&destErr];
    if (!destEnum) {
        if (error) *error = btrv_error(BundleTexture2DRetargetValidatorErrorDestinationEnumerationFailed,
                                        @"could not re-enumerate the rebuilt bundle", destErr);
        return nil;
    }

    NSMutableArray<ZSTexture2DRetargetValidationIssue *> *issues = [NSMutableArray array];

    void (^addIssue)(int64_t, NSString *_Nullable, NSString *) = ^(int64_t pathID, NSString *_Nullable name, NSString *reason) {
        ZSTexture2DRetargetValidationIssue *iss = [ZSTexture2DRetargetValidationIssue new];
        iss.pathID = pathID;
        iss.name = name;
        iss.reason = reason;
        [issues addObject:iss];
    };

    // --- whole-bundle checks -------------------------------------------------

    BOOL targetPlatformOK = destEnum.targetPlatformKnown && destEnum.targetPlatform == 9;
    if (!targetPlatformOK) {
        addIssue(0, nil, destEnum.targetPlatformKnown
                  ? [NSString stringWithFormat:@"rebuilt m_TargetPlatform is %d, expected 9 (iOS)", destEnum.targetPlatform]
                  : @"rebuilt m_TargetPlatform offset not structurally known - cannot confirm the retarget");
    }

    NSArray<SerializedObject *> *origObjects = origEnum.objectTable.objects;
    NSArray<SerializedObject *> *destObjects = destEnum.objectTable.objects;
    NSInteger originalObjectCount = origObjects.count;
    NSInteger rebuiltObjectCount = destObjects.count;
    BOOL objectCountOK = (originalObjectCount == rebuiltObjectCount);
    if (!objectCountOK) {
        addIssue(0, nil, [NSString stringWithFormat:@"object count changed: original %ld, rebuilt %ld",
                           (long)originalObjectCount, (long)rebuiltObjectCount]);
    }

    NSInteger missingPathIDCount = 0;
    for (SerializedObject *orig in origObjects) {
        if (![destEnum.objectTable objectWithPathID:orig.pathID]) {
            missingPathIDCount++;
            addIssue(orig.pathID, nil, @"PathID present in the original bundle no longer resolves in the rebuilt one");
        }
    }

    // --- per-Texture2D-object checks ------------------------------------------
    //
    // Keyed off `summary` (what BundleTexture2DRetargeter believes it did),
    // cross-checked against a fresh reparse of the REBUILT bundle - not
    // against the retargeter's own in-memory state, which is exactly the
    // gap this file exists to close (see this file's header top comment).
    //
    // Objects the ORIGINAL enumerator never parsed at all
    // (result.enumeratorParseError != nil) are skipped here on purpose -
    // BundleTexture2DRetargeter never touches those bytes, so a repeat
    // parse failure in the rebuilt bundle isn't a regression this pass
    // introduced or should flag; the PathID-existence check above already
    // covers them.

    NSMutableDictionary<NSNumber *, ZSTexture2DEnumeratedObject *> *destTexByPathID = [NSMutableDictionary dictionary];
    for (ZSTexture2DEnumeratedObject *obj in destEnum.texture2DObjects) {
        destTexByPathID[@(obj.pathID)] = obj;
    }

    NSInteger verifiedConvertedCount = 0;
    NSInteger verifiedUnchangedCount = 0;

    for (ZSTexture2DRetargetObjectResult *r in summary.objectResults) {
        if (r.enumeratorParseError) continue; // never touched by the retargeter - see note above

        @autoreleasepool {
            ZSTexture2DEnumeratedObject *destObj = destTexByPathID[@(r.pathID)];
            if (!destObj) {
                // Already reported by the missingPathIDCount loop above
                // (every Texture2D PathID is also a whole-table PathID) -
                // don't double-report it here.
                continue;
            }

            ZSTexture2DInfo *info = destObj.info;
            if (!info) {
                addIssue(r.pathID, r.name, [NSString stringWithFormat:
                                             @"object failed to reparse in the rebuilt bundle: %@",
                                             destObj.parseError.localizedDescription ?: @"unknown Texture2DSchema error"]);
                continue;
            }

            NSError *boundsErr = nil;
            NSData *pixelBytes = [destEnum sourcePixelBytesForObject:destObj error:&boundsErr];
            if (!pixelBytes) {
                addIssue(r.pathID, r.name, [NSString stringWithFormat:
                                             @"declared pixel byte range does not resolve: %@",
                                             boundsErr.localizedDescription ?: @"unknown bounds error"]);
                continue;
            }

            if (r.patched) {
                // This object was actually converted+repointed by
                // BundleTexture2DRetargeter - hold it to the full
                // Rework.txt "Validation strategy" bar.
                BOOL ok = YES;

                if (info.textureFormat != 4) {
                    addIssue(r.pathID, r.name, [NSString stringWithFormat:@"m_TextureFormat is %d, expected 4 (RGBA32)", info.textureFormat]);
                    ok = NO;
                }
                if (info.mipCount != 1) {
                    addIssue(r.pathID, r.name, [NSString stringWithFormat:@"m_MipCount is %d, expected 1", info.mipCount]);
                    ok = NO;
                }
                int32_t expectedSize = info.width * info.height * 4;
                if (info.completeImageSize != expectedSize) {
                    addIssue(r.pathID, r.name, [NSString stringWithFormat:@"m_CompleteImageSize is %d, expected %d (width * height * 4)",
                                                 info.completeImageSize, expectedSize]);
                    ok = NO;
                }
                if (!info.hasStreamData) {
                    addIssue(r.pathID, r.name, @"converted object has no StreamingInfo - expected to be streamed (see BundleTexture2DRetargeter's storage decision)");
                    ok = NO;
                }
                if (pixelBytes.length != (NSUInteger)expectedSize) {
                    addIssue(r.pathID, r.name, [NSString stringWithFormat:@"resolved pixel byte range is %lu bytes, expected %d (width * height * 4)",
                                                 (unsigned long)pixelBytes.length, expectedSize]);
                    ok = NO;
                }

                if (ok) verifiedConvertedCount++;
            } else {
                // NotNeeded, or Required/Unsupported but left unchanged
                // after a conversion failure - either way, this object's
                // bytes were never touched by the retargeter, so all that
                // matters here is that it still reparses and its declared
                // pixel range still resolves (already confirmed by
                // reaching this point without an earlier `continue`).
                verifiedUnchangedCount++;
            }
        }
    }

    ZSTexture2DRetargetValidationReport *report = [ZSTexture2DRetargetValidationReport new];
    report.targetPlatformOK = targetPlatformOK;
    report.observedTargetPlatform = destEnum.targetPlatformKnown ? destEnum.targetPlatform : 0;
    report.objectCountOK = objectCountOK;
    report.originalObjectCount = originalObjectCount;
    report.rebuiltObjectCount = rebuiltObjectCount;
    report.missingPathIDCount = missingPathIDCount;
    report.verifiedConvertedCount = verifiedConvertedCount;
    report.verifiedUnchangedCount = verifiedUnchangedCount;
    report.issues = issues;
    report.passed = (issues.count == 0);

    if (!report.passed) {
        ZLog(@"[BundleTexture2DRetargetValidator] %lu issue(s) found validating %@ against %@ - see report.issues",
             (unsigned long)issues.count, destinationPath, originalPath);
    }

    return report;
}

@end
