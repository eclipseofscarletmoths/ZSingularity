// BundleDoctorSettings.h
//
// Persistence for BundleDoctorService.h's BundleDoctorConfig, so the
// repo link + auth key only ever have to be entered once. No UI reads or
// writes this yet - see this file's own note below - this is purely the
// storage layer, split out now so the eventual settings screen has
// something to call on day one instead of inventing its own storage
// inline.
//
// SPLIT STORAGE, ON PURPOSE:
//   - repoOwner / repoName / ref / workflowFile / outputFormat -> a
//     small JSON file in this app's own Documents directory, same
//     pattern GDScripts.m already uses for the graphics panel's settings
//     (gd_settings_file_path/gd_load_settings_dictionary/
//     gd_write_settings_dictionary - see that file). None of this is
//     sensitive; a plist/JSON file is exactly the right amount of
//     ceremony for it.
//   - authToken -> iOS Keychain (Security.framework), NOT that same
//     JSON file. It's a live GitHub PAT - see BundleDoctorService.h's
//     own AUTH note on what scopes it needs and why it should be
//     treated as sensitive - and a plaintext file living in this app's
//     Documents directory is a meaningfully worse place for that than
//     Keychain is.
//
// CAVEAT (same spirit as this project's other "unverified until
// confirmed on-device" notes - see PatchManifestNetwork.h's delegate-
// class guess, BundleTransplant.h's __info heuristic): this tweak runs
// as a dylib injected into Limbus Company's own process, not as its own
// standalone app with its own provisioning/entitlements. Keychain access
// from that position is governed by whatever keychain-access-group the
// HOST app (Limbus Company) was signed with, which this project has no
// control over and hasn't verified on a real device. The write/read
// paths below are written to fail soft either way: a Keychain error is
// logged and surfaced through the normal NSError-out pattern rather than
// crashing, and +loadConfig treats "couldn't read a token" the same as
// "no token was ever saved" (nil authToken) rather than distinguishing
// the two. If Keychain access turns out not to work at all from this
// injection context on a real device, the practical fallback is a
// person re-entering their PAT each session - annoying, not broken.

#import <Foundation/Foundation.h>
#import "BundleDoctorService.h" // BundleDoctorConfig

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleDoctorSettingsErrorDomain;

typedef NS_ENUM(NSInteger, BundleDoctorSettingsErrorCode) {
    BundleDoctorSettingsErrorWriteFailed = 1,        // the non-sensitive JSON file couldn't be written
    BundleDoctorSettingsErrorKeychainWriteFailed,     // SecItemAdd/SecItemUpdate failed - see error's OSStatus in userInfo
    BundleDoctorSettingsErrorKeychainDeleteFailed,
};

@interface BundleDoctorSettings : NSObject

// Cheap existence check (JSON file presence only - does not touch
// Keychain) for a future settings screen to decide whether to show
// "not configured yet" vs a pre-filled form.
+ (BOOL)hasStoredConfig;

// Always returns a non-nil BundleDoctorConfig, even if nothing has ever
// been saved (every property nil in that case). Does not fill in
// BundleDoctorService's own defaults (ref/workflowFile/outputFormat
// falling back to "main"/"doctor-bundle.yml"/"RGBA32") - that logic
// stays owned by BundleDoctorService.m alone, so it's never duplicated
// or allowed to drift between the two files. A nil field here just means
// "let BundleDoctorService pick its own default", not "this field is
// broken".
+ (BundleDoctorConfig *)loadConfig;

// Overwrites everything this class stores - the JSON file AND the
// Keychain item - with exactly what's on `config`, including clearing
// the stored authToken if config.authToken is nil/empty. This is a full
// replace, not a merge: a future settings screen should always read the
// current config (via +loadConfig), mutate the fields the person
// actually changed, and save the whole thing back - not construct a
// partial config from just the fields one particular form field touched.
+ (BOOL)saveConfig:(BundleDoctorConfig *)config error:(NSError **)error;

// Deletes both the JSON file and the Keychain item. Returns YES if the
// end state is "nothing stored", even if one or both didn't exist to
// begin with (same "already-clean is success, not failure" convention
// ModAssetLibrary/BankTransplant/BundleTransplant already use for their
// own restore/delete operations).
+ (BOOL)clearAllWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
