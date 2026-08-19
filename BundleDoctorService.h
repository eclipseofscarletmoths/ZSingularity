// BundleDoctorService.h
//
// The "send-and-intercept" half of the doctor-bundle pipeline: hands a
// modded DESKTOP Unity bundle to a GitHub Actions workflow (running
// AssetsTools.NET in a real .NET environment this tweak can't run
// on-device) and gets back a bundle that's been re-platformed to iOS(9)
// and had its unsupported Texture2D formats re-encoded to RGBA32. See
// this project's own design notes: doing this from-scratch on-device
// kept producing corrupted bundles, so the actual doctoring work moved
// to AssetsTools.NET running in CI, and this class is only the courier.
//
// THE ACTUAL TRANSPORT, AND WHY (read before touching the workflow's own
// YAML - this class's request shapes have to match it exactly):
//
// GitHub's `workflow_dispatch` REST endpoint only accepts up to 10
// string `inputs` in the request body - there is no way to attach an
// arbitrary binary payload (a Unity bundle can be tens of MB) to a
// dispatch call directly. So this class doesn't try to; instead it:
//
//   1. Reads the base commit for `config.ref` (git/ref) and its tree
//      (git/commits/{sha}).
//   2. Uploads the modded bundle's raw bytes as a git blob
//      (git/blobs, base64-encoded).
//   3. Builds a new tree on top of the base tree that adds/replaces
//      exactly one path: BDS_INPUT_PATH (see the .m for the literal
//      string) with that blob.
//   4. Commits that tree (git/commits) and points a brand-new scratch
//      branch at it (git/refs) - "bundle-doctor/<uuid>", never reused.
//   5. Dispatches config.workflowFile on that scratch branch
//      (actions/workflows/{file}/dispatches), passing
//      `{"output_format": config.outputFormat}` as the one input.
//   6. Polls actions/workflows/{file}/runs?branch=<scratch>&event=
//      workflow_dispatch for the run this dispatch created (the
//      dispatch endpoint itself returns no run id - this is a known
//      GitHub API gap, not a bug here), then polls that run's own
//      status until it reports "completed".
//   7. On a successful run, reads the doctored bundle back out via
//      the Contents API from BDS_OUTPUT_PATH (see .m) on that same
//      scratch branch - i.e. the workflow is expected to COMMIT its
//      output back onto the scratch branch at that fixed path, not
//      upload it as a run artifact. (An artifact would need this
//      class to parse a zip container on-device with no library for
//      that on hand; a second git-committed file is one more Contents
//      API GET with nothing new to implement.)
//   8. Deletes the scratch branch (best-effort - a failure here is
//      logged, not surfaced to the caller, since the doctored bundle
//      has already been safely read out by that point).
//
// BDS_INPUT_PATH/BDS_OUTPUT_PATH and the "output_format" input name
// are a CONVENTION THIS CLASS ASSUMES THE WORKFLOW YAML FOLLOWS - they
// are not discoverable from the GitHub API. If the actual doctor-bundle
// workflow uses different paths/input names, update the #define's at
// the top of the .m to match it (or vice versa) - the two have to
// agree exactly, the same way PatchManifestNetwork.m's kTargetHostSuffix/
// kTargetPathSuffix have to match whatever the game's CDN actually
// serves.
//
// AUTH: config.authToken is a GitHub Personal Access Token sent as
// `Authorization: Bearer <token>` on every request below. It needs, at
// minimum: repo contents read/write (steps 1-4, 7) and `actions:write`
// (step 5) / `actions:read` (step 6) on the target repo - i.e. a
// fine-grained PAT scoped to just that repo with Contents (read/write)
// and Actions (read/write) permissions, or a classic PAT with the
// `repo` and `workflow` scopes. See BundleDoctorSettings.h for where
// this token is actually stored (Keychain) and that file's own caveat
// about Keychain access from this tweak's injected-dylib position.
//
// THREADING: +doctorBundleAtURL:config:progress:completion: does all of
// the above synchronously (blocking dispatch_semaphore waits between
// each NSURLSession call) on a background queue it manages itself -
// callers can invoke it from the main thread without freezing the UI.
// `progress` and `completion` are both always called back on the main
// queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleDoctorServiceErrorDomain;

typedef NS_ENUM(NSInteger, BundleDoctorServiceErrorCode) {
    BundleDoctorServiceErrorInvalidConfig = 1,   // missing repoOwner/repoName/authToken
    BundleDoctorServiceErrorCantReadModdedBundle,
    BundleDoctorServiceErrorRequestFailed,       // transport-level failure (no response at all) - see underlying NSError in userInfo[NSUnderlyingErrorKey]
    BundleDoctorServiceErrorAPIError,            // GitHub responded with a non-2xx status - see userInfo[BundleDoctorServiceHTTPStatusKey]/[BundleDoctorServiceResponseBodyKey]
    BundleDoctorServiceErrorRunNotFound,         // dispatched but the corresponding run never showed up in the runs list before the timeout
    BundleDoctorServiceErrorRunFailed,           // run completed but conclusion != "success" - see userInfo[BundleDoctorServiceRunURLKey]
    BundleDoctorServiceErrorTimedOut,
    BundleDoctorServiceErrorOutputMissing,       // run succeeded but BDS_OUTPUT_PATH wasn't there afterward - workflow/path convention mismatch, see this file's header
};

extern NSString * const BundleDoctorServiceHTTPStatusKey;   // NSNumber (NSInteger)
extern NSString * const BundleDoctorServiceResponseBodyKey; // NSString, truncated
extern NSString * const BundleDoctorServiceRunURLKey;       // NSString - the run's html_url, for the person to go look at logs

// Single request's worth of config - see BundleDoctorSettings.h for how
// this gets loaded from/saved to disk+Keychain. Every property except
// repoOwner/repoName/authToken has a hardcoded fallback applied by
// +normalizedConfig below, matching BundleDoctorSettings.h's own note
// that it never fills these in itself.
@interface BundleDoctorConfig : NSObject
@property (nonatomic, copy, nullable) NSString *repoOwner;
@property (nonatomic, copy, nullable) NSString *repoName;
@property (nonatomic, copy, nullable) NSString *ref;            // branch/tag/sha to base the scratch branch on - defaults to "main"
@property (nonatomic, copy, nullable) NSString *workflowFile;   // e.g. "doctor-bundle.yml" - defaults to "doctor-bundle.yml"
@property (nonatomic, copy, nullable) NSString *outputFormat;   // Texture2D re-encode target - defaults to "RGBA32"
@property (nonatomic, copy, nullable) NSString *authToken;

// Returns a copy with ref/workflowFile/outputFormat filled in from
// their hardcoded defaults wherever the receiver left them nil/empty.
// Does NOT fill in repoOwner/repoName/authToken - those have no sane
// default and their absence is what +doctorBundleAtURL:... below
// reports as BundleDoctorServiceErrorInvalidConfig.
- (BundleDoctorConfig *)normalizedConfig;

@end

@interface BundleDoctorService : NSObject

// moddedBundleURL: the modded DESKTOP bundle to doctor - possibly a
// security-scoped URL from UIDocumentPickerViewController (this starts/
// stops that access itself; callers don't need to, same convention as
// BankTransplant's +transplantAndSwapModdedBankAtURL:error:).
//
// progress: called on the main queue zero or more times with a short
// human-readable status ("Uploading modded bundle…", "Waiting for
// workflow to finish…", etc.) - purely cosmetic, safe to ignore.
//
// completion: called exactly once, on the main queue. On success,
// doctoredBundleURL points to a temp file (already re-platformed to
// iOS(9) with textures re-encoded) that the caller owns and can move/
// read/pass to BundleDoctorInstaller; it is NOT cleaned up by this
// class. On failure doctoredBundleURL is nil and error is filled per
// the BundleDoctorServiceErrorCode's above.
+ (void)doctorBundleAtURL:(NSURL *)moddedBundleURL
                    config:(BundleDoctorConfig *)config
                  progress:(nullable void (^)(NSString *status))progress
                completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
