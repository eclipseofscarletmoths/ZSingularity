// BankTransplant.h
//
// REPURPOSED again: the re-encode pipeline (decode modded Vorbis -> PCM ->
// re-encode to FADPCM -> rebuild a stock-shaped FSB5 header, see git
// history for that version) is gone. It turns out the Limbus mobile
// client itself already supports Vorbis-coded FSB5 samples, so there was
// never a codec mismatch to work around - the mobile FMOD runtime just
// plays whatever's in the file. That makes the whole
// decode/re-encode/header-rebuild pipeline (and everything it depended
// on - FADPCMCodec.h, FSB5VorbisExtract.h, FSB5HeaderRebuild.h,
// FSB5SampleHeaderIO.h, VorbisSetupTable.h/FSB5VorbisSetupTable.bin, and
// the libvorbis/AVAudioConverter linkage in the old .m) unnecessary. This
// version does a direct whole-file swap: the modded bank, byte for byte,
// in place of the stock one with the same name. No parsing, no
// transcoding, no header surgery.
//
// Every write to the game's own bank file is still preceded by a
// one-time, never-overwritten backup so +restoreAllBackedUpBanksWithError:
// can always get back to the untouched stock file regardless of how many
// times a bank has since been re-swapped.
//
// IMPORTANT (learned the hard way): that backup must NOT live inside
// +mobileFMODBuildsDirectory as a same-folder sibling file
// (<name>.bank.orig-bak right next to <name>.bank). Whatever validates
// that directory treated an unrecognized extra file as reason to flag
// the bank and force a redownload - and since the backup is written once
// and then just sits there, that flag came back on every subsequent
// launch, not only the one where the swap happened. Backups live under
// +bankBackupDirectory instead (this tweak's own Library directory), so
// +mobileFMODBuildsDirectory only ever contains exactly the bank files
// the game itself expects to find there.
//
// Manifest hash/size verification for the swapped file is handled
// separately and passively by PatchManifestNetwork at the network layer
// (see that file) - this class does not need to trigger or wait on any
// resync itself.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BankTransplantErrorDomain;

typedef NS_ENUM(NSInteger, BankTransplantErrorCode) {
    BankTransplantErrorCantReadModded = 1,
    BankTransplantErrorOriginalNotFound,     // no file with the modded bank's name under the Mobile FMOD build directory
    BankTransplantErrorBackupFailed,         // couldn't create the one-time backup of the original before touching it
    BankTransplantErrorWriteFailed,          // swapping the modded file in failed
};

@interface BankTransplant : NSObject

// Documents/Assets/Sound/FMODBuilds/Mobile inside this app's own sandbox
// (the tweak runs in-process, so NSDocumentDirectory here already IS the
// game's Documents directory - no separate container lookup needed).
+ (NSString *)mobileFMODBuildsDirectory;

// Library/ZSingularityBankBackups inside this app's sandbox - where
// backups of stock banks live now. Deliberately NOT inside
// +mobileFMODBuildsDirectory - see the IMPORTANT note above.
+ (NSString *)bankBackupDirectory;

// moddedURL is whatever the user picked via UIDocumentPickerViewController -
// possibly security-scoped (outside the app sandbox, e.g. from Files/iCloud).
// This starts/stops that access itself; callers don't need to.
//
// Looks up moddedURL.lastPathComponent under +mobileFMODBuildsDirectory,
// backs that file up on first touch, then atomically replaces the stock
// bank with the modded file's bytes as-is. Returns NO and fills error on
// any failure (nothing on disk is modified in that case, aside from the
// backup, which is always safe to have made).
+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL
                                    error:(NSError **)error;

// Restores every <name>.bank under +mobileFMODBuildsDirectory that has a
// matching <name>.bank.orig-bak under +bankBackupDirectory, leaving the
// backups in place (so this is safe to run more than once / after further
// swaps). A bank whose live bytes already match its backup byte-for-byte
// is left untouched and NOT counted as restored - see
// +restoreAllBackedUpBanksForce:error: for the force-through variant.
// Returns the number of files actually (re)written, or -1 with error
// filled on a filesystem-level failure walking the backup directory.
+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error;

// Same as +restoreAllBackedUpBanksWithError: above, but with an explicit
// `force` switch: force:NO is exactly that method's own behavior
// (byte-identical banks are skipped, not counted); force:YES skips the
// byte check entirely and rewrites every backed-up bank unconditionally,
// matching-or-not. Meant for a "Force Restore" fallback offered after a
// plain restore reports nothing to do - see GraphicsDebugOverlay.m's
// -restoreOriginalsTapped / -gd_forceRestoreOriginalsTapped.
+ (NSInteger)restoreAllBackedUpBanksForce:(BOOL)force error:(NSError **)error;

// Scoped counterpart to the method above: restores only the single
// <name>.bank (name should include the extension, e.g. "music.bank")
// that has a matching backup under +bankBackupDirectory, leaving the
// backup in place. Returns 1 if it was restored, 0 (not an error) if
// there's no backup for this name at all, or -1 with error filled on a
// filesystem-level failure.
+ (NSInteger)restoreBackedUpBankNamed:(NSString *)name error:(NSError **)error;

// NOTE: this class used to also own a
// +deleteAllTrackedBanksAndBackupsWithError: "nuclear option" for the
// Config section's "Hard Assets Reset", discovering what to delete by
// walking +bankBackupDirectory the same way +restoreAllBackedUpBanksWithError:
// does. That was unreliable for exactly the reason a backup-directory
// walk always will be for this: if the backup directory's own contents
// are ever lost or cleared by something other than a completed Reset,
// there's nothing left to discover from. -hardAssetsResetTapped in
// GraphicsDebugOverlay.m now drives live-file deletion from
// GDScripts.h's independent gd_tracked_asset_paths() log instead (every
// path +transplantAndSwapModdedBankAtURL:error: has ever swapped into,
// logged at swap time regardless of backup-directory state), and clears
// +bankBackupDirectory directly rather than through this class.

@end

NS_ASSUME_NONNULL_END
