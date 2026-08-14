// PatchManifestSync.h
//
// Closes the gap BankTransplant.h's own history section already flags:
// swapping a bank file in place fixes the CURRENT session (TextAssetPatch's
// integrity gate, per the project's own notes, resolves once during the
// login/"connecting" sequence, and BankTransplant only runs later, as a
// user-triggered action from the Mods panel - by construction, after that
// gate has already passed for this run). What it doesn't fix is the NEXT
// cold boot: TextAssetPatchManager.CheckUpdate() runs again before the
// user can re-invoke a swap, and diffs against a local manifest that still
// records the ORIGINAL stock file's hash for that entry - so a swapped
// file that's still in place looks exactly like local tampering on the
// next check, which is precisely the mismatch this whole project exists to
// route around.
//
// This does NOT reimplement TextAssetPatch's hashing or its manifest
// encryption. Both are unknowns (algorithm, cipher mode, on-disk format)
// that would have to be reverse-engineered and kept in sync with the
// game's own implementation across updates. Instead this calls the game's
// OWN public manifest generator - TextAssetPatchInfoManager
// .GeneratePatchInfoFileFmod(encryptKey, encryptIV) - with the key/IV read
// from TextAssetPatchConfig.Instance, also the game's own. That method
// rescans the FMOD directory (config-driven, not path-argument-driven) and
// rewrites the local encrypted manifest to match whatever's currently on
// disk - which by the time this runs, includes BankTransplant's swapped
// file. Self-consistent by construction: the same code that will read
// this file back next boot is the code that wrote it, using its own key.
// No hash algorithm or encryption scheme needs to be known or matched by
// this tweak at all.
//
// UNVERIFIED - the one real unknown here: GeneratePatchInfoFileFmod's RVA
// is present in the shipped IL2CPP dump (not -1), so it's compiled into
// the player build and isn't stripped as editor-only. But its name and
// argument shape (no path arguments, just the encrypt key/IV - everything
// else evidently comes from TextAssetPatchConfig) strongly suggest it was
// written as a build-time tool Project Moon runs in-editor to produce the
// manifest that ships with the app, not something previously exercised at
// runtime in a live player. It may have an editor-only dependency that
// throws instead of no-oping - that would surface as invokeMethod:...
// setting outException, which this treats as an ordinary failure (logged,
// error filled, nothing left half-written), not a crash. This needs an
// on-device log check the first time it actually runs before it can be
// trusted the way the rest of this project's confirmed pieces are.
//
// Every call in here goes through IL2CppBridge exactly like GDScripts.m -
// plain managed method invocation via il2cpp_runtime_invoke, the same
// mechanism this project has used everywhere without incident. Nothing
// here does inline/native hooking - see GDScripts.h's own note on why a
// Dobby inline hook was tried once for a different problem and abandoned
// after it crashed the game before login. That lesson is exactly why this
// file exists instead of a hook on TextAssetPatchInfoManager's diff
// methods.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PatchManifestSyncErrorDomain;

typedef NS_ENUM(NSInteger, PatchManifestSyncErrorCode) {
    // IL2CppBridge itself couldn't resolve libil2cpp symbols - nothing
    // in this file (or the rest of the tweak's IL2CPP-mediated features)
    // can work on this build.
    PatchManifestSyncErrorBridgeUnavailable = 1,
    // TextAssetPatch.TextAssetPatchConfig or TextAssetPatchInfoManager
    // wasn't found in Assembly-CSharp - either a game update renamed/
    // moved these, or (less likely, see header notes above) this slice
    // of TextAssetPatch was stripped from this specific build.
    PatchManifestSyncErrorClassNotFound,
    // A specific method (get_Instance, get_EncryptKey, get_EncryptIV,
    // or GeneratePatchInfoFileFmod) wasn't found by name/arg-count on an
    // otherwise-resolved class.
    PatchManifestSyncErrorMethodNotFound,
    // TextAssetPatchConfig.get_Instance() returned NULL - the config
    // singleton hasn't been initialized yet. Likely means this ran too
    // early (before TextAssetPatch's own boot-time init) - retry after
    // the game is fully at the main menu, which BankTransplant's own
    // Mods-panel-triggered entry point already guarantees in practice.
    PatchManifestSyncErrorConfigInstanceUnavailable,
    // EncryptKey/EncryptIV read back NULL from the config instance.
    PatchManifestSyncErrorKeyOrIVUnavailable,
    // GeneratePatchInfoFileFmod was called and either threw an IL2CPP
    // exception or returned NULL where control flow was expected to
    // fall through cleanly - see the UNVERIFIED note above. Check the
    // ZLog output (Verbose filter, kZLogTag) for the exception detail
    // IL2CppBridge itself already logs on any thrown exception.
    PatchManifestSyncErrorGenerateCallFailed,
};

@interface PatchManifestSync : NSObject

// Re-syncs TextAssetPatch's local FMOD manifest against whatever's
// currently on disk under the Mobile FMOD build directory, using the
// game's own TextAssetPatchInfoManager.GeneratePatchInfoFileFmod and its
// own TextAssetPatchConfig-held encrypt key/IV. Call this once after
// BankTransplant finishes a swap (or a restore) - not per-sample, not
// per-file; one call resyncs the whole directory since that's how the
// underlying game method works.
//
// This performs a real file rescan + hash + encrypt of every file under
// the FMOD directory on the calling thread - same "don't call this on
// the main thread" guidance as +[BankTransplant
// transplantAndSwapModdedBankAtURL:error:] and for the same reason.
// Callers already invoking that off-main-thread (as BankTransplant.h
// requires) can chain this right after with no extra dispatch needed.
//
// Returns NO and fills error on any failure. A NO here does NOT mean the
// bank swap itself failed or should be rolled back - the swapped file is
// still valid and playable for the current session either way (per the
// header notes above, THIS session's integrity gate already passed
// before this code path is even reachable). It only means the NEXT cold
// boot's integrity check may flag the swapped file again, same as before
// this file existed. Callers should surface this as a soft warning, not
// treat it as the swap having failed.
+ (BOOL)resyncFmodPatchManifestWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
