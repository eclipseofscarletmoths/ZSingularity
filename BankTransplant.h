// BankTransplant.h
//
// ObjC entry point around the chunk-walking splice described in
// bank_transplant.c: takes a desktop-coded (Vorbis) modded .bank picked
// by the user, finds the stock mobile-coded (FADPCM) .bank with the same
// filename under this app's own FMOD build directory, and swaps only the
// trailing FSB5 sample payload onto the stock file's FEV/RIFF wrapper -
// the wrapper (GUIDs, event list, sample name table) is per-project, not
// per-platform, so it's byte-identical between builds except for three
// length fields this rewrites. No Vorbis/FADPCM re-encoding happens here.
//
// This is theory-stage, per the project notes: whether a spliced file
// actually plays depends on the mobile FMOD runtime having Vorbis linked
// in, which hasn't been confirmed on-device yet.
//
// Every write to the game's own bank file is preceded by a one-time,
// never-overwritten backup (<name>.bank.orig-bak) so +restoreAllBackedUpBanksWithError:
// can always get back to the untouched stock file regardless of how many
// times a bank has since been re-swapped.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BankTransplantErrorDomain;

typedef NS_ENUM(NSInteger, BankTransplantErrorCode) {
    BankTransplantErrorCantReadModded = 1,
    BankTransplantErrorOriginalNotFound,   // no file with the modded bank's name under the Mobile FMOD build directory
    BankTransplantErrorCantReadOriginal,
    BankTransplantErrorBadOriginalWrapper, // original doesn't parse as a RIFF/FEV bank with an SNDH+SND wrapper
    BankTransplantErrorBadModdedWrapper,   // modded doesn't parse the same way
    BankTransplantErrorSampleSetMismatch,  // sample name tables differ between the two FSB5 blobs - refused, not spliced
    BankTransplantErrorBackupFailed,       // couldn't create the one-time backup of the original before touching it
    BankTransplantErrorWriteFailed,        // splice succeeded but writing/swapping the result on disk failed
};

@interface BankTransplant : NSObject

// Documents/Assets/Sound/FMODBuilds/Mobile inside this app's own sandbox
// (the tweak runs in-process, so NSDocumentDirectory here already IS the
// game's Documents directory - no separate container lookup needed).
+ (NSString *)mobileFMODBuildsDirectory;

// moddedURL is whatever the user picked via UIDocumentPickerViewController -
// possibly security-scoped (outside the app sandbox, e.g. from Files/iCloud).
// This starts/stops that access itself; callers don't need to.
//
// Looks up moddedURL.lastPathComponent under +mobileFMODBuildsDirectory,
// backs that file up on first touch, splices the modded FSB5 payload onto
// its wrapper, and atomically replaces it in place. Returns NO and fills
// error on any failure (nothing on disk is modified in that case, aside
// from the backup, which is always safe to have made).
+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL
                                    error:(NSError **)error;

// Restores every <name>.bank under +mobileFMODBuildsDirectory that has a
// matching <name>.bank.orig-bak from its backup, leaving the backups in
// place (so this is safe to run more than once / after further swaps).
// Returns the number of files restored, or -1 with error filled on a
// filesystem-level failure walking the directory.
+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
