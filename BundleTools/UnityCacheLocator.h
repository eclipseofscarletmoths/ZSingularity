
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const UnityCacheLocatorErrorDomain;

typedef NS_ENUM(NSInteger, UnityCacheLocatorErrorCode) {
    UnityCacheLocatorErrorSourceCABUnreadable = 1,
    UnityCacheLocatorErrorSharedDirectoryNotFound,
    UnityCacheLocatorErrorNoMatch,
    UnityCacheLocatorErrorSynthesisFailed,
};

@interface UnityCacheLocator : NSObject

+ (NSArray<NSString *> *)unityCacheSharedDirectories;

+ (nullable NSString *)cabForBundleAtPath:(NSString *)moddedOrDoctoredBundlePath error:(NSError **)error;

+ (NSArray<NSString *> *)allBundlePathsForCAB:(NSString *)cab;

+ (nullable NSString *)locateBundlePathForCAB:(NSString *)cab error:(NSError **)error;

+ (nullable NSString *)synthesizeCacheDirectoryForHash1:(NSString *)hash1 hash2:(NSString *)hash2 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

