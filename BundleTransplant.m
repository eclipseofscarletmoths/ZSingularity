// BundleTransplant.m
//
// See BundleTransplant.h. Three phases per call to
// +transplantAndSwapModdedBundlesAtURLs:error: -
//   1. bt2_find_all_data_files: recursive walk of Library/UnityCache/Shared,
//      collecting every path to a file literally named "__data".
//   2. bt2_build_cab_index: parses each of those (UnityBundleCAB.h) to build
//      a CAB -> [paths] dictionary. This is the expensive part ("thousands
//      of bundles" per the project notes) - parallelized with dispatch_apply
//      the same way BankTransplant.m's per-sample re-encode loop is, since
//      each file's header parse is fully independent of every other one.
//   3. For each modded URL: extract its own CAB, look it up in the index
//      from step 2, and swap every matching path.
//
// Building the whole index up front (rather than walking the cache once
// per modded file) is what keeps a multi-select import from being O(mods x
// cache size) - it's one O(cache size) pass total, however many mods were
// picked.

#import "BundleTransplant.h"
#import "UnityBundleCAB.h"
#import "ZTweakLog.h"
#import <dispatch/dispatch.h>

NSString * const BundleTransplantErrorDomain = @"BundleTransplantErrorDomain";
static NSString * const kBT2BackupSuffix = @".orig-bak";

@implementation BundleTransplantResult
@end

static NSError *BT2Error(BundleTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:BundleTransplantErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Backups used to live as "__data.orig-bak" right next to __data in the
// SAME UnityCache/Shared folder - same mistake made (and already fixed)
// on the audio side, see BankTransplant.m's bankBackupDirectory note.
// Whatever validates a cache folder treated that extra sibling file as
// reason to flag the entry and force a redownload, and since it's written
// once and just sits there, the flag came back on every subsequent
// launch, not only the one where the swap happened.
//
// Backups now live under +bundleBackupDirectory instead (this tweak's own
// Library directory, isolated from anything Unity's cache scans), keyed
// by dataPath's location RELATIVE to +unityCacheSharedDirectory with "/"
// percent-encoded to "%2F" so the whole nested path collapses to one flat,
// reversible filename - every cached bundle is literally named "__data"
// (per BundleTransplant.h), so the leaf name alone can't disambiguate
// which of potentially thousands of them a given backup belongs to; only
// the full relative path can. bt2_restore_original_path_for_backup_name
// below is the inverse of this encoding, used by the restore walk.
static NSString *bt2_relative_path(NSString *fullPath, NSString *root) {
    if ([fullPath hasPrefix:root]) {
        NSString *rel = [fullPath substringFromIndex:root.length];
        if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
        return rel;
    }
    return fullPath.lastPathComponent; // shouldn't happen; harmless fallback
}

static NSString *bt2_backup_path_for_data_path(NSString *dataPath, NSString *cacheDir, NSString *backupDir) {
    NSString *rel = bt2_relative_path(dataPath, cacheDir);
    NSString *flat = [rel stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
    return [backupDir stringByAppendingPathComponent:[flat stringByAppendingString:kBT2BackupSuffix]];
}

// Inverse of the encoding above: given a backup file's own name (not its
// full path), returns the original __data path it belongs to under
// cacheDir. Returns nil if `backupName` doesn't have the expected suffix.
static NSString *bt2_original_path_for_backup_name(NSString *backupName, NSString *cacheDir) {
    if (![backupName hasSuffix:kBT2BackupSuffix]) return nil;
    NSString *flat = [backupName substringToIndex:backupName.length - kBT2BackupSuffix.length];
    NSString *rel = [flat stringByReplacingOccurrencesOfString:@"%2F" withString:@"/"];
    return [cacheDir stringByAppendingPathComponent:rel];
}

#pragma mark - Phase 1: recursive __data discovery

// No assumed depth (see BundleTransplant.h) - just every regular file
// anywhere under root whose name is exactly "__data".
static NSArray<NSString *> *bt2_find_all_data_files(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *relPath in walker) {
        if (![relPath.lastPathComponent isEqualToString:@"__data"]) continue;
        [found addObject:[root stringByAppendingPathComponent:relPath]];
    }
    return found;
}

#pragma mark - Phase 2: CAB index (parallel parse, serial merge)

// One entry per discovered __data path, filled in concurrently by
// dispatch_apply, then merged into the CAB -> [paths] dictionary
// single-threaded (avoids needing a lock around the dictionary itself -
// each slot in this array is written by exactly one iteration, so the
// concurrent phase has no shared mutable state at all).
typedef struct {
    __unsafe_unretained NSString *path;
    __unsafe_unretained NSString *cab; // nil if this file's CAB couldn't be parsed
} BT2IndexEntry;

static NSDictionary<NSString *, NSArray<NSString *> *> *bt2_build_cab_index(NSArray<NSString *> *dataPaths) {
    NSUInteger count = dataPaths.count;
    if (count == 0) return @{};

    NSMutableArray<NSString *> *cabs = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [cabs addObject:NSNull.null]; // placeholder, overwritten below

    // dispatch_apply blocks the calling thread until every iteration
    // completes, so `cabs` (accessed by index only, never resized during
    // this loop) is safe to write into from each concurrent iteration
    // without further synchronization.
    dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        NSString *path = dataPaths[i];
        NSError *cabErr = nil;
        NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:path error:&cabErr];
        @synchronized (cabs) { // only the array's storage needs protection; each index is still touched once
            cabs[i] = cab ?: NSNull.null;
        }
        if (!cab) {
            ZLog(@"[BundleTransplant] couldn't read CAB for %@: %@", path, cabErr.localizedDescription);
        }
    });

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *index = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        id cab = cabs[i];
        if (cab == NSNull.null) continue;
        NSMutableArray<NSString *> *paths = index[cab];
        if (!paths) {
            paths = [NSMutableArray array];
            index[cab] = paths;
        }
        [paths addObject:dataPaths[i]];
    }
    return index;
}

#pragma mark - __info best-effort patch (see header note - heuristic, not a real parser)

// Rewrites a little-endian integer occurrence of oldSize to newSize inside
// infoPath, but ONLY if it appears exactly once as either a 4-byte or
// 8-byte LE integer - any other count (zero, or more than one candidate
// location) is treated as "can't safely tell which bytes those are" and
// left alone. Returns YES if a rewrite was made; this is advisory only,
// callers should not treat NO as an error.
static BOOL bt2_try_patch_info_size(NSString *infoPath, uint64_t oldSize, uint64_t newSize) {
    NSMutableData *info = [NSMutableData dataWithContentsOfFile:infoPath];
    if (!info) return NO;

    uint8_t *bytes = (uint8_t *)info.mutableBytes;
    NSUInteger len = info.length;
    NSMutableArray<NSNumber *> *offsets8 = [NSMutableArray array];
    NSMutableArray<NSNumber *> *offsets4 = [NSMutableArray array];

    if (len >= 8) {
        for (NSUInteger i = 0; i + 8 <= len; i++) {
            uint64_t v = 0;
            memcpy(&v, bytes + i, 8); // little-endian by construction on every device this tweak targets (arm64)
            if (v == oldSize) [offsets8 addObject:@(i)];
        }
    }
    if (oldSize <= UINT32_MAX && len >= 4) {
        uint32_t oldSize32 = (uint32_t)oldSize;
        for (NSUInteger i = 0; i + 4 <= len; i++) {
            uint32_t v = 0;
            memcpy(&v, bytes + i, 4);
            if (v == oldSize32) [offsets4 addObject:@(i)];
        }
    }

    // Prefer an unambiguous 8-byte match over a 4-byte one (less likely
    // to be a coincidental collision in a small file); only ever act on
    // a single unique candidate across the preferred width.
    if (offsets8.count == 1) {
        NSUInteger off = offsets8.firstObject.unsignedIntegerValue;
        uint64_t v = newSize;
        memcpy(bytes + off, &v, 8);
    } else if (offsets8.count == 0 && offsets4.count == 1 && newSize <= UINT32_MAX) {
        NSUInteger off = offsets4.firstObject.unsignedIntegerValue;
        uint32_t v = (uint32_t)newSize;
        memcpy(bytes + off, &v, 4);
    } else {
        ZLog(@"[BundleTransplant] __info at %@: %lu 8-byte + %lu 4-byte candidate offset(s) for the old size - "
              @"ambiguous or not found, leaving __info untouched (see BundleTransplant.h __info note)",
              infoPath, (unsigned long)offsets8.count, (unsigned long)offsets4.count);
        return NO;
    }

    return [info writeToFile:infoPath atomically:YES];
}

#pragma mark - Public API

@implementation BundleTransplant

+ (NSString *)unityCacheSharedDirectory {
    // UnityCache sits directly under Library, NOT under Library/Caches -
    // NSCachesDirectory resolves to the latter, which is a sibling
    // directory that happens to also exist (Library/Caches is the
    // fsCachedData location PatchManifestNetwork deals with) but isn't
    // this one. NSLibraryDirectory is Library
    // itself, matching the actual on-device path.
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *cachesDir = paths.firstObject;
    if (!cachesDir) return nil;
    return [cachesDir stringByAppendingPathComponent:@"UnityCache/Shared"];
}

// Library/ZSingularityBundleBackups inside this app's sandbox - where
// backups of cached bundles live now. Deliberately NOT inside
// +unityCacheSharedDirectory - see the comment above
// bt2_backup_path_for_data_path in this file for why.
+ (NSString *)bundleBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityBundleBackups"];
}

+ (nullable NSArray<BundleTransplantResult *> *)transplantAndSwapModdedBundlesAtURLs:(NSArray<NSURL *> *)moddedURLs
                                                                                  error:(NSError **)error {
    NSString *cacheDir = [self unityCacheSharedDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!cacheDir || ![fm fileExistsAtPath:cacheDir isDirectory:&isDir] || !isDir) {
        if (error) *error = BT2Error(BundleTransplantErrorNoCacheDirectory,
            @"Library/UnityCache/Shared doesn't exist yet - the game may not have cached any bundles this session.");
        return nil;
    }

    ZLog(@"[BundleTransplant] scanning %@ for cached bundles…", cacheDir);
    NSArray<NSString *> *dataPaths = bt2_find_all_data_files(cacheDir);
    ZLog(@"[BundleTransplant] found %lu cached __data file(s), indexing by CAB…", (unsigned long)dataPaths.count);
    NSDictionary<NSString *, NSArray<NSString *> *> *cabIndex = bt2_build_cab_index(dataPaths);
    ZLog(@"[BundleTransplant] indexed %lu distinct CAB(s)", (unsigned long)cabIndex.count);

    NSString *backupDir = [self bundleBackupDirectory];
    if (!backupDir) {
        if (error) *error = BT2Error(BundleTransplantErrorBackupFailed, @"Couldn't resolve the backup directory.");
        return nil;
    }
    if (![fm fileExistsAtPath:backupDir]) {
        NSError *dirErr = nil;
        if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            if (error) *error = BT2Error(BundleTransplantErrorBackupFailed,
                [NSString stringWithFormat:@"Couldn't create the backup directory: %@", dirErr.localizedDescription]);
            return nil;
        }
    }

    NSMutableArray<BundleTransplantResult *> *results = [NSMutableArray arrayWithCapacity:moddedURLs.count];

    for (NSURL *moddedURL in moddedURLs) {
        BundleTransplantResult *result = [BundleTransplantResult new];
        result.moddedFileName = moddedURL.lastPathComponent;
        [results addObject:result];

        BOOL accessing = [moddedURL startAccessingSecurityScopedResource];

        NSError *cabErr = nil;
        NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:moddedURL.path error:&cabErr];
        if (!cab) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            result.error = BT2Error(BundleTransplantErrorModdedCABFailed,
                [NSString stringWithFormat:@"Couldn't read %@'s CAB: %@", result.moddedFileName, cabErr.localizedDescription ?: @"unknown error"]);
            continue;
        }
        result.cab = cab;

        NSArray<NSString *> *matches = cabIndex[cab];
        if (matches.count == 0) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            ZLog(@"[BundleTransplant] %@ (%@) has no match in the cache - nothing to swap", result.moddedFileName, cab);
            continue;
        }

        NSData *moddedData = [NSData dataWithContentsOfURL:moddedURL options:0 error:&cabErr];
        if (!moddedData) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            result.error = BT2Error(BundleTransplantErrorCantReadModded,
                [NSString stringWithFormat:@"Matched %@ CAB(s) but couldn't read %@ itself: %@", @(matches.count), result.moddedFileName, cabErr.localizedDescription]);
            continue;
        }

        NSInteger swapped = 0;
        for (NSString *dataPath in matches) {
            NSString *backupPath = bt2_backup_path_for_data_path(dataPath, cacheDir, backupDir);
            if (![fm fileExistsAtPath:backupPath]) {
                NSError *copyErr = nil;
                if (![fm copyItemAtPath:dataPath toPath:backupPath error:&copyErr]) {
                    ZLog(@"[BundleTransplant] couldn't back up %@: %@ - skipping this match", dataPath, copyErr.localizedDescription);
                    continue;
                }
            }

            NSNumber *oldSizeNum = [fm attributesOfItemAtPath:dataPath error:nil][NSFileSize];
            uint64_t oldSize = oldSizeNum.unsignedLongLongValue;

            NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
            NSError *writeErr = nil;
            if (![moddedData writeToFile:tmpPath options:NSDataWritingAtomic error:&writeErr]) {
                ZLog(@"[BundleTransplant] couldn't stage swap for %@: %@", dataPath, writeErr.localizedDescription);
                continue;
            }
            NSError *replaceErr = nil;
            BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:dataPath]
                              withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                             backupItemName:nil
                                    options:0
                           resultingItemURL:nil
                                      error:&replaceErr];
            [fm removeItemAtPath:tmpPath error:nil];
            if (!ok) {
                ZLog(@"[BundleTransplant] couldn't swap %@ in place: %@", dataPath, replaceErr.localizedDescription);
                continue;
            }

            swapped++;
            ZLog(@"[BundleTransplant] swapped %@ (CAB %@)", dataPath, cab);

            NSString *infoPath = [[dataPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"__info"];
            if ([fm fileExistsAtPath:infoPath]) {
                BOOL patched = bt2_try_patch_info_size(infoPath, oldSize, (uint64_t)moddedData.length);
                if (patched) {
                    ZLog(@"[BundleTransplant] __info at %@ updated for new size", infoPath);
                }
            }
        }

        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        result.swappedCount = swapped;
        if (swapped == 0 && !result.error) {
            result.error = BT2Error(BundleTransplantErrorWriteFailed,
                [NSString stringWithFormat:@"Found %@ cached match(es) for %@ but every swap attempt failed - see syslog.", @(matches.count), result.moddedFileName]);
        }
    }

    return results;
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    NSString *cacheDir = [self unityCacheSharedDirectory];
    NSString *backupDir = [self bundleBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!cacheDir) {
        if (error) *error = BT2Error(BundleTransplantErrorNoCacheDirectory, @"Couldn't resolve Library/UnityCache/Shared.");
        return -1;
    }
    if (!backupDir || ![fm fileExistsAtPath:backupDir]) {
        return 0; // nothing has ever been backed up - not an error
    }

    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: BT2Error(BundleTransplantErrorBackupFailed, @"Couldn't list the bundle backup directory.");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *entry in entries) {
        NSString *originalPath = bt2_original_path_for_backup_name(entry, cacheDir);
        if (!originalPath) continue; // not one of ours (unexpected extension) - skip rather than guess
        NSString *backupPath = [backupDir stringByAppendingPathComponent:entry];
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:backupPath toPath:tmpPath error:&copyErr]) {
            ZLog(@"[BundleTransplant] restore: couldn't stage %@: %@", backupPath, copyErr.localizedDescription);
            continue;
        }
        NSError *replaceErr = nil;
        BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                          withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                         backupItemName:nil
                                options:0
                       resultingItemURL:nil
                                  error:&replaceErr];
        [fm removeItemAtPath:tmpPath error:nil];
        if (ok) {
            restored++;
        } else {
            ZLog(@"[BundleTransplant] restore: couldn't swap %@ back in: %@", originalPath, replaceErr.localizedDescription);
        }
        // __info is intentionally left as whatever bt2_try_patch_info_size
        // last wrote - there's no tracked "original __info bytes" backup
        // (only __data gets one), so a restored __data may still be
        // sitting next to a __info that was patched for the modded
        // size. If __info patching turns out to matter for load-time
        // validation, this is the gap to close next: back up __info
        // alongside __data before the first patch, same as __data does.
    }

    return restored;
}

@end
