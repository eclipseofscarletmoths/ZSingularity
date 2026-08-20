#import "BundleDoctorService.h"
#import "ZTweakLog.h"

NSString * const BundleDoctorServiceErrorDomain = @"BundleDoctorServiceErrorDomain";
NSString * const BundleDoctorServiceHTTPStatusKey = @"BundleDoctorServiceHTTPStatusKey";
NSString * const BundleDoctorServiceResponseBodyKey = @"BundleDoctorServiceResponseBodyKey";
NSString * const BundleDoctorServiceRunURLKey = @"BundleDoctorServiceRunURLKey";

// --- Workflow contract - see BundleDoctorService.h's big header comment ---
// These four have to match whatever the actual doctor-bundle workflow
// YAML in the target repo expects/produces. Unverified against a real
// workflow file (none was available when this was written) - same
// "flagged guess, fix if wrong" spirit as PatchManifestNetwork.m's own
// kTargetHostSuffix/kTargetPathSuffix and UnityWebRequestDelegate guess.
static NSString * const kBDSInputPath = @"bundle-doctor-input/input.bundle";
static NSString * const kBDSOutputPath = @"bundle-doctor-output/output.bundle";
static NSString * const kBDSInputFormatKey = @"output_format";

static NSString * const kBDSDefaultRef = @"main";
static NSString * const kBDSDefaultWorkflowFile = @"doctor-bundle.yml";
static NSString * const kBDSDefaultOutputFormat = @"RGBA32";

static const NSTimeInterval kBDSRunDiscoveryTimeout = 30.0;   // waiting for the dispatched run to show up in the runs list
static const NSTimeInterval kBDSRunDiscoveryPollInterval = 2.0;
static const NSTimeInterval kBDSRunCompletionTimeout = 600.0; // waiting for the run itself to finish - AssetsTools.NET re-encoding can be slow on a big bundle
static const NSTimeInterval kBDSRunCompletionPollInterval = 5.0;

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
// plain block, so +bds_createBlobWithData:progress:... below can report
// real progress on the one request in this whole pipeline with an
// actual multi-second body (the base64-encoded bundle blob). Nothing
// else in this file needs this - every other request is a small JSON
// body/response, over before a progress callback would mean anything.
@interface BDSUploadProgressDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>
@property (nonatomic, copy, nullable) void (^onProgress)(double fractionComplete);
@property (nonatomic, strong, nullable) NSMutableData *collectedData;
@property (nonatomic, strong, nullable) NSHTTPURLResponse *httpResponse;
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

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!self.collectedData) self.collectedData = [NSMutableData data];
    [self.collectedData appendData:data];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) self.httpResponse = (NSHTTPURLResponse *)response;
    completionHandler(NSURLSessionResponseAllow);
}

@end

#pragma mark - BundleDoctorService

@implementation BundleDoctorService

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

        NSString *scratchBranch = [NSString stringWithFormat:@"bundle-doctor/%@", [NSUUID UUID].UUIDString];
        ZLog(@"[BundleDoctorService] starting run on %@/%@, scratch branch %@",
              config.repoOwner, config.repoName, scratchBranch);

        report(@"Reading base branch\u2026");
        NSString *baseCommitSHA = nil, *baseTreeSHA = nil;
        if (![self bds_resolveBaseCommitSHA:&baseCommitSHA treeSHA:&baseTreeSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        report(@"Uploading modded bundle\u2026");
        NSString *blobSHA = nil;
        if (![self bds_createBlobWithData:moddedData config:config outSHA:&blobSHA error:&error]) {
            finish(nil, error);
            return;
        }

        NSString *newTreeSHA = nil;
        if (![self bds_createTreeWithBaseTreeSHA:baseTreeSHA path:kBDSInputPath blobSHA:blobSHA
                                            config:config outSHA:&newTreeSHA error:&error]) {
            finish(nil, error);
            return;
        }

        NSString *newCommitSHA = nil;
        if (![self bds_createCommitWithTreeSHA:newTreeSHA parentSHA:baseCommitSHA
                                        config:config outSHA:&newCommitSHA error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_createBranch:scratchBranch atCommitSHA:newCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        report(@"Triggering doctor-bundle workflow\u2026");
        NSDate *dispatchedAt = [NSDate date];
        if (![self bds_dispatchWorkflowOnBranch:scratchBranch config:config error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config]; // best-effort cleanup, ignore result
            finish(nil, error);
            return;
        }

        report(@"Waiting for the run to start\u2026");
        NSString *runID = nil;
        NSString *runURL = nil;
        if (![self bds_findRunOnBranch:scratchBranch dispatchedAfter:dispatchedAt config:config
                                  runID:&runID runURL:&runURL error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Waiting for the workflow to finish\u2026");
        if (![self bds_waitForRunCompletion:runID runURL:runURL config:config error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Downloading doctored bundle\u2026");
        NSData *doctoredData = nil;
        if (![self bds_fetchContentsAtPath:kBDSOutputPath ref:scratchBranch config:config
                                       data:&doctoredData error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Cleaning up\u2026");
        [self bds_deleteBranch:scratchBranch config:config]; // best-effort, logged not surfaced - see header

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

        NSString *scratchBranch = [NSString stringWithFormat:@"bundle-doctor/%@", [NSUUID UUID].UUIDString];
        ZLog(@"[BundleDoctorService] dispatching %@/%@, scratch branch %@",
              config.repoOwner, config.repoName, scratchBranch);

        NSString *baseCommitSHA = nil, *baseTreeSHA = nil;
        if (![self bds_resolveBaseCommitSHA:&baseCommitSHA treeSHA:&baseTreeSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        NSString *blobSHA = nil;
        if (![self bds_createBlobWithData:moddedData progress:reportProgress config:config outSHA:&blobSHA error:&error]) {
            finish(nil, error);
            return;
        }
        reportProgress(1.0); // the blob POST is the entire uploadProgress contract - make sure callers land on a clean 100%

        NSString *newTreeSHA = nil;
        if (![self bds_createTreeWithBaseTreeSHA:baseTreeSHA path:kBDSInputPath blobSHA:blobSHA
                                            config:config outSHA:&newTreeSHA error:&error]) {
            finish(nil, error);
            return;
        }

        NSString *newCommitSHA = nil;
        if (![self bds_createCommitWithTreeSHA:newTreeSHA parentSHA:baseCommitSHA
                                        config:config outSHA:&newCommitSHA error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_createBranch:scratchBranch atCommitSHA:newCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_dispatchWorkflowOnBranch:scratchBranch config:config error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config]; // best-effort cleanup, ignore result
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
        if (![self bds_fetchContentsAtPath:kBDSOutputPath ref:handle.scratchBranch config:config
                                       data:&doctoredData error:&error]) {
            finish(nil, error);
            return;
        }

        [self bds_deleteBranch:handle.scratchBranch config:config]; // best-effort, logged not surfaced - see header

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

#pragma mark - Git Data API steps

+ (BOOL)bds_resolveBaseCommitSHA:(NSString **)outCommitSHA
                          treeSHA:(NSString **)outTreeSHA
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

    NSString *commitPath = [NSString stringWithFormat:@"/repos/%@/%@/git/commits/%@",
                             config.repoOwner, config.repoName, commitSHA];
    id commit = [self bds_getJSON:commitPath config:config error:error];
    if (!commit) return NO;

    NSString *treeSHA = [commit valueForKeyPath:@"tree.sha"];
    if (![treeSHA isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError
                                         description:@"Unexpected response resolving the base tree."];
        return NO;
    }

    if (outCommitSHA) *outCommitSHA = commitSHA;
    if (outTreeSHA) *outTreeSHA = treeSHA;
    return YES;
}

+ (BOOL)bds_createBlobWithData:(NSData *)data
                          config:(BundleDoctorConfig *)config
                          outSHA:(NSString **)outSHA
                           error:(NSError **)error {
    NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/git/blobs", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"content": [data base64EncodedStringWithOptions:0],
        @"encoding": @"base64",
    };
    id result = [self bds_postJSON:path body:body config:config error:error];
    if (!result) return NO;

    NSString *sha = result[@"sha"];
    if (![sha isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Blob creation didn't return a sha."];
        return NO;
    }
    if (outSHA) *outSHA = sha;
    return YES;
}

// Same request as +bds_createBlobWithData:config:outSHA:error: above,
// but sent as an upload task on a dedicated delegate-backed NSURLSession
// instead of the shared session's dataTaskWithRequest:, so
// BDSUploadProgressDelegate's didSendBodyData: callback can report real
// byte-level progress as the (base64-encoded, so ~1.33x the original
// bundle's size) body goes out. This is the only bds_* request in this
// file worth doing this for - see this method's caller,
// +dispatchBundleAtURL:config:uploadProgress:completion:, and this
// file's header on why every other phase is a single small JSON
// request with nothing meaningful to report mid-flight.
+ (BOOL)bds_createBlobWithData:(NSData *)data
                        progress:(nullable void (^)(double fractionComplete))progress
                          config:(BundleDoctorConfig *)config
                          outSHA:(NSString **)outSHA
                           error:(NSError **)error {
    NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/git/blobs", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"content": [data base64EncodedStringWithOptions:0],
        @"encoding": @"base64",
    };

    NSError *encodeError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodeError];
    if (!bodyData) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed
                                         description:encodeError.localizedDescription ?: @"Couldn't encode request body."];
        return NO;
    }

    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return NO;
    }
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    BDSUploadProgressDelegate *delegate = [BDSUploadProgressDelegate new];
    delegate.onProgress = progress;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                             delegate:delegate
                                                        delegateQueue:nil];

    __block NSError *transportError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromData:bodyData
                                                  completionHandler:^(NSData *ignoredData, NSURLResponse *ignoredResponse, NSError *taskError) {
        // The real response body/status come from the delegate
        // (didReceiveResponse:/didReceiveData:) since this session has
        // one - the completion handler's own data/response are not
        // populated when a delegate is set. Only the transport error is
        // read from here.
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

    NSInteger status = delegate.httpResponse.statusCode;
    NSData *responseData = delegate.collectedData;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[BundleDoctorService] POST %@ -> %ld: %@", path, (long)status, bodyString);
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

    NSError *parseError = nil;
    id result = responseData.length > 0 ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseError] : @{};
    if (!result) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError
                                         description:parseError.localizedDescription ?: @"Couldn't parse GitHub API response."];
        return NO;
    }

    NSString *sha = result[@"sha"];
    if (![sha isKindOfClass:NSString.class]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Blob creation didn't return a sha."];
        return NO;
    }
    if (outSHA) *outSHA = sha;
    return YES;
}

+ (BOOL)bds_createTreeWithBaseTreeSHA:(NSString *)baseTreeSHA
                                   path:(NSString *)path
                                blobSHA:(NSString *)blobSHA
                                 config:(BundleDoctorConfig *)config
                                 outSHA:(NSString **)outSHA
                                  error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/trees", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"base_tree": baseTreeSHA,
        @"tree": @[ @{
            @"path": path,
            @"mode": @"100644",
            @"type": @"blob",
            @"sha": blobSHA,
        } ],
    };
    id result = [self bds_postJSON:urlPath body:body config:config error:error];
    if (!result) return NO;

    NSString *sha = result[@"sha"];
    if (![sha isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Tree creation didn't return a sha."];
        return NO;
    }
    if (outSHA) *outSHA = sha;
    return YES;
}

+ (BOOL)bds_createCommitWithTreeSHA:(NSString *)treeSHA
                            parentSHA:(NSString *)parentSHA
                              config:(BundleDoctorConfig *)config
                              outSHA:(NSString **)outSHA
                               error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/commits", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"message": @"BundleDoctor: doctor modded bundle for iOS",
        @"tree": treeSHA,
        @"parents": @[ parentSHA ],
    };
    id result = [self bds_postJSON:urlPath body:body config:config error:error];
    if (!result) return NO;

    NSString *sha = result[@"sha"];
    if (![sha isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Commit creation didn't return a sha."];
        return NO;
    }
    if (outSHA) *outSHA = sha;
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

#pragma mark - Actions API steps

+ (BOOL)bds_dispatchWorkflowOnBranch:(NSString *)branchName
                                config:(BundleDoctorConfig *)config
                                 error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/dispatches",
                          config.repoOwner, config.repoName, config.workflowFile];
    NSDictionary *body = @{
        @"ref": branchName,
        @"inputs": @{ kBDSInputFormatKey: config.outputFormat },
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

#pragma mark - Contents API (output download)

+ (BOOL)bds_fetchContentsAtPath:(NSString *)path
                             ref:(NSString *)ref
                          config:(BundleDoctorConfig *)config
                            data:(NSData **)outData
                           error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/contents/%@?ref=%@",
                          config.repoOwner, config.repoName, path,
                          [ref stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    id result = [self bds_getJSON:urlPath config:config error:error];
    if (!result) {
        // bds_getJSON already filled `error`; a 404 here specifically
        // means the workflow never wrote BDS_OUTPUT_PATH - almost
        // certainly a path-convention mismatch with the actual workflow
        // YAML (see this file's header) rather than a transient failure.
        if (error && (*error).code == BundleDoctorServiceErrorAPIError &&
            [(*error).userInfo[BundleDoctorServiceHTTPStatusKey] isEqual:@404]) {
            *error = [self bds_errorWithCode:BundleDoctorServiceErrorOutputMissing
                                  description:[NSString stringWithFormat:@"Run succeeded but %@ wasn't on the scratch branch afterward - check the workflow writes its output there.", path]];
        }
        return NO;
    }

    NSString *base64 = result[@"content"];
    if (![base64 isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Contents API response had no content."];
        return NO;
    }
    // Contents API base64 is newline-wrapped for readability - strip
    // before decoding.
    NSString *stripped = [base64 stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:stripped options:0];
    if (!data) {
        if (error) *error = [self bds_errorWithCode:BundleDoctorServiceErrorAPIError description:@"Couldn't decode doctored bundle content."];
        return NO;
    }
    if (outData) *outData = data;
    return YES;
}

#pragma mark - HTTP plumbing

+ (nullable NSMutableURLRequest *)bds_requestForPath:(NSString *)path config:(BundleDoctorConfig *)config {
    NSString *urlString = [@"https://api.github.com" stringByAppendingString:path];
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
