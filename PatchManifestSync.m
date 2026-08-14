#import "PatchManifestSync.h"

#import <objc/runtime.h>

static NSString * const kTargetHost = @"downloadfmod.limbuscompanycdn.org";
static NSString * const kTargetPath = @"/Assets/Sound/FmodPatchInfo.json";
static NSString * const kTargetBank = @"Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank";
static NSString * const kDesiredMD5 = @"fbe98ef9f57aff80ada46c4f8af92";
static const NSUInteger kDesiredSize = 57408616;

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

    return [host isEqualToString:kTargetHost] && [path isEqualToString:kTargetPath];
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
        NSLog(@"[PatchManifestNetworkPOC] target response wasn't JSON: %@", jsonError);
        return input;
    }

    NSMutableDictionary *manifest = (NSMutableDictionary *)root;
    NSMutableDictionary *files = manifest[@"Files"];
    if (![files isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"[PatchManifestNetworkPOC] manifest has no Files dictionary");
        return input;
    }

    NSMutableDictionary *entry = files[kTargetBank];
    if (![entry isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"[PatchManifestNetworkPOC] target bank entry not found");
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
        NSLog(@"[PatchManifestNetworkPOC] JSON serialization failed: %@", encodeError);
        return input;
    }

    NSLog(@"[PatchManifestNetworkPOC] patched %@: Hash %@ -> %@, Size %llu -> %lu",
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
        NSLog(@"[PatchManifestNetworkPOC] response exceeded %lu-byte safety cap; forwarding nothing",
              (unsigned long)kMaxManifestBytes);
    }

    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
        self, _cmd, session, task, error);
}

@implementation PatchManifestNetworkPOC

+ (void)install {
    @synchronized (self) {
        if (gInstalled) return;

        gDelegateClass = NSClassFromString(@"UnityWebRequestDelegate");
        if (!gDelegateClass) {
            NSLog(@"[PatchManifestNetworkPOC] UnityWebRequestDelegate class not found");
            return;
        }

        SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
        SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

        Method didReceiveMethod = class_getInstanceMethod(gDelegateClass, didReceiveSEL);
        Method didCompleteMethod = class_getInstanceMethod(gDelegateClass, didCompleteSEL);
        if (!didReceiveMethod || !didCompleteMethod) {
            NSLog(@"[PatchManifestNetworkPOC] required NSURLSession delegate methods not found on %@",
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

        NSLog(@"[PatchManifestNetworkPOC] installed on %@", NSStringFromClass(gDelegateClass));
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

        NSLog(@"[PatchManifestNetworkPOC] uninstalled");
    }
}

@end
