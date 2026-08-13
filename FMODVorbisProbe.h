// FMODVorbisProbe.h
//
// Answers the one open question BankTransplant's splice couldn't settle
// on its own (see BankTransplant.h and the project notes): does this
// device's FMOD runtime actually have a working Vorbis decoder, or not?
//
// BankTransplant's splice result gets rejected before that question is
// even reachable - something evaluates the resulting bank file (size or
// a checksum) and triggers a download prompt, independent of whether
// FMOD could have played it. This sidesteps that entirely by never
// touching a .bank, the Addressables system, or Unity's asset loader at
// all:
//
//   1. Pull the *complete, unmodified* FSB5 blob out of a desktop-coded
//      (Vorbis) .bank - the same bytes FMOD's own tools produced, byte-
//      for-byte. No re-encoding, no sample-header surgery: FSB5 is a
//      self-contained container FMOD can open on its own once separated
//      from the outer FEV/RIFF/SNDH wrapper, so this needs no format
//      knowledge beyond locating that blob (reuses the same wrapper-
//      chunk-walking approach as BankTransplant.h/.m).
//   2. Stage those bytes to a temp file.
//   3. Reach into the game's own already-running FMOD_SYSTEM (via
//      IL2CppBridge, reading FMODUnity.RuntimeManager.CoreSystem's
//      native handle) and call FMOD_System_CreateSound on it directly.
//
// Deliberately does NOT spin up a second, standalone FMOD::System: that
// would need a headerversion guess for FMOD_System_Create that could
// mismatch the actual linked runtime (FMOD_ERR_HEADER_MISMATCH), and
// would leave a second audio system alive alongside the game's own for
// no reason. Reusing the live system needs no version number at all and
// exercises the exact codec/plugin configuration real bank playback
// would use.
//
// A plain FMOD_OK back means Vorbis decode works on this device,
// independent of the Addressables/download-prompt question. Anything
// else - most usefully FMOD_ERR_FORMAT / FMOD_ERR_PLUGIN_MISSING /
// FMOD_ERR_UNSUPPORTED - means it doesn't, which is the answer the
// project notes flagged as still open after the IL2CPP dump (Vorbis is
// declared as a normal codec in the managed layer, but nothing there
// proves the native decoder is actually linked in for iOS).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FMODVorbisProbeErrorDomain;

typedef NS_ENUM(NSInteger, FMODVorbisProbeErrorCode) {
    FMODVorbisProbeErrorCantReadModded = 1,  // couldn't read the picked file
    FMODVorbisProbeErrorBadModdedWrapper,    // didn't parse as RIFF/FEV with an SNDH+SND+FSB5 wrapper
    FMODVorbisProbeErrorNotVorbisCoded,      // FSB5 mode field isn't 15 (Vorbis) - wrong file picked
    FMODVorbisProbeErrorTempWriteFailed,     // couldn't stage the extracted FSB5 blob to a temp file
    FMODVorbisProbeErrorNoLiveFMODSystem,    // couldn't resolve the game's FMOD_SYSTEM* via IL2CPP
    FMODVorbisProbeErrorNoFMODSymbols,       // FMOD_System_CreateSound etc. not resolvable via dlsym
};

@interface FMODVorbisProbe : NSObject

// moddedURL is whatever the user picked via UIDocumentPickerViewController -
// possibly security-scoped (outside the app sandbox, e.g. from Files/
// iCloud). This starts/stops that access itself; callers don't need to.
// Should point at a desktop-coded (Vorbis) .bank - the same kind
// BankTransplant's "Import Bank Mod" expects.
//
// On return, resultDescription is ALWAYS filled with a human-readable
// summary suitable for showing directly in an alert - this is true even
// on a "successful" probe that proves Vorbis is unsupported, since
// that's a valid, useful answer, not a failure. It includes the
// FMOD_RESULT name/code, and on FMOD_OK the decoded sound type/format/
// channel/length FMOD reports back, so a pass can be sanity-checked
// (e.g. confirming format really came back as Vorbis and not a silent
// fallback to something else).
//
// Returns NO and fills error ONLY for failures BEFORE FMOD_System_CreateSound
// was even reached (bad file picked, no live FMOD_SYSTEM found, etc.) -
// nothing on disk outside NSTemporaryDirectory() is touched by this
// class, and the temp file is always cleaned up before returning.
+ (BOOL)probeVorbisSupportWithModdedBankAtURL:(NSURL *)moddedURL
                            resultDescription:(NSString * _Nullable * _Nonnull)resultDescription
                                        error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
