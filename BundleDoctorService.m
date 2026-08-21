#import "BundleDoctorService.h"
#import "ZTweakLog.h"
#import "UnityBundleCAB.h"

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
}

- (instancetype)initWithScratchBranch:(NSString *)scratchBranch {
    if ((self = [super init])) {
        _scratchBranch = [scratchBranch copy];
    }
    return self;
}

- (NSString *)scratchBranch { return _scratchBranch; }

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
                                           config:config data:&doctoredData error:&error]) {
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

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL
                       config:(BundleDoctorConfig *)rawConfig
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

        NSString *scratchBranch = [NSString stringWithFormat:@"bundle-doctor/%@", [NSUUID UUID].UUIDString];
        ZLog(@"[BundleDoctorService] dispatching %@/%@, scratch branch %@",
              config.repoOwner, config.repoName, scratchBranch);

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

        if (![self bds_uploadReleaseAssetData:uploadData name:kBDSInputAssetName
                             uploadURLTemplate:uploadURLTemplate progress:reportProgress
                                        config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }
        reportProgress(1.0); // the asset upload is the entire uploadProgress contract - make sure callers land on a clean 100%

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
                            completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
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
                                           config:config data:&doctoredData error:&error]) {
            finish(nil, error);
            return;
        }

        [self bds_cleanupScratchSubmission:handle.scratchBranch config:config]; // best-effort, logged not surfaced - see header

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

+ (BOOL)bds_createBranch:(NSString *)branchName
              atCommitSHA:(NSString *)commitSHA
                   config:(BundleDoctorConfig *)config
                    error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"ref": [NSString stringWithFormat:@"refs/heads/%@", branchName],
        @"sha": commitSHA,
    };
    return [self bds_postJSON:urlPath body:body config:config error:error] != nil;
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
    id result = [self bds_postJSON:urlPath body:body config:config error:error];
    if (!result) return NO;

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

// Looks up the release tagged releaseTag, finds the asset named `name`
// on it, and downloads its bytes.
+ (BOOL)bds_downloadReleaseAssetNamed:(NSString *)name
                       fromReleaseTag:(NSString *)releaseTag
                               config:(BundleDoctorConfig *)config
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

    NSData *data = [self bds_downloadBinaryAtAbsoluteURLString:assetAPIURL config:config error:error];
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
                                                        error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForAbsoluteURLString:urlString config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    request.HTTPMethod = @"GET";

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
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

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

    return responseData ?: [NSData data];
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
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

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
