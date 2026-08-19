// ModAssetLibrary.m — see the header for the why/shape.

#import "ModAssetLibrary.h"
#import "BankTransplant.h"
#import "ZTweakLog.h"

NSString * const ModAssetLibraryErrorDomain = @"ModAssetLibraryErrorDomain";
static NSString * const kMALManifestFileName = @"manifest.json";

// First bytes of a UnityFS-container asset bundle. Not a real parse -
// just enough of a sniff to tell "this is probably a Unity bundle" from
// "this definitely isn't", now that UnityBundleCAB.h (the real parser)
// is gone. See ModAssetLibrary.h's top comment.
static NSString * const kMALUnityFSMagic = @"UnityFS";

static NSError *MALError(ModAssetLibraryErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ModAssetLibraryErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ModAssetLibraryEntry

- (NSDictionary<NSString *, id> *)mal_dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"fileName"] = self.fileName;
    d[@"kind"] = @(self.kind);
    d[@"path"] = self.path;
    d[@"byteSize"] = @(self.byteSize);
    d[@"dateAdded"] = self.dateAdded;
    if (self.installedStockBundlePath) d[@"installedStockBundlePath"] = self.installedStockBundlePath;
    d[@"doctored"] = @(self.doctored);
    d[@"livePathDescription"] = self.livePathDescription;
    return d;
}

+ (nullable instancetype)mal_fromDictionary:(NSDictionary<NSString *, id> *)d {
    if (![d[@"fileName"] isKindOfClass:NSString.class] || ![d[@"path"] isKindOfClass:NSString.class]) return nil;
    ModAssetLibraryEntry *e = [ModAssetLibraryEntry new];
    e.fileName = d[@"fileName"];
    e.kind = [d[@"kind"] isKindOfClass:NSNumber.class] ? [d[@"kind"] integerValue] : ModAssetLibraryEntryKindUnknown;
    e.path = d[@"path"];
    e.byteSize = [d[@"byteSize"] unsignedLongLongValue];
    e.dateAdded = [d[@"dateAdded"] isKindOfClass:NSString.class] ? d[@"dateAdded"] : @"";
    e.installedStockBundlePath = [d[@"installedStockBundlePath"] isKindOfClass:NSString.class] ? d[@"installedStockBundlePath"] : nil;
    e.doctored = [d[@"doctored"] boolValue];
    e.livePathDescription = [d[@"livePathDescription"] isKindOfClass:NSString.class]
        ? d[@"livePathDescription"]
        : [ModAssetLibrary mal_livePathDescriptionForKind:e.kind fileName:e.fileName installedStockBundlePath:e.installedStockBundlePath];
    return e;
}

@end

@interface ModAssetLibrary ()
+ (NSString *)mal_manifestPathForFolder:(NSString *)folderName;
+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error;
+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath;
+ (ModAssetLibraryEntryKind)mal_kindForFileAtPath:(NSString *)path;
+ (NSString *)mal_libraryRelativePath:(NSString *)path;
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

+ (BOOL)ensureFolderNamed:(NSString *)name error:(NSError **)error {
    NSError *createErr = nil;
    if ([self createFolderNamed:name error:&createErr]) return YES;
    if (createErr.domain == ModAssetLibraryErrorDomain && createErr.code == ModAssetLibraryErrorFolderAlreadyExists) {
        return YES;
    }
    if (error) *error = createErr;
    return NO;
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
// separate import calls).
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

// See this header's top comment - a sniff, not a parse. ".bank" by
// extension is trusted outright (same "not a registered UTI, go by
// extension" convention -importModTapped already uses in
// GraphicsDebugOverlay.m); anything else gets a 7-byte read to check for
// the UnityFS magic. A read failure (unreadable/too-short file) just
// falls through to Unknown rather than raising - this is bookkeeping,
// not validation.
+ (ModAssetLibraryEntryKind)mal_kindForFileAtPath:(NSString *)path {
    if ([path.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
        return ModAssetLibraryEntryKindBank;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return ModAssetLibraryEntryKindUnknown;
    NSData *head = [handle readDataOfLength:kMALUnityFSMagic.length];
    [handle closeFile];
    if (head.length != kMALUnityFSMagic.length) return ModAssetLibraryEntryKindUnknown;

    NSString *headString = [[NSString alloc] initWithData:head encoding:NSASCIIStringEncoding];
    if ([headString isEqualToString:kMALUnityFSMagic]) return ModAssetLibraryEntryKindBundle;
    return ModAssetLibraryEntryKindUnknown;
}

// Rewrites an on-disk path under this app's own Library directory into
// one starting at "Library/..." instead of the full sandbox path
// ("/var/mobile/Containers/Data/Application/<UUID>/Library/..."). Falls
// through to +mal_sandboxRelativePath: for everything else (bank paths -
// they live under the game's own Documents tree via
// +[BankTransplant mobileFMODBuildsDirectory], not this tweak's Library
// folder; likewise a bundle-kind entry's installedStockBundlePath, which
// can point anywhere the person picked it from).
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
// path into "Documents/Assets/..." (the game's own directory tree),
// since the tweak runs in-process and NSHomeDirectory() here already IS
// the game's own sandbox home - no separate container lookup needed.
// Returns `path` unchanged if it doesn't live under the sandbox home at
// all - which for a bundle-kind entry's installedStockBundlePath is
// expected whenever the person picked a stock bundle from outside this
// app's own sandbox (e.g. a Files-app bookmark into a shared container),
// not a bug to work around.
+ (NSString *)mal_sandboxRelativePath:(NSString *)path {
    NSString *home = NSHomeDirectory();
    if (home && [path hasPrefix:home]) {
        NSString *relative = [path substringFromIndex:home.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return relative;
    }
    return path;
}

+ (NSString *)mal_livePathDescriptionForKind:(ModAssetLibraryEntryKind)kind
                                     fileName:(NSString *)fileName
                     installedStockBundlePath:(nullable NSString *)installedStockBundlePath {
    switch (kind) {
        case ModAssetLibraryEntryKindBank: {
            NSString *bankDir = [BankTransplant mobileFMODBuildsDirectory];
            NSString *path = bankDir ? [bankDir stringByAppendingPathComponent:fileName] : fileName;
            return [self mal_libraryRelativePath:path];
        }
        case ModAssetLibraryEntryKindBundle: {
            if (installedStockBundlePath.length == 0) return @"Not installed yet.";
            return [self mal_libraryRelativePath:installedStockBundlePath];
        }
        case ModAssetLibraryEntryKindUnknown:
        default:
            return @"Unrecognized file type - no restore action available.";
    }
}

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs intoFolder:(NSString *)folderName error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return NO;
    }

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];

    NSInteger importedCount = 0;
    for (NSURL *url in moddedURLs) {
        BOOL accessing = [url startAccessingSecurityScopedResource];
        NSString *destName = [self mal_uniqueFileNameFor:url.lastPathComponent inFolder:folderPath];
        NSString *destPath = [folderPath stringByAppendingPathComponent:destName];

        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtPath:url.path toPath:destPath error:&copyErr];
        if (accessing) [url stopAccessingSecurityScopedResource];
        if (!copied) {
            ZLog(@"[ModAssetLibrary] couldn't copy %@ into \"%@\": %@", url.lastPathComponent, folderName, copyErr.localizedDescription);
            continue;
        }

        [entries addObject:[self mal_entryForNewlyCopiedFileAtPath:destPath fileName:destName doctored:NO]];
        importedCount++;
    }

    if (importedCount == 0) {
        if (error) *error = MALError(ModAssetLibraryErrorCopyFailed, @"No file(s) could be imported - see syslog for per-file errors.");
        return NO;
    }

    return [self mal_writeEntries:entries toFolder:folderName error:error];
}

+ (nullable ModAssetLibraryEntry *)importLocalFileAtPath:(NSString *)localPath
                                                intoFolder:(NSString *)folderName
                                                 doctored:(BOOL)doctored
                                                     error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return nil;
    }

    NSString *destName = [self mal_uniqueFileNameFor:localPath.lastPathComponent inFolder:folderPath];
    NSString *destPath = [folderPath stringByAppendingPathComponent:destName];

    NSError *copyErr = nil;
    if (![fm copyItemAtPath:localPath toPath:destPath error:&copyErr]) {
        if (error) *error = copyErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't copy the file into the library.");
        return nil;
    }

    ModAssetLibraryEntry *entry = [self mal_entryForNewlyCopiedFileAtPath:destPath fileName:destName doctored:doctored];

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];
    [entries addObject:entry];

    NSError *writeErr = nil;
    if (![self mal_writeEntries:entries toFolder:folderName error:&writeErr]) {
        if (error) *error = writeErr;
        return nil;
    }
    return entry;
}

+ (ModAssetLibraryEntry *)mal_entryForNewlyCopiedFileAtPath:(NSString *)destPath
                                                     fileName:(NSString *)destName
                                                     doctored:(BOOL)doctored {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];
    ModAssetLibraryEntryKind kind = [self mal_kindForFileAtPath:destPath];

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];

    ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
    entry.fileName = destName;
    entry.kind = kind;
    entry.path = destPath;
    entry.byteSize = attrs.fileSize;
    entry.dateAdded = [iso stringFromDate:[NSDate date]];
    entry.doctored = (kind == ModAssetLibraryEntryKindBundle) && doctored;
    // Resolved here, once - see ModAssetLibrary.h's own comment on
    // livePathDescription. No installedStockBundlePath yet for a
    // freshly-imported bundle-kind entry, so this starts out as
    // "Not installed yet." until a caller reports a real install via
    // +recordInstalledStockBundlePath:forEntry:inFolder:error:.
    entry.livePathDescription = [self mal_livePathDescriptionForKind:kind fileName:destName installedStockBundlePath:nil];
    return entry;
}

+ (BOOL)recordInstalledStockBundlePath:(NSString *)stockBundlePath
                              forEntry:(ModAssetLibraryEntry *)entry
                              inFolder:(NSString *)folderName
                                 error:(NSError **)error {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *current = [self entriesInFolder:folderName error:&entriesErr];
    if (!current) {
        if (error) *error = entriesErr;
        return NO;
    }

    BOOL found = NO;
    for (ModAssetLibraryEntry *e in current) {
        if (![e.path isEqualToString:entry.path]) continue;
        found = YES;
        e.installedStockBundlePath = stockBundlePath;
        e.doctored = YES; // only ever recorded after a successful BundleDoctorInstaller swap
        e.livePathDescription = [self mal_livePathDescriptionForKind:e.kind fileName:e.fileName installedStockBundlePath:stockBundlePath];
        break;
    }

    if (!found) {
        if (error) *error = MALError(ModAssetLibraryErrorEntryNotFound,
            [NSString stringWithFormat:@"No entry matching \"%@\" in \"%@\".", entry.fileName, folderName]);
        return NO;
    }

    return [self mal_writeEntries:current toFolder:folderName error:error];
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

    [NSFileManager.defaultManager removeItemAtPath:entry.path error:nil]; // best-effort - manifest is the source of truth for the UI either way
    return [self mal_writeEntries:remaining toFolder:folderName error:error];
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

@end
