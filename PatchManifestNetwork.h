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

// Whether the hook actually zeroes Hash/Size on an intercepted manifest.
// Independent of install/uninstall: even with this OFF, +install still
// swizzles the delegate and PMDidReceiveData/PMDidComplete still buffer
// and inspect every matching response, so the fetch can't be missed by
// re-enabling this mid-session - PMPatchManifestData just hands the
// manifest back byte-for-byte instead of patching it, which means the
// game's own integrity check runs against the real Hash/Size it asked
// for. Backed by NSUserDefaults (see the .m), defaults to YES to match
// this project's existing behavior for anyone updating from a build
// that didn't have the switch. Read live at patch time rather than
// cached, so flipping the Config section's "Disable FModManifest
// zeroing" switch takes effect on the very next intercepted request,
// no relaunch needed.
+ (BOOL)isZeroingEnabled;
+ (void)setZeroingEnabled:(BOOL)enabled;
@end

NS_ASSUME_NONNULL_END
