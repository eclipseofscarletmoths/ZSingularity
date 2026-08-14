// PatchManifestSync.m -- see PatchManifestSync.h for the why.

#import "PatchManifestSync.h"
#import "ZTweakLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>

NSString * const PatchManifestSyncErrorDomain = @"PatchManifestSyncErrorDomain";

// Same target this whole project's Mobile-side work has centered on -
// see the 120f-tweak notes on the mobile/desktop FMOD hash mismatch and
// BankTransplant's re-encode step. If this project ever needs to patch
// a second bank, this and everything keyed off it below would want to
// become a small array instead of one constant.
static NSString * const kTargetManifestKey = @"Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank";

static dispatch_source_t g_watchSource;
static int g_watchFD = -1;
static dispatch_queue_t g_watchQueue;

static NSError *PMSError(PatchManifestSyncErrorCode code, NSString *message) {
    return [NSError errorWithDomain:PatchManifestSyncErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation PatchManifestSync

+ (NSString *)targetManifestKey {
    return kTargetManifestKey;
}

#pragma mark - Paths

+ (nullable NSString *)fsCachedDataDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachesDir = paths.firstObject;
    if (!cachesDir) return nil;
    return [cachesDir stringByAppendingPathComponent:@"fsCachedData"];
}

// Mirrors BankTransplant's own +mobileFMODBuildsDirectory (kept
// independent rather than imported from there, so this file has no
// compile-time dependency on BankTransplant.h - it only needs to know
// where the already-swapped file lives on disk).
+ (nullable NSString *)targetBankPathOnDisk {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:kTargetManifestKey];
}

#pragma mark - Hashing

// Streamed MD5 of the on-disk file - the manifest's "Size" is plain
// byte count, "Hash" is MD5 hex, both computed directly off whatever
// bt_reencode_bank actually wrote, not assumed.
+ (BOOL)md5:(NSString **)outHexMD5 size:(NSNumber **)outSize ofFileAtPath:(NSString *)path {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!stream) return NO;
    [stream open];
    if (stream.streamStatus == NSStreamStatusError) {
        [stream close];
        return NO;
    }

    CC_MD5_CTX ctx;
    CC_MD5_Init(&ctx);
    uint8_t buf[64 * 1024];
    unsigned long long total = 0;
    NSInteger n;
    while ((n = [stream read:buf maxLength:sizeof(buf)]) > 0) {
        CC_MD5_Update(&ctx, buf, (CC_LONG)n);
        total += (unsigned long long)n;
    }
    BOOL readError = (n < 0);
    [stream close];
    if (readError) return NO;

    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }

    if (outHexMD5) *outHexMD5 = hex;
    if (outSize) *outSize = @(total);
    return YES;
}

#pragma mark - Manifest scan + patch

// Cheap sniff before paying for a full JSON parse: every manifest download
// is a UTF8 JSON object starting with '{' after whitespace; other
// fsCachedData entries (arbitrary cached HTTP bodies) usually aren't.
// Not load-bearing for correctness - json parse below is still the real
// gate - just avoids parsing every binary blob NSURLCache drops in the
// same directory.
+ (BOOL)fileLooksLikeJSONObject:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:256];
    [fh closeFile];
    for (NSUInteger i = 0; i < head.length; i++) {
        unsigned char c = ((const unsigned char *)head.bytes)[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        return c == '{';
    }
    return NO;
}

// Scans fsCachedData for a file that JSON-parses into {"Files": {...}}
// containing kTargetManifestKey. Returns the parsed top-level mutable
// dict and the path it came from, or nil if nothing matched.
+ (nullable NSMutableDictionary *)findCandidateManifestPath:(NSString **)outPath {
    NSString *dir = [self fsCachedDataDirectory];
    if (!dir) return nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!entries) return nil;

    for (NSString *entry in entries) {
        NSString *path = [dir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;
        if (![self fileLooksLikeJSONObject:path]) continue;

        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;

        NSError *jsonErr = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                      options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                                                        error:&jsonErr];
        if (jsonErr || ![parsed isKindOfClass:NSMutableDictionary.class]) continue;

        NSMutableDictionary *root = (NSMutableDictionary *)parsed;
        id files = root[@"Files"];
        if (![files isKindOfClass:NSDictionary.class]) continue;
        if (!((NSDictionary *)files)[kTargetManifestKey]) continue;

        if (outPath) *outPath = path;
        return root;
    }
    return nil;
} 