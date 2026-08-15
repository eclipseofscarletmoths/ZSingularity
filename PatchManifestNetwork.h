// PatchManifestNetwork.h
//
// Renamed from PatchManifestNetworkPOC now that this is the sole/settled
// manifest-patching approach (PatchManifestSync's filesystem-watcher
// version is gone - this one hooks the network response directly instead
// of racing a cache-directory watcher against it).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PatchManifestNetwork : NSObject
+ (void)install;
+ (void)uninstall;
@end

NS_ASSUME_NONNULL_END
