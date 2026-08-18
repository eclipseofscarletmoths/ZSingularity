// BundleTexture2DEnumerator.h
//
// The concrete "bundle parsing and Texture2D enumeration" step of the
// Texture2D retarget pipeline rework (see Rework.txt, project root) -
// wires together the three layers that already exist independently:
//
//   UnityBundleCAB.h        - decompresses a UnityFS archive into its
//                              named nodes (Layer A, archive level)
//   SerializedObjectTable.h - locates the object table inside the
//                              primary (CAB) node, resolving each
//                              entry's real class ID (Layer A, object
//                              level - Texture2D is class ID 28)
//   Texture2DSchema.h       - the fixed structural parser for one
//                              Texture2D object's bytes (Layer B)
//
// and produces one array covering every Texture2D object in the
// bundle, each either successfully parsed (.info) or carrying its own
// per-object failure (.error) - same "report per item, don't abort the
// whole batch" posture BundleTransplantResult already uses elsewhere in
// this project, since a single malformed/out-of-corpus object among
// hundreds shouldn't prevent enumerating the rest.
//
// SCOPE - WHAT THIS FILE DOES NOT DO: decode any pixel bytes
// (Texture2DPixelDecoder.h / CrunchTextureDecoder.h), patch/rewrite any
// object in place, or write a new bundle out. This is the read-only
// "locate and describe every Texture2D in this bundle" step Rework.txt
// calls for before conversion - see -sourcePixelBytesForObject:error:
// below for exactly where that boundary sits: it resolves WHERE a
// texture's still-encoded pixel bytes live (inline in the object, or in
// a companion .resS node), and hands back those raw, unconverted bytes.
// Feeding them through Texture2DPixelDecoder / CrunchTextureDecoder to
// get RGBA32 is the next step, not this one.
//
// MEMORY NOTE (see Rework.txt, "Layer D - Disk-backed bundle writer" /
// "next-generation UnityBundleCAB API"): this goes through
// +[UnityBundleCAB decompressedArchiveAtPath:error:], whose `.data` is
// now a memory-mapped view of a disk-streamed decompression (the
// "next-generation UnityBundleCAB API" Rework.txt called for - see that
// file's implementation and UnityBundleCAB.h's own MEMORY note) rather
// than one heap NSMutableData sized to the whole decompressed bundle.
// This class's own per-object slicing (-sourcePixelBytesForObject:,
// the enumeration loop below) was already written against `.data` as
// plain NSData and needed no changes for that - it benefits from the
// mapped backing automatically.
//
// TARGET PLATFORM RETARGET (m_TargetPlatform: 19 StandaloneWindows64 ->
// 9 iOS) is a whole-SerializedFile-header patch, not a per-Texture2D
// one - SerializedObjectTable.h already exposes exactly where that
// field lives (targetPlatformFieldOffset/targetPlatformFieldOffsetKnown)
// for whichever step ends up writing it. This class surfaces the
// CURRENT value for logging/validation (targetPlatform/
// targetPlatformKnown below) but does not patch it - same "enumerate
// now, patch later" scope line as everything else here.

#import <Foundation/Foundation.h>
#import "Texture2DSchema.h"

@class SerializedObject;
@class SerializedObjectTable;
@class UnityBundleArchive;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleTexture2DEnumeratorErrorDomain;

typedef NS_ENUM(NSInteger, BundleTexture2DEnumeratorErrorCode) {
    BundleTexture2DEnumeratorErrorArchiveFailed = 1,   // UnityBundleCAB couldn't decompress the bundle - see the wrapped underlying error
    BundleTexture2DEnumeratorErrorNoPrimaryNode,        // decompressed fine but reported zero nodes (shouldn't happen - UnityBundleCAB itself refuses that case, kept here defensively)
    BundleTexture2DEnumeratorErrorObjectTableFailed,    // SerializedObjectTable couldn't parse the primary node - see the wrapped underlying error
    BundleTexture2DEnumeratorErrorClassIDsUnresolved,   // table.typesResolved was NO - no structural basis to identify which objects are Texture2D (class ID 28) vs. anything else; see SerializedObjectTable.h's own note on the byte-scan fallback leaving classIDResolved NO for every object. Refused rather than guessed.

    // -sourcePixelBytesForObject:error: specific:
    BundleTexture2DEnumeratorErrorNoResSNode,           // object.info.hasStreamData but no node in the archive matches its streamPath's own file name
    BundleTexture2DEnumeratorErrorStreamRangeOutOfBounds, // streamOffset/streamSize don't fit inside the matched .resS node's own bytes
};

// One Texture2D object found in the bundle's primary SerializedFile
// node, whether or not it parsed cleanly - see this file's top comment
// on why failures are per-object here, not fatal to the whole
// enumeration.
@interface ZSTexture2DEnumeratedObject : NSObject

@property (nonatomic, assign) int64_t pathID;              // this object's PathID, straight from SerializedObjectTable - the stable identity a later patch step keys off of
@property (nonatomic, strong) SerializedObject *tableEntry; // the underlying object-table entry (byteStart/byteSize/tableOffset) - needed by a later step that patches this table in place, e.g. via -[SerializedObjectTable patchObject:newByteStart:newByteSize:inNodeData:error:]
@property (nonatomic, assign) NSUInteger cabAbsoluteOffset; // this object's own bytes' absolute start within the primary CAB node's data (i.e. table.dataOffset + tableEntry.byteStart) - saves a later step from re-deriving it
@property (nonatomic, assign) uint32_t byteSize;            // same value as tableEntry.byteSize, mirrored here for convenience

@property (nonatomic, strong, nullable) ZSTexture2DInfo *info; // Layer B's parse result - nil if parsing/validation failed, see .parseError
@property (nonatomic, strong, nullable) NSError *parseError;   // set (Texture2DSchemaErrorDomain) iff .info is nil

@end

@interface BundleTexture2DEnumerator : NSObject

@property (nonatomic, strong, readonly) UnityBundleArchive *archive;         // the fully-decompressed bundle - see this file's MEMORY NOTE above
@property (nonatomic, strong, readonly) NSData *cabNodeData;                 // archive.data's slice for the primary (CAB) node only
@property (nonatomic, strong, readonly) SerializedObjectTable *objectTable;  // parsed object table for that node

@property (nonatomic, assign, readonly) int32_t targetPlatform;        // current m_TargetPlatform value (19 = StandaloneWindows64 for a desktop-sourced bundle, per Rework.txt) - only meaningful when targetPlatformKnown is YES
@property (nonatomic, assign, readonly) BOOL targetPlatformKnown;       // mirrors objectTable.targetPlatformFieldOffsetKnown - NO means SerializedObjectTable's Types-array walk didn't locate this field (see its own header note), so this enumerator has no basis for reporting a value

@property (nonatomic, copy, readonly) NSArray<ZSTexture2DEnumeratedObject *> *texture2DObjects; // every class-ID-28 object in the table, success or failure - see this file's top comment

// Decompresses the bundle at `path`, locates its primary SerializedFile
// node, parses that node's object table, and enumerates (and
// individually schema-parses) every Texture2D object found. A failure
// parsing/validating one particular Texture2D object does NOT fail
// this call as a whole - check each entry's own .info/.parseError; only
// a failure at the archive/table level (can't decompress, table not
// found, class IDs unresolved) fails the whole call and returns nil.
+ (nullable instancetype)enumeratorForBundleAtPath:(NSString *)path error:(NSError **)error;

// Resolves and returns `object`'s own still-encoded pixel bytes -
// NEVER decoded/converted (see Texture2DPixelDecoder.h for that step).
// `object` must be one of this instance's own .texture2DObjects, with
// a non-nil .info.
//
// If object.info.hasInlineImageData: a subrange of this instance's own
// cabNodeData at object.info.imageDataOffset/imageDataLength - no
// archive-wide lookup needed, the bytes are already inside the object.
//
// If object.info.hasStreamData: locates the node in `archive.nodes`
// whose own path matches object.info.streamPath's last path component
// (Unity records this as something like
// "archive:/CAB-<hash>/CAB-<hash>.resS" - only the trailing
// "CAB-<hash>.resS" identifies which node inside THIS SAME archive
// holds the bytes), then reads
// streamOffset/streamSize from THAT node's own region of archive.data -
// i.e. streamOffset is treated as relative to the start of the
// referenced .resS node's own bytes, the standard convention documented
// by AssetStudio/UnityPy for Unity's external StreamingInfo (same
// public-format reasoning UnityBundleCAB.h's own top comment already
// leans on for the archive format itself). NOT yet cross-validated
// against one of this project's own real streamed Texture2D dumps end
// to end - flagged honestly rather than silently assumed correct, same
// posture CrunchTextureDecoder.h takes for its own unverified path.
//
// Returns nil and fills `error` if the referenced .resS node can't be
// found, or if streamOffset/streamSize don't fit inside it.
- (nullable NSData *)sourcePixelBytesForObject:(ZSTexture2DEnumeratedObject *)object error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
