
#import <Foundation/Foundation.h>
#import "ZTranscoderService.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZTranscoderSettingsErrorDomain;

typedef NS_ENUM(NSInteger, ZTranscoderSettingsErrorCode) {
    ZTranscoderSettingsErrorWriteFailed = 1,
    ZTranscoderSettingsErrorKeychainWriteFailed,
    ZTranscoderSettingsErrorKeychainDeleteFailed,
};

@interface ZTranscoderSettings : NSObject

+ (BOOL)hasStoredConfig;

+ (ZTranscoderConfig *)loadConfig;

+ (BOOL)saveConfig:(ZTranscoderConfig *)config error:(NSError **)error;

+ (BOOL)clearAllWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

