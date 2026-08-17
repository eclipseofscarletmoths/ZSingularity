// TextureAtlasTransplant.h
//
// The payoff of SerializedObjectTable.h/UnityBundleCAB.h's archive
// read/write additions: BundleTransplant.h swaps a WHOLE cached bundle
// file; BankTransplant.h swaps a WHOLE FMOD bank file. Neither is enough
// for a Spine-rigged character reskin (see /areas/120f-tweak.md's
// Ryoshu/LittleFather notes) - the fix there needed several INDIVIDUAL
// objects inside one bundle (texture pages, the Spine AtlasAsset, its
// atlas TextAsset, ...) replaced without disturbing anything else in the
// same file, which is exactly what UABEA's raw object import/export was
// doing by hand. This is that same operation, automated.
//
// WHY WHOLE-OBJECT COPY IS ENOUGH FOR MOST TYPES, NO PER-TYPE SCHEMA
// NEEDED: this project's own manual testing (see /areas/120f-tweak.md)
// confirmed stock and modded share the exact same PathID for every
// object that actually needs to change - the mod doesn't add new
// assets, it changes what's already there. Unity resolves every
// cross-reference (a Material's texture, an AtlasAsset's regions, a
// SkeletonData's atlasAssets) by PathID, not by content - so copying
// modded's object bytes into target at the SAME PathID is enough to
// make every one of those references resolve to the new content
// automatically. No AtlasAsset/Material-specific field parsing exists
// anywhere in this file, deliberately - PathID identity is doing all
// the work.
//
// THE ADD CASE (a mod introducing a PathID target has never seen at
// all - a genuinely new texture page, not a reskin of an existing one):
// this used to be refused outright (objectsSkippedNotInTarget, "never
// invent new PathIDs") because doing it safely depends on locating and
// incrementing SerializedFile's own m_ObjectCount field, which
// SerializedObjectTable.h's own top comment already flags as something
// its table-scan deliberately avoids needing to parse. That gap is
// closed by SerializedObjectTable's -insertObjects:payloads:... (see
// that header): it re-derives m_ObjectCount's location structurally
// (search for a field matching the table's own already-known count,
// same "confirm before trusting" posture as everything else in this
// pair of files) and self-verifies the result by re-parsing before
// committing anything. This file reuses modded's OWN PathID for these
// (there is no target counterpart to collide with by definition, since
// this is exactly the set of PathIDs target didn't have going in) -
// what it does NOT do is patch any cross-references INTO the new
// object, since nothing this file transplants (Texture2D, TextAsset)
// typically holds outbound PPtr references at all; a Spine .atlas
// TextAsset that's now supposed to reference the new page instead does
// so by filename text, not PathID, and would already be one of the
// differing-content TextAsset PathIDs the existing diff loop copies
// over unmodified. A MonoBehaviour or Sprite referencing the new
// texture by PathID PPtr is NOT something this file transplants or
// rewrites - see objectsSkippedWrongType.
//
// THREE EXCEPTIONS, ALL HANDLED IN THE .m:
//
// 1) Type filtering. A whole-object verbatim copy is only safe when
//    the SAME PathID serializes identically on both platforms - true
//    for TextAsset (see BundleTransplant.m's own README note) but NOT
//    for Texture2D, where PC mods carry DXT/DXT5Crunched/RGBA32 pixel
//    data and an iOS target only accepts RGBA ASTC 6x6 (Metal can't
//    bind DXT at all - texture creation fails outright, not just looks
//    wrong). Every differing PathID whose typeID isn't Texture2D (28)
//    or TextAsset (49) is skipped and counted
//    (objectsSkippedWrongType) rather than blindly copied - see the
//    .m's kTAT2ClassID* constants.
//
// 2) Texture2D re-encoding. Since a verbatim copy is unsafe for
//    Texture2D (see above), those objects instead go through
//    Texture2DFields.h (locate/patch the header fields) +
//    Texture2DPixelDecoder.h (decode modded's source format to RGBA32
//    - RGBA32/RGB24/DXT1/DXT5 are supported; DXT5Crunched is not, see
//    that header) + RawPixelPacker.h (re-encode RGBA32 into the cheap
//    RGB565/ARGB4444 formats this project targets instead of a full
//    ASTC re-encode - see RawPixelPacker.h's own top comment on why).
//    Target's OWN header fields/streaming shape are used for the
//    patch step, independently of modded's - see the .m.
//
// 3) New-object encoding. Same Texture2D re-encode as (2), but with no
//    target counterpart to use as the patch template (there IS none -
//    that's the whole reason this object needed adding rather than
//    diffing) - modded's OWN parsed header is patched in place instead,
//    on a mutable copy of modded's own object bytes. Whether the new
//    payload lands inline or in target's .resS follows target's own
//    file-level convention (stream if target has a .resS node at all,
//    inline otherwise) since there's no per-object precedent to match -
//    see the .m's tat_collect_new_object.
//
// THE STREAMED-DATA OFFSET REWRITE: a Texture2D (or any other type)
// whose pixel/payload bytes live in .resS (StreamData.size != 0 - see
// the name-relative Texture2D field layout confirmed against real
// files in /areas/120f-tweak.md) stores an OFFSET into that specific
// bundle's OWN .resS - copying the object's bytes verbatim would carry
// over an offset into modded's .resS, meaningless once that object is
// sitting inside target's file instead. This is detected generically
// (see the .m) by pattern-matching the StreamingInfo struct's
// "archive:/...resS" path string inside whatever object bytes are
// being inspected, rather than by recognizing the object as a
// Texture2D specifically - so this also transparently covers any other
// streamed asset type Unity might use the same StreamingInfo struct
// for. For the re-encoded Texture2D path, both the offset AND the size
// field get rewritten (unlike a verbatim copy, the re-encoded payload's
// byte count essentially never matches what was there before).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TextureAtlasTransplantErrorDomain;

typedef NS_ENUM(NSInteger, TextureAtlasTransplantErrorCode) {
    TextureAtlasTransplantErrorCantReadModded = 1,
    TextureAtlasTransplantErrorModdedCABFailed,   // UnityBundleCAB/decompression couldn't parse the picked file
    TextureAtlasTransplantErrorModdedTableFailed, // SerializedObjectTable couldn't locate the modded file's own object table
    TextureAtlasTransplantErrorNoCacheDirectory,  // same as BundleTransplantErrorNoCacheDirectory
    TextureAtlasTransplantErrorBackupFailed,
    TextureAtlasTransplantErrorWriteFailed,
};

// One matched-and-patched (or attempted) cached bundle's outcome -
// same "report per match, don't abort the whole call on one failure"
// shape as BundleTransplantResult.
@interface TextureAtlasTransplantResult : NSObject
@property (nonatomic, copy) NSString *cachedPath;             // the __data file this applied to
@property (nonatomic, assign) NSInteger objectsInspected;      // PathIDs present in both modded and target, and of a handled type (see objectsSkippedWrongType)
@property (nonatomic, assign) NSInteger objectsTransplanted;   // ...of which actually differed and got copied/re-encoded over
@property (nonatomic, assign) NSInteger objectsSkippedNotInTarget; // PathIDs modded has that target doesn't, of a handled type, that ended up NOT added - see objectsAdded for the ones that were. Only counts real failures now (see .m): SerializedObjectTable.h's -insertObjects:... made adding new PathIDs possible, so this class no longer skips these outright.
@property (nonatomic, assign) NSInteger objectsAdded;              // new Texture2D/TextAsset PathIDs from modded that target didn't have, successfully appended via SerializedObjectTable's -insertObjects:... - see the .m's tat_collect_new_object
@property (nonatomic, assign) NSInteger objectsAddedTexture2DHeaderParseFailed; // new-object counterpart to texture2DHeaderParseFailed below
@property (nonatomic, assign) NSInteger objectsAddedTexture2DFormatUnsupported; // new-object counterpart to texture2DFormatUnsupported below
@property (nonatomic, assign) NSInteger objectsAddedPathIDCollision;           // modded's own pathID for a new object already exists in target under a DIFFERENT PathID slot than expected - see .m; refused rather than remapped, since nothing transplanted here can safely rewrite whatever else in target already owns that PathID
@property (nonatomic, assign) NSInteger objectsSkippedWrongType;   // differing PathIDs whose typeID is neither Texture2D nor TextAsset - see this header's "TWO EXCEPTIONS" note and the .m's kTAT2ClassID* constants
@property (nonatomic, assign) NSInteger texture2DHeaderParseFailed; // Texture2D objects where Texture2DFields couldn't confirm its TAT2VersionProfile against either side of the pair - see Texture2DFields.h. Logged per-object; skipped, target left untouched.
@property (nonatomic, assign) NSInteger texture2DFormatUnsupported; // Texture2D objects whose modded m_TextureFormat has no decoder - see Texture2DPixelDecoder.h. Most notably DXT5Crunched (29), which needs a real crunch decompressor this project hasn't vendored in yet. Logged per-object; skipped, target left untouched.
@property (nonatomic, copy, nullable) NSError *error;           // set if this cached bundle failed outright
@end

@interface TextureAtlasTransplant : NSObject

// Library/ZSingularityAtlasBackups inside this app's sandbox - own
// directory, same "not inside the cache itself" reasoning as every
// other Transplant class's backup directory (see BankTransplant.h/
// BundleTransplant.h's own IMPORTANT notes on why).
+ (NSString *)atlasBackupDirectory;

// moddedURL: a complete UnityFS bundle (built with e.g. UABEA - not a
// loose texture/atlas file) whose own CAB (see UnityBundleCAB.h) matches
// one or more cached bundles under
// +[BundleTransplant unityCacheSharedDirectory] - same matching-by-CAB-
// identity that class itself uses for whole-file swaps, reused here
// rather than reimplemented differently. For each match: diffs every
// shared, type-handled PathID's raw object bytes between modded and the
// live cached copy and transplants whichever differ (verbatim for
// TextAsset, decode+re-encode for Texture2D) - see this header's top
// comment for exactly how. Backs up each cached bundle once before
// writing (see +atlasBackupDirectory), same timing/reasoning as every
// other Transplant class's own backup (written before the swap is known
// to succeed - its presence alone isn't proof a real change happened).
//
// Always returns one result per matching cached bundle found (zero
// matches is not an error - it just means no cached copy of this CAB
// exists yet, same as BundleTransplant's own zero-match case) - check
// each result's own .error rather than relying on a single overall BOOL.
// Only NSError** is used for failures that abort before any matching
// even starts (can't read/parse moddedURL at all, or no cache directory
// exists).
+ (nullable NSArray<TextureAtlasTransplantResult *> *)transplantFromModdedBundleAtURL:(NSURL *)moddedURL
                                                                                  error:(NSError **)error;

// Restores every cached bundle under +[BundleTransplant unityCacheSharedDirectory]
// that has a matching backup under +atlasBackupDirectory, overwriting the
// live (possibly object-patched) copy with the untouched backup. Returns
// the number restored, or -1 with error filled on a filesystem-level
// failure. Returns 0 (not an error) if +atlasBackupDirectory doesn't
// exist yet.
+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;

// Same restore as above, narrowed to backups matching one CAB - the
// per-object counterpart to +[BundleTransplant
// restoreBackedUpBundlesForCAB:force:error:], used by the Mods Library's
// per-entry Reset/delete-restore paths (see GraphicsDebugOverlay.m's
// -gd_restoreModEntry:) so removing one tracked mod only reverts the
// cached bundles that mod itself touched, not every atlas backup on
// disk. Matches by reading each backup's own CAB (untouched stock
// bytes, so its CAB is unaffected by whatever object-level patching
// happened to the live copy) - same reasoning as
// BundleTransplant.m's own per-CAB restore. Returns 0 (not an error) if
// +atlasBackupDirectory doesn't exist or nothing matches.
+ (NSInteger)restoreBackedUpBundlesForCAB:(NSString *)cab error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
