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

// Cursor-based readers for the Types array walk below (sot_walk_types_array
// et al.) - unlike the fixed-offset header reads and the 24-byte-stride
// object table decode above, this walk's field positions are only known
// by having read everything before them, so each of these advances
// *pos itself and fails (returning NO) rather than trusting the buffer
// is long enough, same bounds-checked posture as the rest of this file.
static BOOL sot_cur_i32(NSData *d, size_t *pos, int32_t *out) {
    if (*pos + 4 > d.length) return NO;
    *out = sot_read_i32_le((const uint8_t *)d.bytes + *pos);
    *pos += 4;
    return YES;
}
static BOOL sot_cur_i16(NSData *d, size_t *pos, int16_t *out) {
    if (*pos + 2 > d.length) return NO;
    const uint8_t *p = (const uint8_t *)d.bytes + *pos;
    *out = (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
    *pos += 2;
    return YES;
}
static BOOL sot_cur_bool(NSData *d, size_t *pos, BOOL *out) {
    if (*pos + 1 > d.length) return NO;
    *out = (*((const uint8_t *)d.bytes + *pos)) != 0;
    *pos += 1;
    return YES;
}
static BOOL sot_cur_skip(NSData *d, size_t *pos, size_t n) {
    if (*pos + n > d.length) return NO;
    *pos += n;
    return YES;
}
static BOOL sot_cur_cstring(NSData *d, size_t *pos) {
    const uint8_t *base = (const uint8_t *)d.bytes;
    size_t len = d.length;
    size_t i = *pos;
    while (i < len && base[i] != 0) i++;
    if (i >= len) return NO; // unterminated
    *pos = i + 1; // consume the NUL too
    return YES;
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

// Decodes a full object table under the assumption it starts EXACTLY at
// `start` - kMinConsecutiveValidEntries entries must decode cleanly right
// away (same plausibility bar sot_scan_for_table's blind search uses) or
// this returns nil outright, rather than accepting a short/coincidental
// run. Used both by that blind scan below (candidate-by-candidate) and by
// -tableForSerializedFileNodeData:'s primary path, where `start` comes
// from actually parsing every field between the header and the table
// (sot_walk_types_array) instead of guessing.
static NSArray<SerializedObject *> *sot_decode_table_at(NSData *nodeData, const SOTHeader *header, size_t start, size_t searchEnd) {
    const uint8_t *base = (const uint8_t *)nodeData.bytes;
    size_t stride = 24;
    if (start + stride * kMinConsecutiveValidEntries > searchEnd) return nil;
    for (NSUInteger i = 0; i < kMinConsecutiveValidEntries; i++) {
        SOTRawEntry e;
        if (!sot_decode_entry(base + start + i * stride, header->dataOffset, header->fileSize, &e)) return nil;
    }

    // Plausible run confirmed - walk it to the end (table stops as soon
    // as an entry stops decoding cleanly; the count itself isn't read
    // separately since it isn't needed once the table's own extent is
    // known this way).
    NSMutableArray<SerializedObject *> *objects = [NSMutableArray array];
    size_t off = start;
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

// Blind byte-by-byte fallback - see -tableForSerializedFileNodeData: for
// why this is no longer the primary way the table is located. Still
// needed for files where sot_walk_types_array itself fails to parse
// (unexpected field shape this project hasn't seen yet), so classID
// resolution is unavailable but the table can still be found and
// objects still identified by raw typeID/pathID.
static NSArray<SerializedObject *> *sot_scan_for_table(NSData *nodeData, const SOTHeader *header, size_t *outTableStart, NSError **error) {
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
        NSArray<SerializedObject *> *objects = sot_decode_table_at(nodeData, header, candidate, searchEnd);
        if (!objects) continue;
        if (outTableStart) *outTableStart = candidate;
        return objects;
    }

    if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTableNotFound userInfo:nil];
    return nil;
}

#pragma mark - types array (typeID index -> real classID - see .h "TYPES ARRAY")

// Parses one m_Types[] entry (SerializedFile format version 22 - this
// file only ever supports 22, see sot_parse_header - non-ref-type
// shape; m_RefTypes, a separate trailing array this project has never
// needed to reach, would use a slightly different shape and is not
// handled here). Advances *pos past the whole entry and fills
// *outClassID. The embedded type tree (if enabled) is walked past using
// its own declared node count / string buffer size - never interpreted
// field-by-field, since nothing here needs field names, only enough
// structure to know where the NEXT SerializedType starts. Node size
// (32 bytes) is the format-version>=19 shape (includes the trailing
// 8-byte m_RefTypeHash) - version 22 is always >=19, so no narrower
// variant is implemented.
static BOOL sot_skip_serialized_type(NSData *nodeData, size_t *pos, BOOL enableTypeTree, int32_t *outClassID) {
    int32_t classID;
    if (!sot_cur_i32(nodeData, pos, &classID)) return NO;

    BOOL isStrippedType;
    if (!sot_cur_bool(nodeData, pos, &isStrippedType)) return NO; // version >= 16

    int16_t scriptTypeIndex;
    if (!sot_cur_i16(nodeData, pos, &scriptTypeIndex)) return NO; // version >= 17
    (void)isStrippedType; (void)scriptTypeIndex; // read for correct cursor advance only - neither is needed past that

    if (classID == 114) { // MonoBehaviour - carries its own Hash128 script ID
        if (!sot_cur_skip(nodeData, pos, 16)) return NO;
    }
    if (!sot_cur_skip(nodeData, pos, 16)) return NO; // m_OldTypeHash (Hash128) - version >= 13, always present

    if (enableTypeTree) {
        int32_t nodeCount, stringBufferSize;
        if (!sot_cur_i32(nodeData, pos, &nodeCount)) return NO;
        if (!sot_cur_i32(nodeData, pos, &stringBufferSize)) return NO;
        if (nodeCount < 0 || stringBufferSize < 0) return NO;
        if (!sot_cur_skip(nodeData, pos, (size_t)nodeCount * 32)) return NO;
        if (!sot_cur_skip(nodeData, pos, (size_t)stringBufferSize)) return NO;
        // version >= 21, non-ref type: trailing i32-count array of type
        // dependency indices.
        int32_t depCount;
        if (!sot_cur_i32(nodeData, pos, &depCount)) return NO;
        if (depCount < 0) return NO;
        if (!sot_cur_skip(nodeData, pos, (size_t)depCount * 4)) return NO;
    }

    if (outClassID) *outClassID = classID;
    return YES;
}

// Walks m_UnityVersion/m_TargetPlatform/m_EnableTypeTree/m_Types,
// starting right after the fixed header, building a typeIndex -> classID
// map - then keeps walking through m_ObjectCount. Unlike the old
// sot_parse_types_array this replaced, this does NOT take a
// pre-located table offset to validate against - *outTableStart is
// simply wherever this walk actually lands, since every field position
// here is derived from the one before it (a genuine parse, not a
// heuristic - see .h). *outObjectCount is m_ObjectCount itself, handed
// back so the caller can require the table it eventually decodes to
// contain exactly that many entries - a much stronger check than "at
// least kMinConsecutiveValidEntries decoded cleanly," which a handful
// of coincidentally-plausible bytes can also satisfy (see the false
// positive this whole PRIMARY/FALLBACK split was built to route around
// - -tableForSerializedFileNodeData:'s comment has the story). Returns
// NO on any parse failure (out-params left untouched); the caller is
// responsible for confirming the landing position actually decodes as
// a plausible table before trusting it - see sot_decode_table_at,
// called right after this in -tableForSerializedFileNodeData:.
static BOOL sot_walk_types_array(NSData *nodeData, const SOTHeader *header, size_t *outTableStart, NSDictionary<NSNumber *, NSNumber *> **outMap, int32_t *outObjectCount, size_t *outTargetPlatformFieldOffset) {
    size_t pos = header->headerEnd;

    if (!sot_cur_cstring(nodeData, &pos)) return NO; // m_UnityVersion - version >= 7

    size_t targetPlatformFieldOffset = pos;
    int32_t targetPlatform;
    if (!sot_cur_i32(nodeData, &pos, &targetPlatform)) return NO; // version >= 8
    (void)targetPlatform;
    if (outTargetPlatformFieldOffset) *outTargetPlatformFieldOffset = targetPlatformFieldOffset;

    BOOL enableTypeTree;
    if (!sot_cur_bool(nodeData, &pos, &enableTypeTree)) return NO; // version >= 13

    int32_t typeCount;
    if (!sot_cur_i32(nodeData, &pos, &typeCount)) return NO;
    if (typeCount < 0 || typeCount > 4096) return NO; // same generous-but-bounded posture as sot_decode_entry's typeID check

    NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)typeCount];
    for (int32_t i = 0; i < typeCount; i++) {
        int32_t classID;
        if (!sot_skip_serialized_type(nodeData, &pos, enableTypeTree, &classID)) return NO;
        map[@(i)] = @(classID);
    }

    int32_t objectCount;
    if (!sot_cur_i32(nodeData, &pos, &objectCount)) return NO; // m_ObjectCount, immediately precedes the table itself
    if (objectCount < 0) return NO;

    if (outTableStart) *outTableStart = pos;
    if (outMap) *outMap = map;
    if (outObjectCount) *outObjectCount = objectCount;
    return YES;
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
static uint32_t sot_read_u32_le_public(NSData *data, NSUInteger pos) {
    return sot_read_u32_le((const uint8_t *)data.bytes + pos);
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
    BOOL _typesResolved;
    int64_t _objectCountFieldOffset;      // see .h doc - exact byte offset of m_ObjectCount, or -1 if unknown
    BOOL _objectCountFieldOffsetKnown;
    int64_t _targetPlatformFieldOffset;   // see .h doc - exact byte offset of m_TargetPlatform, or -1 if unknown
    BOOL _targetPlatformFieldOffsetKnown;
}

- (int64_t)dataOffset { return _dataOffset; }
- (NSArray<SerializedObject *> *)objects { return _objects; }
- (BOOL)typesResolved { return _typesResolved; }
- (int64_t)objectCountFieldOffset { return _objectCountFieldOffset; }
- (BOOL)objectCountFieldOffsetKnown { return _objectCountFieldOffsetKnown; }
- (int64_t)targetPlatformFieldOffset { return _targetPlatformFieldOffset; }
- (BOOL)targetPlatformFieldOffsetKnown { return _targetPlatformFieldOffsetKnown; }

// Bounded local search around `center` (the walk's landing position) for
// an offset that decodes to EXACTLY `expectedCount` entries - tried in
// order of increasing distance from center (0, +1, -1, +2, -2, ...) so
// the closest match wins. Requiring an exact count match, not just
// sot_decode_table_at's kMinConsecutiveValidEntries plausibility bar, is
// what makes a small window safe to search at all: a handful of
// coincidentally-valid-looking bytes is a realistic risk (that's the
// false positive this file's whole PRIMARY/FALLBACK design exists to
// route around), but a coincidental run that ALSO happens to be exactly
// expectedCount entries long, ending inside the search window, is not.
// Exists because the walk's landing position has been observed to drift
// by a byte or two, run to run, on the same real device/bundle (see
// -tableForSerializedFileNodeData:'s doc) - most likely a small content-
// dependent field earlier in the walk (m_UnityVersion's length is the
// prime suspect, being the one variable-length field read before
// anything else) shifting by a byte or two between what this project
// has on hand to test against and what's actually on-device, rather
// than a fixed offset bug. A full blind sot_scan_for_table would also
// eventually find the real table, but across a much larger window with
// a much weaker (count-blind) acceptance bar - worth exhausting a tight,
// strongly-validated search first.
static const size_t kNearbySearchWindow = 512;

static NSArray<SerializedObject *> *sot_decode_table_near(NSData *nodeData, const SOTHeader *header, size_t center, size_t searchStart, size_t searchEnd, int32_t expectedCount, size_t *outTableStart) {
    for (size_t delta = 1; delta <= kNearbySearchWindow; delta++) {
        size_t candidates[2];
        int candidateCount = 0;
        candidates[candidateCount++] = center + delta; // try forward first
        if (delta <= center) candidates[candidateCount++] = center - delta; // then backward, if it wouldn't underflow

        for (int i = 0; i < candidateCount; i++) {
            size_t candidate = candidates[i];
            if (candidate < searchStart) continue;
            NSArray<SerializedObject *> *objects = sot_decode_table_at(nodeData, header, candidate, searchEnd);
            if (objects && objects.count == (NSUInteger)expectedCount) {
                if (outTableStart) *outTableStart = candidate;
                return objects;
            }
        }
    }
    return nil;
}

+ (nullable instancetype)tableForSerializedFileNodeData:(NSData *)nodeData error:(NSError **)error {
    SOTHeader header;
    if (!sot_parse_header(nodeData, &header, error)) return nil;

    size_t searchStart = header.headerEnd;
    size_t searchEnd = (size_t)MIN((uint64_t)nodeData.length, header.dataOffset);

    // PRIMARY: sot_walk_types_array is a genuine structural parse - every
    // field position it reads is derived from the one before it, all the
    // way from m_UnityVersion through m_Types to m_ObjectCount - so once
    // it succeeds, its landing position is trusted directly as the table
    // start (after confirming it actually decodes as one; see
    // sot_decode_table_at) rather than only used to cross-check a
    // separately-found scan position, as this used to work. That older
    // order let a coincidental run of plausible-looking bytes immediately
    // BEFORE the real table (found first by the blind scan below, since
    // it searches forward from the header) silently outrank a walk that
    // had already computed the correct answer: a real 213MB bundle's
    // last SerializedType's trailing bytes happened to satisfy
    // kMinConsecutiveValidEntries starting exactly 1 byte before the
    // walk's own (correct) landing position, so the scan grabbed that
    // false start, the walk's genuinely-correct position no longer
    // matched it, and the whole map was discarded - every object's
    // classIDResolved came back NO despite the walk having parsed fine.
    //
    // On-device, the walk's landing position has also been observed to
    // land a few bytes off (and non-deterministically run to run, on
    // what's presumably the same downloaded bundle content) rather than
    // matching exactly - see sot_decode_table_near above for the most
    // likely cause and why a tight, count-validated local search is
    // tried before giving up to the full blind scan.
    size_t tableStart = 0;
    NSArray<SerializedObject *> *objects = nil;
    NSDictionary<NSNumber *, NSNumber *> *typeMap = nil;
    BOOL typesResolved = NO;

    size_t walkTableStart;
    NSDictionary<NSNumber *, NSNumber *> *walkMap;
    int32_t walkObjectCount;
    size_t walkTargetPlatformFieldOffset = 0;
    if (sot_walk_types_array(nodeData, &header, &walkTableStart, &walkMap, &walkObjectCount, &walkTargetPlatformFieldOffset)) {
        NSArray<SerializedObject *> *walkObjects = sot_decode_table_at(nodeData, &header, walkTableStart, searchEnd);
        if (walkObjects && walkObjects.count == (NSUInteger)walkObjectCount) {
            objects = walkObjects;
            tableStart = walkTableStart;
            typeMap = walkMap;
            typesResolved = YES;
        } else {
            ZLog(@"[SerializedObjectTable] m_Types walk parsed cleanly and expects m_ObjectCount=%d, but landing offset %lu decoded %lu entries - trying a nearby window before falling back to byte-scan",
                 walkObjectCount, (unsigned long)walkTableStart, (unsigned long)walkObjects.count);

            size_t nearTableStart;
            NSArray<SerializedObject *> *nearObjects = sot_decode_table_near(nodeData, &header, walkTableStart, searchStart, searchEnd, walkObjectCount, &nearTableStart);
            if (nearObjects) {
                ZLog(@"[SerializedObjectTable] found the real table %ld bytes from the walk's landing offset (at %lu) - using it, classID resolution still available",
                     (long)((NSInteger)nearTableStart - (NSInteger)walkTableStart), (unsigned long)nearTableStart);
                objects = nearObjects;
                tableStart = nearTableStart;
                typeMap = walkMap;
                typesResolved = YES;
            }
        }
    }

    // FALLBACK: only reached when the structural walk above either failed
    // outright (unexpected field shape this project hasn't seen yet), or
    // landed somewhere that isn't table-shaped and no nearby offset
    // decoded to exactly m_ObjectCount entries either. No classID
    // resolution is available this way, same tradeoff as before.
    if (!objects) {
        objects = sot_scan_for_table(nodeData, &header, &tableStart, error);
        if (!objects) return nil;
        ZLog(@"[SerializedObjectTable] m_Types walk unavailable for this file - classID resolution unavailable, every object's classIDResolved will be NO (table start offset %lu, via byte-scan)",
             (unsigned long)tableStart);
    }

    for (SerializedObject *obj in objects) {
        NSNumber *resolved = typeMap[@(obj.typeID)];
        if (resolved) {
            obj.classID = (int32_t)resolved.intValue;
            obj.classIDResolved = YES;
        } else {
            obj.classID = 0;
            obj.classIDResolved = NO;
        }
    }

    SerializedObjectTable *table = [SerializedObjectTable new];
    table->_dataOffset = (int64_t)header.dataOffset;
    table->_objects = objects;
    table->_typesResolved = typesResolved;

    // Capture m_ObjectCount's exact byte offset while we still have it for
    // free, instead of making -insertObjects:... re-derive it later via
    // heuristic byte-value search (see that method's rewritten doc/impl
    // below, and overview.md Entry 7/8 for why that search is fragile on
    // large bundles). By the public SerializedFile format, m_ObjectCount is
    // a fixed 4-byte LE int32 that ALWAYS sits immediately before the first
    // object table entry - no alignment gap - so `tableStart - 4` is exact
    // whether tableStart came from the walk's own landing position or from
    // sot_decode_table_near's nearby-drift correction (the correction only
    // adjusts where the TABLE was found to start; the format invariant that
    // m_ObjectCount is the 4 bytes immediately before it still holds at
    // whichever position turned out to be correct). Only available when
    // typesResolved is YES - the blind byte-scan fallback below has no
    // structural basis for this and leaves it unknown.
    if (typesResolved && tableStart >= 4) {
        table->_objectCountFieldOffset = (int64_t)tableStart - 4;
        table->_objectCountFieldOffsetKnown = YES;
    } else {
        table->_objectCountFieldOffset = -1;
        table->_objectCountFieldOffsetKnown = NO;
    }

    // m_TargetPlatform's offset comes straight from the walk itself (the
    // very first fixed-size field it reads, well before tableStart/the
    // near-search drift correction can affect it) - valid whenever the
    // walk succeeded at all, independent of which of the two typesResolved
    // branches above actually supplied objects/typeMap.
    if (typesResolved) {
        table->_targetPlatformFieldOffset = (int64_t)walkTargetPlatformFieldOffset;
        table->_targetPlatformFieldOffsetKnown = YES;
    } else {
        table->_targetPlatformFieldOffset = -1;
        table->_targetPlatformFieldOffsetKnown = NO;
    }

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

- (BOOL)growFileSizeBy:(uint64_t)delta
             inNodeData:(NSMutableData *)nodeData
                  error:(NSError **)error {
    if (delta == 0) return YES; // nothing appended, nothing to fix up
    if (kSOTFieldFileSize + 8 > nodeData.length) {
        if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain code:SOTErrorTooSmall userInfo:nil];
        return NO;
    }
    uint64_t oldFileSize = sot_read_u64_be_public(nodeData, kSOTFieldFileSize);
    sot_write_u64_be(nodeData, kSOTFieldFileSize, oldFileSize + delta);
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

    NSUInteger countFieldOffset = 0;
    BOOL countFieldBE = NO;
    BOOL foundCountField = NO;

    // PRIMARY: use the structurally-known m_ObjectCount offset captured
    // when this table was parsed (tableForSerializedFileNodeData: - see its
    // doc above). This is a format-derived FACT (m_ObjectCount always
    // immediately precedes the object table, always read/written little-
    // endian, same as every other field sot_walk_types_array reads), not a
    // heuristic guess, so unlike sot_locate_count_field below it can't be
    // fooled by an unrelated 4-byte value elsewhere in the header
    // coincidentally matching the object count - which is exactly the
    // failure mode overview.md's Entry 7 traced CAB-654's "new objects
    // vanish together" symptom to (a large, content-heavy bundle has more
    // candidate bytes nearby, making a coincidental collision - or a
    // coincidental ZERO matches, if the real field's own bytes don't
    // happen to also equal the count in the searched window - more likely
    // than for a small bundle). Still sanity-checked against the table's
    // own known live count before being trusted, so a stale/mismatched
    // offset (table mutated by something else since this instance parsed
    // it, unexpected format edge case, etc.) falls through to the
    // heuristic fallback instead of writing to the wrong field blind.
    if (_objectCountFieldOffsetKnown &&
        _objectCountFieldOffset >= 0 &&
        (NSUInteger)_objectCountFieldOffset + 4 <= nodeData.length) {
        uint32_t liveVal = sot_read_u32_le_public(nodeData, (NSUInteger)_objectCountFieldOffset);
        if (liveVal == (uint32_t)_objects.count) {
            countFieldOffset = (NSUInteger)_objectCountFieldOffset;
            countFieldBE = NO;
            foundCountField = YES;
        } else {
            ZLog(@"[SerializedObjectTable] insertObjects: structural m_ObjectCount offset %lld didn't read back the expected live count (%lu, got %u) - falling back to heuristic search",
                 _objectCountFieldOffset, (unsigned long)_objects.count, liveVal);
        }
    }

    // FALLBACK: only reached when the structural offset wasn't available
    // (typesResolved was NO for this table - the blind byte-scan path found
    // the object table without ever parsing the Types array, so there's no
    // structural basis for where m_ObjectCount lives) or it didn't check out
    // live. Same heuristic byte-value search as before this session -
    // unchanged, still refuses rather than guesses on ambiguity.
    if (!foundCountField) {
        if (!sot_locate_count_field(nodeData, firstEntryOffset, _objects.count, &countFieldOffset, &countFieldBE)) {
            if (error) *error = [NSError errorWithDomain:SerializedObjectTableErrorDomain
                                                      code:SOTErrorCountFieldNotFound
                                                  userInfo:@{NSLocalizedDescriptionKey: @"couldn't locate m_ObjectCount preceding the object table (neither the structural offset from parsing nor the heuristic byte-search succeeded) - see SerializedObjectTable.h's -insertObjects:... doc"}];
            return NO;
        }
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
