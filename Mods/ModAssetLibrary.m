
#import "ModAssetLibrary.h"
#import "BankTransplant.h"
#import "UnityBundleCAB.h"
#import "UnityCacheLocator.h"
#import "LunartiqueModArchive.h"
#import "ZTweakLog.h"

NSString * const ModAssetLibraryErrorDomain = @"ModAssetLibraryErrorDomain";
static NSString * const kMALManifestFileName = @"manifest.json";
static NSString * const kMALFolderRemarkFileName = @"remark.txt";
static NSString * const kMALOriginalBundleBackupsDirectoryName = @".OriginalBundleBackups";

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
    if (self.resolvedInstallTargetPath) d[@"resolvedInstallTargetPath"] = self.resolvedInstallTargetPath;
    if (self.zipCacheHash1) d[@"zipCacheHash1"] = self.zipCacheHash1;
    if (self.zipCacheHash2) d[@"zipCacheHash2"] = self.zipCacheHash2;
    if (self.remark.length > 0) d[@"remark"] = self.remark;
    if (self.cachedFromFolder.length > 0) d[@"cachedFromFolder"] = self.cachedFromFolder;
    if (self.isAssetBundle) d[@"isAssetBundle"] = @YES;
    if (self.cabIdentifier) d[@"cabIdentifier"] = self.cabIdentifier;
    if (self.targetPlatform) d[@"targetPlatform"] = self.targetPlatform;

    if (self.doctorStatus != ModAssetLibraryDoctorStatusNotDispatched) d[@"doctorStatus"] = @(self.doctorStatus);
    if (self.doctorUploadProgress != 0) d[@"doctorUploadProgress"] = @(self.doctorUploadProgress);
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
    e.resolvedInstallTargetPath = [d[@"resolvedInstallTargetPath"] isKindOfClass:NSString.class] ? d[@"resolvedInstallTargetPath"] : nil;
    e.zipCacheHash1 = [d[@"zipCacheHash1"] isKindOfClass:NSString.class] ? d[@"zipCacheHash1"] : nil;
    e.zipCacheHash2 = [d[@"zipCacheHash2"] isKindOfClass:NSString.class] ? d[@"zipCacheHash2"] : nil;
    e.remark = [d[@"remark"] isKindOfClass:NSString.class] ? d[@"remark"] : nil;
    e.cachedFromFolder = [d[@"cachedFromFolder"] isKindOfClass:NSString.class] ? d[@"cachedFromFolder"] : nil;

    e.isAssetBundle = [d[@"isAssetBundle"] isKindOfClass:NSNumber.class] && [d[@"isAssetBundle"] boolValue];
    e.cabIdentifier = [d[@"cabIdentifier"] isKindOfClass:NSString.class] ? d[@"cabIdentifier"] : nil;
    e.targetPlatform = [d[@"targetPlatform"] isKindOfClass:NSNumber.class] ? d[@"targetPlatform"] : nil;

    id rawStatus = d[@"doctorStatus"];
    NSInteger status = [rawStatus isKindOfClass:NSNumber.class] ? [rawStatus integerValue] : ModAssetLibraryDoctorStatusNotDispatched;
    e.doctorStatus = (status >= ModAssetLibraryDoctorStatusNotDispatched && status <= ModAssetLibraryDoctorStatusInstalled)
        ? (ModAssetLibraryDoctorStatus)status : ModAssetLibraryDoctorStatusNotDispatched;
    e.doctorUploadProgress = [d[@"doctorUploadProgress"] isKindOfClass:NSNumber.class] ? [d[@"doctorUploadProgress"] longLongValue] : 0;
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
+ (NSString *)mal_remarkPathForFolder:(NSString *)folderName;
+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error;
+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath;
+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName;
@end

@implementation ModAssetLibrary

+ (NSString *)liveGamePathDescriptionForInstalledURL:(NSURL *)installedURL {
    return [self mal_sandboxRelativePath:installedURL.path];
}

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

+ (NSString *)mal_remarkPathForFolder:(NSString *)folderName {
    return [[[self modLibraryRootDirectory] stringByAppendingPathComponent:folderName]
                stringByAppendingPathComponent:kMALFolderRemarkFileName];
}

+ (NSString *)originalBundleBackupsDirectory {
    NSString *root = [self modLibraryRootDirectory];
    if (!root) return nil;
    return [root stringByAppendingPathComponent:kMALOriginalBundleBackupsDirectoryName];
}

+ (NSArray<NSString *> *)folderNames {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!root || ![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return @[];

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry isEqualToString:kMALOriginalBundleBackupsDirectoryName]) continue;
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

+ (NSString *)mal_sandboxRelativePath:(NSString *)path {
    NSString *home = NSHomeDirectory();
    if (home && [path hasPrefix:home]) {
        NSString *relative = [path substringFromIndex:home.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return relative;
    }
    return path;
}

+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName {
    if ([fileName.pathExtension caseInsensitiveCompare:@"bank"] != NSOrderedSame) return nil;
    NSString *bankDir = [BankTransplant mobileFMODBuildsDirectory];
    NSString *path = bankDir ? [bankDir stringByAppendingPathComponent:fileName] : fileName;
    return [self mal_libraryRelativePath:path];
}

static NSString *MALCABRejectionLine(NSString *displayName) {
    return [NSString stringWithFormat:@"%@: rejected - its CAB identifier could not be found, meaning it's either malformed or outdated", displayName];
}

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs
             intoFolder:(NSString *)folderName
        rejectedFileLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedFileLines
                  error:(NSError **)error {
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

    NSMutableArray<NSString *> *rejectedLines = [NSMutableArray array];
    NSInteger importedCount = 0;
    for (NSURL *url in moddedURLs) {
        BOOL accessing = [url startAccessingSecurityScopedResource];

        BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:url.path];

        NSString *cabID = nil;
        NSNumber *targetPlatformNumber = nil;
        NSString *resolvedTargetPath = nil;
        if (isBundle) {
            NSError *cabErr = nil;
            cabID = [UnityBundleCAB primaryCABForBundleAtPath:url.path error:&cabErr];
            if (cabID.length == 0) {
                cabID = nil;
                ZLog(@"[ModAssetLibrary] %@ has a UnityFS header but its CAB id couldn't be read (%@) - rejecting.",
                     url.lastPathComponent, cabErr.localizedDescription);
                if (accessing) [url stopAccessingSecurityScopedResource];
                [rejectedLines addObject:MALCABRejectionLine(url.lastPathComponent)];
                continue;
            }
            int32_t platform = 0;
            NSError *platformErr = nil;
            if ([UnityBundleCAB targetPlatform:&platform forBundleAtPath:url.path error:&platformErr]) {
                targetPlatformNumber = @(platform);
            } else {
                ZLog(@"[ModAssetLibrary] couldn't read a target platform for %@: %@",
                     url.lastPathComponent, platformErr.localizedDescription);
            }

            NSError *locateErr = nil;
            NSString *matchPath = [UnityCacheLocator locateBundlePathForCAB:cabID error:&locateErr];
            if (matchPath) {
                resolvedTargetPath = [self mal_sandboxRelativePath:matchPath];
            } else {
                ZLog(@"[ModAssetLibrary] no index match for %@'s CAB (%@) - rejecting: %@",
                     url.lastPathComponent, cabID, locateErr.localizedDescription);
                if (accessing) [url stopAccessingSecurityScopedResource];
                [rejectedLines addObject:MALCABRejectionLine(url.lastPathComponent)];
                continue;
            }
        }

        NSString *destPath = nil;
        NSString *destName = nil;
        if (cabID) {

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

        entry.livePathDescription = [self mal_livePathDescriptionForFileName:destName];
        entry.resolvedInstallTargetPath = resolvedTargetPath;
        [entries addObject:entry];
        importedCount++;
    }

    if (rejectedFileLines) *rejectedFileLines = rejectedLines.count > 0 ? [rejectedLines copy] : nil;

    if (importedCount == 0) {
        if (error) {
            *error = rejectedLines.count > 0
                ? MALError(ModAssetLibraryErrorCABNotIndexed, @"Every file was rejected - see rejectedFileLines for per-file reasons.")
                : MALError(ModAssetLibraryErrorCopyFailed, @"No file(s) could be imported - see syslog for per-file errors.");
        }
        return NO;
    }

    return [self mal_writeEntries:entries toFolder:folderName error:error];
}

+ (BOOL)importLunartiqueZipURL:(NSURL *)zipURL
                    intoFolder:(NSString *)folderName
             rejectedEntryLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedEntryLines
                         error:(NSError **)error {
    NSError *formatErr = nil;
    NSArray<LunartiqueModEntry *> *matches = [LunartiqueModArchive matchedEntriesInZipAtURL:zipURL error:&formatErr];
    if (matches.count == 0) {
        if (error) *error = formatErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Not a Lunartique-format mod zip.");
        return NO;
    }

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

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *now = [iso stringFromDate:[NSDate date]];

    NSMutableArray<NSString *> *rejectedLines = [NSMutableArray array];
    NSInteger importedCount = 0;
    for (LunartiqueModEntry *lmaEntry in matches) {
        NSURL *dataURL = nil, *infoURL = nil;
        NSError *extractErr = nil;
        if (![LunartiqueModArchive extractDataForEntry:lmaEntry fromZipAtURL:zipURL dataURL:&dataURL infoURL:&infoURL error:&extractErr]) {
            ZLog(@"[ModAssetLibrary] couldn't extract %@ from %@: %@", lmaEntry.dataEntryName, zipURL.lastPathComponent, extractErr.localizedDescription);
            continue;
        }

        BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:dataURL.path];
        if (!isBundle) {
            ZLog(@"[ModAssetLibrary] Lunartique entry %@ extracted fine but doesn't look like a UnityFS bundle - rejecting.", lmaEntry.dataEntryName);
            [rejectedLines addObject:MALCABRejectionLine(lmaEntry.dataEntryName)];
            continue;
        }

        NSError *cabErr = nil;
        NSString *cabID = [UnityBundleCAB primaryCABForBundleAtPath:dataURL.path error:&cabErr];
        if (cabID.length == 0) {
            ZLog(@"[ModAssetLibrary] Lunartique entry %@ has a UnityFS header but its CAB id couldn't be read (%@) - rejecting.",
                 lmaEntry.dataEntryName, cabErr.localizedDescription);
            [rejectedLines addObject:MALCABRejectionLine(lmaEntry.dataEntryName)];
            continue;
        }
        int32_t platform = 0;
        NSError *platformErr = nil;
        NSNumber *targetPlatformNumber = nil;
        if ([UnityBundleCAB targetPlatform:&platform forBundleAtPath:dataURL.path error:&platformErr]) {
            targetPlatformNumber = @(platform);
        }

        NSError *locateErr = nil;
        NSString *matchPath = [UnityCacheLocator locateBundlePathForCAB:cabID error:&locateErr];
        if (!matchPath) {
            ZLog(@"[ModAssetLibrary] no index match for Lunartique entry %@'s CAB (%@) - rejecting: %@",
                 lmaEntry.dataEntryName, cabID, locateErr.localizedDescription);
            [rejectedLines addObject:MALCABRejectionLine(lmaEntry.dataEntryName)];
            continue;
        }
        NSString *resolvedTargetPath = [self mal_sandboxRelativePath:matchPath];

        NSString *destPath = nil;
        NSString *destName = nil;

        NSString *subFolderName = [self mal_uniqueFolderNameFor:cabID inParentFolder:folderPath];
        NSString *subFolderPath = [folderPath stringByAppendingPathComponent:subFolderName];
        NSError *mkdirErr = nil;
        if ([fm createDirectoryAtPath:subFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
            destName = @"__data";
            destPath = [subFolderPath stringByAppendingPathComponent:destName];
        } else {
            ZLog(@"[ModAssetLibrary] couldn't create subfolder \"%@\" for Lunartique entry %@: %@ - skipping.",
                 subFolderName, lmaEntry.dataEntryName, mkdirErr.localizedDescription);
            continue;
        }

        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtPath:dataURL.path toPath:destPath error:&copyErr];
        if (!copied) {
            ZLog(@"[ModAssetLibrary] couldn't copy extracted %@ into \"%@\": %@", lmaEntry.dataEntryName, folderName, copyErr.localizedDescription);
            continue;
        }

        if (infoURL) {
            [fm copyItemAtPath:infoURL.path toPath:[subFolderPath stringByAppendingPathComponent:@"__info"] error:nil];
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
        entry.zipCacheHash1 = lmaEntry.cacheHash1;
        entry.zipCacheHash2 = lmaEntry.cacheHash2;
        entry.resolvedInstallTargetPath = resolvedTargetPath;

        entry.livePathDescription = nil;
        [entries addObject:entry];
        importedCount++;
    }

    if (rejectedEntryLines) *rejectedEntryLines = rejectedLines.count > 0 ? [rejectedLines copy] : nil;

    if (importedCount == 0) {
        if (error) {
            *error = rejectedLines.count > 0
                ? MALError(ModAssetLibraryErrorCABNotIndexed, @"Every bundle in the Lunartique zip was rejected - see rejectedEntryLines for per-entry reasons.")
                : MALError(ModAssetLibraryErrorCopyFailed, @"No bundle(s) could be extracted from the Lunartique zip - see syslog for per-entry errors.");
        }
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
    [fm removeItemAtPath:entry.path error:nil];

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

+ (nullable ModAssetLibraryEntry *)moveEntry:(ModAssetLibraryEntry *)entry
                                   fromFolder:(NSString *)fromFolder
                                     toFolder:(NSString *)toFolder
                          replacementBytesURL:(nullable NSURL *)replacementBytesURL
                                        error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *toFolderPath = root ? [root stringByAppendingPathComponent:toFolder] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL toIsDir = NO;
    if (!toFolderPath || ![fm fileExistsAtPath:toFolderPath isDirectory:&toIsDir] || !toIsDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", toFolder]);
        return nil;
    }

    NSError *fromEntriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *fromEntries = [self entriesInFolder:fromFolder error:&fromEntriesErr];
    if (!fromEntries) {
        if (error) *error = fromEntriesErr;
        return nil;
    }
    BOOL foundInSource = NO;
    for (ModAssetLibraryEntry *e in fromEntries) {
        if ([e.path isEqualToString:entry.path]) { foundInSource = YES; break; }
    }
    if (!foundInSource) {
        if (error) *error = MALError(ModAssetLibraryErrorEntryNotFound,
            [NSString stringWithFormat:@"\"%@\" is no longer in \"%@\".", entry.fileName, fromFolder]);
        return nil;
    }

    NSString *destPath = nil;
    NSString *destName = entry.fileName;
    if (entry.isAssetBundle && entry.cabIdentifier.length > 0) {
        NSString *cabFolderName = [self mal_uniqueFolderNameFor:entry.cabIdentifier inParentFolder:toFolderPath];
        NSString *cabFolderPath = [toFolderPath stringByAppendingPathComponent:cabFolderName];
        NSError *mkdirErr = nil;
        if (![fm createDirectoryAtPath:cabFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
            if (error) *error = mkdirErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't create the destination folder.");
            return nil;
        }
        destName = @"__data";
        destPath = [cabFolderPath stringByAppendingPathComponent:destName];
    } else {
        destName = [self mal_uniqueFileNameFor:entry.fileName inFolder:toFolderPath];
        destPath = [toFolderPath stringByAppendingPathComponent:destName];
    }

    NSError *copyErr = nil;
    NSString *sourceForBytes = replacementBytesURL ? replacementBytesURL.path : entry.path;
    BOOL copied = [fm copyItemAtPath:sourceForBytes toPath:destPath error:&copyErr];
    if (!copied) {
        if (error) *error = copyErr ?: MALError(ModAssetLibraryErrorCopyFailed,
            [NSString stringWithFormat:@"Couldn't move \"%@\" into \"%@\".", entry.fileName, toFolder]);
        return nil;
    }

    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

    ModAssetLibraryEntry *movedEntry = [ModAssetLibraryEntry new];
    movedEntry.fileName = destName;
    movedEntry.path = destPath;
    movedEntry.byteSize = attrs.fileSize;
    movedEntry.dateAdded = entry.dateAdded;
    movedEntry.livePathDescription = entry.livePathDescription;
    movedEntry.resolvedInstallTargetPath = entry.resolvedInstallTargetPath;
    movedEntry.remark = entry.remark;
    movedEntry.isAssetBundle = entry.isAssetBundle;
    movedEntry.cabIdentifier = entry.cabIdentifier;
    movedEntry.targetPlatform = entry.targetPlatform;
    movedEntry.cachedFromFolder = entry.cachedFromFolder;
    movedEntry.doctorStatus = entry.doctorStatus;
    movedEntry.doctorUploadProgress = entry.doctorUploadProgress;
    movedEntry.doctorProcessProgress = entry.doctorProcessProgress;
    movedEntry.doctorDownloadProgress = entry.doctorDownloadProgress;
    movedEntry.doctorScratchBranch = entry.doctorScratchBranch;
    movedEntry.doctorRunID = entry.doctorRunID;
    movedEntry.doctorRunURL = entry.doctorRunURL;
    movedEntry.doctorLastError = entry.doctorLastError;

    NSMutableArray<ModAssetLibraryEntry *> *toEntries =
        [([self entriesInFolder:toFolder error:nil] ?: @[]) mutableCopy];
    [toEntries addObject:movedEntry];
    NSError *toWriteErr = nil;
    if (![self mal_writeEntries:toEntries toFolder:toFolder error:&toWriteErr]) {
        [fm removeItemAtPath:destPath error:nil];
        if (error) *error = toWriteErr;
        return nil;
    }

    NSMutableArray<ModAssetLibraryEntry *> *remainingInSource = [NSMutableArray arrayWithCapacity:fromEntries.count];
    for (ModAssetLibraryEntry *e in fromEntries) {
        if (![e.path isEqualToString:entry.path]) [remainingInSource addObject:e];
    }
    [fm removeItemAtPath:entry.path error:nil];
    NSString *fromFolderPath = root ? [root stringByAppendingPathComponent:fromFolder] : nil;
    NSString *entryDir = entry.path.stringByDeletingLastPathComponent;
    if (fromFolderPath && ![entryDir isEqualToString:fromFolderPath]) {
        NSArray<NSString *> *remainingInDir = [fm contentsOfDirectoryAtPath:entryDir error:nil];
        if (remainingInDir.count == 0) [fm removeItemAtPath:entryDir error:nil];
    }
    NSError *fromWriteErr = nil;
    if (![self mal_writeEntries:remainingInSource toFolder:fromFolder error:&fromWriteErr]) {
        ZLog(@"[ModAssetLibrary] moved %@ into \"%@\" but couldn't drop its old row from \"%@\": %@ (file now tracked in both folders' manifests until this is retried)",
             entry.fileName, toFolder, fromFolder, fromWriteErr.localizedDescription);
    }

    return movedEntry;
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

    if ([trimmed isEqualToString:folderName]) return YES;

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

+ (nullable NSString *)remarkForFolder:(NSString *)folderName {
    NSString *path = [self mal_remarkPathForFolder:folderName];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *trimmed = [contents stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

+ (BOOL)setRemark:(nullable NSString *)remark forFolder:(NSString *)folderName error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return NO;
    }

    NSString *trimmed = [remark stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *path = [self mal_remarkPathForFolder:folderName];
    if (trimmed.length == 0) {

        [fm removeItemAtPath:path error:nil];
        return YES;
    }

    NSError *writeErr = nil;
    if (![trimmed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
        if (error) *error = writeErr ?: MALError(ModAssetLibraryErrorManifestWriteFailed, @"Couldn't save the folder's remark.");
        return NO;
    }
    return YES;
}

+ (BOOL)deleteAllFoldersWithError:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!root || ![fm fileExistsAtPath:root]) return YES;

    NSError *removeErr = nil;
    if (![fm removeItemAtPath:root error:&removeErr]) {
        if (error) *error = removeErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            @"Couldn't delete the Mod Asset Library.");
        return NO;
    }
    return YES;
}

@end

