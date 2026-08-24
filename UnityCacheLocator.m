// UnityCacheLocator.m — see the header for the why/shape.

#import "UnityCacheLocator.h"
#import "UnityBundleCAB.h"
#import "GDFileIndex.h" // 2 - cached CAB map, see +allBundlePathsForCAB: below
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
    // 2 - GDFileIndex.h builds and maintains exactly this CAB -> path
    // map once at startup (refreshed only when UnityCache/Shared's own
    // contents actually change - see that class's header), specifically
    // so this method doesn't re-open and re-parse every cached file on
    // every single call the way the live scan below always used to. Only
    // fall back to that live scan if the index hasn't been built AT ALL
    // this session (+hasIndex false) - shouldn't happen in practice,
    // since fps120.m kicks the index off on its own background thread at
    // dylib load and every real caller of this method only ever runs off
    // a person's own interaction with the Mods panel, well after that -
    // but this method has no way to enforce that ordering itself, so it
    // stays correct (if slow, same as before) rather than assuming it.
    if ([GDFileIndex hasIndex]) {
        return [GDFileIndex cachedPathsForCAB:cab] ?: @[];
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

+ (nullable NSString *)synthesizeCacheDirectoryForHash1:(NSString *)hash1 hash2:(NSString *)hash2 error:(NSError **)error {
    if (hash1.length == 0 || hash2.length == 0) {
        if (error) *error = UCLError(UnityCacheLocatorErrorSynthesisFailed, @"Missing hash1/hash2 - nothing to synthesize a path from.");
        return nil;
    }

    // Prefer an already-discovered UnityCache/Shared root (the game has
    // cached SOMETHING before, even if not this bundle) so the
    // synthesized directory sits alongside real cache entries rather
    // than in a second, parallel UnityCache tree this class had to
    // guess the location of. Only fall back to the canonical
    // Library/UnityCache/Shared path outright when nothing's ever been
    // cached at all - see +unityCacheSharedDirectories' own header for
    // why that's still the confirmed on-device shape either way.
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
