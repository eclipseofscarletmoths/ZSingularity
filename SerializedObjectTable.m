// SerializedObjectTable.m
//
// See SerializedObjectTable.h for the format notes and what's verified
// vs. structurally inferred. One asymmetry worth flagging up front since
// it's easy to get backwards: SerializedFile's own HEADER fields
// (metadata size, file size, version, data offset...) are big-endian,
// same as everything in UnityBundleCAB.h's archive-level header/blocks-
// info - but the OBJECT TABLE entries this file exists to read
// (pathID/byteStart/byteSize/typeID) are little-endian, matching the
// asset DATA that follows them rather than the structural header that
// precedes them. Confirmed by direct inspection of real files - getting
// this backwards produces plausible-looking-but-wrong numbers rather
// than an outright parse failure, which is exactly the kind of mistake
// worth a comment.

#import "SerializedObjectTable.h"
#import "ZTweakLog.h"
#include <stdint.h>

NSString * const SerializedObjectTableErrorDomain = @"SerializedObjectTableErrorDomain";

#pragma mark - read helpers

static uint32_t sot_read_u32_be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static uint64_t sot_read_u64_be(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
    return v;
}
static int64_t sot_read_i64_le(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return (int64_t)v;
}
static uint32_t sot_read_u32_le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static int32_t sot_read_i32_le(const uint8_t *p) {
    return (int32_t)sot_read_u32_le(p);
}

#pragma mark - header (version 22 only - see .h)

typedef struct {
    uint32_t metadataSize;
    uint64_t fileSize;
    uint32_t version;
    uint64_t dataOffset;
    size_t   headerEnd; // stream position immediately after the fixed header fields
} SOTHeader;

static BOOL sot_parse_header(NSData *nodeData, SOTHeader *out, NSError **error) {
    const uint8_t *base = (const uint8_t *)nodeData.bytes;
    size_t len = nodeData.length;
    if (len < 20) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTooSmall userInfo:nil];
        return NO;
    }

    // v<22 header shape, read first to learn the real version:
    // metadataSize(u32) fileSize(u32) version(u32) dataOffset(u32) endianness(u8) reserved(3)
    uint32_t version = sot_read_u32_be(base + 8);
    if (version != 22) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorUnsupportedVersion userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"SerializedFile version %u not supported - only 22 is (see SerializedObjectTable.h)", version]
        }];
        return NO;
    }

    if (len < 48) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTooSmall userInfo:nil];
        return NO;
    }
    // v>=22 re-reads metadataSize/fileSize/dataOffset as wider fields
    // starting right after the v<22 block's 20 bytes, then an 8-byte
    // field this project hasn't identified a use for (always seen as 0 -
    // possibly reserved/padding) before the real data begins.
    size_t p = 20;
    uint32_t metadataSize = sot_read_u32_be(base + p); p += 4;
    uint64_t fileSize = sot_read_u64_be(base + p); p += 8;
    uint64_t dataOffset = sot_read_u64_be(base + p); p += 8;
    p += 8; // unidentified/reserved

    out->metadataSize = metadataSize;
    out->fileSize = fileSize;
    out->version = version;
    out->dataOffset = dataOffset;
    out->headerEnd = p;
    return YES;
}

#pragma mark - object table locate + parse

// Below this many consecutive self-consistent entries, a run is treated
// as coincidence rather than the real table - see the .h note on why
// this is a scan instead of a direct parse. 8 is comfortably below the
// smallest real object table this project has seen (in the hundreds),
// while being large enough that a run of 8 garbage 24-byte windows all
// independently landing in-range by chance is not a realistic risk.
static const NSUInteger kMinConsecutiveValidEntries = 8;

typedef struct { int64_t pathID; int64_t byteStart; uint32_t byteSize; int32_t typeID; } SOTRawEntry;

static BOOL sot_decode_entry(const uint8_t *p, uint64_t dataOffset, uint64_t fileSize, SOTRawEntry *out) {
    int64_t pathID = sot_read_i64_le(p);
    int64_t byteStart = sot_read_i64_le(p + 8);
    uint32_t byteSize = sot_read_u32_le(p + 16);
    int32_t typeID = sot_read_i32_le(p + 20);

    if (byteStart < 0 || byteSize == 0) return NO;
    if ((uint64_t)byteStart + byteSize > fileSize - dataOffset) return NO; // must fit inside the data region
    if (typeID < -8 || typeID > 4096) return NO; // generous but not unbounded - real files use small indices

    out->pathID = pathID; out->byteStart = byteStart; out->byteSize = byteSize; out->typeID = typeID;
    return YES;
}

static NSArray<SerializedObject *> *sot_scan_for_table(NSData *nodeData, const SOTHeader *header, NSError **error) {
    const uint8_t *base = (const uint8_t *)nodeData.bytes;
    size_t len = nodeData.length;
    size_t stride = 24;

    // Search window: from just after the fixed header out to
    // dataOffset (where actual object bytes begin - the table itself,
    // whatever's in between it and the header, always lives before that
    // boundary).
    size_t searchStart = header->headerEnd;
    size_t searchEnd = (size_t)MIN((uint64_t)len, header->dataOffset);
    if (searchEnd < searchStart || searchEnd - searchStart < stride * kMinConsecutiveValidEntries) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTableNotFound userInfo:nil];
        return nil;
    }

    for (size_t candidate = searchStart; candidate + stride * kMinConsecutiveValidEntries <= searchEnd; candidate++) {
        BOOL allValid = YES;
        for (NSUInteger i = 0; i < kMinConsecutiveValidEntries; i++) {
            SOTRawEntry e;
            if (!sot_decode_entry(base + candidate + i * stride, header->dataOffset, header->fileSize, &e)) {
                allValid = NO;
                break;
            }
        }
        if (!allValid) continue;

        // Found a plausible run - walk it to the end (table stops as
        // soon as an entry stops decoding cleanly; the count itself
        // isn't read separately since it isn't needed once the table's
        // own extent is known this way).
        NSMutableArray<SerializedObject *> *objects = [NSMutableArray array];
        size_t off = candidate;
        while (off + stride <= searchEnd) {
            SOTRawEntry e;
            if (!sot_decode_entry(base + off, header->dataOffset, header->fileSize, &e)) break;
            SerializedObject *obj = [SerializedObject new];
            obj.pathID = e.pathID; obj.byteStart = e.byteStart; obj.byteSize = e.byteSize; obj.typeID = e.typeID;
            obj.tableOffset = off;
            [objects addObject:obj];
            off += stride;
        }
        return objects;
    }

    if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTableNotFound userInfo:nil];
    return nil;
}

#pragma mark - insertion (new PathIDs - see .h)

// Fixed header field byte positions - same ones sot_parse_header reads,
// duplicated here as named constants rather than re-deriving from a
// freshly-parsed SOTHeader, since the insert path needs to WRITE them.
static const NSUInteger kSOTFieldMetadataSize = 20; // u32 BE
static const NSUInteger kSOTFieldFileSize      = 24; // u64 BE
static const NSUInteger kSOTFieldDataOffset    = 32; // u64 BE

static void sot_write_u32_be(NSMutableData *data, NSUInteger pos, uint32_t v) {
    uint8_t *p = (uint8_t *)data.mutableBytes + pos;
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}
static void sot_write_u64_be(NSMutableData *data, NSUInteger pos, uint64_t v) {
    uint8_t *p = (uint8_t *)data.mutableBytes + pos;
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * (7 - i)));
}
static uint32_t sot_read_u32_be_public(NSData *data, NSUInteger pos) {
    return sot_read_u32_be((const uint8_t *)data.bytes + pos);
}
static uint64_t sot_read_u64_be_public(NSData *data, NSUInteger pos) {
    return sot_read_u64_be((const uint8_t *)data.bytes + pos);
}

// Searches [firstEntryOffset - windowBack, firstEntryOffset) for a
// 4-byte integer (tried both endiannesses) equal to expectedCount.
// Returns the byte offset of the field and, via *outBE, which
// endianness matched - NO if zero or more than one position/endianness
// combination matches (see -insertObjects:...'s doc in the .h).
static BOOL sot_locate_count_field(NSData *nodeData, NSUInteger firstEntryOffset, NSUInteger expectedCount,
                                    NSUInteger *outOffset, BOOL *outBE) {
    static const NSUInteger kWindowBack = 16; // covers "count immediately before" and "count, then one alignment word"
    if (firstEntryOffset < 4) return NO;
    NSUInteger windowStart = (firstEntryOffset > kWindowBack) ? firstEntryOffset - kWindowBack : 0;
    const uint8_t *base = (const uint8_t *)nodeData.bytes;

    NSUInteger matchOffset = 0;
    BOOL matchBE = NO;
    NSUInteger matchCount = 0;

    for (NSUInteger pos = windowStart; pos + 4 <= firstEntryOffset; pos++) {
        uint32_t le = sot_read_u32_le(base + pos);
        uint32_t be = sot_read_u32_be(base + pos);
        if (le == (uint32_t)expectedCount) { matchOffset = pos; matchBE = NO; matchCount++; }
        if (be == (uint32_t)expectedCount && be != le) { matchOffset = pos; matchBE = YES; matchCount++; }
    }

    if (matchCount != 1) return NO;
    *outOffset = matchOffset;
    *outBE = matchBE;
    return YES;
}

#pragma mark - public API

@implementation SerializedObject
@end

@implementation SerializedObjectTable {
    NSArray<SerializedObject *> *_objects;
    int64_t _dataOffset;
}

- (int64_t)dataOffset { return _dataOffset; }
- (NSArray<SerializedObject *> *)objects { return _objects; }

+ (nullable instancetype)tableForSerializedFileNodeData:(NSData *)nodeData error:(NSError **)error {
    SOTHeader header;
    if (!sot_parse_header(nodeData, &header, error)) return nil;

    NSArray<SerializedObject *> *objects = sot_scan_for_table(nodeData, &header, error);
    if (!objects) return nil;

    SerializedObjectTable *table = [SerializedObjectTable new];
    table->_dataOffset = (int64_t)header.dataOffset;
    table->_objects = objects;
    return table;
}

- (nullable SerializedObject *)objectWithPathID:(int64_t)pathID {
    for (SerializedObject *o in _objects) {
        if (o.pathID == pathID) return o;
    }
    return nil;
}

- (BOOL)patchObject:(SerializedObject *)object
        newByteStart:(int64_t)newByteStart
         newByteSize:(uint32_t)newByteSize
          inNodeData:(NSMutableData *)nodeData
               error:(NSError **)error {
    if (object.tableOffset + 24 > nodeData.length) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTooSmall userInfo:nil];
        return NO;
    }
    uint8_t *p = (uint8_t *)nodeData.mutableBytes + object.tableOffset;
    uint64_t bs = (uint64_t)newByteStart;
    for (int i = 0; i < 8; i++) p[8 + i] = (uint8_t)(bs >> (8 * i)); // byteStart, little-endian
    for (int i = 0; i < 4; i++) p[16 + i] = (uint8_t)(newByteSize >> (8 * i)); // byteSize, little-endian
    object.byteStart = newByteStart;
    object.byteSize = newByteSize;
    return YES;
}

#pragma mark - insertion method (helpers above, outside this @implementation - see top note)

- (BOOL)insertObjects:(NSArray<SerializedObject *> *)newObjects
              payloads:(NSArray<NSData *> *)payloads
            inNodeData:(NSMutableData *)nodeData
                 error:(NSError **)error {
    if (newObjects.count == 0 || newObjects.count != payloads.count) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTooSmall userInfo:@{
            NSLocalizedDescriptionKey: @"insertObjects/payloads must be equal-length, non-empty arrays"
        }];
        return NO;
    }
    SerializedObject *lastExisting = _objects.lastObject;
    if (!lastExisting || _objects.count == 0) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTableNotFound userInfo:nil];
        return NO;
    }
    NSUInteger firstEntryOffset = _objects.firstObject.tableOffset;
    NSUInteger tableEnd = lastExisting.tableOffset + 24; // insertion point - see .h

    NSUInteger countFieldOffset;
    BOOL countFieldBE;
    if (!sot_locate_count_field(nodeData, firstEntryOffset, _objects.count, &countFieldOffset, &countFieldBE)) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain
                                                  code:SOTErrorCountFieldNotFound
                                              userInfo:@{NSLocalizedDescriptionKey: @"couldn't uniquely locate m_ObjectCount preceding the object table - see SerializedObjectTable.h's -insertObjects:... doc"}];
        return NO;
    }

    // Build the new entries block + compute each new payload's
    // byteStart, all against a scratch copy first - nodeData itself
    // isn't touched until the verify step at the bottom passes.
    uint64_t oldDataOffset = (uint64_t)_dataOffset;
    uint64_t existingDataLength = (uint64_t)nodeData.length - oldDataOffset;
    uint64_t runningPayloadOffset = existingDataLength;

    NSMutableData *entryBlock = [NSMutableData dataWithLength:24 * newObjects.count];
    uint8_t *eb = (uint8_t *)entryBlock.mutableBytes;
    for (NSUInteger i = 0; i < newObjects.count; i++) {
        SerializedObject *obj = newObjects[i];
        NSData *payload = payloads[i];
        uint64_t byteStart = runningPayloadOffset;
        uint32_t byteSize = (uint32_t)payload.length;
        runningPayloadOffset += byteSize;

        uint8_t *p = eb + (i * 24);
        uint64_t pid = (uint64_t)obj.pathID;
        for (int b = 0; b < 8; b++) p[b] = (uint8_t)(pid >> (8 * b));           // pathID LE
        for (int b = 0; b < 8; b++) p[8 + b] = (uint8_t)(byteStart >> (8 * b)); // byteStart LE
        for (int b = 0; b < 4; b++) p[16 + b] = (uint8_t)(byteSize >> (8 * b)); // byteSize LE
        int32_t tid = obj.typeID;
        for (int b = 0; b < 4; b++) p[20 + b] = (uint8_t)((uint32_t)tid >> (8 * b)); // typeID LE

        obj.byteStart = (int64_t)byteStart;
        obj.byteSize = byteSize;
    }

    NSUInteger insertedBytes = entryBlock.length;

    NSMutableData *scratch = [NSMutableData dataWithData:[nodeData subdataWithRange:NSMakeRange(0, tableEnd)]];
    [scratch appendData:entryBlock];
    [scratch appendData:[nodeData subdataWithRange:NSMakeRange(tableEnd, nodeData.length - tableEnd)]];
    for (NSData *payload in payloads) [scratch appendData:payload];

    // Header field fixups - see this method's .h doc for why only
    // these three move (existing entries' byteStart values are
    // relative to dataOffset, and both shift together, so they stay
    // numerically valid without individually touching them).
    uint32_t oldMetadataSize = sot_read_u32_be_public(scratch, kSOTFieldMetadataSize);
    uint64_t oldFileSize = sot_read_u64_be_public(scratch, kSOTFieldFileSize);
    uint64_t totalPayloadBytes = runningPayloadOffset - existingDataLength;
    sot_write_u32_be(scratch, kSOTFieldMetadataSize, oldMetadataSize + (uint32_t)insertedBytes);
    sot_write_u64_be(scratch, kSOTFieldFileSize, oldFileSize + insertedBytes + totalPayloadBytes);
    sot_write_u64_be(scratch, kSOTFieldDataOffset, oldDataOffset + insertedBytes);

    // Count field fixup - position is unaffected by the splice (it sits
    // before firstEntryOffset, and insertion happens at/after tableEnd
    // >= firstEntryOffset).
    uint32_t oldCount = (uint32_t)_objects.count;
    uint32_t newCount = oldCount + (uint32_t)newObjects.count;
    if (countFieldBE) sot_write_u32_be(scratch, countFieldOffset, newCount);
    else {
        uint8_t *p = (uint8_t *)scratch.mutableBytes + countFieldOffset;
        for (int b = 0; b < 4; b++) p[b] = (uint8_t)(newCount >> (8 * b));
    }

    // Verify - re-parse from scratch and confirm the new state is
    // exactly what was intended before touching the real nodeData.
    NSError *verifyErr = nil;
    SerializedObjectTable *reparsed = [SerializedObjectTable tableForSerializedFileNodeData:scratch error:&verifyErr];
    BOOL ok = (reparsed != nil && reparsed.objects.count == newCount);
    if (ok) {
        for (SerializedObject *existing in _objects) {
            SerializedObject *found = [reparsed objectWithPathID:existing.pathID];
            if (!found || found.byteSize != existing.byteSize) { ok = NO; break; }
        }
    }
    if (ok) {
        for (NSUInteger i = 0; i < newObjects.count; i++) {
            SerializedObject *obj = newObjects[i];
            SerializedObject *found = [reparsed objectWithPathID:obj.pathID];
            if (!found || found.byteSize != obj.byteSize) { ok = NO; break; }
        }
    }
    if (!ok) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain
                                                  code:SOTErrorInsertVerifyFailed
                                              userInfo:@{NSLocalizedDescriptionKey: verifyErr.localizedDescription ?: @"post-insert re-scan didn't match the expected state - nodeData left untouched"}];
        return NO;
    }

    // Passed - commit: replace nodeData's real contents in place (same
    // buffer identity callers already hold onto) and adopt the
    // freshly-reparsed table as this instance's own state.
    [nodeData setData:scratch];
    _objects = reparsed.objects;
    _dataOffset = reparsed.dataOffset;
    for (NSUInteger i = 0; i < newObjects.count; i++) {
        SerializedObject *obj = newObjects[i];
        SerializedObject *found = [self objectWithPathID:obj.pathID];
        obj.tableOffset = found.tableOffset; // let the caller's own object instances reflect final state too
    }
    return YES;
}

@end
