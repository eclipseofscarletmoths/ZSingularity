// LunartiqueModArchive.m — see the header for the why/shape.

#import "LunartiqueModArchive.h"
#import "ZTweakLog.h"
#import <compression.h>

NSString * const LunartiqueModArchiveErrorDomain = @"LunartiqueModArchiveErrorDomain";

static NSError *LMAError(LunartiqueModArchiveErrorCode code, NSString *message) {
    return [NSError errorWithDomain:LunartiqueModArchiveErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation LunartiqueModEntry
- (instancetype)initWithHash1:(NSString *)h1 hash2:(NSString *)h2 dataEntryName:(NSString *)dataName infoEntryName:(nullable NSString *)infoName {
    if ((self = [super init])) {
        _cacheHash1 = [h1 copy];
        _cacheHash2 = [h2 copy];
        _dataEntryName = [dataName copy];
        _infoEntryName = [infoName copy];
    }
    return self;
}
@end

// One raw Central Directory File Header record, just the fields this
// class needs - see this file's header for the full on-disk layout.
@interface LMACDRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t uncompressedSize;
@property (nonatomic, assign) uint32_t localHeaderOffset;
@end

@implementation LMACDRecord
@end

@implementation LunartiqueModArchive

#pragma mark - Byte helpers (all ZIP fields are little-endian)

static uint16_t lma_read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static uint32_t lma_read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

#pragma mark - End Of Central Directory

// Scans backward from the end of the file for the EOCD signature - the
// only reliable way to locate it, since a zip comment (0-65535 bytes)
// can sit between the Central Directory and EOF.
static const uint32_t kEOCDSignature = 0x06054b50;
static const uint32_t kCDFileHeaderSignature = 0x02014b50;
static const uint32_t kLocalFileHeaderSignature = 0x04034b50;

+ (nullable NSData *)lma_mappedDataForZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:&readErr];
    if (!data) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCantReadFile,
            [NSString stringWithFormat:@"Couldn't read %@: %@", zipURL.lastPathComponent, readErr.localizedDescription ?: @"unknown error"]);
        return nil;
    }
    return data;
}

+ (BOOL)lma_findEOCDInData:(NSData *)data cdOffset:(uint32_t *)outCDOffset cdSize:(uint32_t *)outCDSize entryCount:(uint16_t *)outCount error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (length < 22) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"File is too small to be a zip.");
        return NO;
    }

    NSUInteger searchWindow = MIN((NSUInteger)(22 + 65535), length);
    NSUInteger start = length - searchWindow;
    // Search from the END of the window backward, so a coincidental
    // signature-looking byte sequence inside a long comment doesn't win
    // over the real EOCD record closest to EOF.
    for (NSInteger i = (NSInteger)(length - 22); i >= (NSInteger)start; i--) {
        const uint8_t *p = bytes + i;
        if (lma_read_u32(p) == kEOCDSignature) {
            uint16_t commentLen = lma_read_u16(p + 20);
            if (i + 22 + commentLen != (NSInteger)length) continue; // not a real match - comment length doesn't reach EOF
            if (outCDOffset) *outCDOffset = lma_read_u32(p + 16);
            if (outCDSize) *outCDSize = lma_read_u32(p + 12);
            if (outCount) *outCount = lma_read_u16(p + 10);
            return YES;
        }
    }

    if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"No End Of Central Directory record found - not a valid zip.");
    return NO;
}

#pragma mark - Central Directory walk

+ (nullable NSArray<LMACDRecord *> *)lma_centralDirectoryRecordsForData:(NSData *)data error:(NSError **)error {
    uint32_t cdOffset = 0, cdSize = 0;
    uint16_t count = 0;
    if (![self lma_findEOCDInData:data cdOffset:&cdOffset cdSize:&cdSize entryCount:&count error:error]) return nil;

    NSUInteger length = data.length;
    if ((NSUInteger)cdOffset + cdSize > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"Central Directory offset/size runs past end of file - corrupt or ZIP64 (unsupported).");
        return nil;
    }

    const uint8_t *bytes = data.bytes;
    NSMutableArray<LMACDRecord *> *records = [NSMutableArray arrayWithCapacity:count];
    NSUInteger cursor = cdOffset;
    NSUInteger cdEnd = (NSUInteger)cdOffset + cdSize;

    for (uint16_t i = 0; i < count && cursor + 46 <= cdEnd; i++) {
        const uint8_t *p = bytes + cursor;
        if (lma_read_u32(p) != kCDFileHeaderSignature) break; // malformed - stop rather than walk garbage

        uint16_t method = lma_read_u16(p + 10);
        uint32_t compSize = lma_read_u32(p + 20);
        uint32_t uncompSize = lma_read_u32(p + 24);
        uint16_t nameLen = lma_read_u16(p + 28);
        uint16_t extraLen = lma_read_u16(p + 30);
        uint16_t commentLen = lma_read_u16(p + 32);
        uint32_t localOffset = lma_read_u32(p + 42);

        NSUInteger nameStart = cursor + 46;
        if (nameStart + nameLen > cdEnd) break;
        NSString *name = [[NSString alloc] initWithBytes:(bytes + nameStart) length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:(bytes + nameStart) length:nameLen encoding:NSISOLatin1StringEncoding];

        LMACDRecord *rec = [LMACDRecord new];
        rec.name = name ?: @"";
        rec.method = method;
        rec.compressedSize = compSize;
        rec.uncompressedSize = uncompSize;
        rec.localHeaderOffset = localOffset;
        [records addObject:rec];

        cursor = nameStart + nameLen + extraLen + commentLen;
    }

    return records;
}

#pragma mark - Matching "Installation/<hex32>/<hex32>/__data"

// Case-insensitive 32-hex-char check - the sample's hashes happen to be
// lowercase, but nothing in the format guarantees that, so this doesn't
// require a specific case.
static BOOL lma_isHex32(NSString *s) {
    if (s.length != 32) return NO;
    for (NSUInteger i = 0; i < 32; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!isHex) return NO;
    }
    return YES;
}

+ (nullable NSArray<LunartiqueModEntry *> *)matchedEntriesInZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return nil;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return nil;

    // Index every record by its normalized (forward-slash, as-is case)
    // path so a __data match can look up its sibling __info by exact
    // same-directory path in one dictionary hit.
    NSMutableDictionary<NSString *, LMACDRecord *> *byName = [NSMutableDictionary dictionaryWithCapacity:records.count];
    for (LMACDRecord *rec in records) byName[rec.name] = rec;

    NSMutableArray<LunartiqueModEntry *> *matches = [NSMutableArray array];
    for (LMACDRecord *rec in records) {
        NSString *normalized = [rec.name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        NSArray<NSString *> *comps = [normalized componentsSeparatedByString:@"/"];
        if (comps.count < 4) continue;
        NSString *last = comps.lastObject;
        if (![last isEqualToString:@"__data"]) continue;

        NSString *hash2 = comps[comps.count - 2];
        NSString *hash1 = comps[comps.count - 3];
        NSString *installComp = comps[comps.count - 4];
        if ([installComp caseInsensitiveCompare:@"Installation"] != NSOrderedSame) continue;
        if (!lma_isHex32(hash1) || !lma_isHex32(hash2)) continue;

        NSString *infoName = [normalized stringByReplacingCharactersInRange:NSMakeRange(normalized.length - @"__data".length, @"__data".length) withString:@"__info"];
        LMACDRecord *infoRec = byName[infoName];

        LunartiqueModEntry *entry = [[LunartiqueModEntry alloc] initWithHash1:hash1.lowercaseString
                                                                          hash2:hash2.lowercaseString
                                                                  dataEntryName:rec.name
                                                                  infoEntryName:infoRec ? infoName : nil];
        [matches addObject:entry];
    }

    if (matches.count == 0) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNoMatchingTree,
            @"No Installation/<hash>/<hash>/__data entry found - doesn't match the Lunartique format's file tree.");
        return @[];
    }

    return matches;
}

+ (BOOL)isLunartiqueFormatZipAtURL:(NSURL *)zipURL error:(NSError * _Nullable * _Nullable)error {
    NSError *innerErr = nil;
    NSArray<LunartiqueModEntry *> *matches = [self matchedEntriesInZipAtURL:zipURL error:&innerErr];
    if (!matches) {
        if (error) *error = innerErr;
        return NO;
    }
    if (matches.count == 0) {
        if (error) *error = innerErr ?: LMAError(LunartiqueModArchiveErrorNoMatchingTree, @"No matching Installation tree found.");
        return NO;
    }
    return YES;
}

#pragma mark - Extraction

// Re-finds rec's Local File Header (its filename/extra field lengths
// can legally differ from the Central Directory copy's, so this can't
// just reuse the CD's own nameLen/extraLen) and returns the offset
// where the actual (possibly compressed) file data begins.
+ (BOOL)lma_dataRangeForRecord:(LMACDRecord *)rec inData:(NSData *)data start:(NSUInteger *)outStart error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger off = rec.localHeaderOffset;
    if (off + 30 > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry, @"Local file header offset runs past end of file.");
        return NO;
    }
    const uint8_t *p = bytes + off;
    if (lma_read_u32(p) != kLocalFileHeaderSignature) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry, @"Local file header signature mismatch.");
        return NO;
    }
    uint16_t nameLen = lma_read_u16(p + 26);
    uint16_t extraLen = lma_read_u16(p + 28);
    NSUInteger dataStart = off + 30 + nameLen + extraLen;
    if (dataStart + rec.compressedSize > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry, @"Entry data runs past end of file.");
        return NO;
    }
    *outStart = dataStart;
    return YES;
}

+ (nullable NSData *)lma_inflatedDataForRecord:(LMACDRecord *)rec inData:(NSData *)data error:(NSError **)error {
    NSUInteger dataStart = 0;
    if (![self lma_dataRangeForRecord:rec inData:data start:&dataStart error:error]) return nil;

    NSData *compressed = [data subdataWithRange:NSMakeRange(dataStart, rec.compressedSize)];

    if (rec.method == 0) { // stored
        return compressed;
    }
    if (rec.method != 8) { // deflate is the only compressed method this class handles
        if (error) *error = LMAError(LunartiqueModArchiveErrorUnsupportedCompression,
            [NSString stringWithFormat:@"\"%@\" uses zip compression method %u - only stored(0)/deflate(8) are supported.", rec.name, rec.method]);
        return nil;
    }

    if (rec.uncompressedSize == 0) return [NSData data];

    NSMutableData *out = [NSMutableData dataWithLength:rec.uncompressedSize];
    // COMPRESSION_ZLIB in Apple's Compression framework implements raw
    // DEFLATE (RFC 1951) with no zlib (RFC 1950) header/trailer - exactly
    // the framing a .zip entry's compressed bytes use. See this file's
    // header for why no third-party inflate library is pulled in.
    size_t decoded = compression_decode_buffer(out.mutableBytes, rec.uncompressedSize,
                                                compressed.bytes, compressed.length,
                                                NULL, COMPRESSION_ZLIB);
    if (decoded != rec.uncompressedSize) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry,
            [NSString stringWithFormat:@"Deflate decode of \"%@\" produced %zu bytes, expected %u.", rec.name, decoded, rec.uncompressedSize]);
        return nil;
    }
    return out;
}

+ (nullable LMACDRecord *)lma_recordNamed:(NSString *)name inRecords:(NSArray<LMACDRecord *> *)records {
    for (LMACDRecord *rec in records) {
        if ([rec.name isEqualToString:name]) return rec;
    }
    return nil;
}

+ (BOOL)extractDataForEntry:(LunartiqueModEntry *)entry
                   fromZipAtURL:(NSURL *)zipURL
                        dataURL:(NSURL * _Nullable * _Nonnull)outDataURL
                        infoURL:(NSURL * _Nullable * _Nonnull)outInfoURL
                          error:(NSError **)error {
    *outDataURL = nil;
    *outInfoURL = nil;

    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return NO;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return NO;

    LMACDRecord *dataRec = [self lma_recordNamed:entry.dataEntryName inRecords:records];
    if (!dataRec) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry,
            [NSString stringWithFormat:@"\"%@\" no longer found in the zip's Central Directory.", entry.dataEntryName]);
        return NO;
    }

    NSError *inflateErr = nil;
    NSData *dataBytes = [self lma_inflatedDataForRecord:dataRec inData:data error:&inflateErr];
    if (!dataBytes) {
        if (error) *error = inflateErr;
        return NO;
    }

    NSURL *tmpDir = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *dataOut = [tmpDir URLByAppendingPathComponent:[NSString stringWithFormat:@"lunartique-%@-data", NSUUID.UUID.UUIDString]];
    NSError *writeErr = nil;
    if (![dataBytes writeToURL:dataOut options:NSDataWritingAtomic error:&writeErr]) {
        if (error) *error = writeErr ?: LMAError(LunartiqueModArchiveErrorExtractionFailed, @"Couldn't write extracted __data to a temp file.");
        return NO;
    }
    *outDataURL = dataOut;

    if (entry.infoEntryName) {
        LMACDRecord *infoRec = [self lma_recordNamed:entry.infoEntryName inRecords:records];
        if (infoRec) {
            NSError *infoInflateErr = nil;
            NSData *infoBytes = [self lma_inflatedDataForRecord:infoRec inData:data error:&infoInflateErr];
            if (infoBytes) {
                NSURL *infoOut = [tmpDir URLByAppendingPathComponent:[NSString stringWithFormat:@"lunartique-%@-info", NSUUID.UUID.UUIDString]];
                if ([infoBytes writeToURL:infoOut options:NSDataWritingAtomic error:nil]) {
                    *outInfoURL = infoOut;
                } else {
                    ZLog(@"[LunartiqueModArchive] extracted __info bytes but couldn't write them to a temp file - continuing without it.");
                }
            } else {
                ZLog(@"[LunartiqueModArchive] couldn't inflate sibling __info for %@: %@ - continuing without it.", entry.dataEntryName, infoInflateErr.localizedDescription);
            }
        }
    }

    return YES;
}

@end
