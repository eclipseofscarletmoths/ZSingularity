
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZTranscoderServiceErrorDomain;

typedef NS_ENUM(NSInteger, ZTranscoderServiceErrorCode) {
    ZTranscoderServiceErrorInvalidConfig = 1,
    ZTranscoderServiceErrorCantReadModdedBundle,
    ZTranscoderServiceErrorRequestFailed,
    ZTranscoderServiceErrorAPIError,
    ZTranscoderServiceErrorRunNotFound,
    ZTranscoderServiceErrorRunFailed,
    ZTranscoderServiceErrorTimedOut,
    ZTranscoderServiceErrorOutputMissing,
};

extern NSString * const ZTranscoderServiceHTTPStatusKey;
extern NSString * const ZTranscoderServiceResponseBodyKey;
extern NSString * const ZTranscoderServiceRunURLKey;

typedef NS_ENUM(NSInteger, ZTranscoderRunStatus) {
    ZTranscoderRunStatusQueued = 0,
    ZTranscoderRunStatusInProgress,
    ZTranscoderRunStatusSucceeded,
    ZTranscoderRunStatusFailed,
};

@interface ZTranscoderConfig : NSObject
@property (nonatomic, copy, nullable) NSString *repoOwner;
@property (nonatomic, copy, nullable) NSString *repoName;
@property (nonatomic, copy, nullable) NSString *ref;
@property (nonatomic, copy, nullable) NSString *workflowFile;
@property (nonatomic, copy, nullable) NSString *outputFormat;
@property (nonatomic, copy, nullable) NSString *authToken;

- (ZTranscoderConfig *)normalizedConfig;

@end

@interface ZTranscoderHandle : NSObject
@property (nonatomic, copy, readonly) NSString *scratchBranch;
@property (nonatomic, copy, nullable) NSString *runID;
@property (nonatomic, copy, nullable) NSString *runURL;

@property (nonatomic, assign, readonly) BOOL alreadyComplete;

- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation;

+ (nullable instancetype)handleFromDictionaryRepresentation:(NSDictionary<NSString *, NSString *> *)dict;
@end

@interface ZTranscoderProcessedRelease : NSObject
@property (nonatomic, copy, readonly) NSString *tagName;

@property (nonatomic, copy, readonly, nullable) NSString *cabDisplayName;

@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, assign, readonly) unsigned long long byteSize;
@property (nonatomic, copy, readonly, nullable) NSString *uploadedAt;

@property (nonatomic, copy, readonly, nullable) NSString *checksum;
@end

@interface ZTranscoderService : NSObject

+ (void)ztranscoderBundleAtURL:(NSURL *)moddedBundleURL
                    config:(ZTranscoderConfig *)config
                  progress:(nullable void (^)(NSString *status))progress
                completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion;

#pragma mark - Decoupled phase API (see this file's header)

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL
                       config:(ZTranscoderConfig *)config
        previousScratchBranch:(nullable NSString *)previousScratchBranch
               uploadProgress:(nullable void (^)(int64_t bytesSent))uploadProgress
                   completion:(void (^)(ZTranscoderHandle * _Nullable handle, NSError * _Nullable error))completion;

+ (void)resolveRunForHandle:(ZTranscoderHandle *)handle
                       config:(ZTranscoderConfig *)config
                   completion:(void (^)(BOOL found, NSError * _Nullable error))completion;

+ (void)fetchRunStatusForHandle:(ZTranscoderHandle *)handle
                           config:(ZTranscoderConfig *)config
                       completion:(void (^)(ZTranscoderRunStatus status, double percentComplete, NSError * _Nullable error))completion;

+ (void)fetchDoctoredBundleForHandle:(ZTranscoderHandle *)handle
                                config:(ZTranscoderConfig *)config
                              progress:(nullable void (^)(int64_t bytesWritten))downloadProgress
                            completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion;

#pragma mark - Upload transport compression

+ (BOOL)isUploadCompressionEnabled;
+ (void)setUploadCompressionEnabled:(BOOL)enabled;

#pragma mark - Processed Bundles listing (6)

+ (void)listProcessedReleasesForConfig:(ZTranscoderConfig *)config
                              completion:(void (^)(NSArray<ZTranscoderProcessedRelease *> * _Nullable releases, NSError * _Nullable error))completion;

#pragma mark - Processed Bundles install (9)

+ (void)downloadProcessedRelease:(ZTranscoderProcessedRelease *)release
                            config:(ZTranscoderConfig *)config
                          progress:(nullable void (^)(int64_t bytesWritten))downloadProgress
                        completion:(void (^)(NSURL * _Nullable bundleURL, NSError * _Nullable error))completion;

#pragma mark - Delete every stored release (8)

+ (void)deleteAllReleasesForConfig:(ZTranscoderConfig *)config
                          completion:(void (^)(NSInteger deletedCount, NSError * _Nullable error))completion;

#pragma mark - Credential check

+ (void)verifyCredentialsForConfig:(ZTranscoderConfig *)config
                          completion:(void (^)(BOOL valid, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

