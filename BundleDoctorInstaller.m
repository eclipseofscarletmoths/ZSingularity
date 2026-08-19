#import "BundleDoctorInstaller.h"
#import "ZTweakLog.h"

NSString * const BundleDoctorInstallerErrorDomain = @"BundleDoctorInstallerErrorDomain";

static NSString * const kBackupSuffix = @".orig-bak";

// Small JSON manifest mapping "<name>.orig-bak" -> the ORIGINAL full
// path it was backed up from. Needed because (unlike BankTransplant,
// which always restores into one fixed, known directory) a stock
// bundle's location here is whatever the person picked at install
// time - see BundleDoctorInstaller.h's header on why this class
// doesn't assume a fixed AssetBundles directory. Lives inside
// +bundleBackupDirectory itself, next to the backups it describes.
static NSString * const kManifestFileName = @"manifest.json";

@implementation BundleDoctorInstaller

+ (NSString *)bundleBackupDirectory {
    NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = libraryPaths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityBundleBackups"];
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

    NSString *name = stockBundleURL.lastPathComponent;
    NSString *backupPath = [[self bundleBackupDirectory] stringByAppendingPathComponent:[name stringByAppendingString:kBackupSuffix]];
    NSFileManager *fm = [NSFileManager defaultManager];

    // One-time backup: only ever written if this exact name hasn't been
    // backed up before, same "never-overwritten" guarantee BankTransplant
    // gives its own backups - so repeated swaps of the same bundle always
    // trace back to the true original, not to a previous mod.
    if (![fm fileExistsAtPath:backupPath]) {
        NSError *backupError = nil;
        if (![fm copyItemAtURL:stockBundleURL toURL:[NSURL fileURLWithPath:backupPath] error:&backupError]) {
            if (error) {
                *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                              code:BundleDoctorInstallerErrorBackupFailed
                                          userInfo:@{NSLocalizedDescriptionKey: backupError.localizedDescription ?: @"Couldn't back up the original bundle."}];
            }
            return NO;
        }

        NSMutableDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
        manifest[name] = stockBundleURL.path;
        [self bds_writeManifest:manifest];
    }

    NSError *writeError = nil;
    if (![doctoredData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                          code:BundleDoctorInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't swap in the doctored bundle."}];
        }
        return NO;
    }

    ZLog(@"[BundleDoctorInstaller] installed doctored bundle at %@", stockBundleURL.path);
    return YES;
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir || ![[NSFileManager defaultManager] fileExistsAtPath:dir]) return 0;

    NSDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
    if (manifest.count == 0) return 0;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger restored = 0;

    for (NSString *name in manifest) {
        NSString *originalPath = manifest[name];
        NSString *backupPath = [dir stringByAppendingPathComponent:[name stringByAppendingString:kBackupSuffix]];
        if (![fm fileExistsAtPath:backupPath] || originalPath.length == 0) continue;

        NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
        if (!backupData) continue;

        NSError *writeError = nil;
        if ([backupData writeToFile:originalPath options:NSDataWritingAtomic error:&writeError]) {
            restored++;
        } else {
            ZLog(@"[BundleDoctorInstaller] couldn't restore %@ to %@: %@", name, originalPath, writeError);
        }
    }

    return restored;
}

@end
