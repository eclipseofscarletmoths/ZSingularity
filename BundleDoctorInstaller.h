// BundleDoctorInstaller.h
//
// The "slot the doctored bundle in place" half of the pipeline -
// BundleDoctorService.h gets the doctored bytes back from GitHub
// Actions; this class does the actual on-disk swap, same backup-once/
// atomic-replace pattern BankTransplant.h already uses for .bank
// files (see that file's own header for why the backup can't live
// next to the original).
//
// UNVERIFIED, ON PURPOSE (read before relying on this without testing):
// unlike BankTransplant's +mobileFMODBuildsDirectory - which is a
// specific, on-device-confirmed relative path this project already
// established - there is no equivalent confirmed path for wherever
// Limbus Company's iOS build caches its Unity AssetBundles. Rather than
// hardcode a guessed directory and silently scan it (the way the old,
// now-removed Mods Library accordion did its CAB matching - see
// GraphicsDebugOverlay.m's Mods section comment), this class takes the
// stock bundle's location as an explicit parameter. The Load Mods flow
// in GraphicsDebugOverlay.m gets that from the person directly via a
// second UIDocumentPickerViewController pass (same picker
// -importModTapped already uses for .bank files) rather than this class
// guessing where to look - so it works regardless of the actual cache
// layout, at the cost of one extra tap per swap.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleDoctorInstallerErrorDomain;

typedef NS_ENUM(NSInteger, BundleDoctorInstallerErrorCode) {
    BundleDoctorInstallerErrorCantReadDoctored = 1,
    BundleDoctorInstallerErrorBackupFailed,     // couldn't create the one-time backup of the original before touching it
    BundleDoctorInstallerErrorWriteFailed,      // swapping the doctored file in failed
};

@interface BundleDoctorInstaller : NSObject

// Library/ZSingularityBundleBackups inside this app's sandbox - where
// backups of stock bundles live. Deliberately separate from wherever
// the stock bundle itself lives, same reasoning as BankTransplant's
// +bankBackupDirectory (an unrecognized sibling file next to a tracked
// asset can trip integrity checks that treat it as reason to flag/
// redownload the asset).
+ (NSString *)bundleBackupDirectory;

// doctoredURL: local temp file from BundleDoctorService's completion
// block (see that class). stockBundleURL: the on-disk stock bundle to
// replace, picked explicitly by the person - see this file's header on
// why this class doesn't try to locate it itself. Backs stockBundleURL
// up on first touch (keyed by stockBundleURL.lastPathComponent, so a
// second swap of the same file reuses/does not re-clobber that backup),
// then atomically replaces it with doctoredURL's bytes as-is. Returns
// NO and fills error on any failure (nothing on disk is modified in
// that case, aside from the backup, which is always safe to have made).
+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error;

// Restores every backed-up bundle under +bundleBackupDirectory to its
// original location, leaving the backups in place (safe to run more
// than once). Returns the number of files restored, or -1 with error
// filled on a filesystem-level failure walking the backup directory.
+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
