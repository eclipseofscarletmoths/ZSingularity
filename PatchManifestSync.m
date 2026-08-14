// PatchManifestSync.m — see PatchManifestSync.h for the why.

#import "PatchManifestSync.h"
#import "IL2CppBridge.h"
#import "ZTweakLog.h"

NSString * const PatchManifestSyncErrorDomain = @"PatchManifestSyncErrorDomain";

// Cached across calls, same reasoning as GDScripts.m's g_classCache/
// g_methodCache: class/method lookups are stable for the process
// lifetime once resolved, and this can plausibly be called more than
// once per session (a swap, then later a restore).
static void *g_configClass;
static void *g_infoManagerClass;
static const void *g_configGetInstance;
static const void *g_configGetEncryptKey;
static const void *g_configGetEncryptIV;
static const void *g_generatePatchInfoFileFmod;

static NSError *PMSError(PatchManifestSyncErrorCode code, NSString *message) {
    return [NSError errorWithDomain:PatchManifestSyncErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}


static NSString * const kPMSCacheTargetPath = @"Assets/Sound/FMODBuilds/Mobile/BGM_Default_S7_3.assets.bank";
static NSString * const kPMSPatchedMD5 = @"fbe98ef9f57aff80c58ada46c4f8af92";
static const unsigned long long kPMSPatchedSize = 57408616ULL;
static dispatch_once_t g_manifestTrackerOnce;

static NSString *PMSManifestCacheRoot(void) {
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (library.length == 0) return nil;
    return [library stringByAppendingPathComponent:@"Caches/com.ProjectMoon.LimbusCompany/fsCachedData"];
}

static BOOL PMSIsManifest(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return NO;
    if (![json[@"Version"] isKindOfClass:[NSString class]]) return NO;
    NSDictionary *files = json[@"Files"];
    return [files isKindOfClass:[NSDictionary class]] && [files[kPMSCacheTargetPath] isKindOfClass:[NSDictionary class]];
}

static BOOL PMSPatchFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data || data.length == 0 || data.length > (2 * 1024 * 1024)) return NO;

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    if (!PMSIsManifest(object)) return NO;

    NSMutableDictionary *root = (NSMutableDictionary *)object;
    NSMutableDictionary *files = [root[@"Files"] mutableCopy];
    NSMutableDictionary *entry = [files[kPMSCacheTargetPath] mutableCopy];
    if (!entry) return NO;

    NSString *oldHash = [entry[@"Hash"] isKindOfClass:[NSString class]] ? entry[@"Hash"] : nil;
    NSNumber *oldSize = [entry[@"Size"] isKindOfClass:[NSNumber class]] ? entry[@"Size"] : nil;
    if ([oldHash isEqualToString:kPMSPatchedMD5] && oldSize.unsignedLongLongValue == kPMSPatchedSize) return NO;

    entry[@"Hash"] = kPMSPatchedMD5;
    entry[@"Size"] = @(kPMSPatchedSize);
    files[kPMSCacheTargetPath] = entry;
    root[@"Files"] = files;

    NSData *patched = [NSJSONSerialization dataWithJSONObject:root options:0 error:&jsonError];
    if (!patched) {
        ZLog(@"[PatchManifestSync] manifest serialization failed for %@: %@", path, jsonError);
        return NO;
    }

    NSString *tmp = [path stringByAppendingFormat:@".zsingularity.%@.tmp", NSUUID.UUID.UUIDString];
    if (![patched writeToFile:tmp options:NSDataWritingAtomic error:&jsonError]) {
        ZLog(@"[PatchManifestSync] manifest temp write failed for %@: %@", path, jsonError);
        return NO;
    }

    BOOL replaced = [[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:path]
                                                        withItemAtURL:[NSURL fileURLWithPath:tmp]
                                                       backupItemName:nil
                                                              options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                                     resultingItemURL:NULL
                                                                error:&jsonError];
    if (!replaced) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        ZLog(@"[PatchManifestSync] manifest replacement failed for %@: %@", path, jsonError);
        return NO;
    }

    ZLog(@"[PatchManifestSync] patched FMOD manifest %@: %@/%llu -> %@/%llu",
         path, oldHash ?: @"<missing>", oldSize.unsignedLongLongValue, kPMSPatchedMD5, kPMSPatchedSize);
    return YES;
}

static void PMSScanManifestCache(void) {
    NSString *root = PMSManifestCacheRoot();
    if (root.length == 0) return;
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) return;

    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:root];
    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        @autoreleasepool {
            NSString *path = [root stringByAppendingPathComponent:relative];
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || isDir) { continue; }
            (void)PMSPatchFile(path);
        }
    }
}

@implementation PatchManifestSync

+ (void)load {
    [self startManifestTracker];
}

+ (BOOL)resyncFmodPatchManifestWithError:(NSError **)error {
    if (![IL2CppBridge resolveSymbols]) {
        if (error) *error = PMSError(PatchManifestSyncErrorBridgeUnavailable,
            @"IL2CppBridge couldn't resolve libil2cpp symbols - can't reach TextAssetPatch at all on this build.");
        return NO;
    }

    // --- Resolve classes (cached) ---
    if (!g_configClass) {
        g_configClass = [IL2CppBridge classNamed:"TextAssetPatchConfig"
                                       inNamespace:"TextAssetPatch"
                                  assemblyContains:"Assembly-CSharp"];
    }
    if (!g_infoManagerClass) {
        g_infoManagerClass = [IL2CppBridge classNamed:"TextAssetPatchInfoManager"
                                            inNamespace:"TextAssetPatch"
                                       assemblyContains:"Assembly-CSharp"];
    }
    if (!g_configClass || !g_infoManagerClass) {
        if (error) *error = PMSError(PatchManifestSyncErrorClassNotFound,
            @"TextAssetPatch.TextAssetPatchConfig or TextAssetPatchInfoManager wasn't found in Assembly-CSharp. "
             "Either this game version renamed/moved them, or this build doesn't ship this slice of TextAssetPatch "
             "- check ZLog Verbose output; IL2CppBridge logs symbol-resolution failures separately from this.");
        return NO;
    }

    // --- Resolve methods (cached) ---
    if (!g_configGetInstance) {
        g_configGetInstance = [IL2CppBridge methodOnClass:g_configClass name:"get_Instance" argCount:0];
    }
    if (!g_configGetEncryptKey) {
        g_configGetEncryptKey = [IL2CppBridge methodOnClass:g_configClass name:"get_EncryptKey" argCount:0];
    }
    if (!g_configGetEncryptIV) {
        g_configGetEncryptIV = [IL2CppBridge methodOnClass:g_configClass name:"get_EncryptIV" argCount:0];
    }
    if (!g_generatePatchInfoFileFmod) {
        g_generatePatchInfoFileFmod = [IL2CppBridge methodOnClass:g_infoManagerClass
                                                               name:"GeneratePatchInfoFileFmod"
                                                           argCount:2];
    }
    if (!g_configGetInstance || !g_configGetEncryptKey || !g_configGetEncryptIV || !g_generatePatchInfoFileFmod) {
        if (error) *error = PMSError(PatchManifestSyncErrorMethodNotFound,
            @"One of get_Instance/get_EncryptKey/get_EncryptIV/GeneratePatchInfoFileFmod wasn't found by name+argcount "
             "on an otherwise-resolved class. A game update likely changed a signature this relies on.");
        return NO;
    }

    // --- TextAssetPatchConfig.Instance ---
    void *exc = NULL;
    void *configInstance = [IL2CppBridge invokeMethod:g_configGetInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !configInstance) {
        if (error) *error = PMSError(PatchManifestSyncErrorConfigInstanceUnavailable,
            @"TextAssetPatchConfig.Instance returned null. Likely called before TextAssetPatch's own boot-time init "
             "ran - retry once the game is actually at the main menu (BankTransplant's Mods-panel entry point "
             "already implies this in practice, since the panel isn't reachable any earlier).");
        return NO;
    }

    // --- EncryptKey / EncryptIV ---
    // These come back as live IL2CPP System.String* objects. They're
    // passed straight back into GeneratePatchInfoFileFmod below as-is -
    // no need to round-trip through NSString, which also sidesteps
    // needing an NSString->IL2CPP-String conversion helper that
    // IL2CppBridge doesn't currently expose (only the reverse exists).
    void *encryptKeyStr = [IL2CppBridge invokeMethod:g_configGetEncryptKey onInstance:configInstance args:NULL outException:&exc];
    if (exc) {
        if (error) *error = PMSError(PatchManifestSyncErrorKeyOrIVUnavailable, @"TextAssetPatchConfig.EncryptKey getter threw.");
        return NO;
    }
    void *encryptIVStr = [IL2CppBridge invokeMethod:g_configGetEncryptIV onInstance:configInstance args:NULL outException:&exc];
    if (exc) {
        if (error) *error = PMSError(PatchManifestSyncErrorKeyOrIVUnavailable, @"TextAssetPatchConfig.EncryptIV getter threw.");
        return NO;
    }
    if (!encryptKeyStr || !encryptIVStr) {
        if (error) *error = PMSError(PatchManifestSyncErrorKeyOrIVUnavailable,
            @"TextAssetPatchConfig.EncryptKey/EncryptIV read back null - config instance exists but isn't fully populated yet.");
        return NO;
    }

    // --- GeneratePatchInfoFileFmod(encryptKey, encryptIV) ---
    // Static method - onInstance:NULL. Per IL2CppBridge.h's args
    // convention, reference-type params go into the args slot as the
    // object pointer itself (see GDScripts.m's GetComponent(Type) call
    // for the same pattern with a Type object), not a pointer-to-pointer.
    //
    // UNVERIFIED (see PatchManifestSync.h's header comment in full):
    // this is presumed to be a build-time tool method never previously
    // exercised at runtime in a live player. exc being set here is the
    // expected failure signature if that presumption is wrong and it
    // has an editor-only dependency - IL2CppBridge already ZLogs the
    // exception itself (see invokeMethod:onInstance:args:outException:),
    // so nothing extra is logged here beyond this call's own outcome.
    void *args[2] = { encryptKeyStr, encryptIVStr };
    [IL2CppBridge invokeMethod:g_generatePatchInfoFileFmod onInstance:NULL args:args outException:&exc];
    if (exc) {
        if (error) *error = PMSError(PatchManifestSyncErrorGenerateCallFailed,
            @"TextAssetPatchInfoManager.GeneratePatchInfoFileFmod threw an IL2CPP exception. Check ZLog Verbose "
             "output for IL2CppBridge's own exception log line. If this is consistently reproducible, this method "
             "likely isn't safely callable outside the Unity Editor on this game version, and this whole approach "
             "needs to fall back to something else (see PatchManifestSync.h's header notes on the alternatives this "
             "was chosen over).");
        return NO;
    }

    ZLog(@"[PatchManifestSync] resynced local FMOD patch manifest against current on-disk state");
    return YES;
}

+ (void)startManifestTracker {
    dispatch_once(&g_manifestTrackerOnce, ^{
        ZLog(@"[PatchManifestSync] starting FMOD manifest cache tracker");
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        if (!timer) return;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ PMSScanManifestCache(); });
        dispatch_resume(timer);
        static dispatch_source_t retainedTimer;
        retainedTimer = timer;
    });
}

+ (BOOL)resyncFmodPatchManifestWithError:(NSError **)error {
    // TODO: POC stub - implement actual manifest resync
    return YES;
}

@end
