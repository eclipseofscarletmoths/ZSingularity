
#import "ZSFileIndex.h"
#import "ZSScripts.h"
#import "UnityBundleCAB.h"
#import "UnityCacheLocator.h"
#import "BankTransplant.h"
#import "ZTweakLog.h"

static NSDictionary<NSString *, NSArray<NSString *> *> *s_cabMap = nil;
static NSSet<NSString *> *s_fmodNames = nil;
static BOOL s_hasIndex = NO;

@implementation ZSFileIndex

#pragma mark - Cheap pass: fingerprinting

+ (NSDictionary *)zsfi_fingerprintForRoots:(NSArray<NSString *> *)roots {
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
                       return YES;
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

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)zsfi_buildCABMapForRoots:(NSArray<NSString *> *)roots {
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

    for (NSString *cab in map) {
        [map[cab] sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *da = [fm attributesOfItemAtPath:a error:nil][NSFileModificationDate];
            NSDate *db = [fm attributesOfItemAtPath:b error:nil][NSFileModificationDate];
            return [db compare:da ?: NSDate.distantPast];
        }];
    }

    ZLog(@"[ZSFileIndex] rebuilt CAB index: %lu file(s) scanned under UnityCache/Shared, %lu distinct CAB(s) found",
         (unsigned long)filesScanned, (unsigned long)map.count);

    return map;
}

#pragma mark - Public API

+ (void)ensureIndexUpToDate {
    @synchronized (self) {
        zs_ensure_file_index_snapshot_loaded();
        NSDictionary *saved = g_fileIndexSnapshot ?: @{};
        NSDictionary *savedUnityFP = [saved[@"unityCacheFingerprint"] isKindOfClass:[NSDictionary class]] ? saved[@"unityCacheFingerprint"] : nil;
        NSDictionary *savedFMODFP  = [saved[@"fmodFingerprint"] isKindOfClass:[NSDictionary class]] ? saved[@"fmodFingerprint"] : nil;

        NSArray<NSString *> *unityRoots = [UnityCacheLocator unityCacheSharedDirectories];
        NSDictionary *currentUnityFP = [self zsfi_fingerprintForRoots:unityRoots];

        NSString *fmodDir = [BankTransplant mobileFMODBuildsDirectory];
        NSDictionary *currentFMODFP = [self zsfi_fingerprintForRoots:fmodDir ? @[fmodDir] : @[]];

        BOOL unityChanged = savedUnityFP == nil || ![currentUnityFP isEqual:savedUnityFP];
        BOOL fmodChanged  = savedFMODFP  == nil || ![currentFMODFP  isEqual:savedFMODFP];

        NSDictionary<NSString *, NSArray<NSString *> *> *cabMap;
        if (!unityChanged && [saved[@"unityCacheCABMap"] isKindOfClass:[NSDictionary class]]) {
            cabMap = saved[@"unityCacheCABMap"];
            ZLog(@"[ZSFileIndex] UnityCache/Shared unchanged since last index (%@) - reusing %lu cached CAB entr%@",
                 currentUnityFP, (unsigned long)cabMap.count, cabMap.count == 1 ? @"y" : @"ies");
        } else {
            cabMap = [self zsfi_buildCABMapForRoots:unityRoots];
        }

        NSArray<NSString *> *fmodNamesArr;
        if (!fmodChanged && [saved[@"fmodFileNames"] isKindOfClass:[NSArray class]]) {
            fmodNamesArr = saved[@"fmodFileNames"];
        } else {
            fmodNamesArr = fmodDir ? ([NSFileManager.defaultManager contentsOfDirectoryAtPath:fmodDir error:nil] ?: @[]) : @[];
            ZLog(@"[ZSFileIndex] FMOD mobile builds folder changed or never indexed - listed %lu file(s)", (unsigned long)fmodNamesArr.count);
        }

        s_cabMap = cabMap;
        s_fmodNames = [NSSet setWithArray:fmodNamesArr];
        s_hasIndex = YES;

        if (unityChanged || fmodChanged) {
            NSDictionary *snapshot = @{
                @"unityCacheFingerprint": currentUnityFP,
                @"fmodFingerprint": currentFMODFP,
                @"unityCacheCABMap": cabMap,
                @"fmodFileNames": fmodNamesArr,
            };
            zs_set_file_index_snapshot(snapshot);
        }
    }
}

+ (void)forceReindex {
    @synchronized (self) {
        NSArray<NSString *> *unityRoots = [UnityCacheLocator unityCacheSharedDirectories];
        NSDictionary *currentUnityFP = [self zsfi_fingerprintForRoots:unityRoots];

        NSString *fmodDir = [BankTransplant mobileFMODBuildsDirectory];
        NSDictionary *currentFMODFP = [self zsfi_fingerprintForRoots:fmodDir ? @[fmodDir] : @[]];

        NSDictionary<NSString *, NSArray<NSString *> *> *cabMap = [self zsfi_buildCABMapForRoots:unityRoots];
        NSArray<NSString *> *fmodNamesArr = fmodDir ? ([NSFileManager.defaultManager contentsOfDirectoryAtPath:fmodDir error:nil] ?: @[]) : @[];

        s_cabMap = cabMap;
        s_fmodNames = [NSSet setWithArray:fmodNamesArr];
        s_hasIndex = YES;

        NSDictionary *snapshot = @{
            @"unityCacheFingerprint": currentUnityFP,
            @"fmodFingerprint": currentFMODFP,
            @"unityCacheCABMap": cabMap,
            @"fmodFileNames": fmodNamesArr,
        };
        zs_set_file_index_snapshot(snapshot);

        NSUInteger totalIndexedFiles = 0;
        for (NSArray<NSString *> *paths in cabMap.allValues) totalIndexedFiles += paths.count;
        ZLog(@"[ZSFileIndex] manual re-index forced: %lu CAB(s) across %lu file(s), %lu FMOD file name(s)",
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

