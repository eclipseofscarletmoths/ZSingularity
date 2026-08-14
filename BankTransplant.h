// BankTransplant.h
//
// REPURPOSED from the original wrapper-splice approach (see git history /
// README for the old version) to an audio re-encode pipeline. The old
// approach spliced a desktop-coded (Vorbis) modded bank's *entire* FSB5
// blob - its own sample headers, name table, and data - onto the stock
// mobile bank's FEV/RIFF wrapper, unchanged. That kept the payload
// Vorbis-coded, which meant two independent things had to hold for it to
// work: whatever integrity check gates a swapped bank file had to accept
// it, AND the mobile FMOD runtime had to have a Vorbis decoder linked in
// - both unconfirmed, per the project notes.
//
// This version drops the header-transplant/splice logic entirely. Instead
// it decodes the modded bank's Vorbis sample data to PCM, re-encodes that
// PCM to FADPCM (FADPCMCodec.h/.m), and rebuilds each sample's FSB5
// header by cloning the STOCK file's own existing FADPCM header for that
// sample name and patching only what changes with re-encoded content
// (data offset/size, peak-normalization value) - see FSB5HeaderRebuild.h.
// The result is structurally an ordinary FADPCM bank in the stock file's
// own shape, not a splice of someone else's header table, which sidesteps
// both open questions above: no Vorbis decode is required on-device, and
// the file is closer to what a real FADPCM build looks like.
//
// This does NOT remove every unknown - see FSB5HeaderRebuild.h and
// FSB5VorbisExtract.h for what's still unverified (the coefficient table
// mapping and the FSB5 packed-header bit layout) before treating output
// from this pipeline as trustworthy on-device.
//
// Every write to the game's own bank file is still preceded by a
// one-time, never-overwritten backup (<name>.bank.orig-bak) so
// +restoreAllBackedUpBanksWithError: can always get back to the untouched
// stock file regardless of how many times a bank has since been re-swapped.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BankTransplantErrorDomain;

typedef NS_ENUM(NSInteger, BankTransplantErrorCode) {
    BankTransplantErrorCantReadModded = 1,
    BankTransplantErrorOriginalNotFound,     // no file with the modded bank's name under the Mobile FMOD build directory
    BankTransplantErrorCantReadOriginal,
    BankTransplantErrorBadOriginalWrapper,   // stock doesn't parse as a RIFF/FEV bank with an SNDH+SND wrapper
    BankTransplantErrorBadModdedWrapper,     // modded doesn't parse the same way
    BankTransplantErrorSampleSetMismatch,    // sample name tables differ between the two FSB5 blobs - refused, not re-encoded
    BankTransplantErrorModdedNotVorbis,      // modded's FSB5 mode isn't 15 (Vorbis) - nothing to re-encode
    BankTransplantErrorVorbisNotLinked,      // <vorbis/codec.h> wasn't found at compile time - BT_HAVE_LIBVORBIS never got defined, so this build has no decoder at all regardless of any sample's content
    BankTransplantErrorVorbisSetupUnknown,   // a sample's crc32 wasn't found in the bundled known-setup-packet table (see FSB5VorbisExtract.h) - can't decode without FMOD's own preset codebook for it
    BankTransplantErrorVorbisDecodeFailed,   // libvorbis IS linked and ran, but rejected/errored on this specific sample's packet stream - a real decode failure, not a build problem
    BankTransplantErrorBackupFailed,         // couldn't create the one-time backup of the original before touching it
    BankTransplantErrorWriteFailed,          // re-encode succeeded but writing/swapping the result on disk failed
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
// backs that file up on first touch, decodes every Vorbis sample in the
// modded bank to PCM, re-encodes each to FADPCM, rebuilds sample headers
// against the stock file's own header table, and atomically replaces the
// stock bank in place. Returns NO and fills error on any failure (nothing
// on disk is modified in that case, aside from the backup, which is
// always safe to have made).
//
// This can legitimately be slow (real Vorbis decode + a from-scratch
// analysis-by-synthesis ADPCM encoder, per-sample, on-device) - callers
// should not run it on the main thread for anything but tiny test banks.
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
