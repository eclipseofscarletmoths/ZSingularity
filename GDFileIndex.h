// GDFileIndex.h
//
// 2 - startup-time index of the two folders the mod loader pipeline
// otherwise re-scans from scratch on every single call:
// Library/UnityCache/Shared (see +[UnityCacheLocator
// unityCacheSharedDirectories]) and Documents/Assets/Sound/FMODBuilds/
// Mobile (see +[BankTransplant mobileFMODBuildsDirectory]).
//
// THE PROBLEM THIS SOLVES: +[UnityCacheLocator allBundlePathsForCAB:]
// used to walk every regular file under Library/UnityCache/Shared and
// hand each one to +[UnityBundleCAB primaryCABForBundleAtPath:error:] -
// a real UnityFS header parse, LZ4-decoding the blocks-info blob for
// every candidate - just to see whether that file's own CAB happened to
// match the one being searched for. With thousands of cached files,
// that's thousands of header parses per call, and it ran on every mod
// IMPORT (+[ModAssetLibrary importFileURLs:intoFolder:error:]) and every
// doctor-pipeline INSTALL resolve (BundleDoctorService.m's CAB resolve
// step) - i.e. constantly, for anyone actively managing more than a
// couple of bundle mods in a session. That's the "massive hangs and
// wait times between operations" this class exists to remove.
//
// THE FIX: do that expensive per-file parse pass exactly once - here,
// at startup (see fps120.m) - and cache the result (CAB identifier ->
// matching cached file path(s)) as its own entry ("fileIndex") in the
// same GraphicsDebugOverlaySettings.json every other control in this
// tweak already round-trips through (see GDScripts.h). Every subsystem
// that used to ask UnityCacheLocator to search now gets an answer
// straight out of this cached map instead - see
// +[UnityCacheLocator allBundlePathsForCAB:], the map's only reader.
//
// STAYING CHEAP ON THE COMMON CASE: re-running the expensive parse pass
// on every single launch would just move the hang from "every call" to
// "every startup" - still bad with thousands of files sitting under
// UnityCache/Shared. So +ensureIndexUpToDate does a CHEAP pass first:
// enumerate both folders (stat only, via NSDirectoryEnumerator's own
// resource-key prefetching - no file content is ever read for this
// part) and fingerprint each folder as (file count, total byte size,
// newest modification date). The expensive per-file CAB-parsing pass
// only actually runs for a folder whose fingerprint differs from the
// one saved alongside the last full index; otherwise last time's cached
// map is trusted as-is and just reloaded from the settings JSON. A
// fingerprint collision (a change that happens to net out to the exact
// same three numbers) is the one accepted false negative here -
// vanishingly unlikely for a cache directory that only ever grows or
// gets wholesale-cleared, and no worse than any other coarse
// size/mtime-based cache-invalidation scheme.
//
// The two folders are fingerprinted (and, when needed, re-indexed)
// independently of each other - a change under UnityCache/Shared alone
// doesn't force the FMOD folder's own (much smaller, much cheaper)
// listing to be rebuilt, and vice versa.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GDFileIndex : NSObject

// Call once at startup (fps120.m's dylib constructor, on its own
// background thread - this is pure filesystem work, it needs neither
// Unity's view nor il2cpp_init(), so there's no reason to sit behind
// background_worker's own wait for those). Cheap when nothing's changed
// under either folder since the last time this ran (see this file's
// header) - safe, and intended, to be called unconditionally on every
// launch rather than gated behind any "is this the first launch" check
// of its own.
+ (void)ensureIndexUpToDate;

// Cached equivalent of the old +[UnityCacheLocator
// allBundlePathsForCAB:] live scan - every Library/UnityCache/Shared
// path this index currently has on file for `cab`, newest-modified
// first, filtered to paths that still exist on disk right now (a file
// removed by something else since the index was last built silently
// drops out here rather than being handed back as a dangling match).
// Returns an empty array (not nil) if the index is built but simply has
// no match for this CAB. Returns nil - a distinct case callers must
// check for - if the index hasn't been populated AT ALL this session
// yet (see +hasIndex); UnityCacheLocator.m treats nil as "fall back to
// a live scan," not as "no match."
+ (nullable NSArray<NSString *> *)cachedPathsForCAB:(NSString *)cab;

// Whether +ensureIndexUpToDate has populated an in-memory index this
// session (freshly built, or reloaded as-is from a previous session's
// settings JSON because nothing had changed). What
// +[UnityCacheLocator allBundlePathsForCAB:] gates its "trust the
// cache, don't fall back to a live scan" decision on.
+ (BOOL)hasIndex;

// Every filename found directly under +[BankTransplant
// mobileFMODBuildsDirectory] as of the last index. Not currently
// consumed by BankTransplant itself, which already addresses a bank by
// its known filename directly rather than needing to search for one -
// this exists because the person's own spec for this feature named that
// folder as one of the two to index regardless, for any future
// subsystem that needs to know what's actually present there without a
// filesystem hit of its own.
+ (NSSet<NSString *> *)cachedFMODBankFileNames;

@end

NS_ASSUME_NONNULL_END
