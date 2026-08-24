#import "ZTranscoderSettings.h"
#import "ZTweakLog.h"
#import <Security/Security.h>

NSString * const ZTranscoderSettingsErrorDomain = @"ZTranscoderSettingsErrorDomain";

static NSString * const kKeychainService = @"com.120F.ZTranscoderService";
static NSString * const kKeychainAccount = @"githubAuthToken";

@implementation ZTranscoderSettings

#pragma mark - JSON file (non-sensitive fields)

static NSString *bds_settings_file_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"ZTranscoderSettings.json"];
}

static NSDictionary *bds_load_json_dictionary(void) {
    NSString *path = bds_settings_file_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[ZTranscoderSettings] failed to parse settings JSON: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

static BOOL bds_write_json_dictionary(NSDictionary *dict, NSError **error) {
    NSString *path = bds_settings_file_path();
    if (!path) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve Documents directory."}];
        }
        return NO;
    }

    NSError *encodeError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&encodeError];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: encodeError.localizedDescription ?: @"Couldn't encode settings JSON."}];
        }
        return NO;
    }

    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't write settings JSON."}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Keychain (authToken only)

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
        return nil;
    }
    if (status != errSecSuccess) {
        ZLog(@"[ZTranscoderSettings] Keychain read failed (OSStatus %d) - see this file's header caveat on injected-dylib Keychain access", (int)status);
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)result;
    if (![data isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

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

        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }

    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorKeychainWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain write failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

static BOOL bds_delete_token(NSError **error) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorKeychainDeleteFailed
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

+ (ZTranscoderConfig *)loadConfig {
    NSDictionary *dict = bds_load_json_dictionary();

    ZTranscoderConfig *config = [ZTranscoderConfig new];
    config.repoOwner     = dict[@"repoOwner"];
    config.repoName      = dict[@"repoName"];
    config.ref           = dict[@"ref"];
    config.workflowFile  = dict[@"workflowFile"];
    config.outputFormat  = dict[@"outputFormat"];
    config.authToken     = bds_read_token();

    return config;
}

+ (BOOL)saveConfig:(ZTranscoderConfig *)config error:(NSError **)error {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (config.repoOwner.length > 0)    dict[@"repoOwner"] = config.repoOwner;
    if (config.repoName.length > 0)     dict[@"repoName"] = config.repoName;
    if (config.ref.length > 0)          dict[@"ref"] = config.ref;
    if (config.workflowFile.length > 0) dict[@"workflowFile"] = config.workflowFile;
    if (config.outputFormat.length > 0) dict[@"outputFormat"] = config.outputFormat;

    if (!bds_write_json_dictionary(dict, error)) {
        return NO;
    }

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
                *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                              code:ZTranscoderSettingsErrorWriteFailed
                                          userInfo:@{NSLocalizedDescriptionKey: removeError.localizedDescription ?: @"Couldn't remove settings JSON."}];
            }
            return NO;
        }
    }

    return bds_delete_token(error);
}

@end

