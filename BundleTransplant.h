// BundleTransplant.h
//
// The general-purpose counterpart to BankTransplant.h/.m: instead of one
// hardcoded FMOD bank swap, this handles arbitrary Unity AssetBundles
// (whatever's sitting under Library/UnityCache/Shared, however deep it's
// nested - see the recursion note below) by matching on CAB identity
// (UnityBundleCAB.h) rather than filename, since every cached bundle on
// disk is literally named "__data" - filename carries zero information
// here, unlike BankTransplant's Assets/Sound/FMODBuilds/Mobile directory
// where the filename IS the bank's identity.
//
// DIRECTORY SHAPE: Library/UnityCache/Shared/<dir>/<dir>/__data(+__info),
// per the project notes - but this doesn't hardcode that exact depth.
// Unity's own cache layout has varied by version (a two-level hash split
// is typical, to keep any one directory from holding too many entries,
// but isn't guaranteed), so this walks the whole Shared subtree
// recursively and treats any file literally named "__data" as a
// candidate, at whatever depth it's found. Slower than assuming a fixed
// depth, but doesn't silently miss entries if a given install's cache
// happens to be shaped differently.
//
// MATCHING: each modded bundle's own CAB (its first directory node - see
// UnityBundleCAB.h) is looked up against an index built by parsing every
// cached __data's CAB once. A CAB can legitimately appear more than once
// in the cache (the same asset downloaded under more than one session/
// build hash), so every match gets swapped, not just the first.
//
// __info FILES: best-effort only. This project doesn't have a confirmed
// spec for __info's binary layout (unlike the UnityFS format itself,
// which is well-documented - see UnityBundleCAB.h). What this does is
// narrow: if the old __data's exact byte size appears as a unique 4- or
// 8-byte little-endian integer inside __info, it's rewritten to the new
// size; otherwise __info is left untouched and a warning is logged. This
// is a heuristic, not a parser - if bundle loading validates __info
// against __data more strictly than a stored size (a hash, a timestamp
// tied to the CDN response, etc.), swapped bundles may still fail
// integrity checks that this can't currently satisfy. Treat this the same
// way BankTransplant.h treats its own open questions: unverified until
// confirmed on-device.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleTransplantErrorDomain;

typedef NS_ENUM(NSInteger, BundleTransplantErrorCode) {
    BundleTransplantErrorCantReadModded = 1,
    BundleTransplantErrorModdedCABFailed,     // UnityBundleCAB couldn't parse the picked file - see its own error for why
    BundleTransplantErrorNoCacheDirectory,    // Library/UnityCache/Shared doesn't exist (game may never have cached anything yet)
    BundleTransplantErrorBackupFailed,
    BundleTransplantErrorWriteFailed,
};

// One picked modded bundle's outcome, reported back per-file since a
// multi-select import can partially succeed (some CABs found, some not).
@interface BundleTransplantResult : NSObject
@property (nonatomic, copy) NSString *moddedFileName;
@property (nonatomic, copy, nullable) NSString *cab;        // nil if CAB extraction itself failed
@property (nonatomic, assign) NSInteger swappedCount;        // number of cached __data files actually replaced
@property (nonatomic, copy, nullable) NSError *error;         // set if this file failed outright (extraction/read failure)
@end

@interface BundleTransplant : NSObject

// Library/UnityCache/Shared inside this app's own sandbox (the tweak runs
// in-process, so NSLibraryDirectory here already IS the game's own
// Library directory - same reasoning as BankTransplant's Documents note).
// UnityCache is a direct child of Library, not of Library/Caches - see
// the implementation note in the .m for why that distinction matters.
+ (NSString *)unityCacheSharedDirectory;

// moddedURLs are whatever the user multi-picked via
// UIDocumentPickerViewController - possibly security-scoped, same as
// BankTransplant. This starts/stops that access itself.
//
// Builds a CAB -> [cached __data paths] index by parsing every cached
// bundle's header ONCE (parallelized - see the .m), then for each modded
// URL: extracts its own CAB, looks it up in the index, backs up and
// swaps every matching cached __data (and best-effort patches its
// sibling __info - see the header note above).
//
// Always returns one BundleTransplantResult per input URL, in the same
// order, even on partial failure - check each result's own .error/.cab/
// .swappedCount rather than relying on a single overall BOOL, since
// "some matched, some didn't" is an expected, non-fatal outcome here.
// The only thing that aborts the whole call early is
// BundleTransplantErrorNoCacheDirectory (nothing to scan at all).
+ (nullable NSArray<BundleTransplantResult *> *)transplantAndSwapModdedBundlesAtURLs:(NSArray<NSURL *> *)moddedURLs
                                                                                  error:(NSError **)error;

// Restores every __data under +unityCacheSharedDirectory that has a
// matching __data.orig-bak from its backup, at whatever depth found -
// same recursive walk as the swap side. Returns the number of files
// restored, or -1 with error filled on a filesystem-level failure.
+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
