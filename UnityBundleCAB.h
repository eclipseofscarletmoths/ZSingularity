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
// COMPRESSION SUPPORT: none and LZ4/LZ4HC (via LZ4BlockDecoder.h - see
// that file). LZMA is NOT implemented - every real bundle this project
// has inspected so far uses LZ4/LZ4HC (the mobile-appropriate choice;
// LZMA trades far more CPU for a size win that matters more on the CDN
// side than on-device), so this hasn't come up in practice, but a bundle
// that does use it will fail extraction with
// UnityBundleCABErrorUnsupportedCompression rather than silently
// returning nothing or a wrong answer.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const UnityBundleCABErrorDomain;

typedef NS_ENUM(NSInteger, UnityBundleCABErrorCode) {
    UnityBundleCABErrorCantReadFile = 1,
    UnityBundleCABErrorTooSmall,               // shorter than a minimal header
    UnityBundleCABErrorBadSignature,            // doesn't start with "UnityFS\0"
    UnityBundleCABErrorUnsupportedCompression,  // LZMA/LZHAM - see header note above
    UnityBundleCABErrorDecompressFailed,        // LZ4BlockDecompress rejected the blocks-info blob
    UnityBundleCABErrorMalformedBlocksInfo,     // decompressed, but the node table didn't parse cleanly
    UnityBundleCABErrorNoNodes,                 // parsed fine, but the directory table is empty
};

// One directory-table entry, WITH its offset/size (not just its name -
// see UnityBundleCAB's own array-of-names methods below for the
// names-only version). offset/size are into +decompressedArchiveAtPath:'s
// .data - i.e. already resolved past whatever block layout/compression
// the file used on disk.
@interface UnityBundleNode : NSObject
@property (nonatomic, copy) NSString *path;   // e.g. @"CAB-...", or @"CAB-....resS"
@property (nonatomic, assign) int64_t offset; // into the owning archive's .data
@property (nonatomic, assign) int64_t size;
@end

// A UnityFS archive with every block actually decompressed and
// concatenated into one buffer - what TextureAtlasTransplant.h (and
// anything else that needs to read/patch bytes INSIDE a node, not just
// identify nodes by name) needs that +primaryCABForBundleAtPath:error:
// and +allNodePathsForBundleAtPath:error: don't provide, since those two
// only ever decompress the much smaller blocks-info blob.
@interface UnityBundleArchive : NSObject
@property (nonatomic, copy) NSString *unityVersion;   // preserved as-is for the rewrite
@property (nonatomic, copy) NSString *unityRevision;  // preserved as-is for the rewrite
@property (nonatomic, strong) NSData *data;           // every node's bytes, concatenated, decompressed
@property (nonatomic, copy) NSArray<UnityBundleNode *> *nodes;
@end

@interface UnityBundleCAB : NSObject

// Like +allNodePathsForBundleAtPath:error:, but decompresses every data
// block (not just blocks-info) and hands back the whole thing as one
// contiguous buffer plus each node's offset/size into it - LZMA/LZHAM
// are still unsupported (see the error codes above), and now so is any
// bundle whose DATA blocks (as opposed to just its blocks-info) use one
// of those, for the same reason.
+ (nullable UnityBundleArchive *)decompressedArchiveAtPath:(NSString *)path error:(NSError **)error;

// Serializes `archive` back out as a valid UnityFS file at `path` and
// writes it atomically. Always writes uncompressed (compression type 0)
// blocks-info stored inline (not at EOF) as a single block covering the
// whole of `archive.data` - this is deliberately the simplest valid
// shape this format allows, not a byte-for-byte reproduction of
// whatever compression/block-count the original had. Confirmed
// on-device (see PatchManifestNetwork's own manifest-patching, and the
// uncompressed-bundle test that preceded this file) that the mobile
// client's UnityFS loader accepts fully uncompressed archives without
// issue, so there's no reason to reimplement an LZ4 *encoder* (only
// LZ4BlockDecoder.h's decoder exists in this project) just to preserve
// the original's compression.
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

@end

NS_ASSUME_NONNULL_END
