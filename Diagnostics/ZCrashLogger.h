
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZCrashLogger : NSObject

+ (void)install;

+ (NSString *)crashLogPath;

@end

NS_ASSUME_NONNULL_END

