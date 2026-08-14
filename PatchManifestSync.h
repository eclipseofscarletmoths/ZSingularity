// PatchManifestSync.h
//
// Filesystem-only POC.
// The previous implementation called TextAssetPatch IL2CPP methods
// (TextAssetPatchConfig / TextAssetPatchInfoManager), which could crash
// the live player. This version does not touch IL2CPP at all.
//
// It watches:
//   <AppContainer>/Library/Caches/com.ProjectMoon.LimbusCompany/fsCachedData
//
// and patches the matching FMOD manifest whenever it is created/replaced/
// rewritten. The manifest has no .json extension in the observed cache,
// so the implementation identifies it by parsing JSON and looking for the
// exact Files entry.
//
// Target:
//   Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank
//
// Desired:
//   Hash = fbe98ef9f57aff80ada46c4f8af92
//   Size = 57408616

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PatchManifestSyncErrorDomain;

typedef NS_ENUM(NSInteger, PatchManifestSyncErrorCode) {
    PatchManifestSyncErrorCacheDirectoryUnavailable = 1,
    PatchManifestSyncErrorManifestNotFound,
    PatchManifestSyncErrorManifestInvalid,
    PatchManifestSyncErrorManifestWriteFailed,
};

@interface PatchManifestSync : NSObject

/// Starts the cache-directory watcher and performs an immediate scan.
/// Safe to call more than once.
+ (void)startMonitoring;

/// Stops the watcher.
+ (void)stopMonitoring;

/// One-shot scan/patch. This replaces the old IL2CPP-based resync call so
/// existing callers can remain unchanged without invoking any managed game code.
+ (BOOL)resyncFmodPatchManifestWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
