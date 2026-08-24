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
//   1. Reads the base commit for `config.ref` (git/ref).
//   2. Points a brand-new scratch branch at that same commit (git/refs)
//      - "bundle-doctor/<uuid>", never reused. No new tree/commit is
//      built - the branch exists only to give this submission a unique
//      `ref` to dispatch the workflow on and to filter the runs list
//      by (see step 5), the same way it always has; it no longer
//      carries the bundle's bytes itself (see step 3 for why that
//      moved).
//   3. Creates a GitHub Release tagged with that same scratch-branch
//      string (repos/.../releases, non-draft so the tag actually gets
//      cut - see BDS_INPUT_ASSET_NAME in the .m) and uploads the
//      modded bundle's bytes to it as a binary release asset named
//      BDS_INPUT_ASSET_NAME (repos/.../releases/{id}/assets on
//      uploads.github.com). Before that POST, an uncompressed or LZ4 UnityFS
//      bundle is transport-recompressed as LZ4HC to reduce bandwidth; an
//      already-LZ4HC bundle is uploaded unchanged. The workflow therefore
//      always receives a valid UnityFS archive, just with a more compact
//      transport representation when applicable.
//      uploads.github.com, Content-Type: application/octet-stream).
//      This used to go through the git Blob API instead (git/blobs,
//      base64-encoded, committed into a tree/commit on the scratch
//      branch) - that path both inflates the payload ~1.33x for
//      base64 and runs into the Blob/Contents APIs' much lower
//      practical size ceiling. Release assets are uploaded as raw
//      bytes and support up to 2GB each, which is the actual
//      constraint a modded desktop Unity bundle can threaten to hit.
//   4. Dispatches config.workflowFile on that scratch branch
//      (actions/workflows/{file}/dispatches), passing
//      `{"release_tag": <scratch branch string>, "output_format":
//      config.outputFormat}` as inputs - the workflow downloads
//      BDS_INPUT_ASSET_NAME off that release by tag (`gh release
//      download`) rather than checking out a committed file.
//   5. Polls actions/workflows/{file}/runs?branch=<scratch>&event=
//      workflow_dispatch for the run this dispatch created (the
//      dispatch endpoint itself returns no run id - this is a known
//      GitHub API gap, not a bug here), then polls that run's own
//      status until it reports "completed".
//   6. On a successful run, downloads the doctored bundle back out as
//      the BDS_OUTPUT_ASSET_NAME asset on that same release (looked up
//      by tag, repos/.../releases/tags/{tag}) - i.e. the workflow is
//      expected to `gh release upload` its output back onto the same
//      release under that fixed asset name, not hand it back as a run
//      artifact. (An artifact would need this class to parse a zip
//      container on-device with no library for that on hand; a second
//      release asset is one more authenticated GET with nothing new to
//      implement.) Before this class ever hands the downloaded bundle
//      back to a caller, it's unconditionally decompressed in place to
//      plain UnityFS (no LZ4/LZ4HC/LZMA framing) via UnityBundleCAB -
//      confirmed on-device that a compressed doctored bundle fails to
//      load once swapped in, so this step isn't gated behind any
//      Config switch the way the upload-side LZ4HC recompression is.
//      An already-uncompressed doctored bundle is left untouched.
//   7. Deletes the release and its underlying tag ref, then the scratch
//      branch (all best-effort - a failure here is logged, not
//      surfaced to the caller, since the doctored bundle has already
//      been safely read out by that point).
//
// BDS_INPUT_ASSET_NAME/BDS_OUTPUT_ASSET_NAME, the "release_tag" input
// name, and the "output_format" input name are a CONVENTION THIS CLASS
// ASSUMES THE WORKFLOW YAML FOLLOWS - they are not discoverable from
// the GitHub API. If the actual doctor-bundle workflow uses different
// asset/input names, update the #define's at the top of the .m to
// match it (or vice versa) - the two have to agree exactly, the same
// way PatchManifestNetwork.m's kTargetHostSuffix/kTargetPathSuffix have
// to match whatever the game's CDN actually serves.
//
// AUTH: config.authToken is a GitHub Personal Access Token sent as
// `Authorization: Bearer <token>` on every request below. It needs, at
// minimum: repo contents read/write (steps 1-3, 6-7 - releases live
// under the Contents permission) and `actions:write` (step 4) /
// `actions:read` (step 5) on the target repo - i.e. a fine-grained PAT
// scoped to just that repo with Contents (read/write) and Actions
// (read/write) permissions, or a classic PAT with the `repo` and
// `workflow` scopes. See BundleDoctorSettings.h for where this token
// is actually stored (Keychain) and that file's own caveat about
// Keychain access from this tweak's injected-dylib position.
//
// THREADING: +doctorBundleAtURL:config:progress:completion: does all of
// the above synchronously (blocking dispatch_semaphore waits between
// each NSURLSession call) on a background queue it manages itself -
// callers can invoke it from the main thread without freezing the UI.
// `progress` and `completion` are both always called back on the main
// queue.
//
// DEPRECATED, IN FAVOR OF THE DECOUPLED PHASE API BELOW (read before
// adding a new caller of the single-shot method above): the one-shot
// +doctorBundleAtURL:config:progress:completion: call above is still
// here and still works, but it made every caller's UI block on the
// full upload-dispatch-poll-download round trip behind a single modal
// popup with nothing useful to do while it waited - see
// GraphicsDebugOverlay.m's Mods (doctor pipeline) section, which is
// exactly what drove the redesign below. Ownership of a submission is
// now split into four independent phases a caller can drive from its
// own state machine (see ModAssetLibrary.h's ModAssetLibraryDoctorStatus,
// which mirrors these phases 1:1) instead of one blocking call:
//
//   1. +dispatchBundleAtURL:config:uploadProgress:completion: - branch
//      + release + asset upload + workflow_dispatch. Real byte-level
//      progress (a raw cumulative byte count) via uploadProgress, since
//      the release-asset upload is the only phase with an actual
//      multi-second body to send. Returns a BundleDoctorHandle the caller persists
//      (ModAssetLibrary's doctorScratchBranch/doctorRunID/doctorRunURL
//      fields exist specifically to round-trip this across app
//      relaunches; scratchBranch doubles as the release's tag name -
//      see this header's transport note above).
//
//   2. +resolveRunForHandle:config:completion: - single-shot lookup of
//      the run the dispatch in step 1 created (the dispatch endpoint
//      itself never returns a run id - see this header's step 6 above).
//      Cheap enough to call from a timer tick; `found == NO` just means
//      "not yet", not a failure - the run typically takes a few seconds
//      to appear in the runs list after dispatch.
//
//   3. +fetchRunStatusForHandle:config:completion: - single-shot status
//      + percent-complete check once handle.runID is known. No internal
//      loop/sleep, unlike the old method's +bds_waitForRunCompletion: -
//      the caller's own timer (e.g. a 6s NSTimer) drives repeated calls.
//
//   4. +fetchDoctoredBundleForHandle:config:completion: - call once
//      phase 3 reports BundleDoctorRunStatusSucceeded. Downloads the
//      doctored bundle as a release asset and best-effort deletes the
//      release/tag/scratch branch, same as the old method's tail end.
//
// None of these four take a `progress:` status-string block the way the
// old method did - phases 2-4 are each one cheap JSON request with a
// single outcome, not a multi-step sequence worth narrating.
//
// UNIQUE RELEASE NAMING + PER-ENTRY RESUME CHECK, AND WHY (read before
// touching +bds_uniqueTagForCAB: in the .m): the scratch branch/release
// tag used to be deterministic - derived from the bundle's own CAB +
// SHA-256, so re-dispatching an unchanged bundle landed on the exact same
// tag a previous submission (possibly a completely unrelated one, on a
// completely unrelated entry, that just happened to share content) had
// already used. That caused a plethora of issues on a re-upload: the
// branch-create/release-create calls below would collide with whatever
// that earlier submission had left behind under the same tag (still
// mid-flight, or cleaned up only halfway through a failure). The tag is
// now always freshly unique instead - a UUID is unconditionally part of
// it - so two dispatches never collide, no matter how many times the same
// bundle gets uploaded:
//
//   bundle-doctor/CAB-<first 5 hex chars of the bundle's own CAB
//   identifier>-<a fresh UUID>
//
// e.g. "bundle-doctor/CAB-38321-9F2A1C3E-...". If the bundle's CAB can't
// be resolved (+[UnityBundleCAB primaryCABForBundleAtPath:error:] failed
// - not a UnityFS archive this can parse), this falls back to a bare
// "bundle-doctor/<uuid>" tag with no CAB segment.
//
// The full tag (CAB segment + UUID) is what +bds_cabDisplayNameFromTag:
// strips down to just "CAB-XXXXX" for display - the UUID itself is never
// shown, but it IS what round-trips through ModAssetLibrary's
// doctorScratchBranch field once a submission is dispatched, i.e. it's
// stored alongside that entry's own bundle information without ever
// appearing in the UI.
//
// +dispatchBundleAtURL:config:previousScratchBranch:uploadProgress:
// completion:'s previousScratchBranch parameter is what lets Dispatch/
// Retry still "check first if it's already there" without resurrecting
// the old cross-bundle dedup: pass the tag from THIS entry's own earlier
// attempt (e.g. Retry, resuming a submission whose run may have quietly
// finished while the app was closed) and, before doing any work, this
// checks that one specific tag - and only that tag - for a release that
// already has BDS_OUTPUT_ASSET_NAME on it. On a hit, it skips the upload/
// branch-create/workflow-dispatch steps entirely and hands back a handle
// with alreadyComplete == YES (see that property above) pointing straight
// at the existing release. Pass nil for a brand-new entry that has never
// been dispatched before - there is nothing of its own to resume, and
// this deliberately does NOT fall back to probing for some OTHER release
// that happens to match the bundle's CAB/SHA, which is exactly the
// global, content-keyed dedup that caused the collisions above.
//
// A run that fails, or is still mid-flight, does NOT get an early-exit
// here - only a release that already has the finished
// BDS_OUTPUT_ASSET_NAME asset on it counts as a resume hit. Because
// every tag is now one-shot/per-submission rather than a long-lived
// cache key, +fetchDoctoredBundleForHandle:...'s post-download cleanup
// goes back to deleting the release/tag itself (not just the scratch
// branch) once its one download succeeds - there's no future submission
// left that could ever reuse this exact tag anyway.

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
    BundleDoctorServiceErrorOutputMissing,       // run succeeded but BDS_OUTPUT_ASSET_NAME wasn't on the release afterward - workflow/asset-name convention mismatch, see this file's header
};

extern NSString * const BundleDoctorServiceHTTPStatusKey;   // NSNumber (NSInteger)
extern NSString * const BundleDoctorServiceResponseBodyKey; // NSString, truncated
extern NSString * const BundleDoctorServiceRunURLKey;       // NSString - the run's html_url, for the person to go look at logs

// Coarse state for the decoupled phase API's +fetchRunStatusForHandle:...
// - see that method below.
typedef NS_ENUM(NSInteger, BundleDoctorRunStatus) {
    BundleDoctorRunStatusQueued = 0,   // run exists but no job has started yet - percentComplete is 0
    BundleDoctorRunStatusInProgress,   // at least one job step has completed - see percentComplete
    BundleDoctorRunStatusSucceeded,    // completed with conclusion "success" - percentComplete is 1.0; call +fetchDoctoredBundleForHandle:... next
    BundleDoctorRunStatusFailed,       // completed with any other conclusion - see the completion block's own NSError
};

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

// Identifies one in-flight (or completed) doctor-bundle submission across
// the four decoupled phases below. Opaque other than the properties
// spelled out here - callers don't construct one directly except via
// +handleFromDictionaryRepresentation:config: when restoring one that was
// persisted (see ModAssetLibrary's doctorScratchBranch/doctorRunID/
// doctorRunURL fields, which are exactly this object's own fields
// flattened for manifest.json storage).
@interface BundleDoctorHandle : NSObject
@property (nonatomic, copy, readonly) NSString *scratchBranch;   // the tag/branch string this submission lives on - both the scratch git branch dispatched against (when one was created - see alreadyComplete) and the tag name of the release carrying its input/output bundle assets (see this header's transport note and its "Deterministic release naming" addendum below)
@property (nonatomic, copy, nullable) NSString *runID;           // nil until +resolveRunForHandle:config:completion: fills it in
@property (nonatomic, copy, nullable) NSString *runURL;          // nil until the same call fills it in - the run's html_url, for surfacing on failure

// YES when +dispatchBundleAtURL:config:uploadProgress:completion: found an
// already-doctored release sitting under this bundle's deterministic tag
// (see the addendum below) and skipped the upload/branch/dispatch steps
// entirely - runID/runURL are (and will stay) nil in this case, since no
// run was ever created for this call. Callers MUST check this before
// falling into the normal phase 2/3 poll loop: when YES, go straight to
// +fetchDoctoredBundleForHandle:config:progress:completion: (phase 4)
// instead, exactly as if phase 3 had just reported
// BundleDoctorRunStatusSucceeded. Always NO on a handle rebuilt via
// +handleFromDictionaryRepresentation: (this flag is a same-call signal,
// not part of a submission's persisted state - by the time a Processing
// entry's handle would need reconstructing after an app relaunch, this
// call has already returned and the caller has already acted on it).
@property (nonatomic, assign, readonly) BOOL alreadyComplete;

// Flattened form of this handle's own three properties, suitable for
// storing verbatim into ModAssetLibraryEntry's doctorScratchBranch/
// doctorRunID/doctorRunURL. Does NOT include repoOwner/repoName/
// authToken - those come back from whatever BundleDoctorConfig the
// caller already has stored (BundleDoctorSettings.h), not from this
// object.
- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation;

// Reconstructs a handle from a previously-persisted
// -dictionaryRepresentation (e.g. after an app relaunch mid-submission).
// Returns nil if scratchBranch is missing/empty - runID/runURL are
// optional (a submission that hadn't resolved its run yet before the
// app was killed comes back with those nil, exactly as if
// +resolveRunForHandle:config:completion: simply hadn't succeeded yet).
+ (nullable instancetype)handleFromDictionaryRepresentation:(NSDictionary<NSString *, NSString *> *)dict;
@end

// One GitHub Release under config.repoOwner/repoName that already
// carries a finished BDS_OUTPUT_ASSET_NAME ("output.bundle") asset -
// i.e. one row in 6's "Processed Bundles" folder listing. Read-only,
// display-only snapshot of the release's own GitHub metadata at the
// moment +listProcessedReleasesForConfig:completion: ran; unlike
// BundleDoctorHandle this doesn't track an in-flight submission and
// isn't persisted anywhere - the release itself, sitting in the repo's
// releases tab, is the only source of truth (see this header's
// "Deterministic release naming" addendum: the release now outlives
// the submission that created it, on purpose, as its own on-proxy
// cache entry).
@interface BundleDoctorProcessedRelease : NSObject
@property (nonatomic, copy, readonly) NSString *tagName; // e.g. "bundle-doctor/CAB-38321-sha256-9f2a1" - the release's own git tag (see bds_deterministicTagForCAB)

// "CAB-XXXXX" parsed out of tagName, per the person's 6 spec ("the
// release's name, excluding the sha part") - i.e. tagName's own
// truncated CAB segment, not a re-read of the doctored bundle's full
// CAB id (nothing in the release response carries that - reading it
// back out would mean downloading the bundle itself just to label a
// list row). nil when tagName doesn't contain a "CAB-<hex>" segment at
// all - the old random-UUID fallback tag (see bds_deterministicTagForCAB)
// used when the original submission's bundle had no readable CAB of
// its own; there's nothing to extract from a bare UUID in that case.
@property (nonatomic, copy, readonly, nullable) NSString *cabDisplayName;
// cabDisplayName when present, else tagName verbatim - what the row
// actually renders as its file name, so a legacy random-UUID-tagged
// release still shows something instead of a blank row.
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, assign, readonly) unsigned long long byteSize;   // BDS_OUTPUT_ASSET_NAME asset's own "size"
@property (nonatomic, copy, readonly, nullable) NSString *uploadedAt;  // that asset's own "created_at", verbatim ISO 8601 UTC as GitHub returns it - nil if the response omitted it
// "sha256:<hex>", verbatim from the release asset's own "digest" field
// (GitHub computes and returns this itself) - NOT recomputed on-device,
// which would mean downloading every listed bundle just to render a
// list row. nil on a response that didn't carry a digest (an older
// GitHub Enterprise version, or an asset uploaded before GitHub started
// returning this field) - the Checksum row is simply omitted for that
// release rather than shown blank; see gd_make_processed_bundle_info_panel
// in GraphicsDebugOverlay.m.
@property (nonatomic, copy, readonly, nullable) NSString *checksum;
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

#pragma mark - Decoupled phase API (see this file's header)

// Phase 1: reads moddedBundleURL, creates a brand-new scratch branch and
// a same-named GitHub Release, uploads the bundle to that release as a
// binary asset (with real byte-level progress via uploadProgress - every
// other phase below is a single small JSON request with nothing
// meaningful to report mid-flight), and dispatches the doctor-bundle
// workflow on the scratch branch with that release's tag as an input.
// uploadProgress is called on the main queue zero or more times with the
// raw cumulative byte count sent so far (across both the modded bundle
// and, when present, the shader-restore original.bundle asset that
// follows it on the same release - see the .m) as the asset's body is
// sent; completion is called exactly once, also on the main queue. On
// success, the returned handle's runID/runURL are still nil - call
// +resolveRunForHandle:config:completion: next.
+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL
                       config:(BundleDoctorConfig *)config
        previousScratchBranch:(nullable NSString *)previousScratchBranch
               uploadProgress:(nullable void (^)(int64_t bytesSent))uploadProgress
                   completion:(void (^)(BundleDoctorHandle * _Nullable handle, NSError * _Nullable error))completion;

// Phase 2: single-shot lookup of the run that phase 1's dispatch call
// created on handle.scratchBranch. Safe to call repeatedly (e.g. once
// right after phase 1, then again on the same 6s timer phase 3 uses,
// until it succeeds) - `found == NO` with a nil error means "the run
// hasn't shown up in the runs list yet", which is normal for the first
// few seconds after a dispatch, not a failure. On found == YES,
// handle.runID/runURL are filled in for the caller to persist alongside
// the rest of the handle.
+ (void)resolveRunForHandle:(BundleDoctorHandle *)handle
                       config:(BundleDoctorConfig *)config
                   completion:(void (^)(BOOL found, NSError * _Nullable error))completion;

// Phase 3: single-shot status/progress check for a run whose id is
// already known (handle.runID non-nil - call +resolveRunForHandle:...
// first if it isn't). Does not loop or sleep internally - intended to be
// driven by the caller's own poll timer (per this project's spec, every
// 6 seconds). percentComplete is derived from the run's own jobs/steps
// (completed steps / total steps across every job in the run) since the
// workflow reports no finer-grained progress than that - see the .m for
// exactly how steps are counted. status/percentComplete are both 0/
// Queued if the run hasn't started any job yet. On
// BundleDoctorRunStatusFailed, error is filled in (same
// BundleDoctorServiceErrorRunFailed shape as the old one-shot method
// used, including BundleDoctorServiceRunURLKey); on every other status,
// error is nil even though this always calls completion (never treats
// "still queued/in progress" as an error the way a timeout-based loop
// would).
+ (void)fetchRunStatusForHandle:(BundleDoctorHandle *)handle
                           config:(BundleDoctorConfig *)config
                       completion:(void (^)(BundleDoctorRunStatus status, double percentComplete, NSError * _Nullable error))completion;

// Phase 4: call once phase 3 reports BundleDoctorRunStatusSucceeded.
// Downloads the doctored bundle as a release asset from the release
// tagged handle.scratchBranch, writes it to a temp file the caller owns
// (same ownership convention as the deprecated one-shot method's
// doctoredBundleURL), and best-effort deletes the release/tag and the
// scratch branch (logged, not surfaced, same as before). Safe to call
// more than once if the caller's own download step needs retrying - the
// release/branch are only deleted after a successful fetch, and deleting
// an already-deleted release/branch is itself best-effort/silent.
// downloadProgress, when non-nil, is called on the main queue with the
// raw cumulative byte count as the doctored bundle's bytes come down -
// same contract as +dispatchBundleAtURL:...'s uploadProgress, mirrored
// for this side of the pipeline. Reported directly off the download
// task's own totalBytesWritten, so - unlike an older 0.0-1.0-fraction
// version of this contract - it never depends on a known expected total
// (GitHub's blob-storage proxy doesn't always give the download response
// one; a Content-Length-less chunked-transfer response used to leave
// progress stuck with nothing to render against).
+ (void)fetchDoctoredBundleForHandle:(BundleDoctorHandle *)handle
                                config:(BundleDoctorConfig *)config
                              progress:(nullable void (^)(int64_t bytesWritten))downloadProgress
                            completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion;

#pragma mark - Upload transport compression

// Whether an uncompressed/LZ4 bundle gets transport-recompressed as
// LZ4HC before upload (see this header's step 3 and
// bds_prepareBundleDataForUpload in the .m). Bundles already using
// LZ4HC, LZMA, or LZHAM are untouched either way - this only gates the
// recompression path itself. Backed by NSUserDefaults, defaults to YES
// to match this project's existing behavior for anyone updating from a
// build that didn't have the switch. Read live at upload-prepare time
// rather than cached, so flipping the Config section's "Disable LZ4HC
// compression on dispatch" switch takes effect on the very next
// dispatch with no relaunch needed. With this off, an uncompressed/LZ4
// bundle just uploads at its original size instead - larger transport
// payload, but skips this project's from-scratch LZ4HC encoder
// entirely.
+ (BOOL)isUploadCompressionEnabled;
+ (void)setUploadCompressionEnabled:(BOOL)enabled;

#pragma mark - Processed Bundles listing (6)

// Every release under config.repoOwner/repoName that already carries a
// finished BDS_OUTPUT_ASSET_NAME asset - i.e. 6's "Processed Bundles"
// folder listing, one BundleDoctorProcessedRelease per release. Pages
// through GET /repos/{owner}/{repo}/releases (100 per page, GitHub's
// own max) until a short page ends it, same "only a release that
// already has the output asset counts" rule
// +bds_releaseAtTagHasOutputAsset:config: already applies to a single
// tag - a release still mid-flight, or one a caller abandoned before
// the workflow uploaded its output, is silently skipped rather than
// listed with a missing size/checksum. Returned array is sorted
// newest-uploaded-first, by the output asset's own created_at - the
// folder's own "always last, ignore A-Z" placement in the accordion is
// the caller's job (GraphicsDebugOverlay.m's -gd_rebuildModsLibrary),
// this is just this folder's own row order. On failure (bad/missing
// credentials, a transport error, a non-2xx partway through pagination),
// releases is nil and error is filled - same BundleDoctorServiceErrorCode
// shape every other call in this class uses.
+ (void)listProcessedReleasesForConfig:(BundleDoctorConfig *)config
                              completion:(void (^)(NSArray<BundleDoctorProcessedRelease *> * _Nullable releases, NSError * _Nullable error))completion;

#pragma mark - Processed Bundles install (9)

// Downloads one already-processed release's BDS_OUTPUT_ASSET_NAME asset
// to a local temp file the caller owns (same ownership convention as
// +fetchDoctoredBundleForHandle:...'s doctoredBundleURL - not cleaned up
// by this class). Deliberately does NOT call
// +bds_cleanupScratchSubmission:config: the way +fetchDoctoredBundleForHandle:...
// does after its own download - a Processed Bundles release is meant to
// stay in the repo's releases tab as a reusable on-proxy cache entry
// (see BundleDoctorProcessedRelease's own header) so it can be installed
// again later or by someone else; only +deleteAllReleasesForConfig:...'s
// "Delete Stored Bundles in Proxy" button ever removes it. Shares
// +bds_downloadReleaseAssetNamed:fromReleaseTag:config:progress:data:error:
// with the phase-4 fetch for the same reason - it's the same "GET this
// named asset off this tag" operation either way, just without the
// teardown afterward. downloadProgress/completion have the exact same
// contract (main-queue callbacks, a raw cumulative byte count, same
// BundleDoctorServiceErrorCode shape on failure) as
// +fetchDoctoredBundleForHandle:config:progress:completion:.
+ (void)downloadProcessedRelease:(BundleDoctorProcessedRelease *)release
                            config:(BundleDoctorConfig *)config
                          progress:(nullable void (^)(int64_t bytesWritten))downloadProgress
                        completion:(void (^)(NSURL * _Nullable bundleURL, NSError * _Nullable error))completion;

#pragma mark - Delete every stored release (8)

// 8: "delete stored bundles in proxy" - unlike +listProcessedReleasesForConfig:
// above (which only surfaces releases that already have an
// output.bundle asset), this deletes EVERY release entry in the
// configured repo, finished or not, plus each one's underlying git
// tag ref (a release delete alone leaves that behind - same fact
// +bds_deleteReleaseWithTag:config: already accounts for). Each
// release/tag-ref pair is best-effort independently, same shape as
// +bds_cleanupScratchSubmission: - one release's 404/failure doesn't
// stop the rest from being attempted. `deletedCount` is how many
// release objects were actually removed (tag-ref cleanup failures
// aren't counted or surfaced - see the .m); `error` is only set for a
// failure that stopped this before it could even list what's there
// (bad/missing credentials, a transport error, a non-2xx partway
// through pagination) - same BundleDoctorServiceErrorCode shape every
// other call in this class uses. Wired to the Config section's
// "Delete Stored Bundles in Proxy" button in GraphicsDebugOverlay.m.
+ (void)deleteAllReleasesForConfig:(BundleDoctorConfig *)config
                          completion:(void (^)(NSInteger deletedCount, NSError * _Nullable error))completion;

#pragma mark - Credential check

// Confirms config.repoOwner/repoName/authToken actually authenticate
// against the GitHub API and can see the target repo - a single
// `GET /repos/{owner}/{repo}` call, not a dry run of any of the four
// phases above. `valid` is YES only on a 2xx response; a bad/expired
// token, a token that can't see the repo, or a repo that doesn't exist
// all come back as `valid == NO` with `error` describing why (same
// BundleDoctorServiceErrorAPIError/BundleDoctorServiceHTTPStatusKey
// shape every other GET in this class already surfaces - see
// +bds_getJSON:config:error: in the .m). Wired to the Auth section's
// "Verify" button in GraphicsDebugOverlay.m.
+ (void)verifyCredentialsForConfig:(BundleDoctorConfig *)config
                          completion:(void (^)(BOOL valid, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
