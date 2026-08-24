// GDFileIndex.m — see the header for the why/shape.

#import "GDFileIndex.h"
#import "GDScripts.h"       // g_fileIndexSnapshot / gd_*_file_index_snapshot* / gd_load_settings_dictionary
#import "UnityBundleCAB.h"
#import "UnityCacheLocator.h" // +unityCacheSharedDirectories - same root-discovery this class already had
#import "BankTransplant.h"    // +mobileFMODBuildsDirectory
#import "ZTweakLog.h"

// In-memory copies of what's currently trusted - populated by
// +ensureIndexUpToDate, either freshly built or reloaded as-is from
// last session's settings JSON. Kept separate from g_fileIndexSnapshot
// (GDScripts.h's raw, JSON-shaped blob) since callers here want a real
// NSSet for the FMOD names and don't want to re-derive that from the
// array on every call.
static NSDictionary<NSString *, NSArray<NSString *> *> *s_cabMap = nil;
static NSSet<NSString *> *s_fmodNames = nil;
static BOOL s_hasIndex = NO;

@implementation GDFileIndex

#pragma mark - Cheap pass: fingerprinting

// Stat-only walk (NSDirectoryEnumerator with resource keys prefetched,
// no file content ever read) across every root in `roots`, folded into
// one (file count, total byte size, newest modification date)
// fingerprint. Never reads UnityFS headers, never LZ4-decodes anything -
// this is the part that's safe to run on every single launch regardless
// of how many thousands of files are down there.
+ (NSDictionary *)gdfi_fingerprintForRoots:(NSArray<NSString *> *)roots {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger fileCount = 0;
    unsigned long long totalSize = 0;
    NSTimeInterval newestModified = 0;

    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLContentModificationDateKey];

    for (NSString *root in roots) {
        NSDirectoryEnumerator<NSURL *> *walker =
            [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
     includingPropertiesForKeys:keys
                        options:0
                   errorHandler:^BOOL(NSURL *url, NSError *error) {
                       return YES; // skip the one bad entry, keep walking
                   }];
        for (NSURL *fileURL in walker) {
            NSNumber *isRegular = nil;
            [fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
            if (!isRegular.boolValue) continue;

            NSNumber *size = nil;
            [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            NSDate *modified = nil;
            [fileURL getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];

            fileCount++;
            totalSize += size.unsignedLongLongValue;
            NSTimeInterval modInterval = modified.timeIntervalSince1970;
            if (modInterval > newestModified) newestModified = modInterval;
        }
    }

    return @{
        @"fileCount": @(fileCount),
        @"totalSize": @(totalSize),
        @"newestModified": @(newestModified),
    };
}

#pragma mark - Expensive pass: CAB parsing

// The actual per-file UnityFS/CAB parse this whole class exists to
// avoid running redundantly - same shape as the old
// +[UnityCacheLocator allBundlePathsForCAB:] live scan, except it builds
// a CAB -> [paths] map for every CAB it finds in one pass instead of
// filtering for one specific CAB at a time.
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)gdfi_buildCABMapForRoots:(NSArray<NSString *> *)roots {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *map = [NSMutableDictionary dictionary];
    NSUInteger filesScanned = 0;

    for (NSString *root in roots) {
        NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
        NSString *relPath;
        while ((relPath = [walker nextObject])) {
            NSDictionary<NSFileAttributeKey, id> *attrs = walker.fileAttributes;
            if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;

            NSString *fullPath = [root stringByAppendingPathComponent:relPath];
            filesScanned++;

            // Same "every regular file gets tried, UnityBundleCAB's own
            // signature check rejects non-UnityFS files cheaply" logic
            // as the old live scan - most files under a Unity cache tree
            // aren't standalone bundles (manifests, partial downloads,
            // etc.) and a per-file miss here is completely expected, not
            // logged.
            NSError *fileErr = nil;
            NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:fullPath error:&fileErr];
            if (cab.length == 0) continue;

            NSMutableArray<NSString *> *bucket = map[cab];
            if (!bucket) {
                bucket = [NSMutableArray array];
                map[cab] = bucket;
            }
            [bucket addObject:fullPath];
        }
    }

    // Newest-modified first within each CAB's bucket - same convention
    // the old live scan used, for the same reason (prefer the most
    // recently (re)downloaded copy when more than one cache entry
    // happens to carry the same CAB).
    for (NSString *cab in map) {
        [map[cab] sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *da = [fm attributesOfItemAtPath:a error:nil][NSFileModificationDate];
            NSDate *db = [fm attributesOfItemAtPath:b error:nil][NSFileModificationDate];
            return [db compare:da ?: NSDate.distantPast];
        }];
    }

    ZLog(@"[GDFileIndex] rebuilt CAB index: %lu file(s) scanned under UnityCache/Shared, %lu distinct CAB(s) found",
         (unsigned long)filesScanned, (unsigned long)map.count);

    return map;
}

#pragma mark - Public API

+ (void)ensureIndexUpToDate {
    @synchronized (self) {
        gd_ensure_file_index_snapshot_loaded();
        NSDictionary *saved = g_fileIndexSnapshot ?: @{};
        NSDictionary *savedUnityFP = [saved[@"unityCacheFingerprint"] isKindOfClass:[NSDictionary class]] ? saved[@"unityCacheFingerprint"] : nil;
        NSDictionary *savedFMODFP  = [saved[@"fmodFingerprint"] isKindOfClass:[NSDictionary class]] ? saved[@"fmodFingerprint"] : nil;

        NSArray<NSString *> *unityRoots = [UnityCacheLocator unityCacheSharedDirectories];
        NSDictionary *currentUnityFP = [self gdfi_fingerprintForRoots:unityRoots];

        NSString *fmodDir = [BankTransplant mobileFMODBuildsDirectory];
        NSDictionary *currentFMODFP = [self gdfi_fingerprintForRoots:fmodDir ? @[fmodDir] : @[]];

        BOOL unityChanged = savedUnityFP == nil || ![currentUnityFP isEqual:savedUnityFP];
        BOOL fmodChanged  = savedFMODFP  == nil || ![currentFMODFP  isEqual:savedFMODFP];

        NSDictionary<NSString *, NSArray<NSString *> *> *cabMap;
        if (!unityChanged && [saved[@"unityCacheCABMap"] isKindOfClass:[NSDictionary class]]) {
            cabMap = saved[@"unityCacheCABMap"];
            ZLog(@"[GDFileIndex] UnityCache/Shared unchanged since last index (%@) - reusing %lu cached CAB entr%@",
                 currentUnityFP, (unsigned long)cabMap.count, cabMap.count == 1 ? @"y" : @"ies");
        } else {
            cabMap = [self gdfi_buildCABMapForRoots:unityRoots];
        }

        NSArray<NSString *> *fmodNamesArr;
        if (!fmodChanged && [saved[@"fmodFileNames"] isKindOfClass:[NSArray class]]) {
            fmodNamesArr = saved[@"fmodFileNames"];
        } else {
            fmodNamesArr = fmodDir ? ([NSFileManager.defaultManager contentsOfDirectoryAtPath:fmodDir error:nil] ?: @[]) : @[];
            ZLog(@"[GDFileIndex] FMOD mobile builds folder changed or never indexed - listed %lu file(s)", (unsigned long)fmodNamesArr.count);
        }

        s_cabMap = cabMap;
        s_fmodNames = [NSSet setWithArray:fmodNamesArr];
        s_hasIndex = YES;

        // Only actually rewrite the settings JSON when something's
        // different from what's already on file - an unchanged relaunch
        // shouldn't touch disk just to write back the exact same
        // fingerprints/map it just read.
        if (unityChanged || fmodChanged) {
            NSDictionary *snapshot = @{
                @"unityCacheFingerprint": currentUnityFP,
                @"fmodFingerprint": currentFMODFP,
                @"unityCacheCABMap": cabMap,
                @"fmodFileNames": fmodNamesArr,
            };
            gd_set_file_index_snapshot(snapshot);
        }
    }
}

+ (void)forceReindex {
    @synchronized (self) {
        NSArray<NSString *> *unityRoots = [UnityCacheLocator unityCacheSharedDirectories];
        NSDictionary *currentUnityFP = [self gdfi_fingerprintForRoots:unityRoots];

        NSString *fmodDir = [BankTransplant mobileFMODBuildsDirectory];
        NSDictionary *currentFMODFP = [self gdfi_fingerprintForRoots:fmodDir ? @[fmodDir] : @[]];

        // Both passes always run here, unlike +ensureIndexUpToDate -
        // that's the entire point of this method (see this file's own
        // header on why the fingerprint short-circuit sometimes needs
        // to be bypassed by hand).
        NSDictionary<NSString *, NSArray<NSString *> *> *cabMap = [self gdfi_buildCABMapForRoots:unityRoots];
        NSArray<NSString *> *fmodNamesArr = fmodDir ? ([NSFileManager.defaultManager contentsOfDirectoryAtPath:fmodDir error:nil] ?: @[]) : @[];

        s_cabMap = cabMap;
        s_fmodNames = [NSSet setWithArray:fmodNamesArr];
        s_hasIndex = YES;

        // Always rewritten here (unlike +ensureIndexUpToDate, which
        // skips the write when nothing changed) - the person tapped a
        // button specifically to force this, so the on-disk snapshot's
        // timestamp/content should reflect that even if it happens to
        // come out identical to what was already there.
        NSDictionary *snapshot = @{
            @"unityCacheFingerprint": currentUnityFP,
            @"fmodFingerprint": currentFMODFP,
            @"unityCacheCABMap": cabMap,
            @"fmodFileNames": fmodNamesArr,
        };
        gd_set_file_index_snapshot(snapshot);

        NSUInteger totalIndexedFiles = 0;
        for (NSArray<NSString *> *paths in cabMap.allValues) totalIndexedFiles += paths.count;
        ZLog(@"[GDFileIndex] manual re-index forced: %lu CAB(s) across %lu file(s), %lu FMOD file name(s)",
             (unsigned long)cabMap.count, (unsigned long)totalIndexedFiles, (unsigned long)fmodNamesArr.count);
    }
}

+ (nullable NSArray<NSString *> *)cachedPathsForCAB:(NSString *)cab {
    if (!s_hasIndex) return nil;
    NSArray<NSString *> *paths = s_cabMap[cab];
    if (paths.count == 0) return @[];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *existing = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) [existing addObject:path];
    }
    return existing;
}

+ (BOOL)hasIndex {
    return s_hasIndex;
}

+ (NSSet<NSString *> *)cachedFMODBankFileNames {
    return s_fmodNames ?: [NSSet set];
}

@end
