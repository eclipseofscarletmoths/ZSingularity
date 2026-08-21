// ModAssetLibrary.h
//
// Bookkeeping only - this does NOT swap anything into the game itself.
// It's a user-organized shelf of modded asset files (grouped into named
// folders, e.g. one per mod pack) living under +modLibraryRootDirectory,
// each folder backed by one manifest.json tracking what's in it. The
// Mods panel's "Add Asset" flow copies picked files in here and records
// them; the accordion list reads this back to render folders/entries.
//
// Per-entry CAB matching (resolving a tracked file against the game's
// live Unity bundle cache) doesn't exist anymore - it depended on
// BundleTransplant/UnityBundleCAB, both retired when the on-device
// retargeting pipeline was replaced by BundleDoctorService's cloud
// doctor-bundle flow. There's no per-entry "Reset" lever at the model
// layer as a result; the Mods panel's entry rows fall back to the
// existing all-or-nothing "Restore Originals" action for that instead
// (see -restoreOriginalsTapped in GraphicsDebugOverlay.m) rather than
// this class trying to resolve a live match itself.
//
// This intentionally does not try to read a file's size against
// anything live-cached by the game - byteSize here is just this
// ON-DISK LIBRARY COPY's own size, recorded once at import time, for
// display and as one of the "uniquely identifiable" fields requested.
// It is not re-validated against anything.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ModAssetLibraryErrorDomain;

typedef NS_ENUM(NSInteger, ModAssetLibraryErrorCode) {
    ModAssetLibraryErrorInvalidFolderName = 1, // empty, or not representable as a single path component
    ModAssetLibraryErrorFolderAlreadyExists,
    ModAssetLibraryErrorFolderNotFound,
    ModAssetLibraryErrorCopyFailed,
    ModAssetLibraryErrorManifestReadFailed,
    ModAssetLibraryErrorManifestWriteFailed,
    ModAssetLibraryErrorDeleteFailed,
    ModAssetLibraryErrorEntryNotFound,          // +updateDoctorStateForEntry:... couldn't find a manifest row matching entry.path
};

// Where one entry sits in the (new, opt-in) manual dispatch flow for the
// BundleDoctorService cloud pipeline. This replaces the old behavior of
// kicking a bundle to the doctor pipeline automatically at import time -
// see BundleDoctorService.h's own header for the phase-by-phase API this
// tracks. Persisted per-entry in manifest.json so it survives the app
// being backgrounded/relaunched mid-flight; the panel rebuilds its rows
// from this on every -gd_rebuildModsLibrary, it does not keep its own
// shadow state.
//
// Meaningless (and left at NotDispatched/0) for anything that never goes
// through the doctor pipeline in the first place - i.e. .bank entries;
// ModAssetLibrary itself doesn't gate on file kind (see this header's
// top comment - bookkeeping only), the panel is what decides which rows
// get a dispatch capsule at all.
// Installed is appended AFTER Failed (rather than slotted in where it
// conceptually belongs, right after ReadyToDownload) on purpose - every
// case's raw integer value is persisted verbatim into manifest.json (see
// ModAssetLibrary.m's +dictionaryRepresentation/+entryFromDictionary:),
// so inserting a case in the middle would silently reinterpret every
// already-written Failed row (previously the last/highest value) as
// something else. Appending keeps every prior case's on-disk meaning
// stable; only the C enum's declaration order looks slightly out of
// sequence as a result.
typedef NS_ENUM(NSInteger, ModAssetLibraryDoctorStatus) {
    ModAssetLibraryDoctorStatusNotDispatched = 0, // default - dispatch capsule shown, nothing sent yet
    ModAssetLibraryDoctorStatusUploading,          // BundleDoctorService dispatchBundleAtURL:... in flight - see doctorUploadProgress
    ModAssetLibraryDoctorStatusProcessing,         // uploaded + workflow dispatched, waiting on the run - see doctorProcessProgress
    ModAssetLibraryDoctorStatusReadyToDownload,    // run succeeded, doctored bundle not yet pulled down - download button shown
    ModAssetLibraryDoctorStatusFailed,             // see doctorLastError
    ModAssetLibraryDoctorStatusInstalled,          // doctored bundle fetched AND swapped in via BundleDoctorInstaller - terminal, no button
};

// One tracked file inside one folder. See this header's own top comment
// for what each field means and where it comes from.
@interface ModAssetLibraryEntry : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *path;               // full on-disk path, under the owning folder - see +importFileURLs:intoFolder:error: for the CAB-subfolder case
@property (nonatomic, assign) unsigned long long byteSize;
@property (nonatomic, copy) NSString *dateAdded;           // ISO 8601, UTC

// Whether +importFileURLs:intoFolder:error: identified this file as a
// UnityFS asset bundle by its actual header bytes (see
// +[UnityBundleCAB isUnityFSBundleAtPath:]) at import time - NOT a
// re-derived check against fileName, which for a bundle-kind entry is
// always literally "__data" (see the CAB-subfolder note on `path`
// above) precisely because that's the one name Unity's own loader
// requires it to have, not because the name is what identifies it as
// a bundle. Persisted so callers (the doctor-pipeline dispatch slot in
// GraphicsDebugOverlay.m's row builder, in particular) don't need to
// re-open and re-sniff the file on every rebuild just to decide
// whether a row gets a dispatch capsule.
@property (nonatomic, assign) BOOL isAssetBundle;

// The bundle's own CAB id (e.g. @"CAB-3832197875c1bd4d48da9ab24c88e996"),
// resolved once at import time the same way the CAB-named subfolder
// itself is (+[UnityBundleCAB primaryCABForBundleAtPath:error:]) - see
// +importFileURLs:intoFolder:error:. nil for a non-bundle entry, and
// also nil (rather than guessed) for a bundle whose CAB id couldn't be
// read at import time (see that method's own comment on the flat-
// placement fallback).
@property (nonatomic, copy, nullable) NSString *cabIdentifier;

// The Unity BuildTarget integer read out of the bundle's own primary
// SerializedFile header at import time (+[UnityBundleCAB
// targetPlatform:forBundleAtPath:error:]) - e.g. 19 for
// StandaloneWindows64. nil for a non-bundle entry, or for a bundle this
// couldn't be read from (unsupported compression, malformed header,
// etc.) - never a guessed/default value. +[UnityBundleCAB
// nameForTargetPlatform:] turns this into a human-readable name.
@property (nonatomic, copy, nullable) NSNumber *targetPlatform;

// Human-readable description of where this file lives (or would live)
// WITHIN THE GAME's own files - i.e. wherever it was/would be swapped
// into. Only ever resolvable for a .bank file (the one deterministic
// +[BankTransplant mobileFMODBuildsDirectory]/<fileName>) - anything
// else has no fixed destination this class can name anymore now that
// CAB-based bundle matching is gone, and reads back nil.
//
// Resolved exactly ONCE, at import time
// (+importFileURLs:intoFolder:error:), and never recomputed after.
@property (nonatomic, copy, nullable) NSString *livePathDescription;

// --- Doctor-pipeline dispatch state (see ModAssetLibraryDoctorStatus above) ---
// All of this is plain bookkeeping mirrored from BundleDoctorService
// call sites via +updateDoctorStateForEntry:inFolder:applyBlock:error:
// below - this class never calls BundleDoctorService itself.
@property (nonatomic, assign) ModAssetLibraryDoctorStatus doctorStatus;
@property (nonatomic, assign) double doctorUploadProgress;   // 0.0-1.0; meaningful only while doctorStatus == Uploading
@property (nonatomic, assign) double doctorProcessProgress;  // 0.0-1.0; meaningful only while doctorStatus == Processing
@property (nonatomic, copy, nullable) NSString *doctorScratchBranch; // BundleDoctorHandle.scratchBranch, once dispatched
@property (nonatomic, copy, nullable) NSString *doctorRunID;         // filled in once +resolveRunForHandle:... finds it
@property (nonatomic, copy, nullable) NSString *doctorRunURL;        // for surfacing "view run" on failure
@property (nonatomic, copy, nullable) NSString *doctorLastError;     // localizedDescription of the last failure, if doctorStatus == Failed
@end

@interface ModAssetLibrary : NSObject

// Library/ZSingularityModsLibrary inside this app's sandbox - same
// "own Library directory, not the game's caches/cache-scanned trees"
// placement as +bankBackupDirectory/+bundleBackupDirectory.
+ (NSString *)modLibraryRootDirectory;

// Every existing folder name, alphabetical. Empty (not nil) if the root
// doesn't exist yet - i.e. nothing's been added.
+ (NSArray<NSString *> *)folderNames;

// Creates an empty folder (and its manifest.json) under
// +modLibraryRootDirectory. `name` is used as a single path component
// as-is - fails with ModAssetLibraryErrorInvalidFolderName if it
// contains a "/" or is empty after trimming whitespace, rather than
// silently sanitizing into something the person didn't type.
+ (BOOL)createFolderNamed:(NSString *)name error:(NSError **)error;

// Reads folderName's manifest.json back into entries, oldest-added
// first. Returns nil (not an empty array) with error filled if the
// folder itself doesn't exist.
+ (nullable NSArray<ModAssetLibraryEntry *> *)entriesInFolder:(NSString *)folderName error:(NSError **)error;

// Copies each URL into folderName and appends one entry per file to
// that folder's manifest.json. moddedURLs are handled the same
// security-scoped-resource way BankTransplant already does for picker
// URLs.
//
// Each file's own bytes (not its name/extension) decide where it lands,
// via +[UnityBundleCAB isUnityFSBundleAtPath:]:
//   - A file whose header actually starts with the UnityFS signature is
//     a bundle. Two bundles cannot both be named "__data" in the same
//     folder (Unity's loader requires that exact literal name, so it
//     can't be renamed away like an ordinary collision), so each one
//     gets its own subfolder instead, named after the bundle's own CAB
//     id (+[UnityBundleCAB primaryCABForBundleAtPath:error:]):
//     folderName/<CAB id>/__data. If that CAB id is already taken
//     (re-importing the same bundle) the subfolder name gets a
//     " 2"/" 3"/... suffix, same collision policy as below, just at the
//     folder level instead of the file level. entry.isAssetBundle is
//     set YES for these, and entry.cabIdentifier/entry.targetPlatform
//     are populated where readable (see those properties' own comments
//     for when either can come back nil instead).
//   - Anything else is placed directly under folderName as before,
//     renamed on collision by appending " 2", " 3", ... before the
//     extension - never silently overwrites an existing tracked file.
//
// Partial success is possible (some files copy, one doesn't) - this
// still returns YES if at least one file made it in, with the failures
// logged via ZLog rather than aborting the whole import over one bad
// file. Returns NO only if folderName itself doesn't exist or the
// manifest couldn't be written back at all.
+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs intoFolder:(NSString *)folderName error:(NSError **)error;

// Removes one entry's on-disk file and its manifest.json record. For a
// bundle-kind entry (see +importFileURLs:intoFolder:error:) whose file
// sits in its own CAB-named subfolder, also removes that subfolder once
// it's empty - so deleting the entry doesn't leave a stray, empty
// CAB-<hash> directory sitting in the folder. Does NOT touch anything
// under +unityCacheSharedDirectory/+mobileFMODBuildsDirectory or either
// backup directory - this only forgets the library's own tracked copy.
+ (BOOL)removeEntry:(ModAssetLibraryEntry *)entry fromFolder:(NSString *)folderName error:(NSError **)error;

// Reads folderName's manifest, finds the row matching entry.path,
// invokes applyBlock with a mutable copy of that row's current state
// so the caller can set doctorStatus/doctorUploadProgress/etc, then
// writes the whole manifest back and returns the updated entry. This is
// a read-modify-write against on-disk state, not against the `entry`
// object passed in - so it's safe to call repeatedly from a 6s poll
// timer even if `entry` itself is stale (e.g. the accordion was
// rebuilt since). Returns nil and fills error with
// ModAssetLibraryErrorEntryNotFound if no row in folderName still has
// entry.path (e.g. it was deleted mid-flight), or
// ModAssetLibraryErrorFolderNotFound if folderName itself is gone.
+ (nullable ModAssetLibraryEntry *)updateDoctorStateForEntry:(ModAssetLibraryEntry *)entry
                                                      inFolder:(NSString *)folderName
                                                    applyBlock:(void (NS_NOESCAPE ^)(ModAssetLibraryEntry *entryToMutate))applyBlock
                                                         error:(NSError **)error;

// Deletes folderName entirely - its manifest.json, every tracked file
// under it, and the folder itself. Same "library bookkeeping only"
// scope as +removeEntry:fromFolder:error: - does NOT touch anything
// under +unityCacheSharedDirectory/+mobileFMODBuildsDirectory or
// either backup directory; callers that want anything actually
// swapped-in restored first should drive BankTransplant (or the
// panel's general "Restore Originals" action) themselves before
// calling this.
+ (BOOL)deleteFolderNamed:(NSString *)folderName error:(NSError **)error;

// Renames folderName's directory in place (its manifest.json and every
// tracked file move with it - a plain directory move, not a per-file
// copy) to newName. newName is validated the same way
// +createFolderNamed:error: validates its own name argument. Fails with
// ModAssetLibraryErrorFolderAlreadyExists if newName already names a
// different existing folder.
+ (BOOL)renameFolderNamed:(NSString *)folderName to:(NSString *)newName error:(NSError **)error;

// Deletes +modLibraryRootDirectory entirely - every folder, manifest,
// and tracked file the library has ever recorded, root directory
// included. Same "library bookkeeping only" scope as
// +deleteFolderNamed:error: (does not touch anything under
// +unityCacheSharedDirectory/+mobileFMODBuildsDirectory or either
// backup directory) - this is the Config section's "Hard Assets Reset"
// clearing its own bookkeeping, not the game-file deletion side of that
// action (see +[BankTransplant deleteAllTrackedBanksAndBackupsWithError:]
// / +[BundleDoctorInstaller deleteAllTrackedBundlesAndBackupsWithError:]
// for that). Same "already-clean is success, not failure" convention as
// +[BundleDoctorSettings clearAllWithError:] - returns YES if the end
// state is "nothing stored", even if the root directory never existed.
+ (BOOL)deleteAllFoldersWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
