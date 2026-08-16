// ModAssetLibrary.h
//
// Bookkeeping only - this does NOT swap anything into the game itself.
// It's a user-organized shelf of modded asset files (grouped into named
// folders, e.g. one per mod pack) living under +modLibraryRootDirectory,
// each folder backed by one manifest.json tracking what's in it. The
// Mods panel's "Add Asset" flow copies picked files in here and records
// them; the accordion list reads this back to render folders/entries.
//
// Per-entry CAB (when the file parses as a Unity bundle - see
// UnityBundleCAB.h) is what lets a single entry's "Reset" button target
// BundleTransplant's existing per-CAB restore
// (+restoreBackedUpBundlesForCAB:force:error:) rather than the
// all-or-nothing +restoreAllBackedUpBundlesWithForce:error:. Files that
// don't parse as a Unity bundle (e.g. an FMOD .bank picked in here by
// mistake, or any other file) are still tracked with cab == nil - reset
// isn't available for those from an entry row; BankTransplant.h's own
// restore-everything button is the only lever for that file type.
//
// This intentionally does not try to read a Unity bundle's size against
// the live cache the way BundleTransplant does at swap time - byteSize
// here is just this ON-DISK LIBRARY COPY's own size, recorded once at
// import time, for display and as one of the "uniquely identifiable"
// fields requested. It is not re-validated against anything.

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
};

// One tracked file inside one folder. See this header's own top comment
// for what each field means and where it comes from.
@interface ModAssetLibraryEntry : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy, nullable) NSString *cab;     // nil if this isn't a parseable Unity bundle
@property (nonatomic, copy) NSString *path;               // full on-disk path, under the owning folder
@property (nonatomic, assign) unsigned long long byteSize;
@property (nonatomic, copy) NSString *dateAdded;           // ISO 8601, UTC

// Human-readable description of where this file lives (or would live)
// WITHIN THE GAME's own files - i.e. wherever it was/would be swapped
// into. For a bundle this means resolving every cached __data whose own
// CAB matches this entry's (there can be more than one - see
// BundleTransplant.h's own MATCHING note); for a bank it's the one
// deterministic +[BankTransplant mobileFMODBuildsDirectory]/<fileName>.
//
// Resolved exactly ONCE, at import time
// (+importFileURLs:intoFolder:error:), and never recomputed after -
// resolving a bundle's match means reading every cached __data's CAB
// header (see UnityBundleCAB.h), which does not scale to "once per UI
// render": recomputing it every time an entry's Info dropdown opened
// used to mean rescanning the entire Unity bundle cache on every tap,
// which is exactly the hang this field exists to avoid. The tradeoff is
// staleness - if the game's cache changes shape after import (a fresh
// login re-caches something under a new hash, say), this won't reflect
// that until the entry is re-imported. Given what this field is FOR
// (a human glancing at "where did this go"), that's the right side of
// the tradeoff to be on.
@property (nonatomic, copy, nullable) NSString *livePathDescription;
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

// Copies each URL into folderName (renaming on collision by appending
// " 2", " 3", ... before the extension - never silently overwrites an
// existing tracked file), attempts a CAB read on each (best-effort -
// UnityBundleCAB failure just means cab stays nil, not a hard failure
// for the whole import), and appends one entry per file to that
// folder's manifest.json. moddedURLs are handled the same
// security-scoped-resource way BankTransplant/BundleTransplant already
// do for picker URLs.
//
// Partial success is possible (some files copy, one doesn't) - this
// still returns YES if at least one file made it in, with the failures
// logged via ZLog rather than aborting the whole import over one bad
// file. Returns NO only if folderName itself doesn't exist or the
// manifest couldn't be written back at all.
+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs intoFolder:(NSString *)folderName error:(NSError **)error;

// Removes one entry's on-disk file and its manifest.json record. Does
// NOT touch anything under +unityCacheSharedDirectory/
// +mobileFMODBuildsDirectory or either backup directory - this only
// forgets the library's own tracked copy.
+ (BOOL)removeEntry:(ModAssetLibraryEntry *)entry fromFolder:(NSString *)folderName error:(NSError **)error;

// Deletes folderName entirely - its manifest.json, every tracked file
// under it, and the folder itself. Same "library bookkeeping only"
// scope as +removeEntry:fromFolder:error: - does NOT touch anything
// under +unityCacheSharedDirectory/+mobileFMODBuildsDirectory or
// either backup directory; callers that want the actual swapped-in
// files restored first should walk +entriesInFolder:error: and drive
// BundleTransplant/BankTransplant themselves before calling this.
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
