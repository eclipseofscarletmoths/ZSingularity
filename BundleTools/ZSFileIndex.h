
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZSFileIndex : NSObject

+ (void)ensureIndexUpToDate;

+ (void)forceReindex;

+ (nullable NSArray<NSString *> *)cachedPathsForCAB:(NSString *)cab;

+ (BOOL)hasIndex;

+ (NSSet<NSString *> *)cachedFMODBankFileNames;

@end

NS_ASSUME_NONNULL_END

