// PatchManifestSync.m
//
// Filesystem-only POC.
// No IL2CPP resolution, no il2cpp_runtime_invoke, and no
// TextAssetPatchInfoManager/Config calls.

#import "PatchManifestSync.h"

#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const PatchManifestSyncErrorDomain = @"PatchManifestSyncErrorDomain";

static NSString * const kManifestRelativePath =
    @"Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank";
static NSString * const kDesiredMD5 =
    @"fbe98ef9f57aff80ada46c4f8af92";
static const NSUInteger kDesiredSize = 57408616;

static dispatch_queue_t gPatchQueue;
static dispatch_source_t gDirectoryWatcher;
static dispatch_source_t gPollingTimer;
static BOOL gStarted;

static NSError *PMSError(PatchManifestSyncErrorCode code, NSString *message) {
    return [NSError errorWithDomain:PatchManifestSyncErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *PMCacheDirectory(void) {
    NSString *cacheRoot =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                            NSUserDomainMask,
                                            YES).firstObject;
    if (cacheRoot.length == 0) {
        return nil;
    }

    return [cacheRoot stringByAppendingPathComponent:
                @"com.ProjectMoon.LimbusCompany/fsCachedData"];
}

static BOOL PMIsRegularFile(NSString *path, NSDictionary<NSFileAttributeKey, id> **attrsOut) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrsOut) {
        *attrsOut = attrs;
    }

    NSNumber *type = attrs[NSFileType];
    return [type isEqual:NSFileTypeRegular] &&
           (attrs[NSFileSize].unsignedLongLongValue <= (32ULL * 1024ULL * 1024ULL));
}

static NSDictionary *PMReadJSONFile(NSString *path) {
    NSDictionary *attrs = nil;
    if (!PMIsRegularFile(path, &attrs)) {
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data.length == 0) {
        return nil;
    }

    // Cheap discriminator before attempting JSON parsing.
    const uint8_t *bytes = data.bytes;
    NSUInteger i = 0;
    while (i < data.length &&
           (bytes[i] == ' ' || bytes[i] == '\n' ||
            bytes[i] == '\r' || bytes[i] == '\t')) {
        i++;
    }

    if (i >= data.length || bytes[i] != '{') {
        return nil;
    }

    id obj = [NSJSONSerialization JSONObjectWithData:data
                                               options:0
                                                 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSString *PMFindManifestPath(void) {
    NSString *cacheDir = PMCacheDirectory();
    if (cacheDir.length == 0) {
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:cacheDir isDirectory:&isDir] || !isDir) {
        return nil;
    }

    NSDirectoryEnumerator *enumerator =
        [fm enumeratorAtURL:[NSURL fileURLWithPath:cacheDir]
        includingPropertiesForKeys:@[
            NSURLIsRegularFileKey,
            NSURLFileSizeKey,
        ]
                       options:NSDirectoryEnumerationSkipsHiddenFiles
                  errorHandler:^BOOL(NSURL *url, NSError *error) {
        // Ignore individual unreadable cache entries; continue searching.
        return YES;
    }];

    for (NSURL *url in enumerator) {
        NSNumber *isRegular = nil;
        NSNumber *fileSize = nil;
        [url getResourceValue:&isRegular
                       forKey:NSURLIsRegularFileKey
                        error:nil];
        [url getResourceValue:&fileSize
                       forKey:NSURLFileSizeKey
                        error:nil];

        if (!isRegular.boolValue || fileSize.unsignedLongLongValue > (32ULL * 1024ULL * 1024ULL)) {
            continue;
        }

        NSDictionary *manifest = PMReadJSONFile(url.path);
        if (![manifest isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSDictionary *files = manifest[@"Files"];
        if (![files isKindOfClass:NSDictionary.class]) {
            continue;
        }

        id entry = files[kManifestRelativePath];
        if ([entry isKindOfClass:NSDictionary.class]) {
            return url.path;
        }
    }

    return nil;
}

static BOOL PMPatchManifestAtPath(NSString *path, NSError **error) {
    NSData *inputData = [NSData dataWithContentsOfFile:path
                                               options:NSDataReadingMappedIfSafe
                                                 error:error];
    if (!inputData) {
        if (error && !*error) {
            *error = PMSError(PatchManifestSyncErrorManifestInvalid,
                              @"Couldn't read the cached manifest.");
        }
        return NO;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:inputData
                                               options:NSJSONReadingMutableContainers
                                                 error:&jsonError];
    if (![root isKindOfClass:[NSMutableDictionary class]]) {
        if (error) {
            *error = jsonError ?: PMSError(PatchManifestSyncErrorManifestInvalid,
                                            @"Cached manifest is not a JSON object.");
        }
        return NO;
    }

    NSMutableDictionary *manifest = (NSMutableDictionary *)root;
    NSMutableDictionary *files = manifest[@"Files"];
    if (![files isKindOfClass:[NSMutableDictionary class]]) {
        if (error) {
            *error = PMSError(PatchManifestSyncErrorManifestInvalid,
                              @"Cached manifest has no mutable Files dictionary.");
        }
        return NO;
    }

    NSMutableDictionary *entry = files[kManifestRelativePath];
    if (![entry isKindOfClass:[NSMutableDictionary class]]) {
        if (error) {
            *error = PMSError(PatchManifestSyncErrorManifestNotFound,
                              @"Target FMOD entry was not present in the manifest.");
        }
        return NO;
    }

    NSString *oldHash = [entry[@"Hash"] isKindOfClass:NSString.class] ? entry[@"Hash"] : @"";
    NSUInteger oldSize = [entry[@"Size"] respondsToSelector:@selector(unsignedIntegerValue)]
                       ? [entry[@"Size"] unsignedIntegerValue]
                       : 0;

    // Important: only touch the file if the target values are actually wrong.
    // This makes the watcher self-stabilizing after its own atomic replace.
    if ([oldHash caseInsensitiveCompare:kDesiredMD5] == NSOrderedSame &&
        oldSize == kDesiredSize) {
        return YES;
    }

    entry[@"Hash"] = kDesiredMD5;
    entry[@"Size"] = @(kDesiredSize);

    NSError *serializationError = nil;
    NSData *outputData =
        [NSJSONSerialization dataWithJSONObject:manifest
                                         options:NSJSONWritingPrettyPrinted
                                           error:&serializationError];

    if (!outputData) {
        if (error) {
            *error = serializationError ?: PMSError(PatchManifestSyncErrorManifestWriteFailed,
                                                     @"Failed to serialize patched manifest.");
        }
        return NO;
    }

    // Atomic write: write the complete new manifest, then replace the old
    // cache object. The watcher will receive another filesystem event, but
    // the next scan becomes a no-op because the values are already correct.
    NSString *tmpPath = [path stringByAppendingFormat:@".pmspatch.%@", NSUUID.UUID.UUIDString];

    if (![outputData writeToFile:tmpPath options:NSDataWritingAtomic error:&serializationError]) {
        if (error) {
            *error = serializationError ?: PMSError(PatchManifestSyncErrorManifestWriteFailed,
                                                     @"Failed to write temporary manifest.");
        }
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm replaceItemAtURL:[NSURL fileURLWithPath:path]
                withItemAtURL:[NSURL fileURLWithPath:tmpPath]
               backupItemName:nil
                      options:0
             resultingItemURL:nil
                        error:&serializationError]) {
        [fm removeItemAtPath:tmpPath error:nil];
        if (error) {
            *error = serializationError ?: PMSError(PatchManifestSyncErrorManifestWriteFailed,
                                                     @"Failed to atomically replace the cached manifest.");
        }
        return NO;
    }

    NSLog(@"[PatchManifestSync] patched %@: Hash %@ -> %@, Size %lu -> %lu",
          kManifestRelativePath,
          oldHash,
          kDesiredMD5,
          (unsigned long)oldSize,
          (unsigned long)kDesiredSize);

    return YES;
}

static void PMScanAndPatch(void) {
    @autoreleasepool {
        NSString *manifestPath = PMFindManifestPath();
        if (manifestPath.length == 0) {
            return;
        }

        NSError *error = nil;
        if (!PMPatchManifestAtPath(manifestPath, &error) && error) {
            NSLog(@"[PatchManifestSync] scan failed: %@", error);
        }
    }
}

@implementation PatchManifestSync

+ (void)startMonitoring {
    dispatch_sync((gPatchQueue ?: dispatch_get_main_queue()), ^{
        if (gStarted) {
            return;
        }

        gStarted = YES;
        gPatchQueue = dispatch_queue_create("com.120F.PatchManifestSync", DISPATCH_QUEUE_SERIAL);

        // First pass handles the case where the manifest already exists.
        dispatch_async(gPatchQueue, ^{
            PMScanAndPatch();
        });

        NSString *cacheDir = PMCacheDirectory();
        if (cacheDir.length == 0) {
            return;
        }

        int fd = open(cacheDir.fileSystemRepresentation, O_EVTONLY);
        if (fd >= 0) {
            gDirectoryWatcher =
                dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                       (uintptr_t)fd,
                                       DISPATCH_VNODE_WRITE |
                                       DISPATCH_VNODE_EXTEND |
                                       DISPATCH_VNODE_RENAME |
                                       DISPATCH_VNODE_DELETE,
                                       gPatchQueue);

            dispatch_source_set_event_handler(gDirectoryWatcher, ^{
                PMScanAndPatch();
            });

            dispatch_source_set_cancel_handler(gDirectoryWatcher, ^{
                close(fd);
            });

            dispatch_resume(gDirectoryWatcher);
        } else {
            NSLog(@"[PatchManifestSync] couldn't watch %@", cacheDir);
        }

        // Small fallback poll. Some download implementations update a file
        // in ways that don't reliably produce the expected directory vnode
        // event on every filesystem configuration.
        gPollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                               0,
                                               0,
                                               gPatchQueue);
        dispatch_source_set_timer(gPollingTimer,
                                  DISPATCH_TIME_NOW,
                                  (uint64_t)(0.50 * NSEC_PER_SEC),
                                  (uint64_t)(0.10 * NSEC_PER_SEC));

        dispatch_source_set_event_handler(gPollingTimer, ^{
            PMScanAndPatch();
        });

        dispatch_resume(gPollingTimer);
    });
}

+ (void)stopMonitoring {
    dispatch_queue_t queue = gPatchQueue ?: dispatch_get_main_queue();

    dispatch_sync(queue, ^{
        if (!gStarted) {
            return;
        }

        gStarted = NO;

        if (gDirectoryWatcher) {
            dispatch_source_cancel(gDirectoryWatcher);
            gDirectoryWatcher = nil;
        }

        if (gPollingTimer) {
            dispatch_source_cancel(gPollingTimer);
            gPollingTimer = nil;
        }

        gPatchQueue = nil;
    });
}

+ (BOOL)resyncFmodPatchManifestWithError:(NSError **)error {
    NSString *cacheDir = PMCacheDirectory();
    BOOL isDir = NO;

    if (cacheDir.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:cacheDir isDirectory:&isDir] ||
        !isDir) {
        if (error) {
            *error = PMSError(PatchManifestSyncErrorCacheDirectoryUnavailable,
                              @"The LimbusCompany fsCachedData cache directory is unavailable.");
        }
        return NO;
    }

    NSString *manifestPath = PMFindManifestPath();
    if (manifestPath.length == 0) {
        if (error) {
            *error = PMSError(PatchManifestSyncErrorManifestNotFound,
                              @"No cached JSON manifest containing the target FMOD entry was found.");
        }
        return NO;
    }

    return PMPatchManifestAtPath(manifestPath, error);
}

@end
