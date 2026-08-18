// PlatformBundleRetarget.h
//
// THE IDEA (person's own, this session): TextureAtlasTransplant.m exists
// because a PC mod's bundle and target's cached mobile bundle are two
// DIFFERENT files with (mostly) the same PathIDs, so getting the mod
// in means diffing them object-by-object and merging. That diff/merge
// machinery - TAT2VersionProfile detection, SerializedObjectTable's
// insert-new-objects path, the whole modded-vs-target split - exists to
// solve "make two different files agree," not anything Texture2D
// specific.
//
// This file sidesteps needing two files at all. Per the person's own
// manual, exhaustive comparison of a real mobile bundle against its
// desktop counterpart for the SAME asset: every object's bytes are
// IDENTICAL across the two platforms except m_TargetPlatform in the
// SerializedFile header, and (Texture2D only) m_TextureFormat/
// m_CompleteImageSize/the pixel payload itself/m_MipCount. Nothing else
// - not width/height, not any other object type, not GLTextureSettings,
// not any other field this project has ever had to reason about in
// Texture2DFields.h - differs by platform at all. If that holds (see
// this file's .m for how heavily this class still leans on the existing
// self-validating parse rather than just trusting the claim), a
// PC-built modded bundle can be turned into something the mobile client
// accepts DIRECTLY:
//
//   1. Rewrite the SerializedFile header's own m_TargetPlatform field.
//   2. Re-encode every Texture2D's pixel payload + format/size/mipCount
//      fields to something the mobile client can actually bind (this
//      project's existing RawPixelPacker target - see that header).
//   3. Nothing else in the file changes - no object added, none
//      removed, no PathID renumbered, object COUNT identical - so none
//      of SerializedObjectTable's insert/count-field machinery is
//      needed at all, only -patchObject:newByteStart:newByteSize:...
//      (repoint one existing entry to a same-node, different-size
//      payload - exactly BundleTransplant.h's whole-file swap, just one
//      layer further in).
//
// The result is then a straight, whole-file drop-in via
// BundleTransplant.h - the caller doesn't juggle a second (modded vs.
// target) file at any point, which is the whole point per the person's
// own framing of this idea.
//
// WHAT THIS BUYS OVER TextureAtlasTransplant.m: no TAT2VersionProfile
// guessing against unverified data. +retargetedArchiveFromDesktopBundle:...
// below runs the SAME +detectVersionProfile:fromObjectSamples: this
// project already had sitting unused (see overview.md's root-cause
// write-up - kTAT2ProfileDefault was being used verbatim, detection was
// written but never actually called), but now against the DESKTOP
// bundle's OWN Texture2D objects being converted - not a separate
// "modded" bundle - so there's no cross-file agreement question, only
// "does this Unity build's own Texture2D layout self-validate," which
// is exactly what that function was built to answer.
//
// WHAT THIS DOES NOT BUY: this only helps a PC-built (or any other
// desktop/non-mobile-format) bundle become a drop-in mobile bundle,
// exactly the shape BundleTransplant.m already swaps wholesale. It is
// NOT a replacement for TextureAtlasTransplant.m's actual job - merging
// a Spine reskin's changed PathIDs into an existing mobile bundle that
// otherwise needs to stay exactly as-is (see that header's Ryoshu/
// LittleFather note). Whether a given mod ships as "a whole desktop
// bundle, drop in wholesale" or "a handful of changed PathIDs merged
// into what's already there" determines which of these two files is the
// right tool - this one is for the former, deliberately at the cost of
// re-encoding EVERY Texture2D in the bundle (including any the mod
// itself didn't touch), not just the changed ones, since the entire
// point is never needing to know which PathIDs differ from stock at
// all. See this file's .m for the size/memory tradeoff that follows
// from that (RawPixelPacker's 16-bit output vs. mobile stock's ASTC
// 6x6 - flagged there, not solved here).

#import <Foundation/Foundation.h>
#import "UnityBundleCAB.h" // for UnityBundleArchive

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PlatformBundleRetargetErrorDomain;

typedef NS_ENUM(NSInteger, PlatformBundleRetargetErrorCode) {
    PlatformBundleRetargetErrorArchiveReadFailed = 1,
    PlatformBundleRetargetErrorNoCABNode,             // couldn't find the archive's own primary CAB node among its nodes
    PlatformBundleRetargetErrorTableParseFailed,      // SerializedObjectTable couldn't parse the CAB node at all
    PlatformBundleRetargetErrorTypesUnresolved,       // typesResolved == NO - can't identify Texture2D objects by real classID, refusing rather than guessing (see .m)
    PlatformBundleRetargetErrorTargetPlatformFieldUnknown, // targetPlatformFieldOffsetKnown == NO - same refusal, for step 1
    PlatformBundleRetargetErrorArchiveWriteFailed,
};

// Per-bundle outcome counters - deliberately named/shaped to match
// TextureAtlasTransplantResult's own split so a caller logging both
// doesn't have to learn two different vocabularies.
@interface PlatformBundleRetargetResult : NSObject
@property (nonatomic, copy, readonly) NSString *cab;
@property (nonatomic, assign, readonly) NSInteger texture2DCount;             // every Texture2D object found in the bundle, regardless of outcome below
@property (nonatomic, assign, readonly) NSInteger texture2DRetargeted;        // successfully decoded, re-packed, and patched in place
@property (nonatomic, assign, readonly) NSInteger texture2DAlreadyPacked;     // rawFormat was already one of RawPixelPacker's own output formats (RGB565/ARGB4444) - almost certainly means this bundle was already retargeted by an earlier run; left untouched, not re-encoded a second time (re-decoding a 16-bit packed format isn't implemented - see Texture2DPixelDecoder.h's format coverage - so this is a deliberate skip, not a failure)
@property (nonatomic, assign, readonly) NSInteger texture2DHeaderParseFailed; // resolved profile didn't fit this particular object - see Texture2DFields.h
@property (nonatomic, assign, readonly) NSInteger texture2DFormatUnsupported; // Texture2DPixelDecoder doesn't decode this object's rawFormat (most notably DXT5Crunched without CrunchTextureDecoder's vendored dependency - see that header)
@end

@interface PlatformBundleRetarget : NSObject

// Reads the UnityFS archive at desktopBundlePath (a PC/desktop-built
// bundle - see this header's top comment), rewrites its SerializedFile
// header's m_TargetPlatform to targetPlatform, re-encodes every
// Texture2D object's pixel payload via Texture2DPixelDecoder + 
// RawPixelPacker, and returns the resulting archive ready for
// +writeArchive:toPath:error: (UnityBundleCAB.h) - this function itself
// does not write anything to disk.
//
// targetPlatform: the raw m_TargetPlatform int32 value to write - this
// project has not independently re-derived Unity's BuildTarget/
// RuntimePlatform enum mapping from scratch; the caller supplies
// whatever value their own real mobile-bundle sample confirmed (per
// this session's chat: 9, replacing the desktop bundle's own 19) rather
// than this file hardcoding a guess it can't verify itself.
//
// Every other object in the bundle (non-Texture2D, or a Texture2D whose
// format isn't one this project decodes) is left completely untouched -
// same "whole-object copy, PathID does the work" posture as
// TextureAtlasTransplant.m, just against one file instead of two.
+ (nullable UnityBundleArchive *)retargetedArchiveFromDesktopBundleAtPath:(NSString *)desktopBundlePath
                                                            targetPlatform:(int32_t)targetPlatform
                                                                    result:(PlatformBundleRetargetResult * _Nullable * _Nullable)outResult
                                                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
