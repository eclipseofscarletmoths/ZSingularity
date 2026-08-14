// PatchManifestSync.m

#import "PatchManifestSync.h"
#import <dispatch/dispatch.h>
#import "ZTweakLog.h"

NSString * const PatchManifestSyncErrorDomain = @"PatchManifestSyncErrorDomain";

static NSString * const kTargetFMODPath = @"Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank";
static NSString * const kPatchedMD5 = @"fbe98ef9f57aff80c58ada46c4f8af92";
static const unsigned long long kPatchedSize = 57408616ULL;
static NSTimeInterval const kPollInterval = 0.10;
static dispatch_once_t g_trackerOnce;

static NSString *PMSManifestRoot(void) {
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (library.length == 0) return nil;
    return [library stringByAppendingPathComponent:@"Caches/com.ProjectMoon.LimbusCompany/fsCachedData"];
}

static BOOL PMSLooksLikeFMODManifest(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return NO;
    if (![json[@"Version"] isKindOfClass:[NSString class]]) return NO;
    if (![json[@"Files"] isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *files = json[@"Files"];
    return [files[kTargetFMODPath] isKindOfClass:[NSDictionary class]];
}

static NSArray<NSString *> *PMSCandidateFiles(NSString *root) {
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:root];
    if (!enumerator) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        NSString *full = [root stringByAppendingPathComponent:relative];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        unsigned long long size = [attrs fileSize];
        // The real manifest in the supplied cache is ~355 KB. Keep a wide
        // bound so this still catches an updated manifest without blindly
        // loading arbitrary multi-megabyte cache blobs.
        if (size == 0 || size > 2 * 1024 * 1024) continue;
        [out addObject:full];
    }
    return out;
}

static BOOL PMSPatchManifestFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data || data.length == 0) return NO;

    NSError *jsonError = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    if (!PMSLooksLikeFMODManifest(obj)) return NO;

    NSMutableDictionary *root = (NSMutableDictionary *)obj;
    NSMutableDictionary *files = [root[@"Files"] mutableCopy];
    NSMutableDictionary *entry = [files[kTargetFMODPath] mutableCopy];
    if (!entry) return NO;

    NSString *oldHash = [entry[@"Hash"] isKindOfClass:[NSString class]] ? entry[@"Hash"] : nil;
    NSNumber *oldSize = [entry[@"Size"] isKindOfClass:[NSNumber class]] ? entry[@"Size"] : nil;

    if ([oldHash isEqualToString:kPatchedMD5] && oldSize.unsignedLongLongValue == kPatchedSize) {
        return NO;
    }

    entry[@"Hash"] = kPatchedMD5;
    entry[@"Size"] = @(kPatchedSize);
    files[kTargetFMODPath] = entry;
    root[@"Files"] = files;

    // Preserve the game's normal JSON semantics rather than attempting to
    // hand-edit the bytes. The cache entry is plain UTF-8 JSON in the supplied
    // cache, and NSJSONSerialization keeps this robust across key ordering.
    NSError *writeError = nil;
    NSData *patched = [NSJSONSerialization dataWithJSONObject:root options:0 error:&writeError];
    if (!patched) {
        ZLog(@"[PatchManifestSync] JSON serialization failed for %@: %@", path, writeError);
        return NO;
    }

    // Atomic replacement: write a sibling temp file, preserve the existing
    // file attributes where possible, then replace the original.
    NSString *tmp = [path stringByAppendingFormat:@".zsingularity.%@.tmp", NSUUID.UUID.UUIDString];
    if (![patched writeToFile:tmp options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[PatchManifestSync] failed writing temporary manifest %@: %@", tmp, writeError);
        return NO;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attrs) {
        [[NSFileManager defaultManager] setAttributes:@{
            NSFileProtectionKey: attrs[NSFileProtectionKey] ?: NSFileProtectionNone,
            NSFilePosixPermissions: attrs[NSFilePosixPermissions] ?: @0644
        } ofItemAtPath:tmp error:NULL];
    }

    BOOL ok = [[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:path]
                                                 withItemAtURL:[NSURL fileURLWithPath:tmp]
                                                backupItemName:nil
                                                       options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                              resultingItemURL:NULL
                                                         error:&writeError];
    if (!ok) {
        // ReplaceItem can fail on some cache implementations; fall back to a
        // direct move only if the original has disappeared between reads.
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        ZLog(@"[PatchManifestSync] atomic replacement failed for %@: %@", path, writeError);
        return NO;
    }

    ZLog(@"[PatchManifestSync] patched fresh FMOD manifest %@: %@ / %llu -> %@ / %llu",
         path,
         oldHash ?: @"<missing>",
         oldSize.unsignedLongLongValue,
         kPatchedMD5,
         kPatchedSize);
    return YES;
}

static void PMSScanOnce(void) {
    NSString *root = PMSManifestRoot();
    if (root.length == 0) return;

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir) return;

    NSArray<NSString *> *candidates = PMSCandidateFiles(root);
    for (NSString *path in candidates) {
        @autoreleasepool {
            (void)PMSPatchManifestFile(path);
        }
    }
}

@implementation PatchManifestSync

+ (void)startManifestTracker {
    dispatch_once(&g_trackerOnce, ^{
        ZLog(@"[PatchManifestSync] starting FMOD manifest tracker");

        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        if (!timer) {
            ZLog(@"[PatchManifestSync] failed to create tracker timer");
            return;
        }

        uint64_t interval = (uint64_t)(kPollInterval * (double)NSEC_PER_SEC);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  interval,
                                  20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            PMSScanOnce();
        });
        dispatch_source_set_cancel_handler(timer, ^{});
        dispatch_resume(timer);

        // Keep the source retained for the life of the process via a static.
        // The dispatch source itself is intentionally never cancelled.
        static dispatch_source_t s_timer;
        s_timer = timer;
    });
}

@end
