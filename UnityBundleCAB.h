// UnityBundleCAB.h
//
// Reads just enough of a UnityFS archive's header to recover its real
// identity: the CAB-<hash> name (or occasionally a non-CAB path, for
// bundles not built through Addressables) stored as the first entry in
// its own directory table.
//
// WHY NOT JUST GREP FOR "CAB-...": a bundle's raw bytes routinely contain
// several CAB strings that are NOT its own name - dependency references to
// OTHER bundles it shares assets with. The sample __data handed to this
// project had 77 "CAB-" matches from a blind scan; only the first was the
// file's own identity, the other 76 were a single shared dependency
// referenced from many places in the asset data. A blind scan has no way
// to tell those apart. This does: the directory table is a specific,
// located structure (see below), and its first node is authoritatively
// the archive's own name - that's a property of the UnityFS format itself,
// not a heuristic.
//
// FORMAT (matches the "FS"/UnityFS archive header used by all builds this
// project has seen; see AssetStudio/UnityPy's public documentation of the
// same format for independent confirmation of this layout):
//   "UnityFS\0"                    signature
//   uint32 BE                      format version
//   cstring                        unity version
//   cstring                        unity revision
//   int64 BE                       total archive size
//   uint32 BE                      compressed blocks-info size
//   uint32 BE                      uncompressed blocks-info size
//   uint32 BE                      flags:
//                                    bits 0-5  compression type
//                                              (0 none, 1 LZMA, 2 LZ4, 3 LZ4HC, 4 LZHAM)
//                                    bit 6     blocks-info + directory info combined
//                                              (unrelated to location; set on
//                                              essentially every modern bundle)
//                                    bit 7     blocks-info stored at EOF instead of here
//                                    bit 9     blocks-info needs padding at its start
//                                              (only meaningful when bit 7 is NOT set -
//                                              see the alignment step below)
//   [16-byte stream alignment, gated on flags bit 9, only when blocks-info is NOT at EOF]
//   <compressed blocks-info bytes, length = compressed size above,
//    located either right here or at (archiveSize - compressedSize)>
//
// Decompressed blocks-info:
//   16 bytes                       uncompressed-data hash (unused here)
//   uint32 BE                      block count
//   [uint32 BE uncompressedSize, uint32 BE compressedSize, uint16 BE flags] * count  (unused here)
//   uint32 BE                      node (directory entry) count
//   [int64 BE offset, int64 BE size, uint32 BE flags, cstring path] * count
//
// node[0].path is what this returns as the bundle's CAB.
//
// COMPRESSION SUPPORT: full decode/decompress support is none and
// LZ4/LZ4HC only (via LZ4BlockDecoder.h - see that file). LZMA decompression
// is NOT implemented - every real bundle this project has inspected so far
// uses LZ4/LZ4HC (the mobile-appropriate choice; LZMA trades far more CPU
// for a size win that matters more on the CDN side than on-device), so
// decoding it hasn't come up in practice. A bundle that does use it will
// fail full extraction with UnityBundleCABErrorLZMADetected (blocks-info)
// or UnityBundleCABErrorUnsupportedCompression (data blocks, or LZHAM
// anywhere) rather than silently returning nothing or a wrong answer.
// LZMA is, however, accurately DETECTED and its 5-byte properties header
// (lc/lp/pb + dictionary size) IS extracted, independent of whether the
// stream itself can be decompressed - see UBCLZMAProperties,
// +isLZMACompressedBundleAtPath:isLZMA:error:, and
// +lzmaPropertiesForBundleAtPath:error: below.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const UnityBundleCABErrorDomain;

typedef NS_ENUM(NSInteger, UnityBundleCABErrorCode) {
    UnityBundleCABErrorCantReadFile = 1,
    UnityBundleCABErrorTooSmall,               // shorter than a minimal header
    UnityBundleCABErrorBadSignature,            // doesn't start with "UnityFS\0"
    UnityBundleCABErrorUnsupportedCompression,  // LZHAM, or anything else outside 0/1/2/3 - see header note above
    UnityBundleCABErrorDecompressFailed,        // LZ4BlockDecompress rejected the blocks-info blob
    UnityBundleCABErrorMalformedBlocksInfo,     // decompressed, but the node table didn't parse cleanly
    UnityBundleCABErrorNoNodes,                 // parsed fine, but the directory table is empty
    UnityBundleCABErrorMalformedSerializedFileHeader, // +targetPlatform:forBundleAtPath:error: couldn't walk the primary node's SerializedFile header far enough to reach m_TargetPlatform
    // The blob in question (blocks-info, or one data block) IS accurately
    // identified as LZMA (compression type 1) and its 5-byte properties
    // header (see UBCLZMAProperties below) WAS successfully extracted -
    // this is not a parse failure. It's kept as a distinct error code
    // (rather than folded into UnityBundleCABErrorUnsupportedCompression)
    // purely because this project has no LZMA decoder, so the blob's
    // actual payload still can't be produced; callers that only care
    // about detection + header info should treat this as a successful
    // identification, not a failure - see +isLZMACompressedBundleAtPath:
    // error: and +lzmaPropertiesForBundleAtPath:error: below, which
    // surface exactly that case without erroring at all.
    UnityBundleCABErrorLZMADetected,
};

// UnityBundleCAB compression-type byte (low 6 bits of the UnityFS header's
// flags field, and of each data block's own per-block flags field - see
// this file's format doc above). Named here so call sites don't have to
// spell out the raw integers 0-4 to know what they mean.
typedef NS_ENUM(uint8_t, UnityBundleCABCompressionType) {
    UnityBundleCABCompressionNone  = 0,
    UnityBundleCABCompressionLZMA  = 1,
    UnityBundleCABCompressionLZ4   = 2,
    UnityBundleCABCompressionLZ4HC = 3,
    UnityBundleCABCompressionLZHAM = 4,
};

// Userinfo key under which the internal blocks-info/data-block parsers and
// the two LZMA detection methods below attach a parsed UBCLZMAProperties
// instance to an NSError with code UnityBundleCABErrorLZMADetected.
extern NSString * const UnityBundleCABLZMAPropertiesErrorKey;

// The 5-byte LZMA properties header every raw LZMA stream in a UnityFS
// bundle begins with (this project's bundles never carry the extra 8-byte
// "uncompressed size" field some standalone .lzma files have - Unity
// already knows each block's uncompressed size from its own block table,
// so it's omitted here; see 7-Zip's lzma-specification.txt for the
// property-byte encoding this decodes):
//   uint8         propertyByte    encodes lc/lp/pb - see decode below
//   uint32 LE     dictionarySize
// propertyByte decodes as (props = pb*45 + lp*9 + lc):
//   lc = propertyByte % 9
//   lp = (propertyByte / 9) % 5
//   pb = propertyByte / 45
// This class only parses that header - it does NOT decompress the LZMA
// stream that follows it. No LZMA decoder is implemented anywhere in this
// project (see the compression-support note atop this file); the value of
// parsing this header on its own is identification/diagnostics (confirming
// a bundle really is LZMA rather than some other unsupported scheme, and
// recovering its dictionary size/literal-context parameters) for whatever
// eventually needs to actually decode it.
@interface UBCLZMAProperties : NSObject
@property (nonatomic, assign, readonly) uint8_t propertyByte;   // raw byte, before lc/lp/pb decode
@property (nonatomic, assign, readonly) uint8_t lc;              // literal context bits, 0-8
@property (nonatomic, assign, readonly) uint8_t lp;              // literal position bits, 0-4
@property (nonatomic, assign, readonly) uint8_t pb;              // position bits, 0-4
@property (nonatomic, assign, readonly) uint32_t dictionarySize; // bytes
@property (nonatomic, copy, readonly) NSData *headerBytes;       // the raw 5 bytes this was parsed from
@end

// One directory-table entry, WITH its offset/size (not just its name -
// see UnityBundleCAB's own array-of-names methods below for the
// names-only version). offset/size are into +decompressedArchiveAtPath:'s
// .data - i.e. already resolved past whatever block layout/compression
// the file used on disk.
@interface UnityBundleNode : NSObject
@property (nonatomic, copy) NSString *path;   // e.g. @"CAB-...", or @"CAB-....resS"
@property (nonatomic, assign) int64_t offset; // into the owning archive's .data
@property (nonatomic, assign) int64_t size;
// Directory-entry flags, as read from the archive's own blocks-info -
// bit 0x04 is "this node is a SerializedFile" (Unity's loader, and
// UABE/UABEA, parse a node with this bit set as a SerializedFile
// header rather than raw bytes). A .resS/.resource node MUST NOT have
// this bit set - it holds raw pixel/audio bytes, not a SerializedFile.
// Previously this field was read and discarded ((void)nFlags in
// UnityBundleCAB.m), and every write path hardcoded 4 for every node
// regardless of type - harmless for a single-node (CAB-only) bundle,
// which is all this project wrote until the Texture2D retarget
// pipeline started producing bundles with a .resS node too, at which
// point the mislabeled .resS node made the whole bundle unloadable/
// "corrupted" (both in-game and in UABEA). See ReworkLog.md.
@property (nonatomic, assign) uint32_t flags;
@end

// A UnityFS archive with every block actually decompressed, in node
// order, and exposed as one `.data` - what TextureAtlasTransplant.h (and
// anything else that needs to read/patch bytes INSIDE a node, not just
// identify nodes by name) needs that +primaryCABForBundleAtPath:error:
// and +allNodePathsForBundleAtPath:error: don't provide, since those two
// only ever decompress the much smaller blocks-info blob.
//
// MEMORY: `.data` is a memory-MAPPED view of a temp file the
// decompressor streamed to disk one block at a time (never a
// heap NSMutableData built up to the whole bundle's decompressed
// size) - see +decompressedArchiveAtPath:error:'s implementation.
// Slicing it (subdataWithRange:, dataWithBytesNoCopy: over its
// .bytes, ...) faults in only the pages touched; the OS can discard
// clean pages under memory pressure. The backing temp file is deleted
// automatically once this archive instance is deallocated - no
// explicit cleanup call needed.
@interface UnityBundleArchive : NSObject
@property (nonatomic, copy) NSString *unityVersion;   // preserved as-is for the rewrite
@property (nonatomic, copy) NSString *unityRevision;  // preserved as-is for the rewrite
@property (nonatomic, strong) NSData *data;           // every node's bytes, concatenated, decompressed - memory-mapped, see MEMORY note above
@property (nonatomic, copy) NSArray<UnityBundleNode *> *nodes;
@end

@interface UnityBundleCAB : NSObject

// Cheap content-based identity check: does this file actually start with
// the 8-byte "UnityFS\0" signature every UnityFS asset bundle has at the
// very top of its header? Reads only those 8 bytes - no blocks-info
// decompression, no CAB resolution, and no dependency on the file's name
// or extension. This is the right check for "is this file an asset
// bundle at all" (a file's name is user-controlled and easily wrong -
// see ModAssetLibrary.m's importer and GraphicsDebugOverlay.m's Load
// Mods picker handler, both of which classify by this instead of by
// name); once a file has passed this check and its own CAB id is
// actually needed, use +primaryCABForBundleAtPath:error: separately.
+ (BOOL)isUnityFSBundleAtPath:(NSString *)path;

// Returns the UnityFS archive-wide compression type from the header - see
// UnityBundleCABCompressionType above for what the raw byte means (0 none,
// 1 LZMA, 2 LZ4, 3 LZ4HC, 4 LZHAM). This only reads the small header and
// does not decompress the bundle, so it works even for a bundle whose
// blocks-info this project otherwise can't decode (LZMA/LZHAM).
+ (uint8_t)compressionTypeForBundleAtPath:(NSString *)path error:(NSError **)error;

// Accurate, cheap (header-only, no decompression attempted) check for
// whether `path`'s blocks-info is LZMA-compressed specifically - i.e.
// UnityBundleCABCompressionLZMA (1), not just "some compression this
// project can't decode" (which also covers LZHAM (4) and any other/future
// value >3). Returns NO + fills `error` if the file isn't even a parseable
// UnityFS header (bad signature, truncated, etc.); otherwise returns YES
// and sets `outIsLZMA` regardless of the answer, so a NO/false result here
// is a real "confirmed not LZMA," not "couldn't tell."
+ (BOOL)isLZMACompressedBundleAtPath:(NSString *)path isLZMA:(BOOL *)outIsLZMA error:(NSError **)error;

// If `path`'s blocks-info is LZMA-compressed, parses and returns the
// 5-byte LZMA properties header (lc/lp/pb + dictionary size) that blob
// begins with - see UBCLZMAProperties above. Returns nil + an error if the
// file isn't a parseable UnityFS header, or if it parses fine but isn't
// LZMA-compressed (error code UnityBundleCABErrorUnsupportedCompression in
// the latter case, distinguishable from a real parse failure). This does
// NOT decompress the LZMA stream - see UBCLZMAProperties's own comment for
// why that's out of scope for this project.
+ (nullable UBCLZMAProperties *)lzmaPropertiesForBundleAtPath:(NSString *)path error:(NSError **)error;

// Rewrites a supported UnityFS bundle as a transport-optimized LZ4HC
// archive. The payload is unchanged logically; only UnityFS block
// framing/compression is changed. The returned NSData is ready to upload
// as a release asset. LZMA/LZHAM input is rejected because this project
// does not contain an on-device decoder for those formats.
+ (nullable NSData *)LZ4HCDataForBundleAtPath:(NSString *)path error:(NSError **)error;

// Like +allNodePathsForBundleAtPath:error:, but decompresses every data
// block (not just blocks-info) and hands back the whole thing as one
// contiguous, memory-mapped `.data` plus each node's offset/size into
// it - LZMA/LZHAM are still unsupported (see the error codes above),
// and now so is any bundle whose DATA blocks (as opposed to just its
// blocks-info) use one of those, for the same reason. Decompression
// itself is disk-backed and streams one block at a time - see
// UnityBundleArchive's MEMORY note above.
+ (nullable UnityBundleArchive *)decompressedArchiveAtPath:(NSString *)path error:(NSError **)error;

// Serializes `archive` back out as a valid UnityFS file at `path` and
// writes it atomically. Always writes uncompressed (compression type 0)
// blocks-info stored inline (not at EOF) as a single block covering the
// whole of `archive.data` - this is deliberately the simplest valid
// uncompressed shape this format allows, not a byte-for-byte reproduction
// of whatever compression/block-count the original had. The upload path
// has a separate LZ4HC transport writer below; this method remains the
// existing uncompressed writer used by callers that explicitly need that
// representation.
+ (BOOL)writeArchive:(UnityBundleArchive *)archive toPath:(NSString *)path error:(NSError **)error;

// Same on-disk result as +writeArchive:toPath:error:, but for a caller
// that doesn't want (or can't afford) to hold one concatenated
// full-bundle NSData in memory at all. `nodes` must already have its
// final offset/size per entry (computable from lengths alone); this
// calls `nodeDataAtIndex` once per node, in order, writes what it
// returns straight to the destination file, and releases it before
// asking for the next one - so peak memory is roughly "whatever the
// caller's block itself needs to produce one node's bytes," not "every
// node's bytes plus one more full-bundle-size copy of all of them
// concatenated." See Rework.txt (project root, Layer D) for the
// intended caller - the disk-backed bundle writer this streaming API
// exists for hasn't been rebuilt yet.
+ (BOOL)writeArchiveStreamingToPath:(NSString *)path
                        unityVersion:(nullable NSString *)unityVersion
                       unityRevision:(nullable NSString *)unityRevision
                               nodes:(NSArray<UnityBundleNode *> *)nodes
                     nodeDataAtIndex:(NSData * _Nullable (^)(NSUInteger index))nodeDataAtIndex
                               error:(NSError **)error;

// Memory-efficient variant for a caller that has one mutable CAB node in memory
// plus a disk-backed append stream containing newly-built objects. The CAB node
// is emitted as [baseCABData][appendFile] without ever concatenating those two
// buffers in RAM. appendFilePath may be nil when appendLength is zero.
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

// The archive's own name (its first directory node's path), e.g.
// @"CAB-3832197875c1bd4d48da9ab24c88e996". nil + error filled if this
// isn't a UnityFS archive this can parse - see the error codes above for
// which case.
+ (nullable NSString *)primaryCABForBundleAtPath:(NSString *)path error:(NSError **)error;

// Every directory node's path, in on-disk order (index 0 is always the
// same string +primaryCABForBundleAtPath:error: returns). Exposed mainly
// for diagnostics/logging - matching against cached bundles should use the
// primary name above, not this list, since only index 0 is the archive's
// own identity.
+ (nullable NSArray<NSString *> *)allNodePathsForBundleAtPath:(NSString *)path error:(NSError **)error;

// The Unity BuildTarget integer (e.g. 19 for StandaloneWindows64, 9 for
// iOS) stored in the bundle's own primary SerializedFile header -
// node[0], the same node +primaryCABForBundleAtPath:error: names (see
// this header's top comment on why node[0] specifically is the
// archive's own identity, not just any CAB string found in it).
//
// FORMAT (SerializedFile header, walked just far enough to reach
// m_TargetPlatform - see AssetStudio/UnityPy's public documentation of
// this format for independent confirmation of this layout, same as the
// UnityFS layout note above):
//   uint32 BE    m_MetadataSize
//   uint32 BE    m_FileSize
//   uint32 BE    m_Version
//   uint32 BE    m_DataOffset
//   uint8        m_Endianess           (only present, version >= 9)
//   uint8[3]     m_Reserved            (only present, version >= 9)
//   [version >= 22: m_MetadataSize re-read as uint32 BE, then m_FileSize/
//    m_DataOffset/an unknown field re-read as int64 BE in place of the
//    32-bit ones above - a wider header some newer Editor versions use]
//   -- everything from here on is encoded per m_Endianess, NOT the
//      header's own fixed big-endian --
//   cstring      unityVersion          (only present, version >= 7)
//   int32        m_TargetPlatform      (only present, version >= 8 -
//                                        this is the value returned)
//
// Requires fully decompressing the archive (unlike
// +primaryCABForBundleAtPath:error:, which only needs the much smaller
// blocks-info blob) since the SerializedFile header lives in the
// bundle's compressed DATA blocks - see +decompressedArchiveAtPath:
// error:'s own MEMORY note for why this is still disk-backed rather
// than a full in-RAM copy.
+ (BOOL)targetPlatform:(int32_t *)outPlatform forBundleAtPath:(NSString *)path error:(NSError **)error;

// Best-effort human-readable name for a Unity BuildTarget integer, e.g.
// 19 -> @"StandaloneWindows64". This project's lookup table only covers
// the more common values; anything not in it comes back as @"Unknown" -
// callers pair this with the raw integer in their own display (e.g.
// "StandaloneWindows64(19)") so an unrecognized platform is never
// presented as if it silently didn't have one.
+ (NSString *)nameForTargetPlatform:(int32_t)platform;

@end

NS_ASSUME_NONNULL_END
