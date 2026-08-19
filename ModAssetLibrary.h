// ModAssetLibrary.h
//
// Bookkeeping only - this does NOT swap anything into the game itself.
// It's a user-organized shelf of modded asset files (grouped into named
// folders, e.g. one per mod pack) living under +modLibraryRootDirectory,
// each folder backed by one manifest.json tracking what's in it.
//
// REIMPLEMENTED against the current pipeline. The original version of
// this class (see git history) resolved a bundle-kind entry's "where did
// this go" field by reading its CAB out of the file itself
// (UnityBundleCAB.h) and matching that against BundleTransplant's own
// live-scanned cache of __data files. Both of those classes are gone -
// see the README's "Visual (bundle/texture) mod support - removed"
// section - along with the whole in-process retarget pipeline they
// belonged to. There is no CAB parser and no cache scanner left in this
// project to lean on.
//
// So this version tracks less, on purpose:
//   - `kind` is a cheap sniff (file extension + a "UnityFS" magic check
//     on the first few bytes - see +mal_kindForFileAtPath: in the .m) as
//     opposed to a real parse. It only has to be good enough to route an
//     entry to the right restore action; it doesn't need to know
//     anything about the bundle's internal structure.
//   - `installedStockBundlePath` replaces the old CAB-matched
//     `livePathDescription` for bundle-kind entries. It's not resolved
//     automatically - it's RECORDED, once, by
//     +recordInstalledStockBundlePath:forEntry:inFolder:error: after a
//     caller (GraphicsDebugOverlay's Load Mods flow) has actually run an
//     entry through BundleDoctorService + BundleDoctorInstaller and
//     knows for a fact which on-disk stock bundle it just overwrote.
//     There's no live cache to scan for a match anymore, so this class
//     no longer tries to guess - same shift BundleDoctorInstaller.h's
//     own header already made (explicit stockBundleURL parameter,
//     picked by the person, rather than a scanned guess).
//   - Bank-kind entries keep the same deterministic resolution as
//     before: +[BankTransplant mobileFMODBuildsDirectory]/<fileName> is
//     always where a bank-kind entry would install to, since that
//     directory is fixed and BankTransplant itself is unchanged.
//
// livePathDescription is still computed once and cached on the entry
// (same reasoning as before - a person glancing at "where did this go"
// doesn't need it recomputed on every render), but it's now cheap enough
// (no bundle cache scan) that "once, at import/record time" is a
// convenience rather than a hard requirement.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ModAssetLibraryErrorDomain;

typedef NS_ENUM(NSInteger, ModAssetLibraryErrorCode) {
    ModAssetLibraryErrorInvalidFolderName = 1, // empty, or not representable as a single path component
    ModAssetLibraryErrorFolderAlreadyExists,
    ModAssetLibraryErrorFolderNotFound,
    ModAssetLibraryErrorEntryNotFound,
    ModAssetLibraryErrorCopyFailed,
    ModAssetLibraryErrorManifestReadFailed,
    ModAssetLibraryErrorManifestWriteFailed,
    ModAssetLibraryErrorDeleteFailed,
};

// What a tracked file looks like, as far as this class can tell without
// parsing it. Unknown just means "not a .bank and doesn't start with the
// UnityFS magic" - it's still tracked, just with no restore action of
// its own (same as the old cab == nil case).
typedef NS_ENUM(NSInteger, ModAssetLibraryEntryKind) {
    ModAssetLibraryEntryKindUnknown = 0,
    ModAssetLibraryEntryKindBank,
    ModAssetLibraryEntryKindBundle,
};

// One tracked file inside one folder. See this header's own top comment
// for what each field means and where it comes from.
@interface ModAssetLibraryEntry : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, assign) ModAssetLibraryEntryKind kind;
@property (nonatomic, copy) NSString *path;               // full on-disk path, under the owning folder
@property (nonatomic, assign) unsigned long long byteSize;
@property (nonatomic, copy) NSString *dateAdded;           // ISO 8601, UTC

// Bundle-kind only. The stock bundle path this entry was last installed
// to via BundleDoctorInstaller, or nil if it never has been. See this
// header's top comment - this is RECORDED by a caller after a real
// install, never guessed at.
@property (nonatomic, copy, nullable) NSString *installedStockBundlePath;

// Bundle-kind only. Whether this library copy is itself already the
// doctored (re-platformed/re-encoded) output of BundleDoctorService, as
// opposed to the original modded desktop bundle still awaiting a trip
// through it. Purely informational - this class doesn't act on it.
@property (nonatomic, assign) BOOL doctored;

// Human-readable "where this lives (or would live) within the game's
// own files" - see this header's top comment for how this differs per
// kind. Never nil; falls back to a plain "Not installed yet." for
// bundle-kind entries with no installedStockBundlePath.
@property (nonatomic, copy) NSString *livePathDescription;
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

// Same as +createFolderNamed:error:, except an already-existing folder
// with this name is treated as success (its existing manifest is left
// untouched) rather than ModAssetLibraryErrorFolderAlreadyExists. For
// callers (like GraphicsDebugOverlay's bank/bundle flows) that just want
// "make sure this folder exists" without caring whether it already did.
+ (BOOL)ensureFolderNamed:(NSString *)name error:(NSError **)error;

// Reads folderName's manifest.json back into entries, oldest-added
// first. Returns nil (not an empty array) with error filled if the
// folder itself doesn't exist.
+ (nullable NSArray<ModAssetLibraryEntry *> *)entriesInFolder:(NSString *)folderName error:(NSError **)error;

// Copies each URL into folderName (renaming on collision by appending
// " 2", " 3", ... before the extension - never silently overwrites an
// existing tracked file), sniffs each one's `kind` (best-effort - see
// this header's top comment; a sniff failure just means kind stays
// Unknown, not a hard failure for the whole import), and appends one
// entry per file to that folder's manifest.json. moddedURLs are handled
// the same security-scoped-resource way BankTransplant/
// BundleDoctorService already do for picker URLs.
//
// Partial success is possible (some files copy, one doesn't) - this
// still returns YES if at least one file made it in, with the failures
// logged via ZLog rather than aborting the whole import over one bad
// file. Returns NO only if folderName itself doesn't exist or the
// manifest couldn't be written back at all.
+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs intoFolder:(NSString *)folderName error:(NSError **)error;

// Copies a single already-on-disk file (not a security-scoped picker
// URL - e.g. a temp file this tweak produced itself, like
// BundleDoctorService's doctored-bundle output) into folderName the same
// way +importFileURLs:intoFolder:error: does, and returns the resulting
// entry directly so a caller can immediately follow up with
// +recordInstalledStockBundlePath:forEntry:inFolder:error: without a
// second +entriesInFolder: round trip. `doctored` seeds the new entry's
// doctored flag (irrelevant for bank-kind files).
+ (nullable ModAssetLibraryEntry *)importLocalFileAtPath:(NSString *)localPath
                                                intoFolder:(NSString *)folderName
                                                 doctored:(BOOL)doctored
                                                     error:(NSError **)error;

// Updates one bundle-kind entry's installedStockBundlePath (and
// livePathDescription) after a real BundleDoctorInstaller swap, and
// rewrites the manifest. `entry` is matched by its `path` against what's
// currently on disk for folderName - pass back the same
// ModAssetLibraryEntry (or an equal-`path` one) returned by
// +importLocalFileAtPath:intoFolder:doctored:error: or
// +entriesInFolder:error:. Fails with ModAssetLibraryErrorEntryNotFound
// if no current entry in folderName has a matching path.
+ (BOOL)recordInstalledStockBundlePath:(NSString *)stockBundlePath
                              forEntry:(ModAssetLibraryEntry *)entry
                              inFolder:(NSString *)folderName
                                 error:(NSError **)error;

// Removes one entry's on-disk file and its manifest.json record. Does
// NOT touch anything under +[BankTransplant mobileFMODBuildsDirectory]
// or wherever a bundle-kind entry's installedStockBundlePath points -
// this only forgets the library's own tracked copy.
+ (BOOL)removeEntry:(ModAssetLibraryEntry *)entry fromFolder:(NSString *)folderName error:(NSError **)error;

// Deletes folderName entirely - its manifest.json, every tracked file
// under it, and the folder itself. Same "library bookkeeping only"
// scope as +removeEntry:fromFolder:error: - does NOT touch anything the
// game itself reads; callers that want swapped-in files restored first
// should drive BankTransplant/BundleDoctorInstaller themselves before
// calling this.
+ (BOOL)deleteFolderNamed:(NSString *)folderName error:(NSError **)error;

// Renames folderName's directory in place (its manifest.json and every
// tracked file move with it - a plain directory move, not a per-file
// copy) to newName. newName is validated the same way
// +createFolderNamed:error: validates its own name argument. Fails with
// ModAssetLibraryErrorFolderAlreadyExists if newName already names a
// different existing folder.
+ (BOOL)renameFolderNamed:(NSString *)folderName to:(NSString *)newName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
