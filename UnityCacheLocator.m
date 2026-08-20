// UnityCacheLocator.m — see the header for the why/shape.

#import "UnityCacheLocator.h"
#import "UnityBundleCAB.h"
#import "ZTweakLog.h"

NSString * const UnityCacheLocatorErrorDomain = @"UnityCacheLocatorErrorDomain";

static NSError *UCLError(UnityCacheLocatorErrorCode code, NSString *message) {
    return [NSError errorWithDomain:UnityCacheLocatorErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation UnityCacheLocator

#pragma mark - Discovering UnityCache/Shared roots

// Bounded-depth walk of this app's own Library directory looking for a
// directory named "Shared" whose immediate parent is named "UnityCache" -
// confirmed on-device as Library/UnityCache/Shared directly (no Caches/
// company/product nesting above it - see this file's header). Depth is
// still capped (not unbounded recursion), purely so a pathological
// directory tree (symlink loop, something unexpected) can't hang this;
// two levels is all the confirmed shape needs, with headroom to spare.
static const NSUInteger kUCLMaxSearchDepth = 6;

static void ucl_search(NSString *dirPath, NSUInteger depthRemaining, NSMutableArray<NSString *> *found) {
    if (depthRemaining == 0) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dirPath error:&listErr];
    if (!entries) return; // unreadable/nonexistent - nothing to contribute from here

    for (NSString *entry in entries) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;

        if ([entry isEqualToString:@"Shared"] && [dirPath.lastPathComponent isEqualToString:@"UnityCache"]) {
            [found addObject:fullPath];
            continue; // a Shared dir's own contents are cache payloads, not further nesting to search into
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
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *root in [self unityCacheSharedDirectories]) {
        NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
        NSString *relPath;
        while ((relPath = [walker nextObject])) {
            NSDictionary<NSFileAttributeKey, id> *attrs = walker.fileAttributes;
            if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;

            NSString *fullPath = [root stringByAppendingPathComponent:relPath];

            // Every regular file gets tried - UnityBundleCAB's own
            // signature check rejects non-UnityFS files cheaply (a
            // handful of bytes) rather than this class second-guessing
            // which sidecar files (manifest/info/partial-download) are
            // worth trying based on an unconfirmed naming convention.
            // A per-file failure here (not a UnityFS bundle, truncated,
            // unsupported compression, etc.) is completely expected for
            // most of what's under a cache tree - not logged per-file,
            // since that would be noise on every single scan.
            NSError *fileErr = nil;
            NSString *fileCAB = [UnityBundleCAB primaryCABForBundleAtPath:fullPath error:&fileErr];
            if (fileCAB && [fileCAB isEqualToString:cab]) {
                [matches addObject:fullPath];
            }
        }
    }

    // Newest-modified first, so the caller's "just give me the one to
    // use" convenience below picks the most recently (re)downloaded
    // copy when more than one cache entry happens to carry the same
    // CAB (e.g. a stale duplicate left behind by a prior cache-clear
    // that didn't fully clear).
    [matches sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fm attributesOfItemAtPath:a error:nil][NSFileModificationDate];
        NSDate *db = [fm attributesOfItemAtPath:b error:nil][NSFileModificationDate];
        return [db compare:da ?: NSDate.distantPast]; // descending: newest first
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

@end
