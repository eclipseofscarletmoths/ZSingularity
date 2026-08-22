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
    // Not raised by this class itself - a synthesized code for
    // GraphicsDebugOverlay.m's own download/install orchestration (see
    // its "Mods (doctor pipeline)" section) to use for every way it can
    // fail to ever GET a stockBundleURL to hand this class in the first
    // place: no UnityCacheLocator match and the person cancelled the
    // manual picker, another entry's download already had the one
    // modal picker claimed, or there was no view controller to present
    // it from at all. Kept in this domain/enum rather than a new one of
    // its own since every one of these is still, from the person's
    // point of view, "the install didn't happen" - same family of
    // failure as the three above, just one step earlier.
    BundleDoctorInstallerErrorNoInstallTarget,
};

@interface BundleDoctorInstaller : NSObject

// +[ModAssetLibrary originalBundleBackupsDirectory] - a subdirectory of
// the Mod Asset Library itself, per the person's own spec (10) that a
// stock bundle's one-time backup lives "in the asset library", not off
// in some wholly separate Library directory of this class's own (which
// is where it lived before this - a leftover from before this class had
// any reason to know ModAssetLibrary existed at all). Kept as this
// class's own accessor (rather than every call site reaching into
// ModAssetLibrary directly) purely so nothing else in this file, or any
// existing caller/comment referencing "+bundleBackupDirectory", had to
// change shape over the move.
+ (NSString *)bundleBackupDirectory;

// doctoredURL: local temp file from BundleDoctorService's completion
// block (see that class). stockBundleURL: the on-disk stock bundle to
// replace, picked explicitly by the person - see this file's header on
// why this class doesn't try to locate it itself. Backs stockBundleURL
// up on first touch, then atomically replaces it with doctoredURL's
// bytes as-is. Returns NO and fills error on any failure (nothing on
// disk is modified in that case, aside from the backup, which is
// always safe to have made).
//
// 10 - the backup is keyed by stockBundleURL's FULL path (via
// +bds_backupKeyForStockBundleURL:), not just its last path component.
// Every Unity asset bundle's on-disk payload file is always literally
// named "__data" (see ModAssetLibrary.h's own note on why bundles get
// CAB-named subfolders) - it's what makes one stock location distinct
// from another, not the shared leaf filename every one of them has. The
// old lastPathComponent-only key meant installing bundle A over stock
// path P1 wrote a backup that bundle B's later install over a
// DIFFERENT stock path P2 then found "already exists" and skipped -
// P2's real original was never captured, and a restore of P2 would
// have handed back A's original bytes instead. Keying on the full path
// means two different stock locations can never collide, so each one's
// true original is backed up exactly once and never overwritten by a
// different bundle's install - regardless of how many other bundles
// happen to share the same "__data" leaf name.
+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error;

// Restores every backed-up bundle under +bundleBackupDirectory to its
// original location, leaving the backups in place (safe to run more
// than once). A bundle whose live bytes already match its backup
// byte-for-byte is left untouched and NOT counted as restored - see
// +restoreAllBackedUpBundlesForce:error: for the force-through variant.
// Returns the number of files actually (re)written, or -1 with error
// filled on a filesystem-level failure walking the backup directory.
+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;

// Same as +restoreAllBackedUpBundlesWithError: above, but with an
// explicit `force` switch: force:NO is exactly that method's own
// behavior (byte-identical bundles are skipped, not counted); force:YES
// skips the byte check entirely and rewrites every backed-up bundle
// unconditionally, matching-or-not. Meant for a "Force Restore" fallback
// offered after a plain restore reports nothing to do - see
// GraphicsDebugOverlay.m's -restoreOriginalsTapped /
// -gd_forceRestoreOriginalsTapped.
+ (NSInteger)restoreAllBackedUpBundlesForce:(BOOL)force error:(NSError **)error;

// 7 "Cache bundle" - per-bundle counterpart to
// +restoreAllBackedUpBundlesForce:error:, for swapping ONE live bundle
// back to its backed-up original without touching any other installed
// bundle. Looks up stockBundleURL's backup the same way (keyed by
// +bds_backupKeyForStockBundleURL: under +bundleBackupDirectory) and, if
// found, overwrites stockBundleURL with the backup's bytes - the backup
// itself is left in place either way (unlike a delete/reset flow, this
// is meant to be reversible - see -gd_restoreStoredBundleEntry:inFolder:
// in GraphicsDebugOverlay.m, which reinstalls over top of it later via
// the ordinary +installDoctoredBundleAtURL:toStockBundleURL:error:,
// relying on that method's own "second swap of the same file reuses the
// existing backup" behavior to avoid re-backing-up what's already sitting
// there as the true original). Returns NO with
// BundleDoctorInstallerErrorBackupFailed if no backup is on file for this
// bundle - shouldn't happen for anything the Mods panel offers "Cache
// bundle" on, since that option only ever appears for an entry whose
// doctorStatus is Installed, which is only reachable after a successful
// +installDoctoredBundleAtURL:toStockBundleURL:error: call already made one.
+ (BOOL)cacheOriginalBackForStockBundleURL:(NSURL *)stockBundleURL error:(NSError **)error;

// NOTE: this class used to also own a
// +deleteAllTrackedBundlesAndBackupsWithError: "nuclear option" for the
// Config section's "Hard Assets Reset", discovering what to delete by
// reading manifest.json under +bundleBackupDirectory. That was
// unreliable for exactly the reason a manifest-file walk always will
// be for this: if the backup directory's own contents are ever lost or
// cleared by something other than a completed Reset, there's nothing
// left to discover from. -hardAssetsResetTapped in
// GraphicsDebugOverlay.m now drives live-file deletion from
// GDScripts.h's independent gd_tracked_asset_paths() log instead (every
// path +installDoctoredBundleAtURL:toStockBundleURL:error: has ever
// installed over, logged at install time regardless of backup-directory
// state), and clears +bundleBackupDirectory directly rather than
// through this class. manifest.json itself is untouched by any of this
// - +restoreAllBackedUpBundlesForce:error: still needs it.

@end

NS_ASSUME_NONNULL_END
