#import "BundleDoctorService.h"
#import "ZTweakLog.h"
#import "UnityBundleCAB.h"
#import "UnityCacheLocator.h"
#import <CommonCrypto/CommonDigest.h>

NSString * const BundleDoctorServiceErrorDomain = @"BundleDoctorServiceErrorDomain";
NSString * const BundleDoctorServiceHTTPStatusKey = @"BundleDoctorServiceHTTPStatusKey";
NSString * const BundleDoctorServiceResponseBodyKey = @"BundleDoctorServiceResponseBodyKey";
NSString * const BundleDoctorServiceRunURLKey = @"BundleDoctorServiceRunURLKey";

// --- Workflow contract - see BundleDoctorService.h's big header comment ---
// These have to match whatever the actual doctor-bundle workflow YAML in
// the target repo expects/produces (see doctor-bundle.yml: it takes
// `release_tag`/`output_format` as workflow_dispatch inputs, downloads
// BDS_INPUT_ASSET_NAME off that release, and uploads BDS_OUTPUT_ASSET_NAME
// - plus a done.marker this class doesn't need to consume, since run
// status already tells it when the workflow is finished - back onto the
// same release).
static NSString * const kBDSInputAssetName = @"input.bundle";
static NSString * const kBDSOutputAssetName = @"output.bundle";
// Optional: only uploaded when +bds_findOriginalBundleDataForModdedBundleAtURL:
// resolves a same-CAB stock bundle via UnityCacheLocator (see that method,
// below). doctor-bundle.yml's own "if present" download step and
// BundleDoctor's --original flag are what actually key off this name - it's
// a fixed asset name for the same reason input.bundle/output.bundle are.
static NSString * const kBDSOriginalAssetName = @"original.bundle";
static NSString * const kBDSReleaseTagInputKey = @"release_tag";
static NSString * const kBDSInputFormatKey = @"output_format";

static NSString * const kBDSDefaultRef = @"main";
static NSString * const kBDSDefaultWorkflowFile = @"doctor-bundle.yml";
static NSString * const kBDSDefaultOutputFormat = @"RGBA32";

static const NSTimeInterval kBDSRunDiscoveryTimeout = 30.0;   // waiting for the dispatched run to show up in the runs list
static const NSTimeInterval kBDSRunDiscoveryPollInterval = 2.0;
static const NSTimeInterval kBDSRunCompletionTimeout = 600.0; // waiting for the run itself to finish - AssetsTools.NET re-encoding can be slow on a big bundle
static const NSTimeInterval kBDSRunCompletionPollInterval = 5.0;

// Persistence for the Config section's "Disable LZ4HC compression on
// dispatch" switch - same NSUserDefaults approach as
// PatchManifestNetwork's own Config-driven boolean (see that file for
// the equivalent).
static NSString * const kBDSUploadCompressionEnabledDefaultsKey = @"com.120F.BundleDoctorService.uploadCompressionEnabled";

static NSString *bds_compressionLabel(uint8_t type) {
    switch (type) {
        case 0: return @"none";
        case 1: return @"LZMA";
        case 2: return @"LZ4";
        case 3: return @"LZ4HC";
        case 4: return @"LZHAM";
        default: return [NSString stringWithFormat:@"type-%u", type];
    }
}

// See BundleDoctorService.h's "Unique release naming + per-entry resume
// check" addendum - this is the tag/branch string, always freshly unique
// per call now (a UUID is unconditionally part of it - see that addendum
// for why the old CAB+SHA-deterministic scheme was dropped). cabIdentifier
// is expected in the @"CAB-<hash>" shape
// +[UnityBundleCAB primaryCABForBundleAtPath:error:] returns; nil/empty
// just means the tag has no CAB segment to display (falls back to a bare
// "bundle-doctor/<uuid>"), not a change in dedup behavior - there never
// was any content-based dedup for this class to lose.
static NSString *bds_uniqueTagForCAB(NSString *cabIdentifier) {
    NSString *uuid = [NSUUID UUID].UUIDString;
    if (cabIdentifier.length == 0) {
        return [NSString stringWithFormat:@"bundle-doctor/%@", uuid];
    }
    NSString *cabHash = [cabIdentifier hasPrefix:@"CAB-"] ? [cabIdentifier substringFromIndex:4] : cabIdentifier;
    NSString *cabTrunc = [cabHash substringToIndex:MIN((NSUInteger)5, cabHash.length)];
    return [NSString stringWithFormat:@"bundle-doctor/CAB-%@-%@", cabTrunc, uuid];
}

// See BundleDoctorProcessedRelease.h's cabDisplayName header comment -
// pulls the "CAB-<hex>" segment back out of a tag (e.g.
// "bundle-doctor/CAB-38321-9f2a1c3e-..." -> "CAB-38321"), i.e. the
// person's spec's "release's name, excluding the UUID part" - the UUID
// itself is kept in the tag (so it round-trips through
// entry.doctorScratchBranch as the per-entry resume key - see this
// file's header) but never shown. Returns nil if tagName has no "CAB-"
// substring at all (the bare-UUID fallback tag - see bds_uniqueTagForCAB
// above - which has nothing to extract).
static NSString *bds_cabDisplayNameFromTag(NSString *tagName) {
    NSRange cabRange = [tagName rangeOfString:@"CAB-"];
    if (cabRange.location == NSNotFound) return nil;
    NSString *fromCAB = [tagName substringFromIndex:cabRange.location];
    // fromCAB is "CAB-<5 hex>-<uuid>" - the UUID itself contains hyphens,
    // so isolate the CAB segment by taking exactly the first two
    // hyphen-delimited components ("CAB" and the 5-char hash) rather than
    // cutting at the first hyphen found or trying to pattern-match a UUID.
    NSArray<NSString *> *components = [fromCAB componentsSeparatedByString:@"-"];
    if (components.count < 2) return fromCAB;
    return [NSString stringWithFormat:@"%@-%@", components[0], components[1]];
}

// Transport optimization only: GitHub sees a smaller release asset, while
// the workflow still receives a completely normal UnityFS bundle. Bundles
// already using LZ4HC are left byte-for-byte untouched; LZMA/LZHAM and other
// unsupported formats are also left alone rather than risking a conversion
// that this on-device parser cannot faithfully reproduce.
static NSData *bds_prepareBundleDataForUpload(NSData *data, NSError **error) {
    if (data.length == 0) return data;

    if (![BundleDoctorService isUploadCompressionEnabled]) {
        ZLog(@"[BundleDoctorService] upload compression disabled via Config switch - uploading %lu bytes unchanged",
             (unsigned long)data.length);
        return data;
    }

    NSString *tmpName = [NSString stringWithFormat:@"bds-upload-%@.bundle", NSUUID.UUID.UUIDString];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName];
    NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];

    NSError *writeError = nil;
    if (![data writeToURL:tmpURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError;
        return nil;
    }

    NSError *compressionError = nil;
    uint8_t type = [UnityBundleCAB compressionTypeForBundleAtPath:tmpPath error:&compressionError];
    if (compressionError) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = compressionError;
        return nil;
    }

    if (type != 0 && type != 2) {
        ZLog(@"[BundleDoctorService] upload compression: leaving %@ bundle unchanged (%lu bytes)",
             bds_compressionLabel(type), (unsigned long)data.length);
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        return data;
    }

    ZLog(@"[BundleDoctorService] upload compression: source is %@ (%lu bytes), recompressing as LZ4HC…",
         bds_compressionLabel(type), (unsigned long)data.length);

    NSData *compressed = [UnityBundleCAB LZ4HCDataForBundleAtPath:tmpPath error:&compressionError];
    [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
    if (!compressed) {
        if (error) *error = compressionError ?: [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                                                       code:BundleDoctorServiceErrorRequestFailed
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Couldn't recompress the bundle as LZ4HC for upload."}];
        return nil;
    }

    ZLog(@"[BundleDoctorService] upload compression: %lu -> %lu bytes (%.1f%% of original)",
         (unsigned long)data.length,
         (unsigned long)compressed.length,
         data.length ? (100.0 * (double)compressed.length / (double)data.length) : 0.0);
    return compressed;
}

// Post-download decompression used to be mandatory here: the re-encoder
// workflow's compressed output was being produced with a broken LZ4HC
// encode (see UnityBundleCAB.m's write-side flags fix), and on top of
// that this step's own "always realign 16 bytes" read logic could
// mis-decompress bundles that didn't actually need it - so this was
// masking one bug by risking a second one, and the on-device "compressed
// doctored bundles fail to load" testing that justified making it
// mandatory was almost certainly observing fallout from the encode bug,
// not anything about compression itself. Now that the doctor-bundle
// workflow emits genuine standard LZ4 (see BundleDoctor/
// UnityFsLz4Packer.cs) instead of LZ4HC, Limbus Company's own Unity
// runtime decompresses that at load time the same as it does for every
// other LZ4 bundle Unity ships - there's nothing left for this tweak to
// do to the bytes before handing them to BundleDoctorInstaller. Removed
// rather than left as a disabled no-op, since a step that silently
// mangled bundles once is not something to leave lying around for a
// future regression to quietly re-enable.

#pragma mark - BundleDoctorConfig

@implementation BundleDoctorConfig

- (BundleDoctorConfig *)normalizedConfig {
    BundleDoctorConfig *copy = [BundleDoctorConfig new];
    copy.repoOwner = self.repoOwner;
    copy.repoName = self.repoName;
    copy.authToken = self.authToken;
    copy.ref = self.ref.length > 0 ? self.ref : kBDSDefaultRef;
    copy.workflowFile = self.workflowFile.length > 0 ? self.workflowFile : kBDSDefaultWorkflowFile;
    copy.outputFormat = self.outputFormat.length > 0 ? self.outputFormat : kBDSDefaultOutputFormat;
    return copy;
}

@end

#pragma mark - BundleDoctorHandle

@implementation BundleDoctorHandle {
    NSString *_scratchBranch;
    BOOL _alreadyComplete;
}

- (instancetype)initWithScratchBranch:(NSString *)scratchBranch {
    return [self initWithScratchBranch:scratchBranch alreadyComplete:NO];
}

// Private - only +dispatchBundleAtURL:...'s cache-hit path constructs one
// of these with alreadyComplete == YES. Not exposed in the header since
// callers only ever read the flag, never set it.
- (instancetype)initWithScratchBranch:(NSString *)scratchBranch alreadyComplete:(BOOL)alreadyComplete {
    if ((self = [super init])) {
        _scratchBranch = [scratchBranch copy];
        _alreadyComplete = alreadyComplete;
    }
    return self;
}

- (NSString *)scratchBranch { return _scratchBranch; }
- (BOOL)alreadyComplete { return _alreadyComplete; }

- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation {
    NSMutableDictionary<NSString *, NSString *> *d = [NSMutableDictionary dictionary];
    d[@"scratchBranch"] = self.scratchBranch;
    if (self.runID) d[@"runID"] = self.runID;
    if (self.runURL) d[@"runURL"] = self.runURL;
    return d;
}

+ (nullable instancetype)handleFromDictionaryRepresentation:(NSDictionary<NSString *, NSString *> *)dict {
    NSString *branch = dict[@"scratchBranch"];
    if (![branch isKindOfClass:NSString.class] || branch.length == 0) return nil;
    BundleDoctorHandle *handle = [[BundleDoctorHandle alloc] initWithScratchBranch:branch];
    handle.runID = [dict[@"runID"] isKindOfClass:NSString.class] ? dict[@"runID"] : nil;
    handle.runURL = [dict[@"runURL"] isKindOfClass:NSString.class] ? dict[@"runURL"] : nil;
    return handle;
}

@end

#pragma mark - BDSUploadProgressDelegate

// Bridges NSURLSessionTaskDelegate's byte-level upload callback to a
// plain block, so +bds_uploadReleaseAssetData:name:uploadURLTemplate:...
// below can report real progress on the one request in this whole
// pipeline with an actual multi-second body (the modded bundle's raw
// bytes). Nothing else in this file needs this - every other request is
// a small JSON body/response, over before a progress callback would
// mean anything.
//
// PROGRESS ONLY - do not add response/data capture back onto this
// class. When a task is created via the block-based
// -uploadTaskWithRequest:fromData:completionHandler:, UIKit/Foundation
// does NOT invoke the session's own data-delegate methods
// (-URLSession:dataTask:didReceiveResponse:completionHandler:,
// -URLSession:dataTask:didReceiveData:) for that task - only delegate
// methods with no completion-handler equivalent still fire, which is
// exactly -URLSession:task:didSendBodyData:...: (upload progress) and
// nothing else. This class used to also implement
// didReceiveResponse:/didReceiveData: and +bds_uploadReleaseAssetData:...
// read the response/status back off THIS delegate instead of off its
// own completion handler's response/data parameters - since those
// delegate methods are never called in this configuration, that read
// -[NSHTTPURLResponse statusCode] off a permanently-nil httpResponse,
// silently returning 0 as "the" GitHub API status on every upload
// regardless of the real response (independent of whether the
// configured credentials/repo were actually valid). The real
// response/data are the completion handler's own parameters - see
// +bds_uploadReleaseAssetData:... below, which reads them from there
// now instead.
@interface BDSUploadProgressDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy, nullable) void (^onProgress)(double fractionComplete);
@end

@implementation BDSUploadProgressDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
    didSendBodyData:(int64_t)bytesSent
     totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (!self.onProgress || totalBytesExpectedToSend <= 0) return;
    double fraction = (double)totalBytesSent / (double)totalBytesExpectedToSend;
    self.onProgress(MIN(MAX(fraction, 0.0), 1.0));
}

@end

#pragma mark - BDSDownloadProgressDelegate

// Download-side mirror of BDSUploadProgressDelegate above, for
// +bds_downloadBinaryAtAbsoluteURLString:... (the release-asset GET that
// pulls the doctored bundle back down - the one download in this whole
// pipeline with an actual multi-second body). Unlike the upload side,
// -URLSession:downloadTask:didWriteData:totalBytesWritten:
// totalBytesExpectedToWrite: DOES still fire for a download task created
// via the block-based -downloadTaskWithRequest:completionHandler: - it's
// a task-level progress callback with no completion-handler equivalent
// of its own (the completion handler only ever gets the finished file's
// temp location), same category as didSendBodyData: on the upload side.
// So, also unlike BDSUploadProgressDelegate, this doesn't need the
// "read the body from the completion handler instead" workaround - a
// download task's completion handler already hands back a location, not
// accumulated data, so there was never a didReceiveData: substitute to
// route around here.
@interface BDSDownloadProgressDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy, nullable) void (^onProgress)(double fractionComplete);
// Set before the task starts, from the release asset's own "size" field
// (see +bds_downloadReleaseAssetNamed:...) - falls back into use below
// whenever totalBytesExpectedToWrite comes back <= 0, which GitHub's
// blob-storage proxy does for a chunked-transfer response with no
// Content-Length. Without this, onProgress was never called at all for
// such a response (matches the reported "indicator stuck at 0%, even
// though the download itself finishes fine" symptom exactly).
@property (nonatomic, assign) int64_t fallbackExpectedByteCount;
@end

@implementation BDSDownloadProgressDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (!self.onProgress) return;
    int64_t expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.fallbackExpectedByteCount;
    if (expected <= 0) return;
    double fraction = (double)totalBytesWritten / (double)expected;
    self.onProgress(MIN(MAX(fraction, 0.0), 1.0));
}

// NSURLSessionDownloadDelegate's one @required method, so this class has
// to implement it to conform - but for a task created via the block-based
// -downloadTaskWithRequest:completionHandler:, Foundation never actually
// invokes it (the completion handler's own `location` parameter is the
// real, only place the finished temp file's URL shows up - see
// +bds_downloadBinaryAtAbsoluteURLString:...). Intentionally empty.
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
}

@end

#pragma mark - BundleDoctorService

// Private class-continuation - every bds_-prefixed helper the class's
// public methods call is implemented further down in this same
// @implementation (grep for each one), but several are called from
// code that appears above their own implementation textually (e.g.
// -dispatchBundleAtURL:... below calls +bds_createBranch:... long
// before that method's own definition). Objective-C class methods sent
// to `self` inside a class method need a declaration visible before
// the call site or the compiler can't resolve the selector - same
// reason ModAssetLibrary.m has its own private mal_-prefixed block
// above +[ModAssetLibrary ...]'s @implementation. Kept in the same
// declaration order the methods are actually implemented in below.
@interface BundleDoctorService ()
+ (nullable NSData *)bds_findOriginalBundleDataForModdedBundleAtPath:(NSString *)moddedBundlePath;
+ (BOOL)bds_resolveBaseCommitSHA:(NSString **)outCommitSHA
                          config:(BundleDoctorConfig *)config
                           error:(NSError **)error;
+ (BOOL)bds_createBranch:(NSString *)branchName
              atCommitSHA:(NSString *)commitSHA
                   config:(BundleDoctorConfig *)config
                    error:(NSError **)error;
+ (BOOL)bds_errorIsAlreadyExists:(NSError *)error;
+ (void)bds_deleteBranch:(NSString *)branchName config:(BundleDoctorConfig *)config;
+ (BOOL)bds_createReleaseWithTagName:(NSString *)tagName
                       targetCommitish:(NSString *)targetCommitish
                                config:(BundleDoctorConfig *)config
                  outUploadURLTemplate:(NSString **)outUploadURLTemplate
                                 error:(NSError **)error;
+ (BOOL)bds_uploadReleaseAssetData:(NSData *)data
                                name:(NSString *)name
                   uploadURLTemplate:(NSString *)uploadURLTemplate
                            progress:(nullable void (^)(double fractionComplete))progress
                              config:(BundleDoctorConfig *)config
                               error:(NSError **)error;
+ (nullable NSDictionary *)bds_fetchReleaseByTag:(NSString *)tagName config:(BundleDoctorConfig *)config error:(NSError **)error;
+ (BOOL)bds_releaseAtTagHasOutputAsset:(NSString *)tagName config:(BundleDoctorConfig *)config;
+ (BOOL)bds_downloadReleaseAssetNamed:(NSString *)name
                       fromReleaseTag:(NSString *)releaseTag
                               config:(BundleDoctorConfig *)config
                             progress:(nullable void (^)(double fractionComplete))progress
                                 data:(NSData **)outData
                                error:(NSError **)error;
+ (void)bds_deleteReleaseWithTag:(NSString *)tagName config:(BundleDoctorConfig *)config;
+ (void)bds_cleanupScratchSubmission:(NSString *)scratchBranch config:(BundleDoctorConfig *)config;
+ (BOOL)bds_dispatchWorkflowOnBranch:(NSString *)branchName
                                config:(BundleDoctorConfig *)config
                                 error:(NSError **)error;
+ (BOOL)bds_findRunOnBranch:(NSString *)branchName
             dispatchedAfter:(NSDate *)dispatchedAt
                      config:(BundleDoctorConfig *)config
                       runID:(NSString **)outRunID
                      runURL:(NSString **)outRunURL
                       error:(NSError **)error;
+ (BOOL)bds_waitForRunCompletion:(NSString *)runID
                            runURL:(NSString *)runURL
                            config:(BundleDoctorConfig *)config
                             error:(NSError **)error;
+ (nullable NSMutableURLRequest *)bds_requestForAbsoluteURLString:(NSString *)urlString config:(BundleDoctorConfig *)config;
+ (nullable NSMutableURLRequest *)bds_requestForPath:(NSString *)path config:(BundleDoctorConfig *)config;
+ (nullable NSData *)bds_downloadBinaryAtAbsoluteURLString:(NSString *)urlString
                                                       config:(BundleDoctorConfig *)config
                                          expectedByteCount:(int64_t)expectedByteCount
                                                     progress:(nullable void (^)(double fractionComplete))progress
                                                        error:(NSError **)error;
+ (nullable id)bds_getJSON:(NSString *)path config:(BundleDoctorConfig *)config error:(NSError **)error;
+ (nullable id)bds_postJSON:(NSString *)path body:(NSDictionary *)body config:(BundleDoctorConfig *)config error:(NSError **)error;
+ (BOOL)bds_deleteJSON:(NSString *)path config:(BundleDoctorConfig *)config error:(NSError **)error;
+ (nullable id)bds_performJSONRequest:(NSURLRequest *)request expectBody:(BOOL)expectBody error:(NSError **)error;
+ (NSDateFormatter *)bds_iso8601Formatter;
+ (NSError *)bds_errorWithCode:(BundleDoctorServiceErrorCode)code description:(NSString *)description;
@end

#pragma mark - BundleDoctorProcessedRelease
//
// Relocated here (still its own complete, standalone @implementation -
// only the POSITION moved) from between two pieces of
// BundleDoctorService's own implementation, where it used to split
// that class's implementation in half. Objective-C doesn't allow a
// class's @implementation to be reopened as a second primary block in
// the same file ("reimplementation of class" - see progress.md for
// the build log this came from) the way separate classes can each get
// their own; keeping BundleDoctorService as one single continuous
// @implementation below (uninterrupted, per its own private extension
// right above needing every bds_ method visible in that one block) and
// moving this class's block out in front of it is what actually fixes
// that, rather than trying to split BundleDoctorService itself.

@implementation BundleDoctorProcessedRelease {
    NSString *_tagName;
    NSString *_cabDisplayName;
    NSString *_displayName;
    unsigned long long _byteSize;
    NSString *_uploadedAt;
    NSString *_checksum;
}

- (instancetype)initWithTagName:(NSString *)tagName
                        byteSize:(unsigned long long)byteSize
                      uploadedAt:(nullable NSString *)uploadedAt
                        checksum:(nullable NSString *)checksum {
    if ((self = [super init])) {
        _tagName = [tagName copy] ?: @"";
        _cabDisplayName = bds_cabDisplayNameFromTag(_tagName);
        _displayName = _cabDisplayName.length > 0 ? _cabDisplayName : _tagName;
        _byteSize = byteSize;
        _uploadedAt = [uploadedAt copy];
        _checksum = [checksum copy];
    }
    return self;
}

- (NSString *)tagName { return _tagName; }
- (NSString *)cabDisplayName { return _cabDisplayName; }
- (NSString *)displayName { return _displayName; }
- (unsigned long long)byteSize { return _byteSize; }
- (NSString *)uploadedAt { return _uploadedAt; }
- (NSString *)checksum { return _checksum; }

@end

#pragma mark - BundleDoctorService

@implementation BundleDoctorService

+ (BOOL)isUploadCompressionEnabled {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kBDSUploadCompressionEnabledDefaultsKey];
    // No stored value yet (fresh install, or a build predating this
    // switch) - default to YES so behavior doesn't silently change out
    // from under anyone already relying on it.
    return stored ? [stored boolValue] : YES;
}

+ (void)setUploadCompressionEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kBDSUploadCompressionEnabledDefaultsKey];
    ZLog(@"[BundleDoctorService] upload compression %@ via Config switch", enabled ? @"enabled" : @"disabled");
}

#pragma mark Public entry point

+ (void)doctorBundleAtURL:(NSURL *)moddedBundleURL
                    config:(BundleDoctorConfig *)rawConfig
                  progress:(void (^)(NSString *status))progress
                completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion {
    void (^report)(NSString *) = ^(NSString *status) {
        if (!progress) return;
        dispatch_async(dispatch_get_main_queue(), ^{ progress(status); });
    };
    void (^finish)(NSURL * _Nullable, NSError * _Nullable) = ^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;

        // --- Read the modded bundle off disk ---
        BOOL scoped = [moddedBundleURL startAccessingSecurityScopedResource];
        NSData *moddedData = [NSData dataWithContentsOfURL:moddedBundleURL options:0 error:&error];
        if (scoped) [moddedBundleURL stopAccessingSecurityScopedResource];
        if (!moddedData) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorCantReadModdedBundle
                                     description:error.localizedDescription ?: @"Couldn't read the modded bundle."]);
            return;
        }

        NSData *uploadData = bds_prepareBundleDataForUpload(moddedData, &error);
        if (!uploadData) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                     description:error.localizedDescription ?: @"Couldn't prepare the bundle for upload."]);
            return;
        }

        NSString *scratchBranch = [NSString stringWithFormat:@"bundle-doctor/%@", [NSUUID UUID].UUIDString];
        ZLog(@"[BundleDoctorService] starting run on %@/%@, scratch branch %@",
              config.repoOwner, config.repoName, scratchBranch);

        report(@"Reading base branch\u2026");
        NSString *baseCommitSHA = nil;
        if (![self bds_resolveBaseCommitSHA:&baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_createBranch:scratchBranch atCommitSHA:baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        report(@"Creating queue release\u2026");
        NSString *uploadURLTemplate = nil;
        if (![self bds_createReleaseWithTagName:scratchBranch targetCommitish:scratchBranch
                                          config:config outUploadURLTemplate:&uploadURLTemplate error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Uploading modded bundle\u2026");
        if (![self bds_uploadReleaseAssetData:uploadData name:kBDSInputAssetName
                             uploadURLTemplate:uploadURLTemplate progress:nil
                                        config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Triggering doctor-bundle workflow\u2026");
        NSDate *dispatchedAt = [NSDate date];
        if (![self bds_dispatchWorkflowOnBranch:scratchBranch config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config]; // best-effort cleanup, ignore result
            finish(nil, error);
            return;
        }

        report(@"Waiting for the run to start\u2026");
        NSString *runID = nil;
        NSString *runURL = nil;
        if (![self bds_findRunOnBranch:scratchBranch dispatchedAfter:dispatchedAt config:config
                                  runID:&runID runURL:&runURL error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Waiting for the workflow to finish\u2026");
        if (![self bds_waitForRunCompletion:runID runURL:runURL config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Downloading doctored bundle\u2026");
        NSData *doctoredData = nil;
        if (![self bds_downloadReleaseAssetNamed:kBDSOutputAssetName fromReleaseTag:scratchBranch
                                           config:config progress:nil data:&doctoredData error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Cleaning up\u2026");
        [self bds_cleanupScratchSubmission:scratchBranch config:config]; // best-effort, logged not surfaced - see header

        NSString *tempName = [NSString stringWithFormat:@"doctored-%@.bundle", [NSUUID UUID].UUIDString];
        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        NSError *writeError = nil;
        if (![doctoredData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError]) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                     description:writeError.localizedDescription ?: @"Couldn't write doctored bundle to a temp file."]);
            return;
        }

        ZLog(@"[BundleDoctorService] doctored bundle ready at %@ (%lu bytes)",
              tempURL.path, (unsigned long)doctoredData.length);

        finish(tempURL, nil);
    });
}

#pragma mark - Decoupled phase API (see this file's header)

// Best-effort lookup of the untouched, correctly-platformed counterpart to
// moddedBundlePath, for BundleDoctor's shader-restore pass (see
// Program.cs's --original). Uses the same CAB the modded bundle already
// carries in its own directory table - editing a Texture2D/re-saving the
// bundle doesn't change that name - to find the matching stock bundle
// already sitting in this app's own UnityCache (see UnityCacheLocator.h).
//
// Deliberately returns nil rather than an NSError on every failure mode
// here (unreadable CAB, no UnityCache directory, no match): none of these
// are failures of the dispatch itself, they just mean this particular
// submission proceeds without a shader-restore pass, exactly as if
// --original were never given. Only an actual read failure on a
// successfully-resolved path is logged any differently.
+ (nullable NSData *)bds_findOriginalBundleDataForModdedBundleAtPath:(NSString *)moddedBundlePath {
    NSError *cabError = nil;
    NSString *cab = [UnityCacheLocator cabForBundleAtPath:moddedBundlePath error:&cabError];
    if (!cab) {
        ZLog(@"[BundleDoctorService] shader-restore: couldn't read a CAB off the modded bundle (%@) - skipping.", cabError.localizedDescription);
        return nil;
    }

    NSError *locateError = nil;
    NSString *originalPath = [UnityCacheLocator locateBundlePathForCAB:cab error:&locateError];
    if (!originalPath) {
        ZLog(@"[BundleDoctorService] shader-restore: no cached original found for CAB %@ (%@) - skipping.", cab, locateError.localizedDescription);
        return nil;
    }

    NSError *readError = nil;
    NSData *originalData = [NSData dataWithContentsOfFile:originalPath options:0 error:&readError];
    if (!originalData) {
        // This one IS worth calling out distinctly - we resolved a path but
        // then couldn't read it (permissions, file vanished mid-read, etc.).
        ZLog(@"[BundleDoctorService] shader-restore: resolved original at %@ but couldn't read it (%@) - skipping.", originalPath, readError.localizedDescription);
        return nil;
    }

    ZLog(@"[BundleDoctorService] shader-restore: matched CAB %@ -> %@ (%lu bytes).", cab, originalPath, (unsigned long)originalData.length);
    return originalData;
}

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL
                       config:(BundleDoctorConfig *)rawConfig
        previousScratchBranch:(nullable NSString *)previousScratchBranch
               uploadProgress:(void (^)(double))uploadProgress
                   completion:(void (^)(BundleDoctorHandle * _Nullable, NSError * _Nullable))completion {
    void (^reportProgress)(double) = ^(double fraction) {
        if (!uploadProgress) return;
        dispatch_async(dispatch_get_main_queue(), ^{ uploadProgress(fraction); });
    };
    void (^finish)(BundleDoctorHandle * _Nullable, NSError * _Nullable) = ^(BundleDoctorHandle * _Nullable handle, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;

        BOOL scoped = [moddedBundleURL startAccessingSecurityScopedResource];
        NSData *moddedData = [NSData dataWithContentsOfURL:moddedBundleURL options:0 error:&error];
        if (scoped) [moddedBundleURL stopAccessingSecurityScopedResource];
        if (!moddedData) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorCantReadModdedBundle
                                     description:error.localizedDescription ?: @"Couldn't read the modded bundle."]);
            return;
        }

        NSData *uploadData = bds_prepareBundleDataForUpload(moddedData, &error);
        if (!uploadData) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                     description:error.localizedDescription ?: @"Couldn't prepare the bundle for upload."]);
            return;
        }

        // Best-effort, resolved from the modded bundle's own path (not
        // moddedData - the lookup reads the CAB straight off disk). nil here
        // just means this submission runs without a shader-restore pass -
        // see +bds_findOriginalBundleDataForModdedBundleAtPath:'s own header.
        // Uploaded byte-for-byte, deliberately NOT run through
        // bds_prepareBundleDataForUpload's LZ4HC recompression: the whole
        // point of this asset is to hand BundleDoctor pristine Shader bytes,
        // and the workflow discards it right after reading them out anyway -
        // no reason to risk a recompression bug touching the one copy of
        // this data that has to stay exact.
        NSData *originalData = [self bds_findOriginalBundleDataForModdedBundleAtPath:moddedBundleURL.path];

        // See BundleDoctorService.h's "Unique release naming + per-entry
        // resume check" addendum: every dispatch now gets its own unique
        // tag/branch (CAB identity is still folded in for readability,
        // but a UUID makes it unique regardless) - no two submissions,
        // even of byte-identical bundles, ever land on the same tag. That
        // means the branch/release-create calls below can never collide
        // with a leftover from an earlier attempt.
        NSError *cabError = nil;
        NSString *cabIdentifier = [UnityBundleCAB primaryCABForBundleAtPath:moddedBundleURL.path error:&cabError];
        if (!cabIdentifier) {
            ZLog(@"[BundleDoctorService] couldn't resolve a CAB identifier for %@ (%@) - tag will just be a bare UUID.",
                 moddedBundleURL.path.lastPathComponent, cabError.localizedDescription);
        }

        // Resume check, scoped to THIS submission only: if the caller
        // handed back a tag from an earlier attempt at dispatching this
        // exact entry (previousScratchBranch - e.g. Retry on an entry
        // that already got as far as a finished-but-never-polled run
        // before the app was killed), check that one specific tag for a
        // finished output asset before doing any new work. Deliberately
        // NOT a fresh content-hash lookup against "any bundle that
        // matches the CAB and SHA" - that global dedup is what used to
        // cause a plethora of issues when the same bundle got uploaded
        // more than once (two unrelated submissions racing/colliding on
        // the one tag their shared content hashed to). A bundle with no
        // previous attempt of its own never short-circuits here.
        if (previousScratchBranch.length > 0 && [self bds_releaseAtTagHasOutputAsset:previousScratchBranch config:config]) {
            ZLog(@"[BundleDoctorService] resume hit on %@ - this entry's earlier submission already finished, skipping upload/dispatch.", previousScratchBranch);
            BundleDoctorHandle *cachedHandle = [[BundleDoctorHandle alloc] initWithScratchBranch:previousScratchBranch alreadyComplete:YES];
            finish(cachedHandle, nil);
            return;
        }

        NSString *scratchBranch = bds_uniqueTagForCAB(cabIdentifier);
        ZLog(@"[BundleDoctorService] dispatching %@/%@, scratch branch %@ (original bundle for shader-restore: %@)",
              config.repoOwner, config.repoName, scratchBranch, originalData ? @"found" : @"not found");

        NSString *baseCommitSHA = nil;
        if (![self bds_resolveBaseCommitSHA:&baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_createBranch:scratchBranch atCommitSHA:baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        NSString *uploadURLTemplate = nil;
        if (![self bds_createReleaseWithTagName:scratchBranch targetCommitish:scratchBranch
                                          config:config outUploadURLTemplate:&uploadURLTemplate error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        // uploadProgress's contract used to be "the modded bundle's own
        // body send" alone, forced to a clean 1.0 the moment that PUT
        // finished - but when originalData is also going up right after
        // (same scratch release, second asset, previously reported with
        // progress:nil), that forced 1.0 was a lie: the caller's progress
        // UI would sit at 100% while original.bundle's own multi-second
        // upload was still happening underneath it. Now both assets share
        // one 0.0-1.0 space, split by their relative byte sizes, so 100%
        // means "both PUTs are actually done" - or, when there's no
        // originalData at all (shader-restore lookup came up empty), the
        // modded upload alone still spans the full range exactly as
        // before.
        unsigned long long moddedBytes = uploadData.length;
        unsigned long long originalBytes = originalData.length;
        double totalUploadBytes = (double)(moddedBytes + originalBytes);
        double moddedShare = (originalData && totalUploadBytes > 0.0)
            ? (double)moddedBytes / totalUploadBytes
            : 1.0;
        void (^reportModdedProgress)(double) = ^(double fraction) {
            reportProgress(fraction * moddedShare);
        };
        void (^reportOriginalProgress)(double) = ^(double fraction) {
            reportProgress(moddedShare + fraction * (1.0 - moddedShare));
        };

        if (![self bds_uploadReleaseAssetData:uploadData name:kBDSInputAssetName
                             uploadURLTemplate:uploadURLTemplate progress:reportModdedProgress
                                        config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }
        if (!originalData) reportProgress(1.0); // nothing more to send - land on a clean 100% same as before

        // A failure uploading original.bundle is NOT fatal to the whole
        // submission: it just means the workflow proceeds without it and
        // BundleDoctor falls back to skipping the shader-restore pass,
        // same as if originalData had been nil to begin with - but the
        // progress space it was allotted above still needs closing out to
        // a clean 100% either way.
        if (originalData) {
            NSError *originalUploadError = nil;
            if (![self bds_uploadReleaseAssetData:originalData name:kBDSOriginalAssetName
                                 uploadURLTemplate:uploadURLTemplate progress:reportOriginalProgress
                                            config:config error:&originalUploadError]) {
                ZLog(@"[BundleDoctorService] couldn't upload original.bundle (proceeding without shader-restore): %@",
                     originalUploadError.localizedDescription);
            }
            reportProgress(1.0);
        }

        if (![self bds_dispatchWorkflowOnBranch:scratchBranch config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config]; // best-effort cleanup, ignore result
            finish(nil, error);
            return;
        }

        BundleDoctorHandle *handle = [[BundleDoctorHandle alloc] initWithScratchBranch:scratchBranch];
        finish(handle, nil);
    });
}

+ (void)resolveRunForHandle:(BundleDoctorHandle *)handle
                       config:(BundleDoctorConfig *)rawConfig
                   completion:(void (^)(BOOL, NSError * _Nullable))completion {
    void (^finish)(BOOL, NSError * _Nullable) = ^(BOOL found, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(found, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(NO, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // A single pass over the runs list, filtered to this handle's
        // scratch branch - deliberately NOT the retried/timeout loop
        // +bds_findRunOnBranch:... below runs for the deprecated one-shot
        // method. This is meant to be called again by the caller's own
        // 6s poll timer until it succeeds, same spirit as
        // +fetchRunStatusForHandle:... not looping internally either.
        NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/runs?branch=%@&event=workflow_dispatch&per_page=10",
                              config.repoOwner, config.repoName, config.workflowFile,
                              [handle.scratchBranch stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

        NSError *error = nil;
        id result = [self bds_getJSON:urlPath config:config error:&error];
        if (!result) {
            finish(NO, error);
            return;
        }

        NSArray *runs = result[@"workflow_runs"];
        if ([runs isKindOfClass:NSArray.class] && runs.count > 0) {
            // Every run on this branch was created by this handle's own
            // dispatch call (the branch is a fresh UUID, never reused -
            // see this file's header) - the most recently created one is
            // the right one if more than one somehow shows up.
            NSDictionary *best = nil;
            NSDate *bestDate = nil;
            NSDateFormatter *iso = [self bds_iso8601Formatter];
            for (NSDictionary *run in runs) {
                if (![run isKindOfClass:NSDictionary.class]) continue;
                NSDate *createdAt = [iso dateFromString:run[@"created_at"] ?: @""];
                if (!best || (createdAt && (!bestDate || [createdAt compare:bestDate] == NSOrderedDescending))) {
                    best = run;
                    bestDate = createdAt;
                }
            }
            if (best) {
                handle.runID = [best[@"id"] stringValue];
                handle.runURL = best[@"html_url"];
                finish(YES, nil);
                return;
            }
        }

        finish(NO, nil); // not found yet - not an error, see this method's header
    });
}

+ (void)fetchRunStatusForHandle:(BundleDoctorHandle *)handle
                           config:(BundleDoctorConfig *)rawConfig
                       completion:(void (^)(BundleDoctorRunStatus, double, NSError * _Nullable))completion {
    void (^finish)(BundleDoctorRunStatus, double, NSError * _Nullable) = ^(BundleDoctorRunStatus status, double percent, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status, percent, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (handle.runID.length == 0) {
        finish(BundleDoctorRunStatusQueued, 0.0, [self bds_errorWithCode:BundleDoctorServiceErrorRunNotFound
                                                              description:@"No run id on this handle yet - call +resolveRunForHandle:config:completion: first."]);
        return;
    }
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(BundleDoctorRunStatusQueued, 0.0, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                                              description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *runPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/runs/%@", config.repoOwner, config.repoName, handle.runID];
        NSError *error = nil;
        id run = [self bds_getJSON:runPath config:config error:&error];
        if (!run) {
            finish(BundleDoctorRunStatusQueued, 0.0, error);
            return;
        }

        NSString *runStatus = run[@"status"];
        if ([runStatus isEqualToString:@"completed"]) {
            NSString *conclusion = run[@"conclusion"];
            if ([conclusion isEqualToString:@"success"]) {
                finish(BundleDoctorRunStatusSucceeded, 1.0, nil);
            } else {
                NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Workflow run finished with conclusion \"%@\".", conclusion ?: @"unknown"];
                if (handle.runURL) userInfo[BundleDoctorServiceRunURLKey] = handle.runURL;
                NSError *runError = [NSError errorWithDomain:BundleDoctorServiceErrorDomain code:BundleDoctorServiceErrorRunFailed userInfo:userInfo];
                finish(BundleDoctorRunStatusFailed, 0.0, runError);
            }
            return;
        }

        // Still queued or in progress - derive a percentage from the
        // run's own jobs/steps rather than reporting nothing. The
        // doctor-bundle workflow itself emits no finer-grained progress
        // than "which step is running" (see the .github/workflows YAML
        // this file's header points at) - completed-steps / total-steps
        // across every job on the run is the best signal available
        // without changing that YAML to emit its own percentage.
        NSString *jobsPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/runs/%@/jobs", config.repoOwner, config.repoName, handle.runID];
        id jobsResult = [self bds_getJSON:jobsPath config:config error:nil]; // best-effort - a failure here just means "0%", not a hard error
        double percent = 0.0;
        NSArray *jobs = [jobsResult isKindOfClass:NSDictionary.class] ? jobsResult[@"jobs"] : nil;
        if ([jobs isKindOfClass:NSArray.class]) {
            NSInteger totalSteps = 0, completedSteps = 0;
            for (NSDictionary *job in jobs) {
                if (![job isKindOfClass:NSDictionary.class]) continue;
                NSArray *steps = job[@"steps"];
                if (![steps isKindOfClass:NSArray.class]) continue;
                for (NSDictionary *step in steps) {
                    if (![step isKindOfClass:NSDictionary.class]) continue;
                    totalSteps++;
                    if ([step[@"status"] isEqualToString:@"completed"]) completedSteps++;
                }
            }
            if (totalSteps > 0) percent = (double)completedSteps / (double)totalSteps;
        }

        BundleDoctorRunStatus status = percent > 0.0 ? BundleDoctorRunStatusInProgress : BundleDoctorRunStatusQueued;
        finish(status, percent, nil);
    });
}

+ (void)fetchDoctoredBundleForHandle:(BundleDoctorHandle *)handle
                                config:(BundleDoctorConfig *)rawConfig
                              progress:(nullable void (^)(double fractionComplete))downloadProgress
                            completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    void (^reportProgress)(double) = ^(double fraction) {
        if (!downloadProgress) return;
        dispatch_async(dispatch_get_main_queue(), ^{ downloadProgress(fraction); });
    };
    void (^finish)(NSURL * _Nullable, NSError * _Nullable) = ^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *doctoredData = nil;
        if (![self bds_downloadReleaseAssetNamed:kBDSOutputAssetName fromReleaseTag:handle.scratchBranch
                                           config:config progress:reportProgress data:&doctoredData error:&error]) {
            finish(nil, error);
            return;
        }
        reportProgress(1.0); // land on a clean 100% even if the last didWriteData: callback landed a hair short

        // Every tag is unique per submission again (see this file's
        // header's "Unique release naming + per-entry resume check"
        // addendum) - nothing else can ever dispatch onto this exact tag
        // in the future, so there's no cache left to preserve. Delete the
        // release and its scratch branch both, same as the pre-Section-5
        // behavior, rather than leaving a one-shot release sitting around
        // on the repo forever.
        [self bds_cleanupScratchSubmission:handle.scratchBranch config:config]; // best-effort, logged not surfaced

        NSString *tempName = [NSString stringWithFormat:@"doctored-%@.bundle", [NSUUID UUID].UUIDString];
        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        NSError *writeError = nil;
        if (![doctoredData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError]) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                     description:writeError.localizedDescription ?: @"Couldn't write doctored bundle to a temp file."]);
            return;
        }

        ZLog(@"[BundleDoctorService] doctored bundle ready at %@ (%lu bytes)", tempURL.path, (unsigned long)doctoredData.length);

        finish(tempURL, nil);
    });
}

#pragma mark - Credential check

+ (void)verifyCredentialsForConfig:(BundleDoctorConfig *)rawConfig
                          completion:(void (^)(BOOL, NSError * _Nullable))completion {
    void (^finish)(BOOL, NSError * _Nullable) = ^(BOOL valid, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(valid, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(NO, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Cheapest call that touches both the token (auth) and the repo
        // (owner/name + the token's visibility into it) at once - the
        // same repo-fetch every other phase above implicitly relies on
        // being reachable before it ever gets to a release/workflow.
        NSString *path = [NSString stringWithFormat:@"/repos/%@/%@", config.repoOwner, config.repoName];
        NSError *error = nil;
        id repo = [self bds_getJSON:path config:config error:&error];
        finish(repo != nil, error);
    });
}

#pragma mark - Processed Bundles listing (6)

+ (void)listProcessedReleasesForConfig:(BundleDoctorConfig *)rawConfig
                              completion:(void (^)(NSArray<BundleDoctorProcessedRelease *> * _Nullable, NSError * _Nullable))completion {
    void (^finish)(NSArray<BundleDoctorProcessedRelease *> * _Nullable, NSError * _Nullable) =
        ^(NSArray<BundleDoctorProcessedRelease *> *releases, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(releases, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static const NSInteger kPerPage = 100; // GitHub's own max for this endpoint
        NSMutableArray<BundleDoctorProcessedRelease *> *results = [NSMutableArray array];
        NSInteger page = 1;
        for (;;) {
            NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/releases?per_page=%ld&page=%ld",
                               config.repoOwner, config.repoName, (long)kPerPage, (long)page];
            NSError *error = nil;
            id result = [self bds_getJSON:path config:config error:&error];
            if (!result) {
                finish(nil, error);
                return;
            }
            NSArray *pageReleases = [result isKindOfClass:NSArray.class] ? result : @[];
            for (NSDictionary *release in pageReleases) {
                if (![release isKindOfClass:NSDictionary.class]) continue;
                NSArray *assets = release[@"assets"];
                if (![assets isKindOfClass:NSArray.class]) continue;

                NSDictionary *outputAsset = nil;
                for (NSDictionary *asset in assets) {
                    if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:kBDSOutputAssetName]) {
                        outputAsset = asset;
                        break;
                    }
                }
                // Same "only a finished release counts" rule as
                // +bds_releaseAtTagHasOutputAsset:config: - a release
                // still mid-flight (or abandoned before the workflow
                // uploaded its output) has no output.bundle asset yet
                // and is silently skipped rather than listed with
                // nothing to show.
                if (!outputAsset) continue;

                NSString *tagName = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
                id sizeValue = outputAsset[@"size"];
                unsigned long long size = [sizeValue respondsToSelector:@selector(unsignedLongLongValue)] ? [sizeValue unsignedLongLongValue] : 0;
                NSString *uploadedAt = [outputAsset[@"created_at"] isKindOfClass:NSString.class] ? outputAsset[@"created_at"] : nil;
                NSString *digest = [outputAsset[@"digest"] isKindOfClass:NSString.class] ? outputAsset[@"digest"] : nil;

                [results addObject:[[BundleDoctorProcessedRelease alloc] initWithTagName:tagName
                                                                                  byteSize:size
                                                                                uploadedAt:uploadedAt
                                                                                  checksum:digest]];
            }
            if (pageReleases.count < kPerPage) break; // short page - this was the last one
            page++;
        }

        [results sortUsingComparator:^NSComparisonResult(BundleDoctorProcessedRelease *a, BundleDoctorProcessedRelease *b) {
            // Newest-uploaded-first. ISO 8601 UTC strings in this exact
            // shape sort lexicographically identically to chronologically,
            // so a plain NSString compare is enough - no date parsing
            // needed just to order rows. A release whose asset carried no
            // created_at (shouldn't normally happen - GitHub always sets
            // this) sorts after everything that has one instead of
            // undefined-ordering against nil.
            if (!a.uploadedAt && !b.uploadedAt) return NSOrderedSame;
            if (!a.uploadedAt) return NSOrderedDescending;
            if (!b.uploadedAt) return NSOrderedAscending;
            return [b.uploadedAt compare:a.uploadedAt];
        }];

        finish(results, nil);
    });
}

#pragma mark - Processed Bundles install (9)

+ (void)downloadProcessedRelease:(BundleDoctorProcessedRelease *)release
                            config:(BundleDoctorConfig *)rawConfig
                          progress:(nullable void (^)(double fractionComplete))downloadProgress
                        completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    void (^reportProgress)(double) = ^(double fraction) {
        if (!downloadProgress) return;
        dispatch_async(dispatch_get_main_queue(), ^{ downloadProgress(fraction); });
    };
    void (^finish)(NSURL * _Nullable, NSError * _Nullable) = ^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *bundleData = nil;
        if (![self bds_downloadReleaseAssetNamed:kBDSOutputAssetName fromReleaseTag:release.tagName
                                           config:config progress:reportProgress data:&bundleData error:&error]) {
            finish(nil, error);
            return;
        }
        reportProgress(1.0); // same clean-100%-landing reasoning as +fetchDoctoredBundleForHandle:...

        // No +bds_cleanupScratchSubmission:... here - see this method's
        // own header on why a Processed Bundles release outlives this
        // download, unlike a scratch submission's one-shot release.

        NSString *tempName = [NSString stringWithFormat:@"processed-%@.bundle", [NSUUID UUID].UUIDString];
        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        NSError *writeError = nil;
        if (![bundleData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError]) {
            finish(nil, [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                     description:writeError.localizedDescription ?: @"Couldn't write the processed bundle to a temp file."]);
            return;
        }

        ZLog(@"[BundleDoctorService] processed release %@ downloaded to %@ (%lu bytes)", release.tagName, tempURL.path, (unsigned long)bundleData.length);

        finish(tempURL, nil);
    });
}

#pragma mark - Delete every stored release (8)

+ (void)deleteAllReleasesForConfig:(BundleDoctorConfig *)rawConfig
                          completion:(void (^)(NSInteger deletedCount, NSError * _Nullable error))completion {
    void (^finish)(NSInteger, NSError * _Nullable) = ^(NSInteger deletedCount, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(deletedCount, error); });
    };

    BundleDoctorConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(0, [self bds_errorWithCode:BundleDoctorServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Same pagination shape as +listProcessedReleasesForConfig:
        // above, but nothing here filters on an output.bundle asset -
        // every release in the repo gets collected, finished or not.
        static const NSInteger kPerPage = 100;
        NSMutableArray<NSDictionary *> *allReleases = [NSMutableArray array];
        NSInteger page = 1;
        for (;;) {
            NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/releases?per_page=%ld&page=%ld",
                               config.repoOwner, config.repoName, (long)kPerPage, (long)page];
            NSError *error = nil;
            id result = [self bds_getJSON:path config:config error:&error];
            if (!result) {
                finish(0, error);
                return;
            }
            NSArray *pageReleases = [result isKindOfClass:NSArray.class] ? result : @[];
            for (NSDictionary *release in pageReleases) {
                if ([release isKindOfClass:NSDictionary.class]) [allReleases addObject:release];
            }
            if (pageReleases.count < kPerPage) break; // short page - this was the last one
            page++;
        }

        // Each release + its tag ref is deleted independently and
        // best-effort, same spirit as +bds_cleanupScratchSubmission: -
        // one release failing to delete (already gone, transient 5xx,
        // etc.) shouldn't stop the rest of the repo from being cleared.
        NSInteger deletedCount = 0;
        for (NSDictionary *release in allReleases) {
            NSString *releaseID = [release[@"id"] stringValue];
            NSString *tagName = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : nil;

            if (releaseID.length > 0) {
                NSString *deletePath = [NSString stringWithFormat:@"/repos/%@/%@/releases/%@",
                                         config.repoOwner, config.repoName, releaseID];
                NSError *deleteError = nil;
                if ([self bds_deleteJSON:deletePath config:config error:&deleteError]) {
                    deletedCount++;
                } else {
                    ZLog(@"[BundleDoctorService] couldn't delete release %@ (tag %@) while clearing the proxy: %@", releaseID, tagName, deleteError);
                }
            }

            // Deleting a release does NOT delete its underlying git tag
            // ref (same fact +bds_deleteReleaseWithTag:config: already
            // handles for a single scratch release) - clean it up
            // regardless of whether the release delete above actually
            // succeeded, so a tag ref orphaned by some earlier failure
            // still gets swept here too.
            if (tagName.length > 0) {
                NSString *escapedTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                NSString *tagRefPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs/tags/%@",
                                         config.repoOwner, config.repoName, escapedTag];
                NSError *tagDeleteError = nil;
                if (![self bds_deleteJSON:tagRefPath config:config error:&tagDeleteError]) {
                    ZLog(@"[BundleDoctorService] couldn't delete release tag ref %@ while clearing the proxy: %@", tagName, tagDeleteError);
                }
            }
        }

        finish(deletedCount, nil);
    });
}

#pragma mark - Git Data API steps

+ (BOOL)bds_resolveBaseCommitSHA:(NSString **)outCommitSHA
                          config:(BundleDoctorConfig *)config
                           error:(NSError **)error {
    NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/git/ref/heads/%@",
                       config.repoOwner, config.repoName, config.ref];
    id ref = [self bds_getJSON:path config:config error:error];
    if (!ref) return NO;

    NSString *commitSHA = [ref valueForKeyPath:@"object.sha"];
    if (![commitSHA isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError
                                         description:@"Unexpected response resolving the base branch ref."];
        return NO;
    }

    if (outCommitSHA) *outCommitSHA = commitSHA;
    return YES;
}

// Deterministic tags (see this file's header addendum) mean two
// submissions of the same CAB+sha256 pair can now legitimately race for
// the same branch name - e.g. a first attempt is still mid-flight (no
// output asset yet, so +bds_releaseAtTagHasOutputAsset:config: didn't
// short-circuit) and a second dispatch/retry for the identical bundle
// comes in before it finishes. A pre-existing random-UUID tag could
// never collide like this, so this is new: a 422 "already exists" here
// isn't a failure, it just means the branch this submission wants is
// already sitting there (pointed at whatever commit the earlier
// submission used, which is fine - workflow_dispatch only needs a ref
// name to run against, not a specific commit).
+ (BOOL)bds_createBranch:(NSString *)branchName
              atCommitSHA:(NSString *)commitSHA
                   config:(BundleDoctorConfig *)config
                    error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"ref": [NSString stringWithFormat:@"refs/heads/%@", branchName],
        @"sha": commitSHA,
    };
    NSError *createError = nil;
    if ([self bds_postJSON:urlPath body:body config:config error:&createError] != nil) return YES;

    if ([self bds_errorIsAlreadyExists:createError]) {
        ZLog(@"[BundleDoctorService] scratch branch %@ already exists (racing/leftover submission for the same bundle) - reusing it.", branchName);
        return YES;
    }
    if (error) *error = createError;
    return NO;
}

// GitHub's shape for "the ref/tag you tried to create is already taken"
// - a 422 whose body mentions it, for both the git/refs (branch) and
// releases (tag) endpoints (the latter nests it as an `errors[].code`
// of "already_exists" on the "tag_name" field; the former just puts
// "Reference already exists" straight in "message" - checking the raw
// body for "already exists" catches both without parsing two different
// shapes).
+ (BOOL)bds_errorIsAlreadyExists:(NSError *)error {
    if (![error.domain isEqualToString:BundleDoctorServiceErrorDomain]) return NO;
    if (error.code != BundleDoctorServiceErrorAPIError) return NO;
    if (![error.userInfo[BundleDoctorServiceHTTPStatusKey] isEqual:@422]) return NO;
    NSString *body = error.userInfo[BundleDoctorServiceResponseBodyKey];
    return [body rangeOfString:@"already exists" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

+ (void)bds_deleteBranch:(NSString *)branchName config:(BundleDoctorConfig *)config {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs/heads/%@",
                          config.repoOwner, config.repoName, branchName];
    NSError *deleteError = nil;
    if (![self bds_deleteJSON:urlPath config:config error:&deleteError]) {
        // Best-effort - see this method's callers/header. A leaked scratch
        // branch is harmless clutter, not a functional problem.
        ZLog(@"[BundleDoctorService] couldn't delete scratch branch %@: %@", branchName, deleteError);
    }
}

#pragma mark - Releases API steps (input/output transport)
//
// The modded bundle's bytes travel as a GitHub Release asset now, not a
// git blob - see BundleDoctorService.h's transport note for why. A
// release's tag doubles as this submission's correlation key: it's set
// to the same string as the scratch branch, so +bds_cleanupScratchSubmission:
// below and any caller inspecting a persisted BundleDoctorHandle only
// ever has to remember one identifier.

+ (BOOL)bds_createReleaseWithTagName:(NSString *)tagName
                       targetCommitish:(NSString *)targetCommitish
                                config:(BundleDoctorConfig *)config
                  outUploadURLTemplate:(NSString **)outUploadURLTemplate
                                 error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/releases", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"tag_name": tagName,
        @"target_commitish": targetCommitish,
        @"name": tagName,
        @"body": @"Scratch release for the BundleDoctor pipeline - holds one submission's input/output bundle assets. Safe to delete; +bds_cleanupScratchSubmission:config: removes it once the doctored bundle has been read back.",
        // MUST be NO: a draft release has no real tag ref behind it until
        // published, so the doctor-bundle workflow's `gh release download
        // <release_tag>` (and this class's own +bds_fetchReleaseByTag:...)
        // would 404 against it.
        @"draft": @NO,
        @"prerelease": @YES,
    };
    NSError *createError = nil;
    id result = [self bds_postJSON:urlPath body:body config:config error:&createError];
    if (!result) {
        // Same race as +bds_createBranch:...'s own note just above it -
        // a release already sitting on this deterministic tag (someone
        // else's in-flight or abandoned submission for the identical
        // bundle) isn't a failure, just look up its own upload_url
        // instead of the one this call would have minted.
        if ([self bds_errorIsAlreadyExists:createError]) {
            ZLog(@"[BundleDoctorService] release tagged %@ already exists (racing/leftover submission for the same bundle) - reusing it.", tagName);
            NSError *lookupError = nil;
            NSDictionary *existing = [self bds_fetchReleaseByTag:tagName config:config error:&lookupError];
            NSString *existingUploadURLTemplate = existing[@"upload_url"];
            if ([existingUploadURLTemplate isKindOfClass:NSString.class]) {
                if (outUploadURLTemplate) *outUploadURLTemplate = existingUploadURLTemplate;
                return YES;
            }
            if (error) *error = lookupError ?: [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Existing release had no upload_url."];
            return NO;
        }
        if (error) *error = createError;
        return NO;
    }

    NSString *uploadURLTemplate = result[@"upload_url"];
    if (![uploadURLTemplate isKindOfClass:NSString.class]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Release creation didn't return an upload_url."];
        return NO;
    }
    if (outUploadURLTemplate) *outUploadURLTemplate = uploadURLTemplate;
    return YES;
}

// uploadURLTemplate is the "upload_url" GitHub hands back when a release
// is created - a URI template like
// "https://uploads.github.com/repos/OWNER/REPO/releases/12345/assets{?name,label}".
// This strips the "{?name,label}" templating tail and appends
// "?name=<name>" itself rather than pulling in a URI Template library
// for one substitution.
//
// Unlike +bds_postJSON:... this sends `data` as-is - raw binary,
// Content-Type: application/octet-stream - not JSON/base64. That's the
// entire point of moving off the git Blob API: no ~1.33x base64
// inflation, and release assets support up to 2GB versus the Blob API's
// much lower practical ceiling. progress, when non-nil, is called with a
// 0.0-1.0 fraction as the body is sent - see +dispatchBundleAtURL:...'s
// uploadProgress and this file's header on why this is the only phase
// worth reporting byte-level progress for.
+ (BOOL)bds_uploadReleaseAssetData:(NSData *)data
                                name:(NSString *)name
                   uploadURLTemplate:(NSString *)uploadURLTemplate
                            progress:(nullable void (^)(double fractionComplete))progress
                              config:(BundleDoctorConfig *)config
                               error:(NSError **)error {
    NSRange templateStart = [uploadURLTemplate rangeOfString:@"{"];
    NSString *baseURLString = templateStart.location == NSNotFound ? uploadURLTemplate
                                                                    : [uploadURLTemplate substringToIndex:templateStart.location];
    NSString *escapedName = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"%@?name=%@", baseURLString, escapedName];

    NSMutableURLRequest *request = [self bds_requestForAbsoluteURLString:urlString config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build the release asset upload URL."];
        return NO;
    }
    request.HTTPMethod = @"POST";
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];

    BDSUploadProgressDelegate *delegate = [BDSUploadProgressDelegate new];
    delegate.onProgress = progress;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                             delegate:delegate
                                                        delegateQueue:nil];

    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *transportError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromData:data
                                                  completionHandler:^(NSData *taskData, NSURLResponse *taskResponse, NSError *taskError) {
        // The real response/body/status - see BDSUploadProgressDelegate's
        // own header comment above on why these have to come from here
        // (the completion handler) rather than from the delegate's own
        // didReceiveResponse:/didReceiveData: methods, which are never
        // invoked for a task created with a completion handler.
        responseData = taskData;
        httpResponse = [taskResponse isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)taskResponse : nil;
        transportError = taskError;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (transportError) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                          code:BundleDoctorServiceErrorRequestFailed
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: transportError.localizedDescription ?: @"Network request failed.",
                                          NSUnderlyingErrorKey: transportError,
                                      }];
        }
        return NO;
    }

    NSInteger status = httpResponse.statusCode;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[BundleDoctorService] POST %@ -> %ld: %@", urlString, (long)status, bodyString);
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                          code:BundleDoctorServiceErrorAPIError
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API returned %ld.", (long)status],
                                          BundleDoctorServiceHTTPStatusKey: @(status),
                                          BundleDoctorServiceResponseBodyKey: bodyString,
                                      }];
        }
        return NO;
    }

    return YES;
}

+ (nullable NSDictionary *)bds_fetchReleaseByTag:(NSString *)tagName config:(BundleDoctorConfig *)config error:(NSError **)error {
    NSString *escapedTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/releases/tags/%@", config.repoOwner, config.repoName, escapedTag];
    id result = [self bds_getJSON:urlPath config:config error:error];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

// Section 5's "check the releases tab first" - a plain GET against the
// deterministic tag, not a dry run of the doctor pipeline. A release
// existing with no BDS_OUTPUT_ASSET_NAME on it yet (someone else's
// submission still mid-flight, or one that failed partway through) does
// NOT count as a hit - only a release that already carries the finished
// output asset does, matching the header's "no early-exit on a failed/
// in-flight run" note.
+ (BOOL)bds_releaseAtTagHasOutputAsset:(NSString *)tagName config:(BundleDoctorConfig *)config {
    NSError *lookupError = nil;
    NSDictionary *release = [self bds_fetchReleaseByTag:tagName config:config error:&lookupError];
    if (!release) return NO; // 404 (no such release yet) or a transient lookup error either way - fall through to a normal dispatch
    NSArray *assets = release[@"assets"];
    if (![assets isKindOfClass:NSArray.class]) return NO;
    for (NSDictionary *asset in assets) {
        if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:kBDSOutputAssetName]) return YES;
    }
    return NO;
}

// Looks up the release tagged releaseTag, finds the asset named `name`
// on it, and downloads its bytes.
+ (BOOL)bds_downloadReleaseAssetNamed:(NSString *)name
                       fromReleaseTag:(NSString *)releaseTag
                               config:(BundleDoctorConfig *)config
                             progress:(nullable void (^)(double fractionComplete))progress
                                 data:(NSData **)outData
                                error:(NSError **)error {
    NSDictionary *release = [self bds_fetchReleaseByTag:releaseTag config:config error:error];
    if (!release) {
        // A 404 here specifically means the workflow never created/
        // uploaded onto this release - almost certainly an asset-name
        // convention mismatch with the actual workflow YAML (see this
        // file's header) rather than a transient failure.
        if (error && (*error).code == BundleDoctorServiceErrorAPIError &&
            [(*error).userInfo[BundleDoctorServiceHTTPStatusKey] isEqual:@404]) {
            *error = [self bds_errorWithCode:BundleDoctorServiceErrorOutputMissing
                                  description:[NSString stringWithFormat:@"Run succeeded but the release tagged %@ wasn't found afterward.", releaseTag]];
        }
        return NO;
    }

    NSArray *assets = release[@"assets"];
    NSDictionary *asset = nil;
    if ([assets isKindOfClass:NSArray.class]) {
        for (NSDictionary *candidate in assets) {
            if ([candidate isKindOfClass:NSDictionary.class] && [candidate[@"name"] isEqual:name]) {
                asset = candidate;
                break;
            }
        }
    }
    if (!asset) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorOutputMissing
                                         description:[NSString stringWithFormat:@"Run succeeded but %@ wasn't on release %@ afterward - check the workflow uploads its output there.", name, releaseTag]];
        return NO;
    }

    NSString *assetAPIURL = asset[@"url"]; // the API url, not browser_download_url - this is the one that honors our Bearer token on a private repo
    if (![assetAPIURL isKindOfClass:NSString.class]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Release asset had no API url."];
        return NO;
    }

    // GitHub's standard release-asset field, the authoritative expected
    // byte count straight from the API response we already have in
    // scope - used as a fallback when the download response itself
    // never reports a Content-Length (see BDSDownloadProgressDelegate's
    // fallbackExpectedByteCount). 0 if missing/malformed, which
    // -bds_downloadBinaryAtAbsoluteURLString:...'s own fallback handles
    // the same as "no fallback available" (progress just never renders,
    // same as before this fix - the download itself is unaffected).
    int64_t expectedByteCount = [asset[@"size"] respondsToSelector:@selector(longLongValue)] ? [asset[@"size"] longLongValue] : 0;

    NSData *data = [self bds_downloadBinaryAtAbsoluteURLString:assetAPIURL config:config expectedByteCount:expectedByteCount progress:progress error:error];
    if (!data) return NO;
    if (outData) *outData = data;
    return YES;
}

+ (void)bds_deleteReleaseWithTag:(NSString *)tagName config:(BundleDoctorConfig *)config {
    NSError *lookupError = nil;
    NSDictionary *release = [self bds_fetchReleaseByTag:tagName config:config error:&lookupError];
    if (!release) {
        // Nothing to clean up (already gone / never created) - not worth
        // logging as a failure the way a real delete failure below is.
        return;
    }

    NSString *releaseID = [release[@"id"] stringValue];
    if (releaseID.length > 0) {
        NSString *deletePath = [NSString stringWithFormat:@"/repos/%@/%@/releases/%@", config.repoOwner, config.repoName, releaseID];
        NSError *deleteError = nil;
        if (![self bds_deleteJSON:deletePath config:config error:&deleteError]) {
            ZLog(@"[BundleDoctorService] couldn't delete scratch release %@: %@", tagName, deleteError);
        }
    }

    // Deleting a release does NOT delete the underlying git tag ref -
    // clean that up separately or it lingers forever.
    NSString *escapedTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *tagRefPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs/tags/%@", config.repoOwner, config.repoName, escapedTag];
    NSError *tagDeleteError = nil;
    if (![self bds_deleteJSON:tagRefPath config:config error:&tagDeleteError]) {
        ZLog(@"[BundleDoctorService] couldn't delete scratch release tag ref %@: %@", tagName, tagDeleteError);
    }
}

// Best-effort teardown of everything one dispatched submission created:
// the queue release (+ its tag ref) and the scratch branch. Every step
// here is independently best-effort/logged-not-surfaced, same spirit as
// the old +bds_deleteBranch:config: alone used to be - see this file's
// header, step 7.
+ (void)bds_cleanupScratchSubmission:(NSString *)scratchBranch config:(BundleDoctorConfig *)config {
    [self bds_deleteReleaseWithTag:scratchBranch config:config];
    [self bds_deleteBranch:scratchBranch config:config];
}

#pragma mark - Actions API steps

+ (BOOL)bds_dispatchWorkflowOnBranch:(NSString *)branchName
                                config:(BundleDoctorConfig *)config
                                 error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/dispatches",
                          config.repoOwner, config.repoName, config.workflowFile];
    // branchName doubles as the queue release's tag name (see the
    // Releases API steps section above) - that's how the dispatched
    // workflow run knows which release to pull input.bundle from.
    NSDictionary *body = @{
        @"ref": branchName,
        @"inputs": @{
            kBDSReleaseTagInputKey: branchName,
            kBDSInputFormatKey: config.outputFormat,
        },
    };
    // Dispatch returns 204 No Content on success - bds_postJSON treats
    // "2xx with no/empty body" as success and hands back an empty dict
    // rather than nil, so a nil-check alone is enough here.
    return [self bds_postJSON:urlPath body:body config:config error:error] != nil;
}

// See this file's header: the dispatch call itself never returns a run
// id, so this polls the runs list filtered to our scratch branch and
// picks the first run whose created_at is at/after `dispatchedAt`. In
// the (unlikely but possible) case of two runs racing on the same
// never-reused scratch branch, taking the earliest qualifying one is
// correct since nothing else ever dispatches onto a branch this class
// just created with a fresh UUID.
+ (BOOL)bds_findRunOnBranch:(NSString *)branchName
             dispatchedAfter:(NSDate *)dispatchedAt
                      config:(BundleDoctorConfig *)config
                       runID:(NSString **)outRunID
                      runURL:(NSString **)outRunURL
                       error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/runs?branch=%@&event=workflow_dispatch&per_page=10",
                          config.repoOwner, config.repoName, config.workflowFile,
                          [branchName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSDate *deadline = [dispatchedAt dateByAddingTimeInterval:kBDSRunDiscoveryTimeout];
    NSDateFormatter *iso = [self bds_iso8601Formatter];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        id result = [self bds_getJSON:urlPath config:config error:error];
        if (!result) return NO;

        NSArray *runs = result[@"workflow_runs"];
        if ([runs isKindOfClass:[NSArray class]]) {
            for (NSDictionary *run in runs) {
                NSString *createdAtString = run[@"created_at"];
                NSDate *createdAt = [iso dateFromString:createdAtString ?: @""];
                // A few seconds of slack: the dispatch call and the run's
                // own created_at aren't guaranteed to be perfectly
                // ordered against this device's clock.
                if (createdAt && [createdAt compare:[dispatchedAt dateByAddingTimeInterval:-5.0]] != NSOrderedAscending) {
                    if (outRunID) *outRunID = [run[@"id"] stringValue];
                    if (outRunURL) *outRunURL = run[@"html_url"];
                    return YES;
                }
            }
        }

        [NSThread sleepForTimeInterval:kBDSRunDiscoveryPollInterval];
    }

    if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRunNotFound
                                     description:@"Dispatched the workflow but no matching run showed up in time."];
    return NO;
}

+ (BOOL)bds_waitForRunCompletion:(NSString *)runID
                            runURL:(NSString *)runURL
                            config:(BundleDoctorConfig *)config
                             error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/runs/%@", config.repoOwner, config.repoName, runID];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kBDSRunCompletionTimeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        id run = [self bds_getJSON:urlPath config:config error:error];
        if (!run) return NO;

        NSString *status = run[@"status"];
        if ([status isEqualToString:@"completed"]) {
            NSString *conclusion = run[@"conclusion"];
            if ([conclusion isEqualToString:@"success"]) return YES;

            if (error) {
                NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Workflow run finished with conclusion \"%@\".", conclusion ?: @"unknown"];
                if (runURL) userInfo[BundleDoctorServiceRunURLKey] = runURL;
                *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                              code:BundleDoctorServiceErrorRunFailed
                                          userInfo:userInfo];
            }
            return NO;
        }

        [NSThread sleepForTimeInterval:kBDSRunCompletionPollInterval];
    }

    if (error) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[NSLocalizedDescriptionKey] = @"Timed out waiting for the workflow run to finish.";
        if (runURL) userInfo[BundleDoctorServiceRunURLKey] = runURL;
        *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain code:BundleDoctorServiceErrorTimedOut userInfo:userInfo];
    }
    return NO;
}

#pragma mark - HTTP plumbing

// Every other request builder in this file funnels through here now,
// including the release-asset upload/download ones, which - unlike
// everything else - don't talk to api.github.com (uploads.github.com
// for the upload, the asset's own api.github.com "url" for the download,
// which happens to be the same host but is still handed to us as a full
// URL rather than assembled from a path). Same headers either way -
// GitHub keys auth/versioning off these regardless of host.
+ (nullable NSMutableURLRequest *)bds_requestForAbsoluteURLString:(NSString *)urlString config:(BundleDoctorConfig *)config {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // GitHub requires a User-Agent on every REST API request or it 403s
    // unconditionally - this is not optional, unlike most APIs.
    [request setValue:@"ZSingularity-BundleDoctor" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", config.authToken] forHTTPHeaderField:@"Authorization"];
    return request;
}

+ (nullable NSMutableURLRequest *)bds_requestForPath:(NSString *)path config:(BundleDoctorConfig *)config {
    return [self bds_requestForAbsoluteURLString:[@"https://api.github.com" stringByAppendingString:path] config:config];
}

// Downloads a release asset's raw bytes from its own API url (the
// "url" field on a release asset object, e.g.
// https://api.github.com/repos/OWNER/REPO/releases/assets/12345) - NOT
// its browser_download_url, which redirects to a signed, unauthenticated
// URL that won't honor our Bearer token on a private repo. Per GitHub's
// API, requesting the asset's own url with an Accept of
// application/octet-stream (instead of the usual vnd.github+json)
// returns the raw file instead of JSON metadata about it.
+ (nullable NSData *)bds_downloadBinaryAtAbsoluteURLString:(NSString *)urlString
                                                       config:(BundleDoctorConfig *)config
                                          expectedByteCount:(int64_t)expectedByteCount
                                                     progress:(nullable void (^)(double fractionComplete))progress
                                                        error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForAbsoluteURLString:urlString config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    request.HTTPMethod = @"GET";

    // Download task, not a data task - see BDSDownloadProgressDelegate's
    // own header comment on why that's what makes byte-level progress
    // observable here at all. The finished file lands at a Foundation-
    // owned temp URL that's deleted the moment this completion handler
    // returns, so it's read into memory synchronously right here rather
    // than handed back as a URL for some later caller to open.
    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *transportError = nil;

    BDSDownloadProgressDelegate *delegate = [BDSDownloadProgressDelegate new];
    delegate.onProgress = progress;
    delegate.fallbackExpectedByteCount = expectedByteCount;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                             delegate:delegate
                                                        delegateQueue:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request
                                                      completionHandler:^(NSURL *location, NSURLResponse *response, NSError *taskError) {
        httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        transportError = taskError;
        if (location) {
            NSError *readError = nil;
            responseData = [NSData dataWithContentsOfURL:location options:0 error:&readError];
            if (!responseData) {
                ZLog(@"[BundleDoctorService] couldn't read downloaded temp file at %@: %@", location, readError);
            }
        }
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (transportError) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                          code:BundleDoctorServiceErrorRequestFailed
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: transportError.localizedDescription ?: @"Network request failed.",
                                          NSUnderlyingErrorKey: transportError,
                                      }];
        }
        return nil;
    }

    NSInteger status = httpResponse.statusCode;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[BundleDoctorService] GET %@ -> %ld: %@", urlString, (long)status, bodyString);
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                          code:BundleDoctorServiceErrorAPIError
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API returned %ld.", (long)status],
                                          BundleDoctorServiceHTTPStatusKey: @(status),
                                          BundleDoctorServiceResponseBodyKey: bodyString,
                                      }];
        }
        return nil;
    }

    if (!responseData) {
        // 2xx status but the temp-file read above failed (logged there) -
        // unlike the old data-task version, "request succeeded" and
        // "bytes are actually in memory" are no longer the same event, so
        // this has to be its own explicit failure instead of silently
        // falling through to an empty NSData.
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                         description:@"Download succeeded but the temp file couldn't be read."];
        return nil;
    }

    return responseData;
}

// Synchronous GET (blocks the calling background queue via a semaphore -
// see this file's header THREADING note; every bds_* method is only
// ever called from the background queue +doctorBundleAtURL:... itself
// dispatches to, never from the caller's own thread).
+ (nullable id)bds_getJSON:(NSString *)path config:(BundleDoctorConfig *)config error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    request.HTTPMethod = @"GET";
    return [self bds_performJSONRequest:request expectBody:YES error:error];
}

+ (nullable id)bds_postJSON:(NSString *)path body:(NSDictionary *)body config:(BundleDoctorConfig *)config error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *encodeError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodeError];
    if (!bodyData) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                         description:encodeError.localizedDescription ?: @"Couldn't encode request body."];
        return nil;
    }
    request.HTTPBody = bodyData;

    return [self bds_performJSONRequest:request expectBody:NO error:error];
}

+ (BOOL)bds_deleteJSON:(NSString *)path config:(BundleDoctorConfig *)config error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return NO;
    }
    request.HTTPMethod = @"DELETE";
    return [self bds_performJSONRequest:request expectBody:NO error:error] != nil;
}

// Bounds every synchronous bds_* network call below to a fixed wall-clock
// ceiling instead of the DISPATCH_TIME_FOREVER wait this used to use.
// NSURLRequest's own 60s default timeoutInterval only fires while the
// task is actually running - it doesn't help if the underlying task
// never resumes cleanly or its completion handler never gets a chance
// to run in this tweak's injected-dylib context (e.g. the host game
// suspending/backgrounding around the request). Without a hard ceiling
// on the wait itself, that left the calling background queue thread -
// and therefore whatever's waiting on its completion, like Config's
// "Delete Stored Bundles in Proxy" button - blocked forever with no way
// to recover short of restarting the game. This wait and NSURLRequest's
// own 60s timeoutInterval are independent of each other - whichever
// fires first wins - so 45s here just needs to feel responsive on a
// stalled connection without cutting off a slow-but-progressing request
// too eagerly.
static const NSTimeInterval kBDSSynchronousRequestTimeout = 45.0;

// expectBody: YES if a non-2xx response with no body should still count
// as a hard failure needing a body to report (used for GETs, where an
// empty 2xx never happens); NO for calls where a 204 No Content success
// is normal (POST dispatch, DELETE) - those return an empty dictionary
// on success rather than nil, so callers can still `!= nil`-check them.
+ (nullable id)bds_performJSONRequest:(NSURLRequest *)request expectBody:(BOOL)expectBody error:(NSError **)error {
    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *transportError = nil;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        responseData = data;
        httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        transportError = taskError;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];

    long timedOut = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBDSSynchronousRequestTimeout * NSEC_PER_SEC)));
    if (timedOut != 0) {
        // The completion handler never ran in time - cancel the task so
        // it isn't left running unbounded either, and fail this call
        // outright rather than waiting on it any further. If the
        // completion handler does still fire later (a cancel doesn't
        // guarantee it won't), it just signals a semaphore nothing is
        // waiting on anymore - harmless.
        [task cancel];
        if (error) {
            *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                  description:@"Timed out waiting for a response from GitHub."];
        }
        return nil;
    }

    if (transportError) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                          code:BundleDoctorServiceErrorRequestFailed
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: transportError.localizedDescription ?: @"Network request failed.",
                                          NSUnderlyingErrorKey: transportError,
                                      }];
        }
        return nil;
    }

    NSInteger status = httpResponse.statusCode;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[BundleDoctorService] %@ %@ -> %ld: %@", request.HTTPMethod, request.URL.path, (long)status, bodyString);
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                          code:BundleDoctorServiceErrorAPIError
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API returned %ld.", (long)status],
                                          BundleDoctorServiceHTTPStatusKey: @(status),
                                          BundleDoctorServiceResponseBodyKey: bodyString,
                                      }];
        }
        return nil;
    }

    if (responseData.length == 0) {
        // 204 No Content (dispatch/delete) - a legitimate success with
        // nothing to parse.
        return expectBody ? @{} : @{};
    }

    NSError *parseError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseError];
    if (!parsed) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError
                                         description:parseError.localizedDescription ?: @"Couldn't parse GitHub API response."];
        return nil;
    }
    return parsed;
}

+ (NSDateFormatter *)bds_iso8601Formatter {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return formatter;
}

+ (NSError *)bds_errorWithCode:(BundleDoctorServiceErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:BundleDoctorServiceErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

@end
