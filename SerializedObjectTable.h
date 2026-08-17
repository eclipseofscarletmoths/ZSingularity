// SerializedObjectTable.h
//
// One level deeper than UnityBundleCAB.h: that file gets you a UnityFS
// archive's NODES (e.g. the "CAB-..." SerializedFile and its
// "CAB-....resS" companion, as flat offset/size/name entries). This
// file reads what's INSIDE one of those nodes when it's a SerializedFile
// (the CAB one, not the .resS one, which has no structure of its own -
// it's just a flat byte pool addressed by StreamingInfo offsets from
// inside the CAB node) - specifically its object table: every
// individual asset (a Texture2D, a MonoBehaviour, a TextAsset, ...)
// packed inside, as a PathID + byte range into that same node's data.
//
// ONLY SerializedFile FORMAT VERSION 22 IS SUPPORTED. Every real bundle
// this project has inspected (stock iOS and modded PC alike) uses it -
// see /areas/120f-tweak.md's notes on the CAB-654/CAB-e07 dumps this was
// built and verified against. Earlier versions use narrower (32-bit)
// offset fields in the header and the object table, which would need
// separate, unverified parsing this project has no real sample to test
// against - rather than guess, a file that reports a different version
// fails with SOTErrorUnsupportedVersion.
//
// OBJECT TABLE LOCATION: SerializedFile's header is fixed-size and
// version-gated (see SOTHeader below, verified against real files this
// session), but everything between that header and the object table
// itself - the Types array - has a genuinely complex, deeply
// version/flag-conditional layout (per-type script hashes, optional
// embedded type trees, reference-type name/namespace/assembly strings)
// that this project has no independent way to verify byte-for-byte
// without a sample where getting it wrong would silently corrupt
// something. Rather than reimplement that from memory and risk exactly
// that, this instead SCANS forward from the header for the object table:
// a run of kMinConsecutiveValidEntries (see the .m) 24-byte entries that
// all decode to plausible-looking (pathID, byteStart, byteSize, typeID)
// tuples in a row is accepted as the table. This was cross-validated
// this session by manually walking a real file's full object table
// (6368+ entries, zero anomalies) both from a known-good anchor AND via
// this same scan-forward approach landing on the identical start
// position - so it's confirmed correct on real data, just framed
// honestly as "detected structurally sound data" rather than "parsed
// the exact preceding format."
//
// TYPES ARRAY (m_Types), NOW PARSED TOO - see typesResolved below: the
// scan above is still what actually locates the object table (unchanged,
// still the trusted anchor), but each entry's raw typeID field is an
// INDEX into m_Types, not a Unity persistent class ID - a real bundle
// this project inspected has Texture2D objects (class ID 28) sitting at
// m_Types index 18, confirmed via an external report tool's separately-
// resolved class_counts vs its own type_id_distribution on the same 179
// objects (see /areas/120f-tweak.md). Code that compared typeID directly
// against 28/49 was therefore silently misclassifying every Texture2D/
// TextAsset as "wrong type" - no error, no log line, just an empty diff.
// sot_parse_types_array (see the .m) now walks m_UnityVersion/
// m_TargetPlatform/m_EnableTypeTree/m_Types structurally (skipping past
// each entry's optional embedded type tree via its own declared node
// count/string buffer size, never interpreting field names) to build a
// typeIndex -> classID map. Since this walk (unlike the object-table
// scan) genuinely IS "parse the exact preceding format" rather than
// "detect structurally sound data," it self-validates the only way that
// matters here: after parsing m_Types and the m_ObjectCount that follows
// it, the resulting byte position must land EXACTLY on the table's own
// start offset the independent scan already found. Any mismatch means
// something about this file's version/flags wasn't the standard case
// assumed - the map is discarded rather than trusted, typesResolved is
// NO, and every object's classIDResolved is NO, rather than risk a
// second silent misclassification.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SerializedObjectTableErrorDomain;

typedef NS_ENUM(NSInteger, SerializedObjectTableErrorCode) {
    SOTErrorTooSmall = 1,
    SOTErrorUnsupportedVersion,   // SerializedFile version != 22 - see header note above
    SOTErrorTableNotFound,        // scan never found a run of plausible entries - see header note above
    SOTErrorCountFieldNotFound,   // -insertObjects:... couldn't find the m_ObjectCount field preceding the table - see that method's doc
    SOTErrorCountFieldAmbiguous,  // more than one plausible m_ObjectCount candidate found - refused rather than guess
    SOTErrorInsertVerifyFailed,   // the post-insert re-scan didn't find exactly the expected new state - nodeData was NOT mutated
};

// One object table entry. byteStart/byteSize are relative to
// SerializedObjectTable.dataOffset (i.e. add dataOffset to byteStart to
// get an absolute position within the owning node's bytes) -
// deliberately left un-added here so a caller patching byteStart doesn't
// have to remember to subtract it back out afterward.
@interface SerializedObject : NSObject
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, assign) int64_t byteStart;
@property (nonatomic, assign) uint32_t byteSize;
// Raw object-table field: an INDEX into this file's own m_Types array,
// not a Unity persistent class ID (28, 49, ...) directly - see
// SerializedObjectTable.typesResolved and classID/classIDResolved below.
// Still needed as-is for -insertObjects:...'s own wire format.
@property (nonatomic, assign) int32_t typeID;
// Resolved Unity persistent class ID (e.g. 28 for Texture2D, 49 for
// TextAsset) via m_Types[typeID].classID - only meaningful when
// classIDResolved is YES. See SerializedObjectTable.m's
// sot_parse_types_array for how/when this is populated.
@property (nonatomic, assign) int32_t classID;
@property (nonatomic, assign) BOOL classIDResolved;
@property (nonatomic, assign) NSUInteger tableOffset; // byte offset of this entry's OWN 24 bytes within the node - see -patchObject:newByteStart:newByteSize:inNodeData:error: below
@end

@interface SerializedObjectTable : NSObject

@property (nonatomic, assign, readonly) int64_t dataOffset; // add to any entry's byteStart for an absolute node-data position
@property (nonatomic, copy, readonly) NSArray<SerializedObject *> *objects;
// YES if every object's classID/classIDResolved was populated via an
// m_Types walk that landed EXACTLY on this table's own (independently
// scan-located) start offset - see the .m's sot_parse_types_array. NO
// means the walk failed or landed somewhere else and was discarded
// rather than trusted; every object's classIDResolved is then NO and
// callers that need to identify object types (Texture2D vs TextAsset
// vs anything else) by real class rather than raw typeID index cannot
// do so for this file.
@property (nonatomic, assign, readonly) BOOL typesResolved;

// Locates and parses the object table inside `nodeData` (one
// UnityBundleNode's slice of a decompressed UnityBundleArchive.data -
// the CAB node, not its .resS companion). See this header's top comment
// for what's actually verified vs. structurally inferred here.
+ (nullable instancetype)tableForSerializedFileNodeData:(NSData *)nodeData error:(NSError **)error;

// Convenience lookup - nil if no object in this table has that pathID.
- (nullable SerializedObject *)objectWithPathID:(int64_t)pathID;

// In-place patch of one entry's byteStart/byteSize fields, directly
// inside `nodeData` (which must be the exact same NSMutableData this
// table was parsed from - `object.tableOffset` is only meaningful
// against that buffer). Does NOT touch the object's own payload bytes at
// the old or new byteStart - callers append/overwrite that separately
// (see TextureAtlasTransplant.m for how the two are used together: grow
// nodeData with the new payload appended at its end, then call this with
// that new length as newByteStart-relative-to-dataOffset and the
// payload's length as newByteSize). Returns NO only if tableOffset+24
// would run past nodeData's bounds - i.e. this table wasn't actually
// parsed from this buffer.
- (BOOL)patchObject:(SerializedObject *)object
        newByteStart:(int64_t)newByteStart
         newByteSize:(uint32_t)newByteSize
          inNodeData:(NSMutableData *)nodeData
               error:(NSError **)error;

// Adds brand-new entries to the object table - the capability
// TextureAtlasTransplant.h's own header used to rule out ("never invent
// new PathIDs") because it depends on a field this class's own top
// comment already flagged as unverified: the int32 m_ObjectCount that,
// per the public SerializedFile format, sits immediately before the
// entries this table's +tableForSerializedFileNodeData:error: only ever
// SCANNED for rather than reached by parsing the Types array that
// precedes it. This method still doesn't parse that array. Instead it
// finds m_ObjectCount the same way the table itself was found -
// structurally, not by offset assumption: this table already knows its
// own true entry count from the scan, so it searches the handful of
// bytes immediately before the first entry for a 4-byte integer (tried
// both little- and big-endian, since the table entries themselves are
// LE but everything structural in the surrounding header is BE - see
// the .m's top comment - and this project has no real dump pinning down
// which convention the count field itself actually uses) that equals
// that known count. Exactly one candidate in that window is treated as
// confirmation; zero is SOTErrorCountFieldNotFound, more than one is
// SOTErrorCountFieldAmbiguous - both refuse rather than guess.
//
// On a confirmed location, splices newObjects.count fresh 24-byte
// entries in immediately after the last existing entry (so every
// existing entry's tableOffset is unaffected - only the count field,
// the header's metadataSize/fileSize/dataOffset, which is why those and
// not the individual existing entries need adjusting, and everything
// structurally AFTER the table shift right by the inserted byte count),
// then appends payloads.count payload byte blobs at the true end of the
// node's data region, each new entry's byteStart/byteSize pointing at
// its corresponding payload. newObjects and payloads must be the same
// length and in the same order; only pathID and typeID need to be set
// on each newObjects entry going in - byteStart/byteSize/tableOffset
// are filled in on return.
//
// Self-verifying: after splicing, re-parses the result from scratch and
// confirms it finds exactly (old count + newObjects.count) entries, a
// lookup for every new pathID at its expected byteSize, and every
// PREVIOUSLY-existing pathID still present unchanged - if any of that
// disagrees, nodeData is left completely untouched (the splice is built
// in a scratch buffer first) and this returns NO with
// SOTErrorInsertVerifyFailed. On success this table's own .objects/
// .dataOffset are updated in place to the freshly-reparsed state, so a
// caller can keep using the same instance afterward.
//
// Caller contract, same spirit as -patchObject:...: nodeData must be
// the exact buffer this table was parsed from (tableOffset values are
// only meaningful against it), and pathID collisions against every
// EXISTING entry are the caller's responsibility to have ruled out
// first (this only refuses on a collision it can detect after the fact,
// via the verify step - it doesn't attempt any reference-patching if
// the caller handed over a colliding pathID by mistake).
- (BOOL)insertObjects:(NSArray<SerializedObject *> *)newObjects
              payloads:(NSArray<NSData *> *)payloads
            inNodeData:(NSMutableData *)nodeData
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
