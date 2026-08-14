// VorbisSetupTable.m — see VorbisSetupTable.h for the format and why this
// table can't be pre-populated here.

#import "VorbisSetupTable.h"
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>

static const uint8_t BT_VORBIS_SETUP_SECTION_MARKER = 0;

@interface VorbisSetupTable ()
@property (nonatomic, strong) NSData *backingData;
@property (nonatomic, strong) NSMapTable<NSNumber *, NSValue *> *offsets; // crc32 -> {offset, length} packed in an NSValue(NSRange)
@end

@implementation VorbisSetupTable

+ (nullable instancetype)loadFromResourceNamed:(NSString *)name error:(NSError **)error {
    NSData *data = nil;

    // First support the normal packaged-resource case. A tweak dylib is not
    // guaranteed to have an NSBundle of its own, so check both the host app
    // and the bundle associated with this class.
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:nil];
    if (!path) path = [[NSBundle bundleForClass:self] pathForResource:name ofType:nil];
    if (path) data = [NSData dataWithContentsOfFile:path options:0 error:error];

    // The build can also embed the table directly into this dylib as a
    // Mach-O section (__DATA,__fsb5setup). This avoids relying on the injected
    // dylib having a standalone resource bundle.
#if defined(__APPLE__) && defined(__LP64__)
    if (!data) {
        Dl_info image = {0};
        if (dladdr((const void *)&BT_VORBIS_SETUP_SECTION_MARKER, &image) && image.dli_fbase) {
            unsigned long sectionSize = 0;
            const uint8_t *section = getsectiondata((const struct mach_header_64 *)image.dli_fbase,
                                                     "__DATA", "__fsb5setup", &sectionSize);
            if (section && sectionSize > 0) {
                data = [NSData dataWithBytes:section length:(NSUInteger)sectionSize];
            }
        }
    }
#endif

    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"VorbisSetupTable" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"%@ not found as a packaged resource or embedded Mach-O section.", name]
        }];
        return nil;
    }

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
