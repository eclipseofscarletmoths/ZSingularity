#import "BundleDoctorSettings.h"
#import "ZTweakLog.h"
#import <Security/Security.h>

NSString * const BundleDoctorSettingsErrorDomain = @"BundleDoctorSettingsErrorDomain";

// Keychain item identity. kSecAttrService scopes this to just this
// tweak (rather than colliding with anything else that might share the
// host app's keychain-access-group); kSecAttrAccount is fixed because
// BundleDoctorConfig is a single value object, not a list of profiles -
// there is exactly one stored token slot, matching the "one request's
// worth of config" framing in BundleDoctorService.h.
static NSString * const kKeychainService = @"com.120F.BundleDoctorService";
static NSString * const kKeychainAccount = @"githubAuthToken";

@implementation BundleDoctorSettings

#pragma mark - JSON file (non-sensitive fields)

static NSString *bds_settings_file_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"BundleDoctorSettings.json"];
}

static NSDictionary *bds_load_json_dictionary(void) {
    NSString *path = bds_settings_file_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[BundleDoctorSettings] failed to parse settings JSON: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

static BOOL bds_write_json_dictionary(NSDictionary *dict, NSError **error) {
    NSString *path = bds_settings_file_path();
    if (!path) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorSettingsErrorDomain
                                          code:BundleDoctorSettingsErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve Documents directory."}];
        }
        return NO;
    }

    NSError *encodeError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&encodeError];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorSettingsErrorDomain
                                          code:BundleDoctorSettingsErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: encodeError.localizedDescription ?: @"Couldn't encode settings JSON."}];
        }
        return NO;
    }

    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorSettingsErrorDomain
                                          code:BundleDoctorSettingsErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't write settings JSON."}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Keychain (authToken only)

// Best-effort read: returns nil on ANY failure (item not found, denied,
// unexpected data shape) rather than distinguishing them to the caller -
// see this file's own header comment on why "no token" and "couldn't
// read the token" are treated the same by +loadConfig.
static NSString *_Nullable bds_read_token(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

    if (status == errSecItemNotFound) {
        return nil; // never saved - not an error
    }
    if (status != errSecSuccess) {
        ZLog(@"[BundleDoctorSettings] Keychain read failed (OSStatus %d) - see this file's header caveat on injected-dylib Keychain access", (int)status);
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)result;
    if (![data isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Adds, or updates in place if an item under this service/account
// already exists (SecItemAdd alone would fail with errSecDuplicateItem
// on the second save otherwise - every settings-screen "Save" after the
// first one needs this to be an upsert, not an insert-or-fail).
static BOOL bds_write_token(NSString *token, NSError **error) {
    NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    NSDictionary *attributesToUpdate = @{
        (__bridge id)kSecValueData: tokenData,
    };

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributesToUpdate);

    if (status == errSecItemNotFound) {
        NSMutableDictionary *addQuery = [query mutableCopy];
        addQuery[(__bridge id)kSecValueData] = tokenData;
        // AfterFirstUnlockThisDeviceOnly: readable in the background
        // (a long doctor-bundle poll can outlive the screen being
        // unlocked) but never included in a device backup/migration -
        // a live PAT has no business leaving this device.
        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }

    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorSettingsErrorDomain
                                          code:BundleDoctorSettingsErrorKeychainWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain write failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

// Success includes "there was nothing to delete" (errSecItemNotFound) -
// same already-clean-is-success convention as the rest of this file.
static BOOL bds_delete_token(NSError **error) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:BundleDoctorSettingsErrorDomain
                                          code:BundleDoctorSettingsErrorKeychainDeleteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain delete failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Public API

+ (BOOL)hasStoredConfig {
    NSString *path = bds_settings_file_path();
    return path && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

+ (BundleDoctorConfig *)loadConfig {
    NSDictionary *dict = bds_load_json_dictionary();

    BundleDoctorConfig *config = [BundleDoctorConfig new];
    config.repoOwner     = dict[@"repoOwner"];
    config.repoName      = dict[@"repoName"];
    config.ref           = dict[@"ref"];
    config.workflowFile  = dict[@"workflowFile"];
    config.outputFormat  = dict[@"outputFormat"];
    config.authToken     = bds_read_token();

    return config;
}

+ (BOOL)saveConfig:(BundleDoctorConfig *)config error:(NSError **)error {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (config.repoOwner.length > 0)    dict[@"repoOwner"] = config.repoOwner;
    if (config.repoName.length > 0)     dict[@"repoName"] = config.repoName;
    if (config.ref.length > 0)          dict[@"ref"] = config.ref;
    if (config.workflowFile.length > 0) dict[@"workflowFile"] = config.workflowFile;
    if (config.outputFormat.length > 0) dict[@"outputFormat"] = config.outputFormat;

    if (!bds_write_json_dictionary(dict, error)) {
        return NO;
    }

    // Token is stored (or cleared) separately, AFTER the JSON write
    // succeeds - if the JSON write had failed, there's no reason to also
    // touch Keychain for a save the caller is about to be told failed.
    if (config.authToken.length > 0) {
        return bds_write_token(config.authToken, error);
    } else {
        return bds_delete_token(error);
    }
}

+ (BOOL)clearAllWithError:(NSError **)error {
    NSString *path = bds_settings_file_path();
    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path error:&removeError]) {
            if (error) {
                *error = [NSError errorWithDomain:BundleDoctorSettingsErrorDomain
                                              code:BundleDoctorSettingsErrorWriteFailed
                                          userInfo:@{NSLocalizedDescriptionKey: removeError.localizedDescription ?: @"Couldn't remove settings JSON."}];
            }
            return NO;
        }
    }

    return bds_delete_token(error);
}

@end
