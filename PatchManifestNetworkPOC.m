#import "PatchManifestNetworkPOC.h"
#import "ZTweakLog.h"

#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach-o/dyld.h>

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
static NSString * const kTargetBank = @"Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank";
static NSString * const kDesiredMD5 = @"fbe98ef9f57aff80c58ada46c4f8af92";
static const NSUInteger kDesiredSize = 57408616;

static const NSUInteger kMaxManifestBytes = 32ULL * 1024ULL * 1024ULL;

static IMP gOrigDidReceiveData;
static IMP gOrigDidComplete;
static Class gDelegateClass;
static BOOL gInstalled;


static void PMFileLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSString *path = @"/var/mobile/Documents/pmnet.log"; // pull via Filza/scp after a login
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

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
    ZLog(@"[PatchManifestNetworkPOC] observed request host=%@ path=%@ match=%@",
          host, path, match ? @"YES" : @"NO");

    return match;
}

static NSData *PMPatchManifestData(NSData *input) {
    if (input.length == 0 || input.length > kMaxManifestBytes) {
        return input;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:input
                                               options:NSJSONReadingMutableContainers
                                                 error:&jsonError];
    if (![root isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetworkPOC] target response wasn't JSON: %@", jsonError);
        return input;
    }

    NSMutableDictionary *manifest = (NSMutableDictionary *)root;
    NSMutableDictionary *files = manifest[@"Files"];
    if (![files isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetworkPOC] manifest has no Files dictionary");
        return input;
    }

    NSMutableDictionary *entry = files[kTargetBank];
    if (![entry isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetworkPOC] target bank entry not found");
        return input;
    }

    NSString *oldHash = [entry[@"Hash"] isKindOfClass:NSString.class] ? entry[@"Hash"] : @"";
    NSNumber *oldSizeNumber = [entry[@"Size"] respondsToSelector:@selector(unsignedLongLongValue)]
        ? entry[@"Size"] : nil;
    unsigned long long oldSize = oldSizeNumber.unsignedLongLongValue;

    if ([oldHash caseInsensitiveCompare:kDesiredMD5] == NSOrderedSame &&
        oldSize == kDesiredSize) {
        return input;
    }

    entry[@"Hash"] = kDesiredMD5;
    entry[@"Size"] = @(kDesiredSize);

    NSError *encodeError = nil;
    NSData *output = [NSJSONSerialization dataWithJSONObject:manifest
                                                       options:0
                                                         error:&encodeError];
    if (!output) {
        ZLog(@"[PatchManifestNetworkPOC] JSON serialization failed: %@", encodeError);
        return input;
    }

    ZLog(@"[PatchManifestNetworkPOC] patched %@: Hash %@ -> %@, Size %llu -> %lu",
          kTargetBank,
          oldHash,
          kDesiredMD5,
          oldSize,
          (unsigned long)kDesiredSize);

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

    if (!error && buffer.length > 0 && buffer.length <= kMaxManifestBytes) {
        NSData *patched = PMPatchManifestData(buffer);
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self,
            @selector(URLSession:dataTask:didReceiveData:),
            session,
            (NSURLSessionDataTask *)task,
            patched);
    } else if (buffer.length > kMaxManifestBytes) {
        ZLog(@"[PatchManifestNetworkPOC] response exceeded %lu-byte safety cap; forwarding nothing",
              (unsigned long)kMaxManifestBytes);
    }

    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
        self, _cmd, session, task, error);
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

@implementation PatchManifestNetworkPOC

+ (void)install {
    @synchronized (self) {
        if (gInstalled) return;

        gDelegateClass = NSClassFromString(@"UnityWebRequestDelegate");
        if (!gDelegateClass) {
            NSArray<NSString *> *candidates = PMFindCandidateDelegateClassNames();
            ZLog(@"[PatchManifestNetworkPOC] UnityWebRequestDelegate class not found. "
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
            ZLog(@"[PatchManifestNetworkPOC] required NSURLSession delegate methods not found on %@",
                  NSStringFromClass(gDelegateClass));
            return;
        }

        gOrigDidReceiveData = method_getImplementation(didReceiveMethod);
        gOrigDidComplete = method_getImplementation(didCompleteMethod);

        gBuffers = [NSMutableDictionary dictionary];
        gStateQueue = dispatch_queue_create("com.120F.PatchManifestNetworkPOC", DISPATCH_QUEUE_SERIAL);

        method_setImplementation(didReceiveMethod, (IMP)PMDidReceiveData);
        method_setImplementation(didCompleteMethod, (IMP)PMDidComplete);
        gInstalled = YES;

        ZLog(@"[PatchManifestNetworkPOC] installed on %@", NSStringFromClass(gDelegateClass));
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

        ZLog(@"[PatchManifestNetworkPOC] uninstalled");
    }
}

@end

// Nothing in the rest of the project ever called +[PatchManifestNetworkPOC
// install] - that's the actual reason no requests were being detected at
// all, independent of the two bugs above. Unlike the IL2CPP-touching
// hooks elsewhere in this project, this one only needs Foundation/the ObjC
// runtime, both available from process attach, so installing from a plain
// constructor here (rather than wiring it into fps120.m's IL2CPP-gated
// startup poll) is safe and keeps this POC self-contained.
__attribute__((constructor))
static void PMNetworkPOCConstructor(void) {
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
    NSLog(@"[PatchManifestNetworkPOC] constructor fired - dylib loaded and this file is running");


static void PMTryInstallIfNeeded(void) {
    @synchronized ([PatchManifestNetworkPOC class]) {
        if (gInstalled) return;
    }
    [PatchManifestNetworkPOC install]; // your existing method; already no-ops safely if class not found
}

static void PMImageAddedCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    PMTryInstallIfNeeded();
}

__attribute__((constructor))
static void PMNetworkPOCConstructor(void) {
    NSLog(@"[PatchManifestNetworkPOC] constructor fired");
    _dyld_register_func_for_add_image(PMImageAddedCallback);
}

        
    // Play a strong haptic immediately on startup so the operator knows
    // the dylib is loaded and running. Ensure this runs on the main
    // thread and fall back to the vibration system sound on older iOS.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [generator prepare];
            [generator impactOccurred];
        } else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        }
    });

    [PatchManifestNetworkPOC install];
}
