
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZTranscoderInstallerErrorDomain;

typedef NS_ENUM(NSInteger, ZTranscoderInstallerErrorCode) {
    ZTranscoderInstallerErrorCantReadDoctored = 1,
    ZTranscoderInstallerErrorBackupFailed,
    ZTranscoderInstallerErrorWriteFailed,

    ZTranscoderInstallerErrorNoInstallTarget,
};

@interface ZTranscoderInstaller : NSObject

+ (NSString *)bundleBackupDirectory;

+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error;

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;

+ (NSInteger)restoreAllBackedUpBundlesForce:(BOOL)force error:(NSError **)error;

+ (BOOL)cacheOriginalBackForStockBundleURL:(NSURL *)stockBundleURL error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

