// VorbisSetupTable.m — see VorbisSetupTable.h for the format and why this
// table can't be pre-populated here.

#import "VorbisSetupTable.h"

@interface VorbisSetupTable ()
@property (nonatomic, strong) NSData *backingData;
@property (nonatomic, assign) NSMapTable<NSNumber *, NSValue *> *offsets; // crc32 -> {offset, length} packed in an NSValue(NSRange)
@end

@implementation VorbisSetupTable

+ (nullable instancetype)loadFromResourceNamed:(NSString *)name error:(NSError **)error {
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:nil];
    if (!path) {
        if (error) *error = [NSError errorWithDomain:@"VorbisSetupTable" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"%@ not found in the app bundle - this pipeline can't decode Vorbis without it. "
                 "See VorbisSetupTable.h for the format; it has to be built externally, this tool can't ship FMOD's preset table.", name]
        }];
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;

    VorbisSetupTable *table = [VorbisSetupTable new];
    table.backingData = data;
    table.offsets = [NSMapTable strongToStrongObjectsMapTable];

    const uint8_t *p = data.bytes;
    size_t len = data.length;
    if (len < 4) {
        if (error) *error = [NSError errorWithDomain:@"VorbisSetupTable" code:2 userInfo:@{NSLocalizedDescriptionKey: @"truncated table header"}];
        return nil;
    }
    uint32_t count = p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
    size_t off = 4;
    for (uint32_t i = 0; i < count; i++) {
        if (off + 8 > len) {
            if (error) *error = [NSError errorWithDomain:@"VorbisSetupTable" code:3 userInfo:@{NSLocalizedDescriptionKey: @"truncated table entry"}];
            return nil;
        }
        uint32_t crc = p[off] | (p[off+1] << 8) | (p[off+2] << 16) | ((uint32_t)p[off+3] << 24);
        uint32_t plen = p[off+4] | (p[off+5] << 8) | (p[off+6] << 16) | ((uint32_t)p[off+7] << 24);
        off += 8;
        if (off + plen > len) {
            if (error) *error = [NSError errorWithDomain:@"VorbisSetupTable" code:4 userInfo:@{NSLocalizedDescriptionKey: @"truncated table payload"}];
            return nil;
        }
        [table.offsets setObject:[NSValue valueWithRange:NSMakeRange(off, plen)] forKey:@(crc)];
        off += plen;
    }
    return table;
}

- (nullable const uint8_t *)setupPacketForCRC32:(uint32_t)crc32 length:(size_t *)outLength {
    NSValue *v = [self.offsets objectForKey:@(crc32)];
    if (!v) return NULL;
    NSRange r = v.rangeValue;
    if (outLength) *outLength = r.length;
    return ((const uint8_t *)self.backingData.bytes) + r.location;
}

- (NSUInteger)entryCount {
    return self.offsets.count;
}

@end
