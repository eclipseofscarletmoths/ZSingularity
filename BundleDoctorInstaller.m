#import "BundleDoctorInstaller.h"
#import "ZTweakLog.h"
#import "GDScripts.h" // gd_track_asset_path - see that file's header
#import "ModAssetLibrary.h" // originalBundleBackupsDirectory - see +bundleBackupDirectory below

NSString * const BundleDoctorInstallerErrorDomain = @"BundleDoctorInstallerErrorDomain";

static NSString * const kBackupSuffix = @".orig-bak";

// Small JSON manifest mapping a backup key (see
// +bds_backupKeyForStockBundleURL: below) -> the ORIGINAL full path it
// was backed up from. Needed because (unlike BankTransplant, which
// always restores into one fixed, known directory) a stock bundle's
// location here is whatever the person picked at install time - see
// BundleDoctorInstaller.h's header on why this class doesn't assume a
// fixed AssetBundles directory. Lives inside +bundleBackupDirectory
// itself, next to the backups it describes.
static NSString * const kManifestFileName = @"manifest.json";

@implementation BundleDoctorInstaller

+ (NSString *)bundleBackupDirectory {
    return [ModAssetLibrary originalBundleBackupsDirectory];
}

// 10 - stockBundleURL's full path, not just its last path component,
// turned into a filesystem-safe key: a short human-recognizable prefix
// (the leaf name every stock bundle shares, e.g. "__data") plus a
// deterministic hash of the FULL path, which is what actually tells one
// stock bundle's location apart from another's - see this class's
// header for why lastPathComponent alone isn't enough. FNV-1a rather
// than a CommonCrypto digest since this only needs to be
// collision-resistant and stable across runs of this same process, not
// cryptographically secure, and avoids pulling in another framework
// dependency for it.
+ (NSString *)bds_backupKeyForStockBundleURL:(NSURL *)stockBundleURL {
    NSString *path = stockBundleURL.path ?: stockBundleURL.absoluteString ?: @"";
    uint64_t hash = 1469598103934665603ULL; // FNV-1a 64-bit offset basis
    const char *bytes = path.UTF8String;
    if (bytes) {
        for (; *bytes != '\0'; bytes++) {
            hash ^= (uint64_t)(uint8_t)*bytes;
            hash *= 1099511628211ULL; // FNV-1a 64-bit prime
        }
    }
    return [NSString stringWithFormat:@"%@-%016llx", path.lastPathComponent ?: @"backup", hash];
}

+ (BOOL)bds_ensureBackupDirectoryExists:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve Library directory."}];
        }
        return NO;
    }
    NSError *createError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&createError]) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorBackupFailed
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
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorCantReadDoctored
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the doctored bundle."}];
        }
        return NO;
    }

    if (![self bds_ensureBackupDirectoryExists:error]) return NO;

    // stockBundleURL can arrive two ways now that the download tap
    // handler (GraphicsDebugOverlay.m's "Mods (doctor pipeline)"
    // section) drives this: a UnityCacheLocator match under this app's
    // own Library directory (never security-scoped), or a person's own
    // pick from UIDocumentPickerViewController (always security-scoped)
    // when no cache match was found. -startAccessingSecurityScopedResource
    // is a documented no-op (returns NO, changes nothing) on a URL that
    // was never security-scoped in the first place, so it's safe to
    // wrap every call here unconditionally rather than have the caller
    // track which kind of URL it's holding - same convention
    // BankTransplant.m/BundleDoctorService.m already use for their own
    // picker-sourced URLs.
    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];

    // 10 - keyed by the full path (see +bds_backupKeyForStockBundleURL:),
    // not stockBundleURL.lastPathComponent - every stock bundle's leaf
    // file is always literally named "__data", so a lastPathComponent-
    // only key made every bundle's backup collide on the same name and
    // silently skip backing up anything but the first one ever installed.
    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = [[self bundleBackupDirectory] stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
    NSFileManager *fm = [NSFileManager defaultManager];

    // One-time backup: only ever written if this exact stock location
    // hasn't been backed up before, same "never-overwritten" guarantee
    // BankTransplant gives its own backups - so repeated swaps of the
    // same bundle always trace back to the true original, not to a
    // previous mod, and a DIFFERENT bundle installed over a different
    // stock location can never clobber this one's backup.
    if (![fm fileExistsAtPath:backupPath]) {
        NSError *backupError = nil;
        if (![fm copyItemAtURL:stockBundleURL toURL:[NSURL fileURLWithPath:backupPath] error:&backupError]) {
            if (error) {
                *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                              code:BundleDoctorInstallerErrorBackupFailed
                                          userInfo:@{NSLocalizedDescriptionKey: backupError.localizedDescription ?: @"Couldn't back up the original bundle."}];
            }
            if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
            return NO;
        }

        NSMutableDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
        manifest[backupKey] = stockBundleURL.path;
        [self bds_writeManifest:manifest];
    }

    NSError *writeError = nil;
    if (![doctoredData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't swap in the doctored bundle."}];
        }
        if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
        return NO;
    }

    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
    ZLog(@"[BundleDoctorInstaller] installed doctored bundle at %@", stockBundleURL.path);

    // Independent of this class's own manifest.json bookkeeping - see
    // GDScripts.h's gd_track_asset_path() header for why Hard Assets
    // Reset needs this logged separately.
    gd_track_asset_path(stockBundleURL.path);

    return YES;
}

// Byte-for-byte comparison (not just size) between a live file and its
// backup - used so a restore doesn't overwrite a live bundle that's
// already identical to what it would be restored to. Size is checked
// first as a cheap short-circuit before either file is read in full.
// Either path missing/unreadable counts as "not identical" so a real
// restore attempt still happens rather than silently no-op'ing. Same
// helper shape as BankTransplant's own +bt_fileAtPath:hasIdenticalBytesToFileAtPath:
// - not shared between the two classes since it's a few lines and
// neither has (nor needs) a common base class.
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
            continue; // already matches the backup - nothing to restore
        }

        NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
        if (!backupData) continue;

        NSError *writeError = nil;
        if ([backupData writeToFile:originalPath options:NSDataWritingAtomic error:&writeError]) {
            restored++;
        } else {
            ZLog(@"[BundleDoctorInstaller] couldn't restore %@ to %@: %@", backupKey, originalPath, writeError);
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
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"No backed-up original found for this bundle."}];
        }
        return NO;
    }

    NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
    if (!backupData) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorBackupFailed
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
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't write the original bundle back."}];
        }
        return NO;
    }

    ZLog(@"[BundleDoctorInstaller] cached %@ - live bytes swapped back to the backed-up original", stockBundleURL.lastPathComponent);
    return YES;
}

// +deleteAllTrackedBundlesAndBackupsWithError: used to live here - see
// the NOTE at the bottom of BundleDoctorInstaller.h for why Hard Assets
// Reset no longer discovers what to delete by reading manifest.json.

@end
