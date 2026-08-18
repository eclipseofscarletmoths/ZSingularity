// BundleTexture2DRetargetValidator.h
//
// Rework.txt's "Validation strategy" section - the post-write
// reparse/verification pass BundleTexture2DRetargeter.h's own header
// explicitly flags as NOT done by that class (see its "WHAT THIS CLASS
// DOES NOT DO (yet - see ReworkLog.md for what's next)" note) and
// ReworkLog.md lists as still outstanding after Entry 3.
//
// +[BundleTexture2DRetargeter retargetBundleAtPath:toPath:error:] writes
// a destination bundle and returns a ZSTexture2DRetargetSummary built
// from the same in-memory state it constructed the file FROM - it never
// re-reads what actually landed on disk. This file closes that gap: it
// re-parses the ALREADY-WRITTEN destination bundle from scratch, through
// the exact same enumerator/schema/table code every other layer already
// uses (no new parsing logic here - see Rework.txt's own "Why fuzzy
// neighboring-byte search is the wrong fix" reasoning for why a
// structural parser should be self-verifying rather than self-correcting;
// this applies that same idea one level up, at the whole-bundle level),
// and checks the result against both the original bundle and the
// retargeter's own summary before a caller is allowed to trust it.
//
// USAGE: call this AFTER +[BundleTexture2DRetargeter
// retargetBundleAtPath:toPath:error:] has already returned a non-nil
// summary and written `destinationPath`. This class does not call
// BundleTexture2DRetargeter itself and does not write anything - it is
// strictly read-only, against two bundles that already exist on disk
// (the original at `originalPath`, the just-written one at
// `destinationPath`).
//
// WHAT THIS CHECKS (Rework.txt, "Validation strategy"):
//
//   whole-bundle level:
//     - m_TargetPlatform reads back as 9 in the rebuilt bundle
//     - object count unchanged (every object, not just Texture2D -
//       BundleTexture2DRetargeter never inserts/removes table rows, only
//       patches existing Texture2D entries' byteStart/byteSize, so this
//       should hold for every real retarget)
//     - every original PathID still resolves in the rebuilt table
//
//   per Texture2D object (everything BundleTexture2DRetargeter's summary
//   reported a decision for - i.e. everything that parsed at all in the
//   ORIGINAL bundle; an object that failed to parse originally is left
//   completely untouched by the retargeter and is not expected to
//   suddenly parse differently here, so this class does not re-litigate
//   that failure - only confirms the object's PathID still exists,
//   covered by the whole-bundle check above):
//     - the object still parses via Texture2DSchema in the rebuilt bundle
//     - its declared pixel byte range (inline or StreamingInfo) resolves
//       without error - reuses
//       -[BundleTexture2DEnumerator sourcePixelBytesForObject:error:]'s
//       own bounds-checking rather than duplicating it, so "every
//       untouched object's byte range is valid" and "all streamed
//       offsets stay within the .resS node" are the SAME check, not two
//       - for a CONVERTED object (ZSTexture2DRetargetObjectResult.patched
//       == YES) additionally:
//         - m_TextureFormat reads back as 4
//         - m_MipCount reads back as 1
//         - m_CompleteImageSize reads back as width * height * 4
//         - hasStreamData is YES (this pipeline always streams converted
//           output - see BundleTexture2DRetargeter.h's storage decision)
//         - the resolved pixel byte range's length is exactly
//           width * height * 4
//
// SCOPE - WHAT THIS FILE DOES NOT DO: retry/repair anything it finds
// wrong, delete or otherwise touch either bundle, or decide whether a
// caller should proceed with a failed report - it only reports. Per this
// project's "report per item, don't abort the whole batch" posture used
// throughout this pipeline, a single object-level discrepancy does not
// stop the rest of the report from being built - see .issues on the
// returned report for the full list. Only a whole-bundle-level failure
// (either bundle couldn't even be re-enumerated) fails this call outright
// and returns nil.
//
// MEMORY POSTURE: this necessarily holds BOTH bundles' decompressed
// representations in memory at once (via two independent
// BundleTexture2DEnumerator instances - see that class's own MEMORY NOTE
// on why a single instance already does this for one bundle), which is
// more than any other step in this pipeline holds at a time. This is a
// deliberate, explicit exception to the "let the disk do the work" rule
// the rest of this pipeline follows: Rework.txt frames this validation
// pass as a trust-building step to run BEFORE a caller replaces a
// production bundle with the retargeted one, not as part of the
// conversion hot path itself - see this header's "Suggested next entry"
// pointer in ReworkLog.md for the same framing. Each per-texture pixel
// byte range check below is still done one object at a time inside its
// own @autoreleasepool, same discipline as every other layer.

#import <Foundation/Foundation.h>

@class ZSTexture2DRetargetSummary;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleTexture2DRetargetValidatorErrorDomain;

typedef NS_ENUM(NSInteger, BundleTexture2DRetargetValidatorErrorCode) {
    // Couldn't even re-enumerate the ORIGINAL bundle at `originalPath` -
    // see the wrapped underlying error. Fatal to the whole validation
    // call: without the original bundle's own object table there is no
    // basis for the object-count/PathID-existence checks at all.
    BundleTexture2DRetargetValidatorErrorOriginalEnumerationFailed = 1,

    // Couldn't even re-enumerate the just-written bundle at
    // `destinationPath` - see the wrapped underlying error. Fatal, same
    // reasoning as above but for the rebuilt side: if the file
    // BundleTexture2DRetargeter just wrote can't be read back at all,
    // there is nothing left to validate against.
    BundleTexture2DRetargetValidatorErrorDestinationEnumerationFailed,
};

// One thing this pass found wrong. `pathID` is 0 for a whole-bundle-level
// issue (e.g. target platform mismatch) that isn't about any one object.
@interface ZSTexture2DRetargetValidationIssue : NSObject
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, copy, nullable) NSString *name;   // mirrors ZSTexture2DRetargetObjectResult.name, if known - nil for whole-bundle issues
@property (nonatomic, copy) NSString *reason;             // human-readable, for logging - not meant to be parsed
@end

// Whole-report outcome. A non-nil return means both bundles were
// successfully re-read and every check below ran to completion - it does
// NOT by itself mean everything passed. Check .passed (or walk .issues
// directly) before treating the retargeted bundle as trustworthy.
@interface ZSTexture2DRetargetValidationReport : NSObject

@property (nonatomic, assign) BOOL passed; // YES iff every check below succeeded - i.e. .issues is empty

@property (nonatomic, assign) BOOL targetPlatformOK;             // rebuilt m_TargetPlatform == 9
@property (nonatomic, assign) int32_t observedTargetPlatform;    // whatever the rebuilt bundle actually reported (only meaningful if targetPlatformOK is NO, or targetPlatformKnown was NO - see .issues for which)

@property (nonatomic, assign) BOOL objectCountOK;                // original whole-table object count == rebuilt whole-table object count
@property (nonatomic, assign) NSInteger originalObjectCount;
@property (nonatomic, assign) NSInteger rebuiltObjectCount;

@property (nonatomic, assign) NSInteger missingPathIDCount;      // original PathIDs that no longer resolve in the rebuilt table - should be 0

// Per-Texture2D-object counters - see this header's top comment for
// exactly what "verified" means for each. These count objects that
// PASSED every check applicable to them; a failure increments neither
// counter but does add an entry to .issues.
@property (nonatomic, assign) NSInteger verifiedConvertedCount;   // decision == Required, .patched == YES in the original summary
@property (nonatomic, assign) NSInteger verifiedUnchangedCount;   // decision == NotNeeded, or Required/Unsupported but left unchanged (conversion failed) - either way, expected to still reparse and resolve cleanly

@property (nonatomic, copy) NSArray<ZSTexture2DRetargetValidationIssue *> *issues;

@end

@interface BundleTexture2DRetargetValidator : NSObject

// Re-reads `originalPath` (the bundle BundleTexture2DRetargeter was
// originally given) and `destinationPath` (the bundle it wrote) from
// scratch and cross-checks the rebuilt one against both the original
// and `summary` (the ZSTexture2DRetargetSummary that same retarget call
// returned) per this header's top comment.
//
// Returns nil (no report produced) only if either bundle could not be
// re-enumerated at all - see the error codes above. Any other
// discrepancy is captured as an issue on a non-nil report with .passed
// == NO, not a failure of this call.
+ (nullable ZSTexture2DRetargetValidationReport *)validateRetargetedBundleAtPath:(NSString *)destinationPath
                                                             originalBundleAtPath:(NSString *)originalPath
                                                                          summary:(ZSTexture2DRetargetSummary *)summary
                                                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
