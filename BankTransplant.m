// BankTransplant.m
//
// See BankTransplant.h. Direct whole-file swap only - no FSB5/RIFF
// parsing, no codec work. Mobile plays Vorbis-coded banks natively, so
// the modded bank's bytes go in as-is.

#import "BankTransplant.h"
#import "ZTweakLog.h"

NSString * const BankTransplantErrorDomain = @"BankTransplantErrorDomain";

static NSError *BTError(BankTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:BankTransplantErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * const kBTBackupSuffix = @".orig-bak";

@interface BankTransplant ()
+ (BOOL)bt_restoreOneBackupEntry:(NSString *)backupEntryName inBackupDir:(NSString *)backupDir mobileDir:(NSString *)mobileDir;
@end

@implementation BankTransplant

+ (NSString *)mobileFMODBuildsDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"Assets/Sound/FMODBuilds/Mobile"];
}

// Backups deliberately do NOT live in +mobileFMODBuildsDirectory:
// whatever validates that directory treated an unexpected
// <name>.bank.orig-bak sibling sitting there as reason to flag the bank
// and force a redownload, and since a backup is written once and then
// just sits there, that flag came back on every subsequent launch, not
// only the one where the swap happened. Backups live under this tweak's
// own Library directory instead - the directory the game/engine actually
// reads banks from stays exactly {stock or swapped bank}, never anything
// extra.
+ (NSString *)bankBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityBankBackups"];
}

+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL error:(NSError **)error {
    BOOL accessing = [moddedURL startAccessingSecurityScopedResource];

    NSString *fileName = moddedURL.lastPathComponent;
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *originalPath = mobileDir ? [mobileDir stringByAppendingPathComponent:fileName] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!originalPath || ![fm fileExistsAtPath:originalPath]) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorOriginalNotFound,
            [NSString stringWithFormat:@"No stock bank named \"%@\" found under Assets/Sound/FMODBuilds/Mobile.", fileName]);
        return NO;
    }

    if (![fm isReadableFileAtPath:moddedURL.path]) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read the picked file %@.", fileName]);
        return NO;
    }

    NSString *backupDir = [self bankBackupDirectory];
    if (!backupDir) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorBackupFailed, @"Couldn't resolve the backup directory.");
        return NO;
    }
    if (![fm fileExistsAtPath:backupDir]) {
        NSError *dirErr = nil;
        if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            if (error) *error = BTError(BankTransplantErrorBackupFailed,
                [NSString stringWithFormat:@"Couldn't create the backup directory: %@", dirErr.localizedDescription]);
            return NO;
        }
    }
    NSString *backupPath = [backupDir stringByAppendingPathComponent:[fileName stringByAppendingString:kBTBackupSuffix]];
    if (![fm fileExistsAtPath:backupPath]) {
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:originalPath toPath:backupPath error:&copyErr]) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            if (error) *error = BTError(BankTransplantErrorBackupFailed,
                [NSString stringWithFormat:@"Couldn't back up %@ before touching it: %@", fileName, copyErr.localizedDescription]);
            return NO;
        }
        ZLog(@"[BankTransplant] backed up %@ -> %@", fileName, backupPath);
    }

    // Stage a copy of the modded file in tmp first so the final swap-in
    // is a single atomic replace, same as every other write path in this
    // project.
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.swap.%@", fileName, [NSUUID UUID].UUIDString]];

    NSError *copyErr = nil;
    BOOL staged = [fm copyItemAtPath:moddedURL.path toPath:tmpPath error:&copyErr];

    if (accessing) [moddedURL stopAccessingSecurityScopedResource];

    if (!staged) {
        [fm removeItemAtPath:tmpPath error:nil];
        if (error) *error = BTError(BankTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read the picked file %@: %@", fileName, copyErr.localizedDescription]);
        return NO;
    }

    NSError *replaceErr = nil;
    BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                      withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                     backupItemName:nil
                            options:0
                   resultingItemURL:nil
                              error:&replaceErr];
    [fm removeItemAtPath:tmpPath error:nil];

    if (!ok) {
        if (error) *error = BTError(BankTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Swapping %@ in place failed: %@", fileName, replaceErr.localizedDescription]);
        return NO;
    }

    ZLog(@"[BankTransplant] swapped %@ in place with the modded file's bytes as-is", fileName);
    return YES;
}

// Shared by +restoreAllBackedUpBanksWithError: and
// +restoreBackedUpBankNamed:error: below - restores one <name>.bank
// from its <name>.bank.orig-bak backup, leaving the backup in place.
// Returns YES/NO for that one file; doesn't fill `error` on a simple
// "couldn't stage/swap this one" failure (logged via ZLog instead,
// same as the old inline loop body did), since the all-banks caller
// wants to keep going past a single bad entry rather than abort.
+ (BOOL)bt_restoreOneBackupEntry:(NSString *)backupEntryName inBackupDir:(NSString *)backupDir mobileDir:(NSString *)mobileDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backupPath = [backupDir stringByAppendingPathComponent:backupEntryName];
    NSString *fileName = [backupEntryName substringToIndex:backupEntryName.length - kBTBackupSuffix.length];
    NSString *originalPath = [mobileDir stringByAppendingPathComponent:fileName];

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:backupPath toPath:tmpPath error:&copyErr]) {
        ZLog(@"[BankTransplant] restore: couldn't stage %@: %@", backupEntryName, copyErr.localizedDescription);
        return NO;
    }
    NSError *replaceErr = nil;
    BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                      withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                     backupItemName:nil
                            options:0
                   resultingItemURL:nil
                              error:&replaceErr];
    [fm removeItemAtPath:tmpPath error:nil];
    if (!ok) {
        ZLog(@"[BankTransplant] restore: couldn't swap %@ back in: %@", originalPath.lastPathComponent, replaceErr.localizedDescription);
    }
    return ok;
}

+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error {
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *backupDir = [self bankBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!backupDir || ![fm fileExistsAtPath:backupDir]) {
        return 0; // nothing has ever been backed up - not an error
    }

    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: BTError(BankTransplantErrorOriginalNotFound, @"Couldn't list the bank backup directory.");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *entry in entries) {
        if (![entry hasSuffix:kBTBackupSuffix]) continue;
        if ([self bt_restoreOneBackupEntry:entry inBackupDir:backupDir mobileDir:mobileDir]) restored++;
    }

    return restored;
}

+ (NSInteger)restoreBackedUpBankNamed:(NSString *)name error:(NSError **)error {
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *backupDir = [self bankBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!backupDir || ![fm fileExistsAtPath:backupDir]) {
        return 0; // nothing has ever been backed up - not an error
    }

    NSString *backupEntryName = [name stringByAppendingString:kBTBackupSuffix];
    NSString *backupPath = [backupDir stringByAppendingPathComponent:backupEntryName];
    if (![fm fileExistsAtPath:backupPath]) {
        return 0; // no backup for this bank specifically - not an error
    }

    return [self bt_restoreOneBackupEntry:backupEntryName inBackupDir:backupDir mobileDir:mobileDir] ? 1 : 0;
}

@end
