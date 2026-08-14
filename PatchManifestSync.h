// PatchManifestSync.h
//
// POC: monitor the game's cached FMOD manifest and patch the target bank's
// expected MD5/size immediately after a fresh manifest appears.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PatchManifestSyncErrorDomain;

@interface PatchManifestSync : NSObject

// Starts a low-overhead background tracker for:
// Library/Caches/com.ProjectMoon.LimbusCompany/fsCachedData
//
// The cache objects use UUID-like filenames, so the tracker does not depend
// on a literal "FmodPatchInfo.json" filename. It scans candidate files for
// a JSON object containing Version + Files + the target FMOD path. Once found,
// it patches only that entry's Hash and Size and atomically writes the manifest
// back in place. This is intentionally a POC: it does not hook networking or
// TextAssetPatch, and it uses polling so it survives cache-file replacement
// and rename patterns.
+ (void)startManifestTracker;

@end

NS_ASSUME_NONNULL_END
