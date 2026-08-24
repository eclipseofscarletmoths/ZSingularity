
#import "UnityCacheLocator.h"
#import "UnityBundleCAB.h"
#import "ZSFileIndex.h"
#import "ZTweakLog.h"

NSString * const UnityCacheLocatorErrorDomain = @"UnityCacheLocatorErrorDomain";

static NSError *UCLError(UnityCacheLocatorErrorCode code, NSString *message) {
    return [NSError errorWithDomain:UnityCacheLocatorErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation UnityCacheLocator

#pragma mark - Discovering UnityCache/Shared roots

static const NSUInteger kUCLMaxSearchDepth = 6;

static void ucl_search(NSString *dirPath, NSUInteger depthRemaining, NSMutableArray<NSString *> *found) {
    if (depthRemaining == 0) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dirPath error:&listErr];
    if (!entries) return;

    for (NSString *entry in entries) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;

        if ([entry isEqualToString:@"Shared"] && [dirPath.lastPathComponent isEqualToString:@"UnityCache"]) {
            [found addObject:fullPath];
            continue;
        }
        ucl_search(fullPath, depthRemaining - 1, found);
    }
}

+ (NSArray<NSString *> *)unityCacheSharedDirectories {
    NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = libraryPaths.firstObject;
    if (!libraryDir) return @[];

    NSMutableArray<NSString *> *found = [NSMutableArray array];
    ucl_search(libraryDir, kUCLMaxSearchDepth, found);
    return found;
}

#pragma mark - CAB lookups

+ (nullable NSString *)cabForBundleAtPath:(NSString *)moddedOrDoctoredBundlePath error:(NSError **)error {
    NSError *underlying = nil;
    NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:moddedOrDoctoredBundlePath error:&underlying];
    if (!cab) {
        if (error) {
            *error = UCLError(UnityCacheLocatorErrorSourceCABUnreadable,
                [NSString stringWithFormat:@"Couldn't read a CAB off %@: %@",
                    moddedOrDoctoredBundlePath.lastPathComponent,
                    underlying.localizedDescription ?: @"unknown error"]);
        }
        return nil;
    }
    return cab;
}

+ (NSArray<NSString *> *)allBundlePathsForCAB:(NSString *)cab {

    if ([ZSFileIndex hasIndex]) {
        return [ZSFileIndex cachedPathsForCAB:cab] ?: @[];
    }

    ZLog(@"[UnityCacheLocator] file index not built yet this session - falling back to a live scan for CAB %@", cab);

    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *root in [self unityCacheSharedDirectories]) {
        NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
        NSString *relPath;
        while ((relPath = [walker nextObject])) {
            NSDictionary<NSFileAttributeKey, id> *attrs = walker.fileAttributes;
            if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;

            NSString *fullPath = [root stringByAppendingPathComponent:relPath];

            NSError *fileErr = nil;
            NSString *fileCAB = [UnityBundleCAB primaryCABForBundleAtPath:fullPath error:&fileErr];
            if (fileCAB && [fileCAB isEqualToString:cab]) {
                [matches addObject:fullPath];
            }
        }
    }

    [matches sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fm attributesOfItemAtPath:a error:nil][NSFileModificationDate];
        NSDate *db = [fm attributesOfItemAtPath:b error:nil][NSFileModificationDate];
        return [db compare:da ?: NSDate.distantPast];
    }];

    if (matches.count > 0) {
        ZLog(@"[UnityCacheLocator] CAB %@ matched %lu cached file(s), using %@",
             cab, (unsigned long)matches.count, matches.firstObject);
    }

    return matches;
}

+ (nullable NSString *)locateBundlePathForCAB:(NSString *)cab error:(NSError **)error {
    NSArray<NSString *> *roots = [self unityCacheSharedDirectories];
    if (roots.count == 0) {
        if (error) {
            *error = UCLError(UnityCacheLocatorErrorSharedDirectoryNotFound,
                @"No UnityCache/Shared directory found under Library.");
        }
        return nil;
    }

    NSArray<NSString *> *matches = [self allBundlePathsForCAB:cab];
    if (matches.count == 0) {
        if (error) {
            *error = UCLError(UnityCacheLocatorErrorNoMatch,
                [NSString stringWithFormat:@"No cached bundle under UnityCache/Shared reports CAB %@ as its own identity.", cab]);
        }
        return nil;
    }

    return matches.firstObject;
}

+ (nullable NSString *)synthesizeCacheDirectoryForHash1:(NSString *)hash1 hash2:(NSString *)hash2 error:(NSError **)error {
    if (hash1.length == 0 || hash2.length == 0) {
        if (error) *error = UCLError(UnityCacheLocatorErrorSynthesisFailed, @"Missing hash1/hash2 - nothing to synthesize a path from.");
        return nil;
    }

    NSArray<NSString *> *roots = [self unityCacheSharedDirectories];
    NSString *root = roots.firstObject;
    if (!root) {
        NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libraryDir = libraryPaths.firstObject;
        if (!libraryDir) {
            if (error) *error = UCLError(UnityCacheLocatorErrorSynthesisFailed, @"Couldn't resolve this app's own Library directory.");
            return nil;
        }
        root = [libraryDir stringByAppendingPathComponent:@"UnityCache/Shared"];
    }

    NSString *dirPath = [[root stringByAppendingPathComponent:hash1] stringByAppendingPathComponent:hash2];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *mkdirErr = nil;
    if (![fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
        if (error) *error = mkdirErr ?: UCLError(UnityCacheLocatorErrorSynthesisFailed,
            [NSString stringWithFormat:@"Couldn't create %@.", dirPath]);
        return nil;
    }

    ZLog(@"[UnityCacheLocator] SYNTHESIZED (unverified) cache directory at %@ - see +synthesizeCacheDirectoryForHash1:hash2:error:'s own header caveat", dirPath);
    return dirPath;
}

@end

