
#import "ZSScripts.h"
#import "IL2CppBridge.h"
#import "ZTweakLog.h"

#pragma mark - Generic IL2CPP class/field/type/method caches

static NSMutableDictionary<NSString *, NSValue *> *g_classCache;
static NSMutableDictionary<NSString *, NSValue *> *g_fieldOffsetCache;
static NSMutableDictionary<NSString *, NSValue *> *g_typeObjCache;
static NSMutableDictionary<NSString *, NSValue *> *g_methodCache;

static void *zs_class(const char *ns, const char *name, const char *assemblySubstring) {
    if (!g_classCache) g_classCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%s.%s@%s", ns, name, assemblySubstring];
    NSValue *cached = g_classCache[key];
    if (cached) return cached.pointerValue;

    void *klass = [IL2CppBridge classNamed:name inNamespace:ns assemblyContains:assemblySubstring];
    if (klass) g_classCache[key] = [NSValue valueWithPointer:klass];
    return klass;
}

static int32_t zs_offset(void *klass, const char *fieldName) {
    if (!klass) return -1;
    if (!g_fieldOffsetCache) g_fieldOffsetCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p.%s", klass, fieldName];
    NSValue *cached = g_fieldOffsetCache[key];
    if (cached) return (int32_t)(intptr_t)cached.pointerValue;

    int32_t off = [IL2CppBridge fieldOffsetOnClass:klass name:fieldName];
    g_fieldOffsetCache[key] = [NSValue valueWithPointer:(void *)(intptr_t)off];
    return off;
}

static void *zs_type_object(void *klass) {
    if (!klass) return NULL;
    if (!g_typeObjCache) g_typeObjCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p", klass];
    NSValue *cached = g_typeObjCache[key];
    if (cached) return cached.pointerValue;

    void *typeObj = [IL2CppBridge reflectionTypeForClass:klass];
    if (typeObj) g_typeObjCache[key] = [NSValue valueWithPointer:typeObj];
    return typeObj;
}

static const void *zs_method(void *klass, const char *name, int argCount) {
    if (!klass) return NULL;
    if (!g_methodCache) g_methodCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p.%s/%d", klass, name, argCount];
    NSValue *cached = g_methodCache[key];
    if (cached) return cached.pointerValue;

    const void *method = [IL2CppBridge methodOnClass:klass name:name argCount:argCount];
    if (method) g_methodCache[key] = [NSValue valueWithPointer:(void *)method];
    return method;
}

#pragma mark - GlobalGameManager / urpAsset (render scale + extended settings)

static void *zs_get_global_game_manager_instance(void) {
    void *klass = zs_class("", "GlobalGameManager", "Assembly-CSharp");
    if (!klass) return NULL;
    const void *getInstance = zs_method(klass, "get_Instance", 0);
    if (!getInstance) return NULL;
    void *exc = NULL;
    void *instance = [IL2CppBridge invokeMethod:getInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !instance) return NULL;
    return instance;
}

static void *zs_get_urp_asset(void) {
    void *manager = zs_get_global_game_manager_instance();
    if (!manager) return NULL;
    void *klass = zs_class("", "GlobalGameManager", "Assembly-CSharp");
    int32_t off = zs_offset(klass, "urpAsset");
    if (off < 0) return NULL;
    return *(void **)((uint8_t *)manager + off);
}

static void *zs_urp_asset_class(void) {
    return zs_class("UnityEngine.Rendering.Universal", "UniversalRenderPipelineAsset", "Universal.Runtime");
}

void zs_set_render_scale(float scale) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), "set_renderScale", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &scale };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void zs_urp_set_bool(const char *setterName, BOOL value) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void zs_urp_set_int(const char *setterName, int32_t value) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void zs_urp_set_float(const char *setterName, float value) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

int32_t zs_step_value(const int32_t *steps, int count, float sliderValue) {
    int idx = (int)roundf(sliderValue);
    if (idx < 0) idx = 0;
    if (idx >= count) idx = count - 1;
    return steps[idx];
}

const int32_t kMSAASteps[4] = { 1, 2, 4, 8 };

#pragma mark - QualitySettings (texture mip limit)

void zs_set_texture_mip_limit(int32_t mipLimit) {
    void *klass = zs_class("UnityEngine", "QualitySettings", "CoreModule");
    const void *setter = zs_method(klass, "set_globalTextureMipmapLimit", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &mipLimit };
    [IL2CppBridge invokeMethod:setter onInstance:NULL args:args outException:&exc];
}

#pragma mark - Volume system (shared by Post FX)

static void *g_volumeManagerInstance;
static void *g_volumeStackInstance;
static int g_vmTicksSinceRefresh = 999;

static void *zs_get_volume_stack(void) {
    void *vmClass = zs_class("UnityEngine.Rendering", "VolumeManager", "Core.Runtime");
    if (!vmClass) return NULL;

    BOOL needsRefresh = (!g_volumeStackInstance || g_vmTicksSinceRefresh >= 8);
    if (!needsRefresh) {
        g_vmTicksSinceRefresh++;
        return g_volumeStackInstance;
    }

    const void *getInstance = zs_method(vmClass, "get_instance", 0);
    if (!getInstance) return NULL;
    void *exc = NULL;
    void *vmInstance = [IL2CppBridge invokeMethod:getInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !vmInstance) return NULL;
    g_volumeManagerInstance = vmInstance;

    const void *getStack = zs_method(vmClass, "get_stack", 0);
    if (!getStack) return NULL;
    exc = NULL;
    void *stack = [IL2CppBridge invokeMethod:getStack onInstance:vmInstance args:NULL outException:&exc];
    if (exc || !stack) return NULL;

    g_volumeStackInstance = stack;
    g_vmTicksSinceRefresh = 0;
    return stack;
}

static void *zs_get_volume_component_ns(NSString *namespaze, NSString *assemblySubstring, const char *componentClassName) {
    void *stack = zs_get_volume_stack();
    if (!stack) return NULL;

    void *componentClass = zs_class(namespaze.UTF8String, componentClassName, assemblySubstring.UTF8String);
    if (!componentClass) return NULL;
    void *typeObj = zs_type_object(componentClass);
    if (!typeObj) return NULL;

    void *stackClass = [IL2CppBridge classOfInstance:stack];
    const void *getComponent = zs_method(stackClass, "GetComponent", 1);
    if (!getComponent) return NULL;

    void *exc = NULL;
    void *args[1] = { typeObj };
    void *component = [IL2CppBridge invokeMethod:getComponent onInstance:stack args:args outException:&exc];
    if (exc) return NULL;
    return component;
}

static void *zs_get_volume_component(const char *componentClassName) {
    return zs_get_volume_component_ns(@"UnityEngine.Rendering.Universal", @"Universal.Runtime", componentClassName);
}

static void zs_set_component_active(void *component, BOOL active) {
    if (!component) return;
    void *klass = [IL2CppBridge classOfInstance:component];
    int32_t off = zs_offset(klass, "active");
    if (off < 0) return;
    *(BOOL *)((uint8_t *)component + off) = active;
}

static void *zs_get_param_object(void *component, const char *paramFieldName) {
    if (!component) return NULL;
    void *componentClass = [IL2CppBridge classOfInstance:component];
    int32_t off = zs_offset(componentClass, paramFieldName);
    if (off < 0) return NULL;
    return *(void **)((uint8_t *)component + off);
}

static void zs_set_param_float(void *paramObj, float value) {
    if (!paramObj) return;
    void *klass = [IL2CppBridge classOfInstance:paramObj];
    int32_t off = zs_offset(klass, "m_Value");
    if (off < 0) return;
    *(float *)((uint8_t *)paramObj + off) = value;
}

static void zs_set_param_int(void *paramObj, int32_t value) {
    if (!paramObj) return;
    void *klass = [IL2CppBridge classOfInstance:paramObj];
    int32_t off = zs_offset(klass, "m_Value");
    if (off < 0) return;
    *(int32_t *)((uint8_t *)paramObj + off) = value;
}

void zs_apply_motion_blur(void) {
    void *blur = zs_get_volume_component("MotionBlur");
    if (!blur) return;
    zs_set_component_active(blur, YES);
    zs_set_param_float(zs_get_param_object(blur, "intensity"), g_blurIntensity);
}

#pragma mark - Renderer features (feature-level toggles, distinct from Volume components)

static int32_t zs_unbox_int32(void *boxed) {
    if (!boxed) return 0;
    void *klass = [IL2CppBridge classOfInstance:boxed];
    int32_t off = zs_offset(klass, "m_value");
    if (off < 0) return 0;
    return *(int32_t *)((uint8_t *)boxed + off);
}

static void *zs_get_scriptable_renderer(void) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return NULL;
    const void *getter = zs_method(zs_urp_asset_class(), "get_scriptableRenderer", 0);
    if (!getter) return NULL;
    void *exc = NULL;
    void *renderer = [IL2CppBridge invokeMethod:getter onInstance:urpAsset args:NULL outException:&exc];
    if (exc || !renderer) return NULL;
    return renderer;
}

static void *zs_get_renderer_features_list(void) {
    void *renderer = zs_get_scriptable_renderer();
    if (!renderer) return NULL;
    void *rendererClass = [IL2CppBridge classOfInstance:renderer];
    const void *getter = zs_method(rendererClass, "get_rendererFeatures", 0);
    if (!getter) return NULL;
    void *exc = NULL;
    void *list = [IL2CppBridge invokeMethod:getter onInstance:renderer args:NULL outException:&exc];
    if (exc || !list) return NULL;
    return list;
}

static void *zs_find_renderer_feature(NSString *namespaze, NSString *assemblySubstring, NSArray<NSString *> *candidateNames) {
    void *list = zs_get_renderer_features_list();
    if (!list) return NULL;
    void *listClass = [IL2CppBridge classOfInstance:list];
    const void *getCount = zs_method(listClass, "get_Count", 0);
    const void *getItem = zs_method(listClass, "get_Item", 1);
    if (!getCount || !getItem) return NULL;

    void *exc = NULL;
    void *countBoxed = [IL2CppBridge invokeMethod:getCount onInstance:list args:NULL outException:&exc];
    if (exc) return NULL;
    int32_t count = zs_unbox_int32(countBoxed);

    NSMutableArray<NSValue *> *candidateKlasses = [NSMutableArray new];
    for (NSString *name in candidateNames) {
        void *klass = zs_class(namespaze.UTF8String, name.UTF8String, assemblySubstring.UTF8String);
        if (klass) [candidateKlasses addObject:[NSValue valueWithPointer:klass]];
    }
    if (candidateKlasses.count == 0) return NULL;

    for (int32_t i = 0; i < count; i++) {
        int32_t idx = i;
        void *args[1] = { &idx };
        exc = NULL;
        void *item = [IL2CppBridge invokeMethod:getItem onInstance:list args:args outException:&exc];
        if (exc || !item) continue;
        void *itemKlass = [IL2CppBridge classOfInstance:item];
        for (NSValue *v in candidateKlasses) {
            if (v.pointerValue == itemKlass) return item;
        }
    }
    return NULL;
}

static void zs_set_feature_active(void *feature, BOOL active) {
    if (!feature) return;
    void *klass = [IL2CppBridge classOfInstance:feature];
    const void *setter = zs_method(klass, "SetActive", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &active };
    [IL2CppBridge invokeMethod:setter onInstance:feature args:args outException:&exc];
}

#pragma mark - Extended native URP Post FX

const ZSVolumeEffectDef kURPPostEffects[] = {
    { "Chroma",            "ChromaticAberration", "intensity",   0.0f,   1.0f,   0.0f },
    { "Vignette",          "Vignette",            "intensity",   0.0f,   1.0f,   0.3f },
    { "Film Grain",        "FilmGrain",           "intensity",   0.0f,   1.0f,   0.3f },
    { "Lens Distort",      "LensDistortion",      "intensity",  -1.0f,   1.0f,   0.0f },
    { "White Balance",     "WhiteBalance",        "temperature", -100.0f, 100.0f, 0.0f },
    { "Saturation",        "ColorAdjustments",    "saturation", -100.0f, 100.0f, 0.0f },

};
const int kURPPostEffectCount = sizeof(kURPPostEffects) / sizeof(kURPPostEffects[0]);

NSMutableDictionary<NSString *, NSNumber *> *g_urpActive;
NSMutableDictionary<NSString *, NSNumber *> *g_urpValue;

static const ZSVolumeEffectDef *zs_urp_def_named(NSString *name) {
    for (int i = 0; i < kURPPostEffectCount; i++) {
        if ([name isEqualToString:[NSString stringWithUTF8String:kURPPostEffects[i].name]]) return &kURPPostEffects[i];
    }
    return NULL;
}

void zs_apply_urp_post_effect(NSString *name) {
    const ZSVolumeEffectDef *def = zs_urp_def_named(name);
    if (!def) return;
    BOOL active = g_urpActive[name].boolValue;

    void *component = zs_get_volume_component(def->engineName);
    if (component) {
        zs_set_component_active(component, active);
        if (def->floatField) {
            NSNumber *val = g_urpValue[name];
            float fv = val ? val.floatValue : def->defaultV;
            zs_set_param_float(zs_get_param_object(component, def->floatField), fv);
        }
    }
    NSString *rendererName = [NSString stringWithFormat:@"%sRenderer", def->engineName];
    void *feature = zs_find_renderer_feature(@"UnityEngine.Rendering.Universal", @"Universal.Runtime", @[rendererName]);
    zs_set_feature_active(feature, active);
}

int32_t g_tonemapMode = 0;

void zs_apply_tonemapping(void) {
    void *component = zs_get_volume_component("Tonemapping");
    if (!component) return;
    zs_set_component_active(component, YES);
    zs_set_param_int(zs_get_param_object(component, "mode"), g_tonemapMode);
}

#pragma mark - Camera-level post settings (antialiasing / dithering)

static void *zs_get_main_camera(void) {
    void *klass = zs_class("UnityEngine", "Camera", "CoreModule");
    if (!klass) return NULL;
    const void *getMain = zs_method(klass, "get_main", 0);
    if (!getMain) return NULL;
    void *exc = NULL;
    void *cam = [IL2CppBridge invokeMethod:getMain onInstance:NULL args:NULL outException:&exc];
    if (exc || !cam) return NULL;
    return cam;
}

static void *zs_get_camera_data(void) {
    void *cam = zs_get_main_camera();
    if (!cam) return NULL;
    void *camKlass = [IL2CppBridge classOfInstance:cam];
    void *dataKlass = zs_class("UnityEngine.Rendering.Universal", "UniversalAdditionalCameraData", "Universal.Runtime");
    if (!dataKlass) return NULL;
    void *typeObj = zs_type_object(dataKlass);
    if (!typeObj) return NULL;
    const void *getComponent = zs_method(camKlass, "GetComponent", 1);
    if (!getComponent) return NULL;
    void *exc = NULL;
    void *args[1] = { typeObj };
    void *data = [IL2CppBridge invokeMethod:getComponent onInstance:cam args:args outException:&exc];
    if (exc) return NULL;
    return data;
}

void zs_camera_data_set_int(const char *setterName, int32_t value) {
    void *data = zs_get_camera_data();
    if (!data) return;
    void *klass = [IL2CppBridge classOfInstance:data];
    const void *setter = zs_method(klass, setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:data args:args outException:&exc];
}

void zs_camera_data_set_bool(const char *setterName, BOOL value) {
    void *data = zs_get_camera_data();
    if (!data) return;
    void *klass = [IL2CppBridge classOfInstance:data];
    const void *setter = zs_method(klass, setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:data args:args outException:&exc];
}

const int32_t kAAModeSteps[4]    = { 0, 1, 2, 3 };
const int32_t kAAQualitySteps[3] = { 0, 1, 2 };

#pragma mark - Hardcoded setting defaults

const NSInteger kDefaultMenuFPS          = 60;
const NSInteger kDefaultCombatFPS        = 60;
const int32_t   kDefaultTextureMipEngine = 0;
const float     kDefaultRenderScalePct   = 100.0f;
const int32_t   kDefaultMSAAIndex        = 0;
const BOOL      kDefaultHDR              = YES;
const float     kDefaultMotionBlur       = 0.0f;
const int32_t   kDefaultTonemapIndex     = 0;
const int32_t   kDefaultAAModeIndex      = 0;
const int32_t   kDefaultAAQualityIndex   = 1;
const BOOL      kDefaultDithering        = NO;

#pragma mark - Current-value globals

int32_t   g_textureMip     = 0;
float     g_renderScale    = 1.0f;
int32_t   g_msaaIndex      = 0;
BOOL      g_hdrOn          = YES;
float     g_blurIntensity  = 0.0f;
int32_t   g_aaModeIndex    = 0;
int32_t   g_aaQualityIndex = 1;
BOOL      g_ditheringOn    = NO;
NSInteger g_menuFPS        = 60;
NSInteger g_combatFPS      = 60;
NSArray<NSString *> *g_syslogBlacklist = nil;
NSMutableArray<NSString *> *g_trackedAssetPaths = nil;
NSDictionary *g_fileIndexSnapshot = nil;

#pragma mark - Settings persistence (JSON in Documents)

static NSString *zs_settings_file_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"UserInterfaceSettings.json"];
}

NSDictionary *zs_load_settings_dictionary(void) {
    NSString *path = zs_settings_file_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[ZSScripts] failed to parse settings JSON: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

void zs_write_settings_dictionary(NSDictionary *dict) {
    NSString *path = zs_settings_file_path();
    if (!path) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (error || !data) {
        ZLog(@"[ZSScripts] failed to encode settings JSON: %@", error);
        return;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[ZSScripts] failed to write settings JSON: %@", writeError);
    }
}

#pragma mark - Tracked asset paths (Hard Assets Reset)

static void zs_ensure_tracked_asset_paths_loaded(void) {
    if (g_trackedAssetPaths) return;
    NSDictionary *saved = zs_load_settings_dictionary();
    NSArray *savedPaths = [saved[@"trackedAssetPaths"] isKindOfClass:[NSArray class]] ? saved[@"trackedAssetPaths"] : nil;
    g_trackedAssetPaths = [NSMutableArray new];
    for (id path in savedPaths) {
        if ([path isKindOfClass:[NSString class]]) [g_trackedAssetPaths addObject:path];
    }
}

void zs_track_asset_path(NSString *path) {
    if (path.length == 0) return;
    zs_ensure_tracked_asset_paths_loaded();
    if ([g_trackedAssetPaths containsObject:path]) return;
    [g_trackedAssetPaths addObject:path];

    zs_write_settings_dictionary(zs_current_settings_dictionary());
}

NSArray<NSString *> *zs_tracked_asset_paths(void) {
    zs_ensure_tracked_asset_paths_loaded();
    return [g_trackedAssetPaths copy];
}

void zs_clear_tracked_asset_paths(void) {
    zs_ensure_tracked_asset_paths_loaded();
    [g_trackedAssetPaths removeAllObjects];
    zs_write_settings_dictionary(zs_current_settings_dictionary());
}

#pragma mark - File index (Mod Loader Pipeline caching)

static void zs_ensure_file_index_snapshot_loaded_impl(void) {
    if (g_fileIndexSnapshot) return;
    NSDictionary *saved = zs_load_settings_dictionary();
    NSDictionary *savedIndex = [saved[@"fileIndex"] isKindOfClass:[NSDictionary class]] ? saved[@"fileIndex"] : nil;

    g_fileIndexSnapshot = savedIndex ?: @{};
}

void zs_ensure_file_index_snapshot_loaded(void) {
    zs_ensure_file_index_snapshot_loaded_impl();
}

void zs_set_file_index_snapshot(NSDictionary *snapshot) {
    g_fileIndexSnapshot = snapshot ?: @{};
    zs_write_settings_dictionary(zs_current_settings_dictionary());
}

NSDictionary *zs_current_settings_dictionary(void) {

    zs_ensure_tracked_asset_paths_loaded();
    zs_ensure_file_index_snapshot_loaded_impl();

    NSMutableDictionary *urp = [NSMutableDictionary new];
    for (int i = 0; i < kURPPostEffectCount; i++) {
        if (!kURPPostEffects[i].floatField) continue;
        NSString *name = [NSString stringWithUTF8String:kURPPostEffects[i].name];
        NSNumber *v = g_urpValue[name];
        if (v) urp[name] = v;
    }
    return @{
        @"menuFPS": @(g_menuFPS),
        @"combatFPS": @(g_combatFPS),
        @"textureMip": @(g_textureMip),
        @"renderScalePercent": @(roundf(g_renderScale * 100.0f)),
        @"msaaIndex": @(g_msaaIndex),
        @"hdr": @(g_hdrOn),
        @"motionBlur": @(g_blurIntensity),
        @"tonemapIndex": @(g_tonemapMode),
        @"urpEffects": urp,
        @"aaModeIndex": @(g_aaModeIndex),
        @"aaQualityIndex": @(g_aaQualityIndex),
        @"dithering": @(g_ditheringOn),
        @"syslogBlacklist": g_syslogBlacklist ?: @[],
        @"trackedAssetPaths": g_trackedAssetPaths ?: @[],
        @"fileIndex": g_fileIndexSnapshot ?: @{},
    };
}

#pragma mark - FPS120Controller

static BOOL zs_set_application_target_fps(int32_t fps) {
    void *klass = zs_class("UnityEngine", "Application", "CoreModule");
    const void *setter = zs_method(klass, "set_targetFrameRate", 1);
    if (!setter) return NO;
    void *exc = NULL;
    void *args[1] = { &fps };
    [IL2CppBridge invokeMethod:setter onInstance:NULL args:args outException:&exc];
    return (exc == NULL);
}

static const int32_t kSceneStateBattle = 1;

static void *g_cachedGameManagerInstance;
static int g_ticksSinceInstanceRefresh;
static const int kInstanceRefreshTicks = 8;

static int g_ticksSinceLoadCheck;
static const int kLoadCheckThrottleTicks = 2;

static void *zs_get_cached_game_manager_instance(void) {
    BOOL needsRefresh = (!g_cachedGameManagerInstance || g_ticksSinceInstanceRefresh >= kInstanceRefreshTicks);
    if (needsRefresh) {
        void *instance = zs_get_global_game_manager_instance();
        if (!instance) {
            g_cachedGameManagerInstance = NULL;
            return NULL;
        }
        g_cachedGameManagerInstance = instance;
        g_ticksSinceInstanceRefresh = 0;
    } else {
        g_ticksSinceInstanceRefresh++;
    }
    return g_cachedGameManagerInstance;
}

static BOOL zs_try_read_is_in_battle(BOOL *outIsBattle) {
    void *klass = zs_class("", "GlobalGameManager", "Assembly-CSharp");
    if (!klass) return NO;
    void *instance = zs_get_cached_game_manager_instance();
    if (!instance) return NO;

    int32_t off = zs_offset(klass, "sceneState");
    if (off < 0) return NO;
    int32_t sceneState = *(int32_t *)((uint8_t *)instance + off);
    *outIsBattle = (sceneState == kSceneStateBattle);
    return YES;
}

static BOOL zs_try_read_is_loading_screen_present(BOOL *outIsLoading) {
    void *objectKlass  = zs_class("UnityEngine", "Object", "CoreModule");
    void *loadingKlass = zs_class("", "LoadingSceneManager", "Assembly-CSharp");
    if (!objectKlass || !loadingKlass) return NO;

    const void *findMethod = zs_method(objectKlass, "FindObjectOfType", 2);
    if (!findMethod) return NO;

    void *typeObj = zs_type_object(loadingKlass);
    if (!typeObj) return NO;

    BOOL includeInactive = YES;
    void *exc = NULL;
    void *args[2] = { typeObj, &includeInactive };
    void *result = [IL2CppBridge invokeMethod:findMethod onInstance:NULL args:args outException:&exc];
    if (exc) {
        static BOOL loggedOnce = NO;
        if (!loggedOnce) {
            ZLog(@"[ZSScripts] FindObjectOfType(LoadingSceneManager, true) threw - loading-screen presence detection is not working, falling back to battle-exit heuristic only");
            loggedOnce = YES;
        }
        return NO;
    }

    *outIsLoading = (result != NULL);
    return YES;
}

#pragma mark - Scene-loaded event hook (replaces the LoadingSceneManager poll)

static BOOL g_sceneLoadedHookInstalled = NO;

static void zs_on_scene_loaded_trampoline(void) {
    ZLog(@"[ZSScripts] SceneManager.sceneLoaded fired - reapplying settings");
    zs_reapply_all_settings();
}

static void zs_install_scene_loaded_hook(void) {
    void *sceneManagerClass = zs_class("UnityEngine.SceneManagement", "SceneManager", "CoreModule");
    if (!sceneManagerClass) return;

    const void *addSceneLoaded = zs_method(sceneManagerClass, "add_sceneLoaded", 1);
    if (!addSceneLoaded) return;

    const void *paramType = [IL2CppBridge paramTypeForMethod:addSceneLoaded index:0];
    void *delegateClass = paramType ? [IL2CppBridge classFromType:paramType] : NULL;
    if (!delegateClass) return;

    const void *ctor = [IL2CppBridge methodOnClass:delegateClass name:".ctor" argCount:2];
    if (!ctor) return;

    void *delegateInstance = [IL2CppBridge newObjectForClass:delegateClass];
    if (!delegateInstance) return;

    void *methodPtr = (void *)&zs_on_scene_loaded_trampoline;
    void *ctorExc = NULL;
    void *ctorArgs[2] = { NULL, &methodPtr };
    [IL2CppBridge invokeMethod:ctor onInstance:delegateInstance args:ctorArgs outException:&ctorExc];
    if (ctorExc) {
        ZLog(@"[ZSScripts] scene-loaded delegate construction threw - falling back to polling");
        return;
    }

    void *addExc = NULL;
    void *addArgs[1] = { delegateInstance };
    [IL2CppBridge invokeMethod:addSceneLoaded onInstance:NULL args:addArgs outException:&addExc];
    if (addExc) {
        ZLog(@"[ZSScripts] SceneManager.add_sceneLoaded threw - falling back to polling");
        return;
    }

    g_sceneLoadedHookInstalled = YES;
    ZLog(@"[ZSScripts] scene-loaded event hook installed - loading-screen poll disabled");
}

@interface FPS120Controller ()
@property (nonatomic, strong) NSTimer *battleStatePollTimer;

@property (nonatomic, assign) BOOL wasLoading;
@end

@implementation FPS120Controller

+ (instancetype)shared {
    static FPS120Controller *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [FPS120Controller new];
        instance.menuFPS = 120;
        instance.combatFPS = 60;
        instance.targetFPS = instance.menuFPS;
    });
    return instance;
}

- (BOOL)start {
    if (!self.battleStatePollTimer) {
        zs_install_scene_loaded_hook();

        self.battleStatePollTimer = [NSTimer timerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(battleStatePoll)
                                                            userInfo:nil
                                                             repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.battleStatePollTimer forMode:NSRunLoopCommonModes];
    }
    return zs_set_application_target_fps((int32_t)self.targetFPS);
}

- (void)battleStatePoll {
    BOOL isBattle = NO;
    BOOL haveBattleState = zs_try_read_is_in_battle(&isBattle);
    BOOL wasInBattle = self.isInBattle;
    if (haveBattleState) self.isInBattle = isBattle;

    if (!g_sceneLoadedHookInstalled) {
        BOOL shouldCheckLoad = (g_ticksSinceLoadCheck == 0);
        g_ticksSinceLoadCheck = (g_ticksSinceLoadCheck + 1) % kLoadCheckThrottleTicks;

        if (shouldCheckLoad) {
            BOOL isLoading = NO;
            BOOL haveLoadState = zs_try_read_is_loading_screen_present(&isLoading);
            if (haveLoadState) {
                if (self.wasLoading && !isLoading) {
                    ZLog(@"[ZSScripts] loading screen torn down (LoadingSceneManager gone, isBattle=%d) - reapplying settings", isBattle);
                    zs_reapply_all_settings();
                }
                self.wasLoading = isLoading;
            } else if (haveBattleState && wasInBattle && !isBattle) {

                ZLog(@"[ZSScripts] loading screen detected (battle-exit fallback, LoadingSceneManager lookup unavailable) - reapplying settings");
                zs_reapply_all_settings();
            }
        }
    }

    if (!haveBattleState) return;

    if (isBattle) {
        if (self.manualOverrideActiveCombat) return;
        [self applyTargetFPSIfNeeded:self.combatFPS];
    } else {
        if (self.manualOverrideActiveMenu) return;
        [self applyTargetFPSIfNeeded:self.menuFPS];
    }
}

- (void)applyTargetFPSIfNeeded:(NSInteger)desired {
    if (self.targetFPS != desired) {
        self.targetFPS = desired;
        zs_set_application_target_fps((int32_t)desired);
    }
}

- (void)setManualMenuFPS:(NSInteger)fps {
    self.menuFPS = fps;
    self.manualOverrideActiveMenu = YES;

    if (!self.isInBattle) {
        self.targetFPS = fps;
        zs_set_application_target_fps((int32_t)fps);
    }
}

- (void)clearManualMenuOverride {
    self.manualOverrideActiveMenu = NO;
    if (!self.isInBattle) {
        [self applyTargetFPSIfNeeded:self.menuFPS];
    }
}

- (void)setManualCombatFPS:(NSInteger)fps {
    self.combatFPS = fps;
    self.manualOverrideActiveCombat = YES;
    if (self.isInBattle) {
        self.targetFPS = fps;
        zs_set_application_target_fps((int32_t)fps);
    }
}

- (void)clearManualCombatOverride {
    self.manualOverrideActiveCombat = NO;
    if (self.isInBattle) {
        [self applyTargetFPSIfNeeded:self.combatFPS];
    }
}

- (void)dealloc {
    [self.battleStatePollTimer invalidate];
}

@end

#pragma mark - Apply-everything entry points

void zs_reapply_all_settings(void) {
    [[FPS120Controller shared] setManualMenuFPS:g_menuFPS];
    [[FPS120Controller shared] setManualCombatFPS:g_combatFPS];

    zs_set_texture_mip_limit(g_textureMip);
    zs_set_render_scale(g_renderScale);
    zs_urp_set_int("set_msaaSampleCount", zs_step_value(kMSAASteps, 4, g_msaaIndex));
    zs_urp_set_bool("set_supportsHDR", g_hdrOn);

    zs_apply_motion_blur();
    zs_apply_tonemapping();
    for (NSString *name in g_urpActive) {
        if (g_urpActive[name].boolValue) zs_apply_urp_post_effect(name);
    }

    zs_camera_data_set_int("set_antialiasing", zs_step_value(kAAModeSteps, 4, g_aaModeIndex));
    zs_camera_data_set_int("set_antialiasingQuality", zs_step_value(kAAQualitySteps, 3, g_aaQualityIndex));
    zs_camera_data_set_bool("set_dithering", g_ditheringOn);
}

void zs_reapply_post_fx(void) {
    zs_apply_motion_blur();
    zs_apply_tonemapping();

    for (NSString *name in g_urpActive) {
        if (g_urpActive[name].boolValue) zs_apply_urp_post_effect(name);
    }
}

