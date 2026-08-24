// LunartiqueModArchive.h
//
// Detects and reads the "Lunartique format" mod zip - the popular PC
// modding container this project's sample (Middle finger Tang mod.zip)
// is shaped like: a Windows-oriented Installer.bat/Uninstaller.bat pair
// plus a mirrored Assets/Installation/<hash1>/<hash2>/{__data,__info}
// and Assets/Uninstallation/<hash1>/<hash2>/{__data,__info} tree, where
// <hash1>/<hash2> mirrors the two-level bucket Unity's own Caching
// subsystem uses under Library/UnityCache/Shared on-device (see
// UnityCacheLocator.h). This class only cares about the Installation
// side - the actual mod payload; Uninstallation exists in the zip for
// the desktop .bat workflow this class doesn't drive at all.
//
// MATCH SEMANTICS (what "roughly matches the sample zip's file tree"
// means, per the person's own spec): the zip is accepted as Lunartique
// format if, anywhere inside it, there's a path shaped like
// ".../Installation/<32 lowercase hex chars>/<32 lowercase hex chars>/__data"
// with a sibling "__info" right next to it. Nothing else about the
// zip's contents is checked - an installer/uninstaller .bat pair and a
// READ ME.txt are common in the wild but not required, since the only
// thing this project's pipeline actually consumes is that one nested
// __data payload.
//
// WHAT THIS DOES NOT DO: this does not validate __data as a UnityFS
// bundle - that's UnityBundleCAB's job, run separately once the file's
// been extracted (see +[ModAssetLibrary importLunartiqueZipURL:
// intoFolder:error:]). This class is purely "is this zip shaped like a
// Lunartique mod, and if so, hand me its Installation-side hash pair
// and the raw bytes of __data/__info."
//
// ZIP SUPPORT: minimal, from-scratch (Central Directory + Local File
// Header parsing per the standard .ZIP format), same "write it
// ourselves rather than pull in a dependency" spirit as this project's
// own LZ4BlockDecoder.h. Supports the two storage methods actually seen
// in the wild for this kind of archive: method 0 (stored, no
// compression) and method 8 (deflate) - deflate is decoded via Apple's
// Compression framework (COMPRESSION_ZLIB, which implements raw DEFLATE
// per RFC 1951, the exact framing a .zip entry's compressed bytes use -
// no zlib/gzip wrapper to strip). ZIP64 (>4GB archives/entries) is not
// supported - not a realistic size for this kind of mod. Only entries
// actually requested by name are decompressed; nothing is unzipped in
// bulk.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const LunartiqueModArchiveErrorDomain;

typedef NS_ENUM(NSInteger, LunartiqueModArchiveErrorCode) {
    LunartiqueModArchiveErrorCantReadFile = 1,
    LunartiqueModArchiveErrorNotAZip,                // no valid End Of Central Directory record found
    LunartiqueModArchiveErrorNoMatchingTree,          // parsed fine as a zip, but no Installation/<hex32>/<hex32>/__data(+__info) entry found - see this file's header for the exact shape required
    LunartiqueModArchiveErrorUnsupportedCompression,  // a matching entry exists but uses a compression method other than stored(0)/deflate(8)
    LunartiqueModArchiveErrorCorruptEntry,            // local header/CRC mismatch, or deflate decode failed
    LunartiqueModArchiveErrorExtractionFailed,        // decoded fine but couldn't be written to the destination URL
};

// One matched Installation-side bundle inside a Lunartique-format zip.
// hash1/hash2 are exactly the two path components between "Installation/"
// and "__data" - the folder names AS WRITTEN IN THE ZIP, lowercased and
// otherwise untouched. Nothing here has been validated as a real UnityFS
// bundle yet; see +[ModAssetLibrary importLunartiqueZipURL:intoFolder:
// error:] for the caller that does that after extraction.
@interface LunartiqueModEntry : NSObject
@property (nonatomic, copy, readonly) NSString *cacheHash1;      // e.g. "cf961c90a478b28d385caa3aa3088748"
@property (nonatomic, copy, readonly) NSString *cacheHash2;      // e.g. "f03ee158701c7ca8726c98762493e4be"
@property (nonatomic, copy, readonly) NSString *dataEntryName;   // the zip's own internal path to __data, for logging
@property (nonatomic, copy, readonly, nullable) NSString *infoEntryName; // nil if this particular match had no sibling __info (still accepted - see this file's header)
@end

@interface LunartiqueModArchive : NSObject

// Cheap-ish structural check: does zipURL parse as a real zip AND
// contain at least one Installation/<hex32>/<hex32>/__data entry? Does
// NOT extract or decompress anything - only reads the Central Directory
// (a small blob at the end of the archive) and checks entry NAMES. This
// is what the Load Mods picker's zip-acceptance gate should call before
// ever touching +matchedEntriesInZipAtURL:error: or extraction.
+ (BOOL)isLunartiqueFormatZipAtURL:(NSURL *)zipURL error:(NSError * _Nullable * _Nullable)error;

// Every Installation/<hex32>/<hex32>/__data match found in the zip's
// Central Directory, in archive order. Empty (not nil) + a
// LunartiqueModArchiveErrorNoMatchingTree error if the zip parses but
// has no such entry. This project's own sample only ever has one, but a
// multi-bundle Lunartique pack isn't ruled out structurally, so callers
// (see +[ModAssetLibrary importLunartiqueZipURL:intoFolder:error:])
// import every match rather than assuming exactly one.
+ (nullable NSArray<LunartiqueModEntry *> *)matchedEntriesInZipAtURL:(NSURL *)zipURL error:(NSError **)error;

// Decompresses one matched entry's __data (and, if entry.infoEntryName
// is non-nil, its sibling __info) out to fresh temp files and returns
// their URLs. The caller owns both temp files - not cleaned up by this
// class. infoURL is set to nil (not an error) when entry.infoEntryName
// was nil to begin with.
+ (BOOL)extractDataForEntry:(LunartiqueModEntry *)entry
                   fromZipAtURL:(NSURL *)zipURL
                        dataURL:(NSURL * _Nullable * _Nonnull)outDataURL
                        infoURL:(NSURL * _Nullable * _Nonnull)outInfoURL
                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
