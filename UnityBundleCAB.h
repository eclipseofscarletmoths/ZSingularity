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
//                                    bit 6     blocks-info stored at EOF instead of here
//                                    bit 7     blocks-info + directory info combined
//   [4-byte stream alignment, format version >= 7, only when blocks-info is NOT at EOF]
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

@interface UnityBundleCAB : NSObject

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
