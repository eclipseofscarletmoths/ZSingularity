// ModAssetLibrary.m — see the header for the why/shape.

#import "ModAssetLibrary.h"
#import "BankTransplant.h"
#import "UnityBundleCAB.h" // isUnityFSBundleAtPath: / primaryCABForBundleAtPath:error: - see +importFileURLs:intoFolder:error: below
#import "ZTweakLog.h"

NSString * const ModAssetLibraryErrorDomain = @"ModAssetLibraryErrorDomain";
static NSString * const kMALManifestFileName = @"manifest.json";

static NSError *MALError(ModAssetLibraryErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ModAssetLibraryErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ModAssetLibraryEntry

- (NSDictionary<NSString *, id> *)mal_dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"fileName"] = self.fileName;
    d[@"path"] = self.path;
    d[@"byteSize"] = @(self.byteSize);
    d[@"dateAdded"] = self.dateAdded;
    if (self.livePathDescription) d[@"livePathDescription"] = self.livePathDescription;
    if (self.isAssetBundle) d[@"isAssetBundle"] = @YES; // only written when true, same "stay compact" convention as the doctor-state fields below
    if (self.cabIdentifier) d[@"cabIdentifier"] = self.cabIdentifier;
    if (self.targetPlatform) d[@"targetPlatform"] = self.targetPlatform;

    // Doctor-pipeline state - only written when non-default, so a
    // manifest touched entirely by pre-dispatch-flow code (or an entry
    // that never enters the pipeline, e.g. a .bank) stays exactly as
    // compact as it always was.
    if (self.doctorStatus != ModAssetLibraryDoctorStatusNotDispatched) d[@"doctorStatus"] = @(self.doctorStatus);
    if (self.doctorUploadProgress != 0.0) d[@"doctorUploadProgress"] = @(self.doctorUploadProgress);
    if (self.doctorProcessProgress != 0.0) d[@"doctorProcessProgress"] = @(self.doctorProcessProgress);
    if (self.doctorScratchBranch) d[@"doctorScratchBranch"] = self.doctorScratchBranch;
    if (self.doctorRunID) d[@"doctorRunID"] = self.doctorRunID;
    if (self.doctorRunURL) d[@"doctorRunURL"] = self.doctorRunURL;
    if (self.doctorLastError) d[@"doctorLastError"] = self.doctorLastError;
    return d;
}

+ (nullable instancetype)mal_fromDictionary:(NSDictionary<NSString *, id> *)d {
    if (![d[@"fileName"] isKindOfClass:NSString.class] || ![d[@"path"] isKindOfClass:NSString.class]) return nil;
    ModAssetLibraryEntry *e = [ModAssetLibraryEntry new];
    e.fileName = d[@"fileName"];
    e.path = d[@"path"];
    e.byteSize = [d[@"byteSize"] unsignedLongLongValue];
    e.dateAdded = [d[@"dateAdded"] isKindOfClass:NSString.class] ? d[@"dateAdded"] : @"";
    e.livePathDescription = [d[@"livePathDescription"] isKindOfClass:NSString.class] ? d[@"livePathDescription"] : nil;
    // Absent entirely on any manifest row written before this field
    // existed - defaults to NO, same as a non-bundle entry, which is
    // the safest read for a row this class no longer has a way to
    // re-sniff (the file's own path is still known, but re-opening
    // every entry on every manifest read just to backfill this flag
    // isn't worth it for what's cosmetic-only until the file is
    // re-imported).
    e.isAssetBundle = [d[@"isAssetBundle"] isKindOfClass:NSNumber.class] && [d[@"isAssetBundle"] boolValue];
    e.cabIdentifier = [d[@"cabIdentifier"] isKindOfClass:NSString.class] ? d[@"cabIdentifier"] : nil;
    e.targetPlatform = [d[@"targetPlatform"] isKindOfClass:NSNumber.class] ? d[@"targetPlatform"] : nil;
    // Older manifests may still carry a "cab" key from before CAB
    // matching was retired - just ignored on read, nothing to migrate.

    // Doctor-pipeline state - absent entirely on any manifest row
    // written before this flow existed, which is indistinguishable from
    // (and defaults to) NotDispatched/0/nil, same as a freshly-imported
    // entry that just hasn't been dispatched yet.
    id rawStatus = d[@"doctorStatus"];
    NSInteger status = [rawStatus isKindOfClass:NSNumber.class] ? [rawStatus integerValue] : ModAssetLibraryDoctorStatusNotDispatched;
    e.doctorStatus = (status >= ModAssetLibraryDoctorStatusNotDispatched && status <= ModAssetLibraryDoctorStatusInstalled)
        ? (ModAssetLibraryDoctorStatus)status : ModAssetLibraryDoctorStatusNotDispatched;
    e.doctorUploadProgress = [d[@"doctorUploadProgress"] isKindOfClass:NSNumber.class] ? [d[@"doctorUploadProgress"] doubleValue] : 0.0;
    e.doctorProcessProgress = [d[@"doctorProcessProgress"] isKindOfClass:NSNumber.class] ? [d[@"doctorProcessProgress"] doubleValue] : 0.0;
    e.doctorScratchBranch = [d[@"doctorScratchBranch"] isKindOfClass:NSString.class] ? d[@"doctorScratchBranch"] : nil;
    e.doctorRunID = [d[@"doctorRunID"] isKindOfClass:NSString.class] ? d[@"doctorRunID"] : nil;
    e.doctorRunURL = [d[@"doctorRunURL"] isKindOfClass:NSString.class] ? d[@"doctorRunURL"] : nil;
    e.doctorLastError = [d[@"doctorLastError"] isKindOfClass:NSString.class] ? d[@"doctorLastError"] : nil;
    return e;
}

@end

@interface ModAssetLibrary ()
+ (NSString *)mal_manifestPathForFolder:(NSString *)folderName;
+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error;
+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath;
+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName;
@end

@implementation ModAssetLibrary

+ (NSString *)modLibraryRootDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityModsLibrary"];
}

+ (NSString *)mal_manifestPathForFolder:(NSString *)folderName {
    return [[[self modLibraryRootDirectory] stringByAppendingPathComponent:folderName]
                stringByAppendingPathComponent:kMALManifestFileName];
}

+ (NSArray<NSString *> *)folderNames {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!root || ![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return @[];

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (NSString *entry in entries) {
        NSString *full = [root stringByAppendingPathComponent:entry];
        BOOL entryIsDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&entryIsDir] && entryIsDir) {
            [folders addObject:entry];
        }
    }
    return [folders sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

+ (BOOL)createFolderNamed:(NSString *)name error:(NSError **)error {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed containsString:@"/"]) {
        if (error) *error = MALError(ModAssetLibraryErrorInvalidFolderName,
            @"Folder name can't be empty or contain \"/\".");
        return NO;
    }

    NSString *root = [self modLibraryRootDirectory];
    if (!root) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound, @"Couldn't resolve the mods library directory.");
        return NO;
    }
    NSString *folderPath = [root stringByAppendingPathComponent:trimmed];

    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:folderPath]) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderAlreadyExists,
            [NSString stringWithFormat:@"A folder named \"%@\" already exists.", trimmed]);
        return NO;
    }

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = dirErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't create the folder.");
        return NO;
    }

    // Empty manifest up front, so +entriesInFolder:error: and the
    // "does this folder exist" checks elsewhere never have to
    // distinguish "just created, nothing added yet" from "manifest
    // write never happened".
    NSError *writeErr = nil;
    if (![self mal_writeEntries:@[] toFolder:trimmed error:&writeErr]) {
        if (error) *error = writeErr;
        return NO;
    }
    return YES;
}

+ (nullable NSArray<ModAssetLibraryEntry *> *)entriesInFolder:(NSString *)folderName error:(NSError **)error {
    NSString *manifestPath = [self mal_manifestPathForFolder:folderName];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:manifestPath]) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    NSArray *raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![raw isKindOfClass:NSArray.class]) {
        if (error) *error = MALError(ModAssetLibraryErrorManifestReadFailed,
            [NSString stringWithFormat:@"%@'s manifest.json is missing or unreadable.", folderName]);
        return nil;
    }

    NSMutableArray<ModAssetLibraryEntry *> *entries = [NSMutableArray array];
    for (id d in raw) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        ModAssetLibraryEntry *e = [ModAssetLibraryEntry mal_fromDictionary:d];
        if (e) [entries addObject:e];
    }
    return entries;
}

+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error {
    NSMutableArray<NSDictionary *> *raw = [NSMutableArray arrayWithCapacity:entries.count];
    for (ModAssetLibraryEntry *e in entries) [raw addObject:[e mal_dictionaryRepresentation]];

    NSError *serErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:&serErr];
    if (!data) {
        if (error) *error = serErr ?: MALError(ModAssetLibraryErrorManifestWriteFailed, @"Couldn't serialize manifest.json.");
        return NO;
    }

    NSString *manifestPath = [self mal_manifestPathForFolder:folderName];
    NSError *writeErr = nil;
    if (![data writeToFile:manifestPath options:NSDataWritingAtomic error:&writeErr]) {
        if (error) *error = writeErr ?: MALError(ModAssetLibraryErrorManifestWriteFailed, @"Couldn't write manifest.json.");
        return NO;
    }
    return YES;
}

// "name.ext" -> "name 2.ext", "name 2.ext" -> "name 3.ext", etc. -
// collision-avoidance for two files with the same leaf name imported
// into the same folder (either in one multi-select, or across two
// separate Add Asset runs).
+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *candidate = desired;
    NSString *stem = desired.stringByDeletingPathExtension;
    NSString *ext = desired.pathExtension;
    NSInteger n = 2;
    while ([fm fileExistsAtPath:[folderPath stringByAppendingPathComponent:candidate]]) {
        candidate = ext.length > 0
            ? [NSString stringWithFormat:@"%@ %ld.%@", stem, (long)n, ext]
            : [NSString stringWithFormat:@"%@ %ld", stem, (long)n];
        n++;
    }
    return candidate;
}

// Same idea as +mal_uniqueFileNameFor:inFolder: above, but for a
// directory name under parentPath rather than a file name within one -
// "CAB-xxxx" -> "CAB-xxxx 2" -> "CAB-xxxx 3", etc. Used when a bundle's
// own CAB id is already taken by a previously-imported subfolder (e.g.
// re-importing the exact same bundle into the same mod folder), so the
// new one still gets its own directory rather than colliding with (or
// silently reusing) the existing one.
+ (NSString *)mal_uniqueFolderNameFor:(NSString *)desired inParentFolder:(NSString *)parentPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *candidate = desired;
    NSInteger n = 2;
    while ([fm fileExistsAtPath:[parentPath stringByAppendingPathComponent:candidate]]) {
        candidate = [NSString stringWithFormat:@"%@ %ld", desired, (long)n];
        n++;
    }
    return candidate;
}

// Rewrites an on-disk path under this app's own Library directory into
// one starting at "Library/..." instead of the full sandbox path
// ("/var/mobile/Containers/Data/Application/<UUID>/Library/...").
// Falls through to +mal_sandboxRelativePath: for everything else (most
// bank paths - they live under the game's own bundle/Documents tree via
// +[BankTransplant mobileFMODBuildsDirectory], not this tweak's Library
// folder), which does the same rewrite rooted at the app's own
// NSHomeDirectory() instead, so those come back as e.g.
// "Documents/Assets/Sound/FMODBuilds/Mobile/music.bank" rather than the
// full "/var/mobile/Containers/Data/Application/<UUID>/..." path.
// (Previously this fell back to just path.lastPathComponent in that
// case, which is why a bank's Info dropdown used to show only its
// filename with no path at all - that was the bug, not a deliberate
// simplification. Then it fell back to the untouched absolute path,
// which is the /var/mobile/... the person is now asking to drop too.)
+ (NSString *)mal_libraryRelativePath:(NSString *)path {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (libraryDir && [path hasPrefix:libraryDir]) {
        NSString *relative = [path substringFromIndex:libraryDir.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return [@"Library/" stringByAppendingString:relative];
    }
    return [self mal_sandboxRelativePath:path];
}

// Same idea as +mal_libraryRelativePath: above, but rooted at the app's
// sandbox home (NSHomeDirectory()) rather than just its Library
// subdirectory - this is what turns a bank's full
// "/var/mobile/Containers/Data/Application/<UUID>/Documents/Assets/..."
// path into "Documents/Assets/..." (the game's own NSDirectory tree),
// since the tweak runs in-process and NSHomeDirectory() here already IS
// the game's own sandbox home - no separate container lookup needed.
// Returns `path` unchanged if it doesn't live under the sandbox home at
// all (shouldn't normally happen for anything this tweak tracks, but
// better than silently returning an empty string).
+ (NSString *)mal_sandboxRelativePath:(NSString *)path {
    NSString *home = NSHomeDirectory();
    if (home && [path hasPrefix:home]) {
        NSString *relative = [path substringFromIndex:home.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return relative;
    }
    return path;
}

// Only a .bank file has a deterministic destination this class can
// still name - CAB-based bundle matching (BundleTransplant/
// UnityBundleCAB) is gone, so anything else just reads back nil rather
// than guessing.
+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName {
    if ([fileName.pathExtension caseInsensitiveCompare:@"bank"] != NSOrderedSame) return nil;
    NSString *bankDir = [BankTransplant mobileFMODBuildsDirectory];
    NSString *path = bankDir ? [bankDir stringByAppendingPathComponent:fileName] : fileName;
    return [self mal_libraryRelativePath:path];
}

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs intoFolder:(NSString *)folderName error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = [root stringByAppendingPathComponent:folderName];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!root || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return NO;
    }

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *now = [iso stringFromDate:[NSDate date]];

    NSInteger importedCount = 0;
    for (NSURL *url in moddedURLs) {
        BOOL accessing = [url startAccessingSecurityScopedResource];

        // Identified by the file's own header bytes, not its name/
        // extension - see +[UnityBundleCAB isUnityFSBundleAtPath:]'s own
        // header comment for why a name-based check (what this used to
        // be) is unreliable here.
        BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:url.path];

        // Resolved once, up front, for any detected bundle - used below
        // both to pick the CAB-named subfolder (when available) and to
        // populate the entry's own cabIdentifier/targetPlatform either
        // way, even on the flat-placement fallback path.
        NSString *cabID = nil;
        NSNumber *targetPlatformNumber = nil;
        if (isBundle) {
            NSError *cabErr = nil;
            cabID = [UnityBundleCAB primaryCABForBundleAtPath:url.path error:&cabErr];
            if (cabID.length == 0) {
                cabID = nil;
                ZLog(@"[ModAssetLibrary] %@ has a UnityFS header but its CAB id couldn't be read (%@).",
                     url.lastPathComponent, cabErr.localizedDescription);
            }
            int32_t platform = 0;
            NSError *platformErr = nil;
            if ([UnityBundleCAB targetPlatform:&platform forBundleAtPath:url.path error:&platformErr]) {
                targetPlatformNumber = @(platform);
            } else {
                ZLog(@"[ModAssetLibrary] couldn't read a target platform for %@: %@",
                     url.lastPathComponent, platformErr.localizedDescription);
            }
        }

        NSString *destPath = nil;
        NSString *destName = nil;
        if (cabID) {
            // Two bundles can't both be named "__data" in one flat
            // folder - Unity's own loader requires that exact literal
            // name, so (unlike an ordinary collision) it can't just be
            // renamed away. Give each bundle its own subfolder, named
            // after its own CAB id, instead: folderName/<CAB id>/__data.
            NSString *cabFolderName = [self mal_uniqueFolderNameFor:cabID inParentFolder:folderPath];
            NSString *cabFolderPath = [folderPath stringByAppendingPathComponent:cabFolderName];
            NSError *mkdirErr = nil;
            if ([fm createDirectoryAtPath:cabFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
                destName = @"__data";
                destPath = [cabFolderPath stringByAppendingPathComponent:destName];
            } else {
                ZLog(@"[ModAssetLibrary] couldn't create CAB subfolder \"%@\" for %@: %@ - importing flat instead.",
                     cabFolderName, url.lastPathComponent, mkdirErr.localizedDescription);
            }
        }
        if (!destPath) {
            destName = [self mal_uniqueFileNameFor:url.lastPathComponent inFolder:folderPath];
            destPath = [folderPath stringByAppendingPathComponent:destName];
        }

        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtPath:url.path toPath:destPath error:&copyErr];
        if (accessing) [url stopAccessingSecurityScopedResource];
        if (!copied) {
            ZLog(@"[ModAssetLibrary] couldn't copy %@ into \"%@\": %@", url.lastPathComponent, folderName, copyErr.localizedDescription);
            continue;
        }

        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

        ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
        entry.fileName = destName;
        entry.path = destPath;
        entry.byteSize = attrs.fileSize;
        entry.dateAdded = now;
        entry.isAssetBundle = isBundle;
        entry.cabIdentifier = cabID;
        entry.targetPlatform = targetPlatformNumber;
        // Resolved here, once, and never again - see ModAssetLibrary.h's
        // own comment on livePathDescription.
        entry.livePathDescription = [self mal_livePathDescriptionForFileName:destName];
        [entries addObject:entry];
        importedCount++;
    }

    if (importedCount == 0) {
        if (error) *error = MALError(ModAssetLibraryErrorCopyFailed, @"No file(s) could be imported - see syslog for per-file errors.");
        return NO;
    }

    return [self mal_writeEntries:entries toFolder:folderName error:error];
}

+ (BOOL)removeEntry:(ModAssetLibraryEntry *)entry fromFolder:(NSString *)folderName error:(NSError **)error {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *current = [self entriesInFolder:folderName error:&entriesErr];
    if (!current) {
        if (error) *error = entriesErr;
        return NO;
    }

    NSMutableArray<ModAssetLibraryEntry *> *remaining = [NSMutableArray arrayWithCapacity:current.count];
    for (ModAssetLibraryEntry *e in current) {
        if (![e.path isEqualToString:entry.path]) [remaining addObject:e];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:entry.path error:nil]; // best-effort - manifest is the source of truth for the UI either way

    // Bundle-kind entries live in their own CAB-named subfolder (see
    // +importFileURLs:intoFolder:error:) - clean that up too once it's
    // empty, so removing the entry doesn't leave a stray empty
    // CAB-<hash> directory behind. Not gated on entry.isAssetBundle:
    // just checking "is this directory (still) empty" is simpler than
    // threading that flag through, and is a no-op for a flat entry
    // whose parent is folderPath itself (never removed here).
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSString *entryDir = entry.path.stringByDeletingLastPathComponent;
    if (folderPath && ![entryDir isEqualToString:folderPath]) {
        NSArray<NSString *> *remainingInDir = [fm contentsOfDirectoryAtPath:entryDir error:nil];
        if (remainingInDir.count == 0) {
            [fm removeItemAtPath:entryDir error:nil];
        }
    }

    return [self mal_writeEntries:remaining toFolder:folderName error:error];
}

+ (nullable ModAssetLibraryEntry *)updateDoctorStateForEntry:(ModAssetLibraryEntry *)entry
                                                      inFolder:(NSString *)folderName
                                                    applyBlock:(void (NS_NOESCAPE ^)(ModAssetLibraryEntry *entryToMutate))applyBlock
                                                         error:(NSError **)error {
    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *current =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];
    if (!current) {
        if (error) *error = entriesErr;
        return nil;
    }

    ModAssetLibraryEntry *match = nil;
    for (ModAssetLibraryEntry *e in current) {
        if ([e.path isEqualToString:entry.path]) { match = e; break; }
    }
    if (!match) {
        if (error) *error = MALError(ModAssetLibraryErrorEntryNotFound,
            [NSString stringWithFormat:@"\"%@\" is no longer in the mods library.", entry.fileName]);
        return nil;
    }

    if (applyBlock) applyBlock(match);

    NSError *writeErr = nil;
    if (![self mal_writeEntries:current toFolder:folderName error:&writeErr]) {
        if (error) *error = writeErr;
        return nil;
    }
    return match;
}

+ (BOOL)deleteFolderNamed:(NSString *)folderName error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return NO;
    }

    NSError *removeErr = nil;
    if (![fm removeItemAtPath:folderPath error:&removeErr]) {
        if (error) *error = removeErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            [NSString stringWithFormat:@"Couldn't delete \"%@\".", folderName]);
        return NO;
    }
    return YES;
}

+ (BOOL)renameFolderNamed:(NSString *)folderName to:(NSString *)newName error:(NSError **)error {
    NSString *trimmed = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed containsString:@"/"]) {
        if (error) *error = MALError(ModAssetLibraryErrorInvalidFolderName,
            @"Folder name can't be empty or contain \"/\".");
        return NO;
    }

    NSString *root = [self modLibraryRootDirectory];
    NSString *oldPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!oldPath || ![fm fileExistsAtPath:oldPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return NO;
    }

    if ([trimmed isEqualToString:folderName]) return YES; // no-op rename

    NSString *newPath = [root stringByAppendingPathComponent:trimmed];
    if ([fm fileExistsAtPath:newPath]) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderAlreadyExists,
            [NSString stringWithFormat:@"A folder named \"%@\" already exists.", trimmed]);
        return NO;
    }

    NSError *moveErr = nil;
    if (![fm moveItemAtPath:oldPath toPath:newPath error:&moveErr]) {
        if (error) *error = moveErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            [NSString stringWithFormat:@"Couldn't rename \"%@\".", folderName]);
        return NO;
    }
    return YES;
}

+ (BOOL)deleteAllFoldersWithError:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!root || ![fm fileExistsAtPath:root]) return YES; // already-clean is success

    NSError *removeErr = nil;
    if (![fm removeItemAtPath:root error:&removeErr]) {
        if (error) *error = removeErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            @"Couldn't delete the Mod Asset Library.");
        return NO;
    }
    return YES;
}

@end
