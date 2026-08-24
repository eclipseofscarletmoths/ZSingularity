
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const LunartiqueModArchiveErrorDomain;

typedef NS_ENUM(NSInteger, LunartiqueModArchiveErrorCode) {
    LunartiqueModArchiveErrorCantReadFile = 1,
    LunartiqueModArchiveErrorNotAZip,
    LunartiqueModArchiveErrorNoMatchingTree,
    LunartiqueModArchiveErrorUnsupportedCompression,
    LunartiqueModArchiveErrorCorruptEntry,
    LunartiqueModArchiveErrorExtractionFailed,
};

@interface LunartiqueModEntry : NSObject
@property (nonatomic, copy, readonly) NSString *cacheHash1;
@property (nonatomic, copy, readonly) NSString *cacheHash2;
@property (nonatomic, copy, readonly) NSString *dataEntryName;
@property (nonatomic, copy, readonly, nullable) NSString *infoEntryName;
@end

@interface LunartiqueModArchive : NSObject

+ (BOOL)isLunartiqueFormatZipAtURL:(NSURL *)zipURL error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSArray<LunartiqueModEntry *> *)matchedEntriesInZipAtURL:(NSURL *)zipURL error:(NSError **)error;

+ (BOOL)extractDataForEntry:(LunartiqueModEntry *)entry
                   fromZipAtURL:(NSURL *)zipURL
                        dataURL:(NSURL * _Nullable * _Nonnull)outDataURL
                        infoURL:(NSURL * _Nullable * _Nonnull)outInfoURL
                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

