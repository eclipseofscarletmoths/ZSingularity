
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const UnityBundleCABErrorDomain;

typedef NS_ENUM(NSInteger, UnityBundleCABErrorCode) {
    UnityBundleCABErrorCantReadFile = 1,
    UnityBundleCABErrorTooSmall,
    UnityBundleCABErrorBadSignature,
    UnityBundleCABErrorUnsupportedCompression,
    UnityBundleCABErrorDecompressFailed,
    UnityBundleCABErrorMalformedBlocksInfo,
    UnityBundleCABErrorNoNodes,
    UnityBundleCABErrorMalformedSerializedFileHeader,

    UnityBundleCABErrorLZMADetected,
};

typedef NS_ENUM(uint8_t, UnityBundleCABCompressionType) {
    UnityBundleCABCompressionNone  = 0,
    UnityBundleCABCompressionLZMA  = 1,
    UnityBundleCABCompressionLZ4   = 2,
    UnityBundleCABCompressionLZ4HC = 3,
    UnityBundleCABCompressionLZHAM = 4,
};

extern NSString * const UnityBundleCABLZMAPropertiesErrorKey;

@interface UBCLZMAProperties : NSObject
@property (nonatomic, assign, readonly) uint8_t propertyByte;
@property (nonatomic, assign, readonly) uint8_t lc;
@property (nonatomic, assign, readonly) uint8_t lp;
@property (nonatomic, assign, readonly) uint8_t pb;
@property (nonatomic, assign, readonly) uint32_t dictionarySize;
@property (nonatomic, copy, readonly) NSData *headerBytes;
@end

@interface UnityBundleNode : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) int64_t offset;
@property (nonatomic, assign) int64_t size;

@property (nonatomic, assign) uint32_t flags;
@end

@interface UnityBundleArchive : NSObject
@property (nonatomic, copy) NSString *unityVersion;
@property (nonatomic, copy) NSString *unityRevision;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, copy) NSArray<UnityBundleNode *> *nodes;
@end

@interface UnityBundleCAB : NSObject

+ (BOOL)isUnityFSBundleAtPath:(NSString *)path;

+ (uint8_t)compressionTypeForBundleAtPath:(NSString *)path error:(NSError **)error;

+ (BOOL)isLZMACompressedBundleAtPath:(NSString *)path isLZMA:(BOOL *)outIsLZMA error:(NSError **)error;

+ (nullable UBCLZMAProperties *)lzmaPropertiesForBundleAtPath:(NSString *)path error:(NSError **)error;

+ (nullable NSData *)LZ4HCDataForBundleAtPath:(NSString *)path error:(NSError **)error;

+ (nullable UnityBundleArchive *)decompressedArchiveAtPath:(NSString *)path error:(NSError **)error;

+ (BOOL)writeArchive:(UnityBundleArchive *)archive toPath:(NSString *)path error:(NSError **)error;

+ (BOOL)writeArchiveStreamingToPath:(NSString *)path
                        unityVersion:(nullable NSString *)unityVersion
                       unityRevision:(nullable NSString *)unityRevision
                               nodes:(NSArray<UnityBundleNode *> *)nodes
                     nodeDataAtIndex:(NSData * _Nullable (^)(NSUInteger index))nodeDataAtIndex
                               error:(NSError **)error;

+ (BOOL)writeArchiveStreamingToPath:(NSString *)path
                        unityVersion:(nullable NSString *)unityVersion
                       unityRevision:(nullable NSString *)unityRevision
                               nodes:(NSArray<UnityBundleNode *> *)nodes
                         cabNodePath:(NSString *)cabNodePath
                         baseCABData:(NSData *)baseCABData
                      appendFilePath:(nullable NSString *)appendFilePath
                        appendLength:(int64_t)appendLength
                     nodeDataAtIndex:(NSData * _Nullable (^)(NSUInteger index))nodeDataAtIndex
                               error:(NSError **)error;

+ (nullable NSString *)primaryCABForBundleAtPath:(NSString *)path error:(NSError **)error;

+ (nullable NSArray<NSString *> *)allNodePathsForBundleAtPath:(NSString *)path error:(NSError **)error;

+ (BOOL)targetPlatform:(int32_t *)outPlatform forBundleAtPath:(NSString *)path error:(NSError **)error;

+ (NSString *)nameForTargetPlatform:(int32_t)platform;

@end

NS_ASSUME_NONNULL_END

