// UnityCacheLocator.h
//
// Reintroduces the CAB-based bundle lookup this project used to have
// (see ModAssetLibrary.h/BundleDoctorInstaller.h's "CAB-based bundle
// matching is gone" notes) - but as its own class now, not baked into
// BundleTransplant like before. UnityBundleCAB.h/.m + LZ4BlockDecoder.h/.m
// do the actual UnityFS header parsing; this class is just "where do I
// look, and what counts as a match."
//
// WHAT THIS SOLVES: BundleDoctorInstaller.h intentionally does NOT guess
// where a stock bundle lives on disk - see that file's own header - so
// today the Load Mods flow makes the person pick the destination by hand
// via a second document-picker pass every time. A bundle's own CAB name
// (the identity string baked into its UnityFS directory table - see
// UnityBundleCAB.h) is exactly the thing that lets this be automatic
// instead: read the CAB off the modded/doctored bundle, then find the
// cached stock file that reports the SAME CAB as its own identity. Two
// files with matching CABs are the same logical asset, regardless of
// which cache subfolder either one happens to sit in.
//
// WHERE THIS LOOKS: confirmed path is Library/UnityCache/Shared -
// directly under this app's own Library directory, NOT under
// Library/Caches (an earlier version of this class guessed Caches,
// since that's Unity's more commonly documented cache location in
// general - it isn't what this project's own cache actually uses).
// +unityCacheSharedDirectories still does a short bounded walk under
// Library rather than hardcoding that one path outright, so a build
// that adds one more layer of nesting above UnityCache doesn't silently
// stop matching.
//
// MATCH SEMANTICS: a "match" is a regular file under a UnityCache/Shared
// root whose OWN UnityBundleCAB primary CAB string equals the CAB being
// searched for. Every regular file encountered is handed to
// +[UnityBundleCAB primaryCABForBundleAtPath:error:] and the result kept
// only on success - most files under a Unity cache tree are NOT
// standalone UnityFS bundles (manifest/info sidecar files, partial
// downloads, etc.), and UnityBundleCAB's own header-signature check
// rejects those cheaply (a handful of bytes read) rather than this class
// trying to pre-filter by filename convention it hasn't independently
// confirmed either.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const UnityCacheLocatorErrorDomain;

typedef NS_ENUM(NSInteger, UnityCacheLocatorErrorCode) {
    UnityCacheLocatorErrorSourceCABUnreadable = 1, // couldn't get a CAB off the source (modded/doctored) bundle at all
    UnityCacheLocatorErrorSharedDirectoryNotFound, // no "UnityCache/Shared"-shaped directory found under Library
    UnityCacheLocatorErrorNoMatch,                 // searched every candidate root, nothing reported this CAB as its own
};

@interface UnityCacheLocator : NSObject

// Every directory found under this app's own Library directory whose own name
// is "Shared" with an immediate parent named "UnityCache" - practically
// just Library/UnityCache/Shared (confirmed on-device), but this walks
// for it rather than hardcoding that single path outright - see this
// file's header. Empty (not nil) array if the directory genuinely isn't
// there (e.g. nothing's ever been cached yet); this is not itself an error.
+ (NSArray<NSString *> *)unityCacheSharedDirectories;

// Convenience: reads moddedOrDoctoredBundlePath's own CAB via
// +[UnityBundleCAB primaryCABForBundleAtPath:error:] and returns it, or
// nil + UnityCacheLocatorErrorSourceCABUnreadable (wrapping whatever
// UnityBundleCAB itself reported) if that bundle isn't parseable at all.
// Doctoring (BundleDoctorService) only re-encodes Texture2D/TextAsset
// object bytes, not the archive's own directory-table CAB name, so
// either the pre-doctor modded file or the post-doctor result reads the
// same CAB - callers can use whichever they still have a path to.
+ (nullable NSString *)cabForBundleAtPath:(NSString *)moddedOrDoctoredBundlePath error:(NSError **)error;

// Every cached file under every +unityCacheSharedDirectories root whose
// own primary CAB (per UnityBundleCAB) equals `cab`, newest-modified
// first. Empty (not nil) array if the search completed but nothing
// matched - see +locateBundlePathForCAB:error: for the "give me just
// the one to use" convenience that turns "empty" into a proper error.
+ (NSArray<NSString *> *)allBundlePathsForCAB:(NSString *)cab;

// The single best match for `cab` - the newest-modified entry from
// +allBundlePathsForCAB: - or nil with `error` filled in (No shared
// directory found at all vs. searched but no file reported this CAB)
// when there's nothing to return.
+ (nullable NSString *)locateBundlePathForCAB:(NSString *)cab error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
