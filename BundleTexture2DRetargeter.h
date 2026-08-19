// BundleTexture2DRetargeter.h
//
// Layer D of the Texture2D retarget pipeline rework (see Rework.txt,
// project root - "Layer D - Disk-backed bundle writer" and "Bundle
// writer redesign"). Sits on top of the three already-wired layers:
//
//   BundleTexture2DEnumerator (Layer A/B glue) - locates/schema-parses
//   every Texture2D object in a bundle.
//   Texture2DConverter (Layer C) - decodes one object's source pixel
//   bytes to RGBA32 at a time, per its own MEMORY POSTURE contract
//   (handler-synchronous, never accumulates an array of results).
//
// and does the thing nothing before it does yet: actually produces a
// retargeted bundle on disk - m_TargetPlatform patched 19 -> 9, every
// converted Texture2D's format/completeImageSize/mipCount/StreamingInfo
// patched, and a brand-new UnityFS file written out.
//
// SINGLE-.resS INVARIANT: a Unity bundle asset may contain at most ONE
// .resS node - this is a hard format constraint, not a style choice.
// An earlier version of this class ignored that and always created a
// second, pipeline-owned node ("CAB-<hash>.zsingularity-rgba32.resS")
// for every converted texture's RGBA32 bytes, alongside whatever
// pre-existing .resS node the source bundle already had. That produced
// a bundle with two .resS nodes, which the mobile client's own UnityFS
// loader refuses to load at all - not a per-object failure, a
// whole-bundle one. See ReworkLog.md for the write-up. This class now
// always writes AT MOST one .resS node.
//
// STORAGE DECISION (Rework.txt: "Recommended storage decision: keep
// converted textures streamed"): every converted texture's RGBA32
// bytes - whether the SOURCE was inline or already streamed - go into
// THE bundle's one .resS node: whichever one already exists (identified
// the same way BundleTexture2DEnumerator.h's own
// -sourcePixelBytesForObject:error: resolves it for reading - an
// already-streamed object's own streamPath, trailing path component),
// or, only if the bundle has no streamed textures at all yet, a
// freshly-created one named "CAB-<hash>.resS" per Unity's own
// convention. Each converted object's m_StreamData.path is rewritten to
// "archive:/CAB-<hash>/<that node's name>" - the same
// archive:/<cabName>/<resSNodeName> shape BundleTexture2DEnumerator.h
// already documents Unity itself uses, and streamOffset is relative to
// the START of that node's own bytes, same convention that file's
// -sourcePixelBytesForObject:error: already assumes for READING (see
// its own "not yet cross-validated" caveat - still true here, this
// class inherits the same open assumption for the bytes it WRITES).
//
// HOW THE EXISTING NODE IS REUSED WITHOUT A WHOLE-ARCHIVE REFLOW: the
// node's final bytes are [the existing node's bytes, verbatim] +
// [every converted texture's RGBA32 payload, appended] - never a
// from-scratch rebuild. This matters because any OTHER Texture2D in the
// bundle that's still streamed from this node (RGBA32/ASTC-native
// objects that never needed conversion, or one whose conversion failed
// and was left alone) keeps pointing at its original, untouched offset
// - its StreamingInfo is never patched, so the bytes it points at have
// to still be there. A converted object's OLD bytes inside that base
// region become dead space once its own StreamingInfo is repointed past
// the end of it (into the appended tail) - wasted, not wrong, the same
// "append, never reflow" posture this file already uses for the CAB
// node itself (see "CAB NODE GROWTH IS SMALL" below). Because the base
// bytes are reused verbatim, the node's final size is knowable up front
// (existing length + however many bytes get staged) without waiting for
// every conversion to finish, so no other node's offset has to move
// because of it either - same property the old two-node design was
// after, without the second node.
// +[UnityBundleCAB writeArchiveStreamingToPath:...
// cabNodePath:baseCABData:appendFilePath:...] (see that method's own
// header comment) already knows how to write exactly one such
// [base][append] composite node without holding it in RAM - this class
// reuses that method as-is, with the composite role assigned to the
// resS node (not, despite the method's parameter name, the actual
// "CAB"/SerializedFile node) - baseCABData is the existing node's bytes
// (or empty, if none existed), appendFilePath is the disk-backed
// staging file of newly-converted RGBA32 bytes.
//
// CAB NODE GROWTH IS SMALL: a converted object's own bytes inside the
// CAB node do NOT grow by anything close to its pixel payload size -
// that payload lives entirely in the new resS node instead. What
// changes in the CAB node per converted object is: three 4-byte ints
// patched in place (format/completeImageSize/mipCount), the inline
// image-data length field zeroed (if it was previously inline - its
// old content bytes are simply left in place afterward, unreferenced
// and unread by anything once the length field says 0, not physically
// removed), and m_StreamData rewritten to the new node/offset/size/
// path - which is a different byte LENGTH than whatever StreamingInfo
// (empty, or pointing at a different node) the object had before.
//
// An earlier version of this class refused to convert any object whose
// rewritten tail came out longer than its ORIGINAL span
// (BundleTexture2DRetargeterErrorObjectWouldGrow), on the theory that
// growth past the original span was an unexpected shape this project's
// corpus wouldn't produce. That reasoning didn't hold: a STREAMED
// object's original span is already just its header + a short
// StreamingInfo path (no inline pixel payload to drop), and the new
// resS path this class synthesizes is necessarily longer than whatever
// short path the object streamed from originally - so the rewritten
// tail is reliably a few dozen bytes BIGGER than the original span for
// every already-streamed texture, which is the common case in a
// streamed-heavy bundle, not the rare one. The check was also never a
// correctness requirement in the first place: see the next paragraph -
// a converted object's tail is always relocated to freshly-appended
// space, never written back into its own original span, so there was
// nothing for that span to overflow. It's been removed; see
// ReworkLog.md for the write-up. Rather than reflow the object to its
// OWN original position, each
// converted object's freshly-rewritten (smaller) bytes are appended at
// the true end of the CAB node's own data - same pattern
// -[SerializedObjectTable insertObjects:payloads:inNodeData:error:]
// already uses for brand-new objects - and only that ONE object's
// table entry is patched (via the existing -[SerializedObjectTable
// patchObject:newByteStart:newByteSize:inNodeData:error:], unmodified)
// to point at the new location; nothing else in the node moves. The
// old bytes at the object's original position become dead/unreferenced
// space, not corrupted or overwritten - wasted, not wrong.
//
// WHAT THIS CLASS DOES NOT DO (yet - see ReworkLog.md for what's next):
// it does not re-parse/verify the bundle it just wrote (Rework.txt's
// "Validation strategy" - reparsing the rebuilt object via
// Texture2DSchema and the rebuilt SerializedFile via
// SerializedObjectTable), and nothing calls this class yet - no
// GraphicsDebugOverlay.m entry point exists for it. Both are next
// entries' work, deliberately, per this rework's own "split the work
// up, don't do it all in one run" instruction.
//
// MEMORY POSTURE: this class holds the bundle's CAB node bytes in RAM
// as one mutable buffer (inherited from BundleTexture2DEnumerator's own
// already-documented, already-accepted whole-archive-in-RAM read path -
// not a new limitation this class introduces) plus the small
// (kilobytes, not megabytes, for a bundle with hundreds of textures -
// each converted object's own rewritten tail is a few dozen bytes)
// per-object append growth described above. The one thing that is NOT
// held in RAM, per Rework.txt's explicit "let the disk do the work"
// requirement and its ~600 MiB corpus estimate, is any converted
// texture's RGBA32 payload: each one is written to a disk-backed
// staging file within the same synchronous handler invocation
// Texture2DConverter hands it to (never retained past that scope,
// consistent with that method's own MEMORY POSTURE contract), and
// only once this class has already built and validated the object's
// rewritten tail - and is written straight back out (never rolled
// back) unless the table-entry patch immediately following it fails,
// in which case both the staging-file bytes and the CAB node append
// for that one object are truncated back off before moving on. This
// keeps a failed object's already-decoded pixels from ever riding
// along into the final resS node unreferenced - see ReworkLog.md for
// the bug this closes.

#import <Foundation/Foundation.h>
#import "Texture2DConverter.h"

@class BundleTexture2DEnumerator;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BundleTexture2DRetargeterErrorDomain;

typedef NS_ENUM(NSInteger, BundleTexture2DRetargeterErrorCode) {
    BundleTexture2DRetargeterErrorEnumerationFailed = 1,  // BundleTexture2DEnumerator itself failed - see the wrapped underlying error
    BundleTexture2DRetargeterErrorTargetPlatformUnknown,   // enumerator.targetPlatformKnown was NO - no structural basis to patch m_TargetPlatform, refused rather than guessed (see SerializedObjectTable.h)
    BundleTexture2DRetargeterErrorStagingFileFailed,        // couldn't create/open/write the disk-backed .resS staging file
    BundleTexture2DRetargeterErrorObjectWouldGrow,          // RETIRED - see this header's "CAB NODE GROWTH IS SMALL" note. Kept (unused) so this enum's later values don't renumber.
    BundleTexture2DRetargeterErrorTableEntryPatchFailed,    // -[SerializedObjectTable patchObject:...] itself returned NO for a converted object - see the wrapped underlying error. Per-object, not fatal.
    BundleTexture2DRetargeterErrorFinalWriteFailed,         // +[UnityBundleCAB writeArchiveStreamingToPath:...] failed producing the destination file - see the wrapped underlying error. Fatal to the whole call.
    BundleTexture2DRetargeterErrorHeaderFixupFailed,        // -[SerializedObjectTable growFileSizeBy:inNodeData:error:] failed after appending converted objects' tails - see the wrapped underlying error. Fatal to the whole call: leaving fileSize stale would make every relocated object's table entry fail a later re-parse's bounds check.
};

// One Texture2D object's outcome, reported per-object for the same
// reason BundleTexture2DEnumerator/Texture2DConverter already report
// per-object - a handful of bad objects in a bundle of hundreds
// shouldn't fail the whole retarget.
@interface ZSTexture2DRetargetObjectResult : NSObject
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, copy, nullable) NSString *name;               // info.name, if this object parsed at all - nil if it didn't (see -enumeratorParseError)
@property (nonatomic, assign) ZSTexture2DConversionDecision decision; // NotNeeded/Required/Unsupported - meaningless (0) if enumeratorParseError is set
@property (nonatomic, assign) BOOL patched;                          // YES iff this object's table entry / bytes were actually changed in the output
@property (nonatomic, strong, nullable) NSError *enumeratorParseError; // mirrors ZSTexture2DEnumeratedObject.parseError - this object never reached conversion at all
@property (nonatomic, strong, nullable) NSError *error;                // set (Texture2DConverterErrorDomain or BundleTexture2DRetargeterErrorDomain) iff this object's conversion/patch failed - .patched is NO whenever this is set
@end

// Whole-bundle outcome. A non-nil return means the destination file was
// written successfully; per-object failures (tracked here, not fatal to
// the call) mean some objects were left unchanged rather than converted -
// check .failedCount / walk .objectResults for detail before assuming
// every texture actually retargeted.
@interface ZSTexture2DRetargetSummary : NSObject
@property (nonatomic, copy) NSArray<ZSTexture2DRetargetObjectResult *> *objectResults;
@property (nonatomic, assign) NSInteger convertedCount;   // decision == Required, converted+patched successfully
@property (nonatomic, assign) NSInteger unchangedCount;   // decision == NotNeeded, or a parse failure the enumerator already reported (left alone either way)
@property (nonatomic, assign) NSInteger failedCount;      // decision == Required or Unsupported but .error is set - left unchanged despite needing conversion
@property (nonatomic, assign) int32_t originalTargetPlatform;  // m_TargetPlatform as read before patching (e.g. 19)
@property (nonatomic, assign) int32_t newTargetPlatform;        // always 9 (iOS) on a non-nil summary
@property (nonatomic, copy) NSString *resSNodeName;              // the bundle's one .resS node's name, e.g. "CAB-<hash>.resS" - reused if it already existed, otherwise newly created; not currently needed by any caller, kept for logging
@property (nonatomic, assign) int64_t resSNodeByteLength;        // that node's FINAL total size (preserved pre-existing bytes + newly-staged converted bytes) - not just what this run appended
@end

@interface BundleTexture2DRetargeter : NSObject

// Reads the bundle at `sourcePath`, converts every Texture2D object
// that needs it (per Texture2DConverter's Layer C table), patches
// m_TargetPlatform 19 -> 9, and writes a new UnityFS bundle to
// `destinationPath` (must not already exist as a directory; an
// existing regular file there is overwritten atomically, same as
// +[UnityBundleCAB writeArchive*] elsewhere in this project).
//
// Returns nil (destination NOT written) only for a whole-bundle-level
// failure: enumeration itself failed, m_TargetPlatform's offset isn't
// structurally known, the staging file couldn't be opened, or the
// final UnityFS write failed. A per-object conversion/patch failure
// does NOT fail this call - see ZSTexture2DRetargetSummary above.
//
// Does NOT delete/back up/replace `sourcePath` and does NOT touch
// wherever the game's own cache keeps its copy of this bundle -
// purely "read one bundle, write a retargeted one somewhere new."
// Slotting the result into place is a caller concern (see
// BundleTransplant.h for this project's existing swap-in-place
// machinery elsewhere) - not yet wired to this pipeline, see
// ReworkLog.md.
+ (nullable ZSTexture2DRetargetSummary *)retargetBundleAtPath:(NSString *)sourcePath
                                                  toPath:(NSString *)destinationPath
                                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
