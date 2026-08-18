// TextureAtlasTransplant.m
//
// See TextureAtlasTransplant.h for what's here and why the
// diff/transplant pipeline that used to live in this file is gone.
// The two cache-discovery helpers below are the only pieces the
// restore methods still need - mirrors BundleTransplant.m's own
// bt2_find_all_data_files/bt2_build_cab_index rather than calling into
// it, same "duplicating ~20 lines is simpler than restructuring"
// reasoning that file's own top comment already gives.

#import "TextureAtlasTransplant.h"
#import "UnityBundleCAB.h"
#import "BundleTransplant.h" // for +unityCacheSharedDirectory only
#import "ZTweakLog.h"

NSString * const TextureAtlasTransplantErrorDomain = @"TextureAtlasTransplantErrorDomain";

static NSError *TATError(TextureAtlasTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TextureAtlasTransplantErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - public API

@implementation TextureAtlasTransplant

+ (NSString *)atlasBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityAtlasBackups"];
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    NSString *backupDir = [self atlasBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:backupDir]) return 0;

    NSString *cacheDir = [BundleTransplant unityCacheSharedDirectory];
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: TATError(TextureAtlasTransplantErrorBackupFailed, @"couldn't list backup directory");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *encodedRel in entries) {
        if (![encodedRel hasSuffix:@".atlasbak"]) continue;
        NSString *flat = [encodedRel substringToIndex:encodedRel.length - @".atlasbak".length];
        NSString *relPath = [flat stringByReplacingOccurrencesOfString:@"%2F" withString:@"/"];
        NSString *targetPath = [cacheDir stringByAppendingPathComponent:relPath];
        NSString *backupPath = [backupDir stringByAppendingPathComponent:encodedRel];
        NSError *copyErr = nil;
        [fm removeItemAtPath:targetPath error:nil];
        if ([fm copyItemAtPath:backupPath toPath:targetPath error:&copyErr]) {
            restored++;
        } else {
            ZLog(@"[TextureAtlasTransplant] restore: couldn't restore %@: %@", targetPath, copyErr.localizedDescription);
        }
    }
    return restored;
}

+ (NSInteger)restoreBackedUpBundlesForCAB:(NSString *)cab error:(NSError **)error {
    NSString *backupDir = [self atlasBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:backupDir]) return 0;

    NSString *cacheDir = [BundleTransplant unityCacheSharedDirectory];
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: TATError(TextureAtlasTransplantErrorBackupFailed, @"couldn't list backup directory");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *encodedRel in entries) {
        if (![encodedRel hasSuffix:@".atlasbak"]) continue;
        NSString *backupPath = [backupDir stringByAppendingPathComponent:encodedRel];

        // The backup is untouched stock bytes, so reading its CAB gives
        // the same identity the modded file was matched against at
        // transplant time - no need to touch the live (possibly
        // already object-patched) __data to find out which entries
        // belong to this CAB.
        NSError *cabErr = nil;
        NSString *entryCAB = [UnityBundleCAB primaryCABForBundleAtPath:backupPath error:&cabErr];
        if (!entryCAB || ![entryCAB isEqualToString:cab]) continue;

        NSString *flat = [encodedRel substringToIndex:encodedRel.length - @".atlasbak".length];
        NSString *relPath = [flat stringByReplacingOccurrencesOfString:@"%2F" withString:@"/"];
        NSString *targetPath = [cacheDir stringByAppendingPathComponent:relPath];

        NSError *copyErr = nil;
        [fm removeItemAtPath:targetPath error:nil];
        if ([fm copyItemAtPath:backupPath toPath:targetPath error:&copyErr]) {
            restored++;
        } else {
            ZLog(@"[TextureAtlasTransplant] restore: couldn't restore %@: %@", targetPath, copyErr.localizedDescription);
        }
    }
    return restored;
}

@end
