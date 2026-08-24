#import "ZTranscoderInstaller.h"
#import "ZTweakLog.h"
#import "ZSScripts.h"
#import "ModAssetLibrary.h"

NSString * const ZTranscoderInstallerErrorDomain = @"ZTranscoderInstallerErrorDomain";

static NSString * const kBackupSuffix = @".orig-bak";

static NSString * const kManifestFileName = @"manifest.json";

@implementation ZTranscoderInstaller

+ (NSString *)bundleBackupDirectory {
    return [ModAssetLibrary originalBundleBackupsDirectory];
}

+ (NSString *)bds_backupKeyForStockBundleURL:(NSURL *)stockBundleURL {
    NSString *path = stockBundleURL.path ?: stockBundleURL.absoluteString ?: @"";
    uint64_t hash = 1469598103934665603ULL;
    const char *bytes = path.UTF8String;
    if (bytes) {
        for (; *bytes != '\0'; bytes++) {
            hash ^= (uint64_t)(uint8_t)*bytes;
            hash *= 1099511628211ULL;
        }
    }
    return [NSString stringWithFormat:@"%@-%016llx", path.lastPathComponent ?: @"backup", hash];
}

+ (BOOL)bds_ensureBackupDirectoryExists:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve Library directory."}];
        }
        return NO;
    }
    NSError *createError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&createError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: createError.localizedDescription ?: @"Couldn't create backup directory."}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Manifest

+ (NSString *)bds_manifestPath {
    return [[self bundleBackupDirectory] stringByAppendingPathComponent:kManifestFileName];
}

+ (NSMutableDictionary<NSString *, NSString *> *)bds_loadManifest {
    NSData *data = [NSData dataWithContentsOfFile:[self bds_manifestPath]];
    if (!data) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return [NSMutableDictionary dictionary];
    return (NSMutableDictionary *)obj;
}

+ (BOOL)bds_writeManifest:(NSDictionary<NSString *, NSString *> *)manifest {
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return NO;
    return [data writeToFile:[self bds_manifestPath] options:NSDataWritingAtomic error:nil];
}

#pragma mark - Public API

+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error {
    NSData *doctoredData = [NSData dataWithContentsOfURL:doctoredURL options:0 error:error];
    if (!doctoredData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorCantReadDoctored
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the doctored bundle."}];
        }
        return NO;
    }

    if (![self bds_ensureBackupDirectoryExists:error]) return NO;

    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];

    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = [[self bundleBackupDirectory] stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL stockExists = [fm fileExistsAtPath:stockBundleURL.path];
    if (stockExists && ![fm fileExistsAtPath:backupPath]) {
        NSError *backupError = nil;
        if (![fm copyItemAtURL:stockBundleURL toURL:[NSURL fileURLWithPath:backupPath] error:&backupError]) {
            if (error) {
                *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                              code:ZTranscoderInstallerErrorBackupFailed
                                          userInfo:@{NSLocalizedDescriptionKey: backupError.localizedDescription ?: @"Couldn't back up the original bundle."}];
            }
            if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
            return NO;
        }

        NSMutableDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
        manifest[backupKey] = stockBundleURL.path;
        [self bds_writeManifest:manifest];
    } else if (!stockExists) {
        ZLog(@"[ZTranscoderInstaller] no existing file at %@ - nothing to back up (synthesized/never-cached destination), writing doctored bundle fresh.", stockBundleURL.path);
    }

    NSError *writeError = nil;
    if (![doctoredData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't swap in the doctored bundle."}];
        }
        if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
        return NO;
    }

    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
    ZLog(@"[ZTranscoderInstaller] installed doctored bundle at %@", stockBundleURL.path);

    zs_track_asset_path(stockBundleURL.path);

    return YES;
}

+ (BOOL)bds_fileAtPath:(NSString *)pathA hasIdenticalBytesToFileAtPath:(NSString *)pathB {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:pathA] || ![fm fileExistsAtPath:pathB]) return NO;

    NSDictionary<NSFileAttributeKey, id> *attrsA = [fm attributesOfItemAtPath:pathA error:nil];
    NSDictionary<NSFileAttributeKey, id> *attrsB = [fm attributesOfItemAtPath:pathB error:nil];
    unsigned long long sizeA = [attrsA[NSFileSize] unsignedLongLongValue];
    unsigned long long sizeB = [attrsB[NSFileSize] unsignedLongLongValue];
    if (sizeA != sizeB) return NO;

    NSData *dataA = [NSData dataWithContentsOfFile:pathA];
    NSData *dataB = [NSData dataWithContentsOfFile:pathB];
    if (!dataA || !dataB) return NO;
    return [dataA isEqualToData:dataB];
}

+ (NSInteger)restoreAllBackedUpBundlesForce:(BOOL)force error:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir || ![[NSFileManager defaultManager] fileExistsAtPath:dir]) return 0;

    NSDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
    if (manifest.count == 0) return 0;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger restored = 0;

    for (NSString *backupKey in manifest) {
        NSString *originalPath = manifest[backupKey];
        NSString *backupPath = [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
        if (![fm fileExistsAtPath:backupPath] || originalPath.length == 0) continue;

        if (!force && [self bds_fileAtPath:originalPath hasIdenticalBytesToFileAtPath:backupPath]) {
            continue;
        }

        NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
        if (!backupData) continue;

        NSError *writeError = nil;
        if ([backupData writeToFile:originalPath options:NSDataWritingAtomic error:&writeError]) {
            restored++;
        } else {
            ZLog(@"[ZTranscoderInstaller] couldn't restore %@ to %@: %@", backupKey, originalPath, writeError);
        }
    }

    return restored;
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    return [self restoreAllBackedUpBundlesForce:NO error:error];
}

+ (BOOL)cacheOriginalBackForStockBundleURL:(NSURL *)stockBundleURL error:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = dir ? [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!backupPath || ![fm fileExistsAtPath:backupPath]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"No backed-up original found for this bundle."}];
        }
        return NO;
    }

    NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
    if (!backupData) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the backed-up original."}];
        }
        return NO;
    }

    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];
    NSError *writeError = nil;
    BOOL wrote = [backupData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError];
    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];

    if (!wrote) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't write the original bundle back."}];
        }
        return NO;
    }

    ZLog(@"[ZTranscoderInstaller] cached %@ - live bytes swapped back to the backed-up original", stockBundleURL.lastPathComponent);
    return YES;
}

@end

