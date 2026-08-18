// TextureAtlasTransplant.h
//
// REWORK NOTE (see Rework.txt in the project root): this file used to
// own a whole second mod-import path - diff every shared PathID
// between a modded bundle and a matching cached one, decode+re-pack
// whichever Texture2D objects differed via Texture2DFields.h/
// Texture2DPixelDecoder.h/RawPixelPacker.h, and insert any PathIDs the
// target didn't have via SerializedObjectTable's insert path. That
// entire path (+transplantFromModdedBundleAtURL:error: and everything
// it called) is deleted here, for two reasons:
//
//   1. It was already dead code. GraphicsDebugOverlay.m's own comments
//      say so directly: "no longer the bundle-mod import path itself"
//      - PlatformBundleRetarget.h's whole-bundle retarget, itself now
//      also deleted pending the Rework.txt rebuild, had replaced it as
//      the actual entry point some time before this cleanup.
//   2. What it built its Texture2D handling on
//      (Texture2DFields.h's old TAT2VersionProfile/Texture2DHeader,
//      RawPixelPacker.h) is exactly the flawed pipeline Rework.txt
//      diagnoses and replaces - see Texture2DFields.h's own note.
//
// What's kept: the backup/restore half. Nothing about restoring a
// previously-backed-up cached bundle depends on any of the above - it
// only ever copies untouched backup bytes back over the live cache
// file - so it's unaffected by the diff/transplant path's removal and
// stays fully functional. GraphicsDebugOverlay.m still calls both
// restore entry points (see -gd_restoreModEntry: and the Reset-All
// path) for backups any earlier build of this tweak already wrote via
// the now-removed transplant path, or via whatever replaces it next.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TextureAtlasTransplantErrorDomain;

typedef NS_ENUM(NSInteger, TextureAtlasTransplantErrorCode) {
    TextureAtlasTransplantErrorBackupFailed = 1,
};

@interface TextureAtlasTransplant : NSObject

// Library/ZSingularityAtlasBackups inside this app's sandbox - own
// directory, same "not inside the cache itself" reasoning as every
// other Transplant class's backup directory (see BankTransplant.h/
// BundleTransplant.h's own IMPORTANT notes on why).
+ (NSString *)atlasBackupDirectory;

// Restores every cached bundle under +[BundleTransplant unityCacheSharedDirectory]
// that has a matching backup under +atlasBackupDirectory, overwriting the
// live (possibly object-patched) copy with the untouched backup. Returns
// the number restored, or -1 with error filled on a filesystem-level
// failure. Returns 0 (not an error) if +atlasBackupDirectory doesn't
// exist yet.
+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;

// Same restore as above, narrowed to backups matching one CAB - the
// per-object counterpart to +[BundleTransplant
// restoreBackedUpBundlesForCAB:force:error:], used by the Mods Library's
// per-entry Reset/delete-restore paths (see GraphicsDebugOverlay.m's
// -gd_restoreModEntry:) so removing one tracked mod only reverts the
// cached bundles that mod itself touched, not every atlas backup on
// disk. Matches by reading each backup's own CAB (untouched stock
// bytes, so its CAB is unaffected by whatever object-level patching
// happened to the live copy) - same reasoning as
// BundleTransplant.m's own per-CAB restore. Returns 0 (not an error) if
// +atlasBackupDirectory doesn't exist or nothing matches.
+ (NSInteger)restoreBackedUpBundlesForCAB:(NSString *)cab error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
