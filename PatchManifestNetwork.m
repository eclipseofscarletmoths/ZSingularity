#import "PatchManifestNetwork.h"
#import "ZTweakLog.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>

// NOTE: this used to be compared against url.host, which only ever
// contains the bare hostname (e.g. "downloadfmod.limbuscompanycdn.org").
// A full "https://host/path" string can never match .host, so
// PMIsTargetTask() was unconditionally returning NO and nothing was
// ever intercepted regardless of what the game actually requested.
static NSString * const kTargetHostSuffix = @"limbuscompanycdn.org";
// The path we actually observed included a build-dated token segment
// ("/f20260813_S8pD8WWQc4i0MQKT1X1W/...") ahead of the real filename.
// That token is almost certainly per-build/per-session and will change
// on the next patch, so match on the filename instead of the full path.
static NSString * const kTargetPathSuffix = @"FmodPatchInfo.json";

static const NSUInteger kMaxManifestBytes = 32ULL * 1024ULL * 1024ULL;

static IMP gOrigDidReceiveData;
static IMP gOrigDidComplete;
static Class gDelegateClass;
static BOOL gInstalled;

static NSMutableDictionary<NSNumber *, NSMutableData *> *gBuffers;
static dispatch_queue_t gStateQueue;

static BOOL PMIsTargetTask(NSURLSessionDataTask *task) {
    NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
    if (!url) return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";

    BOOL match = [host hasSuffix:kTargetHostSuffix] && [path hasSuffix:kTargetPathSuffix];

    // Log every request that reaches this delegate, matched or not, at
    // least once. If this never prints anything, the hook itself isn't
    // firing (see the +install log line) - that's a different problem
    // than the URL not matching, and worth ruling out first.
    ZLog(@"[PatchManifestNetwork] observed request host=%@ path=%@ match=%@",
          host, path, match ? @"YES" : @"NO");

    return match;
}

// Zeroes every entry's Hash and Size in the manifest's Files dictionary,
// rather than only the one bank this project happens to be swapping.
// This makes the check pass for any locally-modded asset the manifest
// covers, not just a single hardcoded target - which matters now that
// bank swaps are a direct file copy with no re-encode step re-deriving a
// "correct" hash/size to target instead.
static NSData *PMPatchManifestData(NSData *input) {
    if (input.length == 0 || input.length > kMaxManifestBytes) {
        return input;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:input
                                               options:NSJSONReadingMutableContainers
                                                 error:&jsonError];
    if (![root isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetwork] target response wasn't JSON: %@", jsonError);
        return input;
    }

    NSMutableDictionary *manifest = (NSMutableDictionary *)root;
    NSMutableDictionary *files = manifest[@"Files"];
    if (![files isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetwork] manifest has no Files dictionary");
        return input;
    }

    NSUInteger patchedCount = 0;
    for (NSString *key in files) {
        NSMutableDictionary *entry = files[key];
        if (![entry isKindOfClass:[NSMutableDictionary class]]) continue;

        BOOL hashAlreadyZero = [entry[@"Hash"] isEqual:@"0"] || [entry[@"Hash"] isEqual:@0];
        BOOL sizeAlreadyZero = [entry[@"Size"] respondsToSelector:@selector(unsignedLongLongValue)]
            ? [entry[@"Size"] unsignedLongLongValue] == 0
            : NO;
        if (hashAlreadyZero && sizeAlreadyZero) continue;

        entry[@"Hash"] = @"0";
        entry[@"Size"] = @0;
        patchedCount++;
    }

    if (patchedCount == 0) {
        return input;
    }

    NSError *encodeError = nil;
    NSData *output = [NSJSONSerialization dataWithJSONObject:manifest
                                                       options:0
                                                         error:&encodeError];
    if (!output) {
        ZLog(@"[PatchManifestNetwork] JSON serialization failed: %@", encodeError);
        return input;
    }

    ZLog(@"[PatchManifestNetwork] zeroed Hash/Size on %lu Files entries", (unsigned long)patchedCount);

    return output;
}

static void PMDidReceiveData(id self,
                             SEL _cmd,
                             NSURLSession *session,
                             NSURLSessionDataTask *task,
                             NSData *data) {
    if (!PMIsTargetTask(task)) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self, _cmd, session, task, data);
        return;
    }

    NSNumber *key = @(task.taskIdentifier);
    __block NSMutableData *buffer = nil;

    dispatch_sync(gStateQueue, ^{
        buffer = gBuffers[key];
        if (!buffer) {
            buffer = [NSMutableData data];
            gBuffers[key] = buffer;
        }

        if (buffer.length <= kMaxManifestBytes &&
            data.length <= (kMaxManifestBytes - buffer.length)) {
            [buffer appendData:data];
        } else {
            [buffer setLength:kMaxManifestBytes + 1];
        }
    });

    // Deliberately do not forward target chunks yet. They are forwarded once,
    // after the complete manifest can be rewritten.
}

static void PMDidComplete(id self,
                          SEL _cmd,
                          NSURLSession *session,
                          NSURLSessionTask *task,
                          NSError *error) {
    if (![task isKindOfClass:NSURLSessionDataTask.class] ||
        !PMIsTargetTask((NSURLSessionDataTask *)task)) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
            self, _cmd, session, task, error);
        return;
    }

    NSNumber *key = @(task.taskIdentifier);
    __block NSMutableData *buffer = nil;

    dispatch_sync(gStateQueue, ^{
        buffer = gBuffers[key];
        [gBuffers removeObjectForKey:key];
    });

    BOOL patched = NO;
    if (!error && buffer.length > 0 && buffer.length <= kMaxManifestBytes) {
        NSData *patchedData = PMPatchManifestData(buffer);
        patched = (patchedData != buffer);
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self,
            @selector(URLSession:dataTask:didReceiveData:),
            session,
            (NSURLSessionDataTask *)task,
            patchedData);
    } else if (buffer.length > kMaxManifestBytes) {
        ZLog(@"[PatchManifestNetwork] response exceeded %lu-byte safety cap; forwarding nothing",
              (unsigned long)kMaxManifestBytes);
    }

    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
        self, _cmd, session, task, error);

    // Job's done for this session once a manifest has actually been
    // patched - deactivate rather than keep intercepting every
    // subsequent matching request for the rest of the run.
    if (patched) {
        ZLog(@"[PatchManifestNetwork] manifest patched - deactivating for the rest of this session");
        [PatchManifestNetwork uninstall];
    }
}

// "UnityWebRequestDelegate" is a guess, not a name confirmed to exist in
// this build. Unity's iOS UnityWebRequest backend has used different
// internal class names across engine versions, and Limbus Company's
// symbols are stripped, so there's no way to know the literal name
// without checking on-device. This walks every loaded Objective-C class
// and logs the ones that actually implement both delegate methods we
// need to hook, so the real name (whatever it is) shows up in the
// device console/syslog.
static NSArray<NSString *> *PMFindCandidateDelegateClassNames(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
    SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return candidates;

    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned long)count);
    if (!classes) return candidates;

    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (class_getInstanceMethod(cls, didReceiveSEL) &&
            class_getInstanceMethod(cls, didCompleteSEL)) {
            [candidates addObject:NSStringFromClass(cls)];
        }
    }

    free(classes);
    return candidates;
}

@implementation PatchManifestNetwork

+ (void)install {
    @synchronized (self) {
        if (gInstalled) return;

        gDelegateClass = NSClassFromString(@"UnityWebRequestDelegate");
        if (!gDelegateClass) {
            NSArray<NSString *> *candidates = PMFindCandidateDelegateClassNames();
            ZLog(@"[PatchManifestNetwork] UnityWebRequestDelegate class not found. "
                  @"Classes implementing both NSURLSessionDataDelegate methods we need: %@. "
                  @"If this list is non-empty, set gDelegateClass to the right one of these "
                  @"(usually the Unity/UnityEngine-prefixed one) and rerun. If it's empty, "
                  @"the delegate methods may not be exposed as ObjC methods at all in this "
                  @"build (e.g. a pure C/CFNetwork backend) and this approach needs a different "
                  @"hook point entirely.", candidates);
            return;
        }

        SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
        SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

        Method didReceiveMethod = class_getInstanceMethod(gDelegateClass, didReceiveSEL);
        Method didCompleteMethod = class_getInstanceMethod(gDelegateClass, didCompleteSEL);
        if (!didReceiveMethod || !didCompleteMethod) {
            ZLog(@"[PatchManifestNetwork] required NSURLSession delegate methods not found on %@",
                  NSStringFromClass(gDelegateClass));
            return;
        }

        gOrigDidReceiveData = method_getImplementation(didReceiveMethod);
        gOrigDidComplete = method_getImplementation(didCompleteMethod);

        gBuffers = [NSMutableDictionary dictionary];
        gStateQueue = dispatch_queue_create("com.120F.PatchManifestNetwork", DISPATCH_QUEUE_SERIAL);

        method_setImplementation(didReceiveMethod, (IMP)PMDidReceiveData);
        method_setImplementation(didCompleteMethod, (IMP)PMDidComplete);
        gInstalled = YES;

        ZLog(@"[PatchManifestNetwork] installed on %@", NSStringFromClass(gDelegateClass));
    }
}

+ (void)uninstall {
    @synchronized (self) {
        if (!gInstalled || !gDelegateClass) return;

        SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
        SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

        Method didReceiveMethod = class_getInstanceMethod(gDelegateClass, didReceiveSEL);
        Method didCompleteMethod = class_getInstanceMethod(gDelegateClass, didCompleteSEL);

        if (didReceiveMethod && gOrigDidReceiveData) {
            method_setImplementation(didReceiveMethod, gOrigDidReceiveData);
        }
        if (didCompleteMethod && gOrigDidComplete) {
            method_setImplementation(didCompleteMethod, gOrigDidComplete);
        }

        gBuffers = nil;
        gStateQueue = nil;
        gDelegateClass = Nil;
        gOrigDidReceiveData = NULL;
        gOrigDidComplete = NULL;
        gInstalled = NO;

        ZLog(@"[PatchManifestNetwork] uninstalled");
    }
}

@end

// Nothing in the rest of the project ever called +[PatchManifestNetwork
// install] - that's the actual reason no requests were being detected at
// all, independent of the two bugs above. Unlike the IL2CPP-touching
// hooks elsewhere in this project, this one only needs Foundation/the ObjC
// runtime, both available from process attach, so installing from a plain
// constructor here (rather than wiring it into fps120.m's IL2CPP-gated
// startup poll) is safe and keeps this file self-contained.
__attribute__((constructor))
static void PMNetworkConstructor(void) {
    // This line is the decisive signal. It fires the instant this
    // translation unit's constructor runs, before any class lookup,
    // any swizzling, or any request has to occur - so if this never
    // shows up in the Verbose syslog filter, the problem is upstream
    // of everything else in this file (dylib not injected/loaded, this
    // .m not linked into the built dylib, etc). If this DOES show up
    // but "installed on ..." (see +install below) never follows, the
    // problem is narrowed to delegate-class resolution. If "installed
    // on ..." shows up but "observed request host=..." never follows,
    // the problem is narrowed further still (see PMIsTargetTask) - most
    // likely that the matched class's didReceiveData/didCompleteWithError
    // methods are simply never invoked for this task (e.g. the task was
    // started with a completion-handler API, which bypasses session
    // delegate callbacks entirely regardless of which class implements
    // them - see the README note added alongside this build).
    NSLog(@"[PatchManifestNetwork] constructor fired - dylib loaded and this file is running");
}

// Replaces the old _dyld_register_func_for_add_image approach, which
// called +install (and therefore PMFindCandidateDelegateClassNames's
// full objc_getClassList scan) once per loaded Mach-O image - often
// 100-300+ times during a normal launch, each rescanning every
// currently-loaded ObjC class. That's O(images x classes) run inline
// on dyld's own loading path, which is what produced the ~20s black
// screen / watchdog kill with no .ips: startup never got a chance to
// finish before the OS gave up on it.
//
// Same fix pattern as fps120.m's background_worker: a detached pthread
// doing a cheap, cheap-per-iteration poll with a real sleep between
// attempts. NSClassFromString is a symbol-table lookup, not a scan, so
// polling it every 200ms is negligible. The expensive diagnostic scan
// only ever runs once, and only if the class still hasn't shown up
// after a real timeout - at that point something IS actually wrong
// and the candidate dump is worth its cost.
static const int kPMPollIntervalUsec = 200 * 1000;
static const int kPMMaxPollAttempts = 150; // ~30s

static void *PMBackgroundWorker(void *arg) {
    (void)arg;

    for (int attempt = 0; attempt < kPMMaxPollAttempts; attempt++) {
        if (NSClassFromString(@"UnityWebRequestDelegate")) {
            [PatchManifestNetwork install];
            return NULL;
        }
        usleep(kPMPollIntervalUsec);
    }

    // Timed out for real (not just "hasn't loaded yet") - now it's
    // worth paying for the diagnostic scan, once, to see what actually
    // exists.
    ZLog(@"[PatchManifestNetwork] UnityWebRequestDelegate never appeared after %ds of polling; "
          @"running one-shot diagnostic scan", (kPMMaxPollAttempts * kPMPollIntervalUsec) / 1000000);
    [PatchManifestNetwork install];
    return NULL;
}

__attribute__((constructor))
static void PMNetworkConstructor2(void) {
    NSLog(@"[PatchManifestNetwork] constructor fired - starting poll thread");
    pthread_t t;
    pthread_create(&t, NULL, PMBackgroundWorker, NULL);
    pthread_detach(t);
}
