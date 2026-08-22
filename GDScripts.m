// GDScripts.m
//
// See GDScripts.h for the overview. Layout mirrors it: FPS120Controller
// and its scene-change poll first, then every rendering/Post FX/camera
// script GraphicsDebugOverlay.m used to own directly, then settings
// persistence, then the two apply-everything entry points that tie it
// all together.

#import "GDScripts.h"
#import "IL2CppBridge.h"
#import "ZTweakLog.h"

#pragma mark - Generic IL2CPP class/field/type/method caches
//
// Keeps every script below from re-typing dlsym-style boilerplate for
// every new class - lookups are cheap to cache by key since
// classes/fields are stable pointers for the process lifetime. Shared
// by FPS120Controller's scene-state poll and every rendering script,
// which is what lets the FPS side reuse IL2CppBridge instead of
// hand-rolling its own independent dlsym setup the way fps120.m used
// to.

static NSMutableDictionary<NSString *, NSValue *> *g_classCache;
static NSMutableDictionary<NSString *, NSValue *> *g_fieldOffsetCache;
static NSMutableDictionary<NSString *, NSValue *> *g_typeObjCache;
static NSMutableDictionary<NSString *, NSValue *> *g_methodCache;

static void *gd_class(const char *ns, const char *name, const char *assemblySubstring) {
    if (!g_classCache) g_classCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%s.%s@%s", ns, name, assemblySubstring];
    NSValue *cached = g_classCache[key];
    if (cached) return cached.pointerValue;

    void *klass = [IL2CppBridge classNamed:name inNamespace:ns assemblyContains:assemblySubstring];
    if (klass) g_classCache[key] = [NSValue valueWithPointer:klass];
    return klass;
}

// Field offset cache keyed by (class pointer, field name) - safe to
// share across different concrete classes since the key includes the
// class pointer itself.
static int32_t gd_offset(void *klass, const char *fieldName) {
    if (!klass) return -1;
    if (!g_fieldOffsetCache) g_fieldOffsetCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p.%s", klass, fieldName];
    NSValue *cached = g_fieldOffsetCache[key];
    if (cached) return (int32_t)(intptr_t)cached.pointerValue;

    int32_t off = [IL2CppBridge fieldOffsetOnClass:klass name:fieldName];
    g_fieldOffsetCache[key] = [NSValue valueWithPointer:(void *)(intptr_t)off];
    return off;
}

static void *gd_type_object(void *klass) {
    if (!klass) return NULL;
    if (!g_typeObjCache) g_typeObjCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p", klass];
    NSValue *cached = g_typeObjCache[key];
    if (cached) return cached.pointerValue;

    void *typeObj = [IL2CppBridge reflectionTypeForClass:klass];
    if (typeObj) g_typeObjCache[key] = [NSValue valueWithPointer:typeObj];
    return typeObj;
}

static const void *gd_method(void *klass, const char *name, int argCount) {
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

static void *gd_get_global_game_manager_instance(void) {
    void *klass = gd_class("", "GlobalGameManager", "Assembly-CSharp");
    if (!klass) return NULL;
    const void *getInstance = gd_method(klass, "get_Instance", 0);
    if (!getInstance) return NULL;
    void *exc = NULL;
    void *instance = [IL2CppBridge invokeMethod:getInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !instance) return NULL;
    return instance;
}

static void *gd_get_urp_asset(void) {
    void *manager = gd_get_global_game_manager_instance();
    if (!manager) return NULL;
    void *klass = gd_class("", "GlobalGameManager", "Assembly-CSharp");
    int32_t off = gd_offset(klass, "urpAsset");
    if (off < 0) return NULL;
    return *(void **)((uint8_t *)manager + off);
}

static void *gd_urp_asset_class(void) {
    return gd_class("UnityEngine.Rendering.Universal", "UniversalRenderPipelineAsset", "Universal.Runtime");
}

void gd_set_render_scale(float scale) {
    void *urpAsset = gd_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = gd_method(gd_urp_asset_class(), "set_renderScale", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &scale };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

// Shared single-arg setter helpers for the extra urpAsset properties
// below - same object, same lookup pattern as render scale, just
// generalized so each new property is a one-line call instead of a
// hand-rolled function. Some of these setters are C# `internal` rather
// than `public` (e.g. set_supportsHDR) - that's a compile-time C#
// accessibility concept the IL2Cpp native invoke path below doesn't
// enforce, so it doesn't matter here.
void gd_urp_set_bool(const char *setterName, BOOL value) {
    void *urpAsset = gd_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = gd_method(gd_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void gd_urp_set_int(const char *setterName, int32_t value) {
    void *urpAsset = gd_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = gd_method(gd_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void gd_urp_set_float(const char *setterName, float value) {
    void *urpAsset = gd_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = gd_method(gd_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

int32_t gd_step_value(const int32_t *steps, int count, float sliderValue) {
    int idx = (int)roundf(sliderValue);
    if (idx < 0) idx = 0;
    if (idx >= count) idx = count - 1;
    return steps[idx];
}

const int32_t kMSAASteps[4] = { 1, 2, 4, 8 };

#pragma mark - QualitySettings (texture mip limit)

void gd_set_texture_mip_limit(int32_t mipLimit) {
    void *klass = gd_class("UnityEngine", "QualitySettings", "CoreModule");
    const void *setter = gd_method(klass, "set_globalTextureMipmapLimit", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &mipLimit };
    [IL2CppBridge invokeMethod:setter onInstance:NULL args:args outException:&exc];
}

#pragma mark - Volume system (shared by Post FX)

static void *g_volumeManagerInstance;
static void *g_volumeStackInstance;
static int g_vmTicksSinceRefresh = 999; // force a refresh on first use

// VolumeManager.instance is a Lazy<T> singleton and .stack is the
// process-global default stack for a single-camera mobile game -
// stable for the app's lifetime, but revalidated occasionally anyway
// (same cheap-insurance pattern as GlobalGameManager's instance cache
// below) in case of a scene/domain event that swaps it.
static void *gd_get_volume_stack(void) {
    void *vmClass = gd_class("UnityEngine.Rendering", "VolumeManager", "Core.Runtime");
    if (!vmClass) return NULL;

    BOOL needsRefresh = (!g_volumeStackInstance || g_vmTicksSinceRefresh >= 8);
    if (!needsRefresh) {
        g_vmTicksSinceRefresh++;
        return g_volumeStackInstance;
    }

    const void *getInstance = gd_method(vmClass, "get_instance", 0);
    if (!getInstance) return NULL;
    void *exc = NULL;
    void *vmInstance = [IL2CppBridge invokeMethod:getInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !vmInstance) return NULL;
    g_volumeManagerInstance = vmInstance;

    const void *getStack = gd_method(vmClass, "get_stack", 0);
    if (!getStack) return NULL;
    exc = NULL;
    void *stack = [IL2CppBridge invokeMethod:getStack onInstance:vmInstance args:NULL outException:&exc];
    if (exc || !stack) return NULL;

    g_volumeStackInstance = stack;
    g_vmTicksSinceRefresh = 0;
    return stack;
}

// Fetches a VolumeComponent from the live stack via the non-generic
// GetComponent(Type) overload - sidesteps needing to instantiate an
// IL2CPP generic method by name. Namespace/assembly are parameters so
// this same function could serve any Volume-based component set by
// namespace/assembly, not just the native URP one wrapped below.
static void *gd_get_volume_component_ns(NSString *namespaze, NSString *assemblySubstring, const char *componentClassName) {
    void *stack = gd_get_volume_stack();
    if (!stack) return NULL;

    void *componentClass = gd_class(namespaze.UTF8String, componentClassName, assemblySubstring.UTF8String);
    if (!componentClass) return NULL;
    void *typeObj = gd_type_object(componentClass);
    if (!typeObj) return NULL;

    void *stackClass = [IL2CppBridge classOfInstance:stack];
    const void *getComponent = gd_method(stackClass, "GetComponent", 1);
    if (!getComponent) return NULL;

    void *exc = NULL;
    void *args[1] = { typeObj };
    void *component = [IL2CppBridge invokeMethod:getComponent onInstance:stack args:args outException:&exc];
    if (exc) return NULL;
    return component;
}

// Thin wrapper for the native-URP case (Bloom/MotionBlur/ChromaticAberration/...) - kept
// so existing call sites don't need the namespace/assembly spelled out every time.
static void *gd_get_volume_component(const char *componentClassName) {
    return gd_get_volume_component_ns(@"UnityEngine.Rendering.Universal", @"Universal.Runtime", componentClassName);
}

// VolumeComponent.active - same offset for every subclass since it's
// declared on the shared non-generic base, but looked up per concrete
// class anyway rather than assumed.
static void gd_set_component_active(void *component, BOOL active) {
    if (!component) return;
    void *klass = [IL2CppBridge classOfInstance:component];
    int32_t off = gd_offset(klass, "active");
    if (off < 0) return;
    *(BOOL *)((uint8_t *)component + off) = active;
}

// Reads a VolumeParameter<T> field (e.g. Bloom.intensity) off a
// component, then writes/reads its boxed m_Value via the PARAMETER
// OBJECT'S OWN concrete class (a generic instantiation like
// MinFloatParameter) since m_Value is declared on the generic base and
// field lookup needs the concrete runtime class to resolve correctly.
static void *gd_get_param_object(void *component, const char *paramFieldName) {
    if (!component) return NULL;
    void *componentClass = [IL2CppBridge classOfInstance:component];
    int32_t off = gd_offset(componentClass, paramFieldName);
    if (off < 0) return NULL;
    return *(void **)((uint8_t *)component + off);
}

static void gd_set_param_float(void *paramObj, float value) {
    if (!paramObj) return;
    void *klass = [IL2CppBridge classOfInstance:paramObj];
    int32_t off = gd_offset(klass, "m_Value");
    if (off < 0) return;
    *(float *)((uint8_t *)paramObj + off) = value;
}

// Same as gd_set_param_float but for int/enum-backed parameters (e.g.
// Tonemapping.mode, which is a TonemappingModeParameter wrapping an
// enum int, not a float) - writing a float through the float setter
// onto an int-backed m_Value would just corrupt the bit pattern.
static void gd_set_param_int(void *paramObj, int32_t value) {
    if (!paramObj) return;
    void *klass = [IL2CppBridge classOfInstance:paramObj];
    int32_t off = gd_offset(klass, "m_Value");
    if (off < 0) return;
    *(int32_t *)((uint8_t *)paramObj + off) = value;
}

void gd_apply_motion_blur(void) {
    void *blur = gd_get_volume_component("MotionBlur");
    if (!blur) return;
    gd_set_component_active(blur, YES); // no on/off toggle anymore - always active, tuned by intensity
    gd_set_param_float(gd_get_param_object(blur, "intensity"), g_blurIntensity);
}

#pragma mark - Renderer features (feature-level toggles, distinct from Volume components)
//
// ScriptableRendererFeatures live on the active renderer, not the
// Volume stack - a separate hook path from Bloom/MotionBlur/etc.
// Namespace/assembly are parameters for the same reason as
// gd_get_volume_component_ns above.

static int32_t gd_unbox_int32(void *boxed) {
    if (!boxed) return 0;
    void *klass = [IL2CppBridge classOfInstance:boxed];
    int32_t off = gd_offset(klass, "m_value");
    if (off < 0) return 0;
    return *(int32_t *)((uint8_t *)boxed + off);
}

static void *gd_get_scriptable_renderer(void) {
    void *urpAsset = gd_get_urp_asset();
    if (!urpAsset) return NULL;
    const void *getter = gd_method(gd_urp_asset_class(), "get_scriptableRenderer", 0);
    if (!getter) return NULL;
    void *exc = NULL;
    void *renderer = [IL2CppBridge invokeMethod:getter onInstance:urpAsset args:NULL outException:&exc];
    if (exc || !renderer) return NULL;
    return renderer;
}

// ScriptableRenderer.rendererFeatures is a public IReadOnlyList<ScriptableRendererFeature>
// backed by a concrete List<T> - get_Count/get_Item are real
// instantiated methods on that concrete class, found the same way
// every other method lookup in this file works.
static void *gd_get_renderer_features_list(void) {
    void *renderer = gd_get_scriptable_renderer();
    if (!renderer) return NULL;
    void *rendererClass = [IL2CppBridge classOfInstance:renderer];
    const void *getter = gd_method(rendererClass, "get_rendererFeatures", 0);
    if (!getter) return NULL;
    void *exc = NULL;
    void *list = [IL2CppBridge invokeMethod:getter onInstance:renderer args:NULL outException:&exc];
    if (exc || !list) return NULL;
    return list;
}

// Returns the first matching feature instance found in the active
// renderer's feature list, or NULL. candidateNames should list every
// plausible class name (e.g. both a Render Graph and legacy variant)
// most-likely-first.
static void *gd_find_renderer_feature(NSString *namespaze, NSString *assemblySubstring, NSArray<NSString *> *candidateNames) {
    void *list = gd_get_renderer_features_list();
    if (!list) return NULL;
    void *listClass = [IL2CppBridge classOfInstance:list];
    const void *getCount = gd_method(listClass, "get_Count", 0);
    const void *getItem = gd_method(listClass, "get_Item", 1);
    if (!getCount || !getItem) return NULL;

    void *exc = NULL;
    void *countBoxed = [IL2CppBridge invokeMethod:getCount onInstance:list args:NULL outException:&exc];
    if (exc) return NULL;
    int32_t count = gd_unbox_int32(countBoxed);

    NSMutableArray<NSValue *> *candidateKlasses = [NSMutableArray new];
    for (NSString *name in candidateNames) {
        void *klass = gd_class(namespaze.UTF8String, name.UTF8String, assemblySubstring.UTF8String);
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

static void gd_set_feature_active(void *feature, BOOL active) {
    if (!feature) return;
    void *klass = [IL2CppBridge classOfInstance:feature];
    const void *setter = gd_method(klass, "SetActive", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &active };
    [IL2CppBridge invokeMethod:setter onInstance:feature args:args outException:&exc];
}

#pragma mark - Extended native URP Post FX
//
// Same Volume-stack hook Motion Blur already proved out, just more
// components. None of these have a dedicated ScriptableRendererFeature
// (they all render through URP's single built-in post-process pass),
// so gd_apply_urp_post_effect's renderer-feature lookup below will
// simply find nothing for these and no-op - that's expected, not a
// bug.

const GDVolumeEffectDef kURPPostEffects[] = {
    { "Chroma",            "ChromaticAberration", "intensity",   0.0f,   1.0f,   0.0f },
    { "Vignette",          "Vignette",            "intensity",   0.0f,   1.0f,   0.3f },
    { "Film Grain",        "FilmGrain",           "intensity",   0.0f,   1.0f,   0.3f },
    { "Lens Distort",      "LensDistortion",      "intensity",  -1.0f,   1.0f,   0.0f },
    { "White Balance",     "WhiteBalance",        "temperature", -100.0f, 100.0f, 0.0f },
    { "Saturation",        "ColorAdjustments",    "saturation", -100.0f, 100.0f, 0.0f },
    // Depth of Field removed - confirmed to do nothing in-game (per request).
};
const int kURPPostEffectCount = sizeof(kURPPostEffects) / sizeof(kURPPostEffects[0]);

NSMutableDictionary<NSString *, NSNumber *> *g_urpActive;
NSMutableDictionary<NSString *, NSNumber *> *g_urpValue;

static const GDVolumeEffectDef *gd_urp_def_named(NSString *name) {
    for (int i = 0; i < kURPPostEffectCount; i++) {
        if ([name isEqualToString:[NSString stringWithUTF8String:kURPPostEffects[i].name]]) return &kURPPostEffects[i];
    }
    return NULL;
}

void gd_apply_urp_post_effect(NSString *name) {
    const GDVolumeEffectDef *def = gd_urp_def_named(name);
    if (!def) return;
    BOOL active = g_urpActive[name].boolValue;

    void *component = gd_get_volume_component(def->engineName);
    if (component) {
        gd_set_component_active(component, active);
        if (def->floatField) {
            NSNumber *val = g_urpValue[name];
            float fv = val ? val.floatValue : def->defaultV;
            gd_set_param_float(gd_get_param_object(component, def->floatField), fv);
        }
    }
    NSString *rendererName = [NSString stringWithFormat:@"%sRenderer", def->engineName];
    void *feature = gd_find_renderer_feature(@"UnityEngine.Rendering.Universal", @"Universal.Runtime", @[rendererName]);
    gd_set_feature_active(feature, active);
}

// Tonemapping is handled separately (not in the float-only table above)
// because its one interesting knob, .mode, is an int-backed enum
// parameter (None=0 / Neutral=1 / ACES=2), not a float. Its own on/off
// toggle was removed along with the rest of Post FX's toggles - mode 0
// (None) already covers "off", so the component just stays permanently
// active and the mode slider decides what that means visually.
int32_t g_tonemapMode = 0;

void gd_apply_tonemapping(void) {
    void *component = gd_get_volume_component("Tonemapping");
    if (!component) return;
    gd_set_component_active(component, YES);
    gd_set_param_int(gd_get_param_object(component, "mode"), g_tonemapMode);
}

#pragma mark - Camera-level post settings (antialiasing / dithering)

static void *gd_get_main_camera(void) {
    void *klass = gd_class("UnityEngine", "Camera", "CoreModule");
    if (!klass) return NULL;
    const void *getMain = gd_method(klass, "get_main", 0);
    if (!getMain) return NULL;
    void *exc = NULL;
    void *cam = [IL2CppBridge invokeMethod:getMain onInstance:NULL args:NULL outException:&exc];
    if (exc || !cam) return NULL;
    return cam;
}

static void *gd_get_camera_data(void) {
    void *cam = gd_get_main_camera();
    if (!cam) return NULL;
    void *camKlass = [IL2CppBridge classOfInstance:cam];
    void *dataKlass = gd_class("UnityEngine.Rendering.Universal", "UniversalAdditionalCameraData", "Universal.Runtime");
    if (!dataKlass) return NULL;
    void *typeObj = gd_type_object(dataKlass);
    if (!typeObj) return NULL;
    const void *getComponent = gd_method(camKlass, "GetComponent", 1);
    if (!getComponent) return NULL;
    void *exc = NULL;
    void *args[1] = { typeObj };
    void *data = [IL2CppBridge invokeMethod:getComponent onInstance:cam args:args outException:&exc];
    if (exc) return NULL;
    return data;
}

void gd_camera_data_set_int(const char *setterName, int32_t value) {
    void *data = gd_get_camera_data();
    if (!data) return;
    void *klass = [IL2CppBridge classOfInstance:data];
    const void *setter = gd_method(klass, setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:data args:args outException:&exc];
}

void gd_camera_data_set_bool(const char *setterName, BOOL value) {
    void *data = gd_get_camera_data();
    if (!data) return;
    void *klass = [IL2CppBridge classOfInstance:data];
    const void *setter = gd_method(klass, setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:data args:args outException:&exc];
}

const int32_t kAAModeSteps[4]    = { 0, 1, 2, 3 }; // None / FXAA / SMAA / TAA
const int32_t kAAQualitySteps[3] = { 0, 1, 2 };    // Low / Medium / High

#pragma mark - Hardcoded setting defaults
//
// Defaults are NOT read back from the live game - these constants are
// simply the starting value for each control, so both the "current
// value" fallback (when there's no save file yet) and the default-
// indicator/reset-target logic in GraphicsDebugOverlay.m read from a
// single spot. A few intentionally differ from the engine's own
// default (Menu/Combat FPS both 60 rather than ~120/60, Bloom/HDR on
// rather than off, Motion Blur 0 rather than 0.5, MSAA 1x rather than
// 4x) - see the panel's UI header comment for the request history.
const NSInteger kDefaultMenuFPS          = 60;
const NSInteger kDefaultCombatFPS        = 60;
const int32_t   kDefaultTextureMipEngine = 0;    // engine value; 0 = max quality (see GraphicsDebugOverlay.m header note on the reversal)
const float     kDefaultRenderScalePct   = 100.0f;
const int32_t   kDefaultMSAAIndex        = 0;    // -> 1x
const BOOL      kDefaultHDR              = YES;  // Bloom row
const float     kDefaultMotionBlur       = 0.0f;
const int32_t   kDefaultTonemapIndex     = 0;    // None
const int32_t   kDefaultAAModeIndex      = 0;    // None
const int32_t   kDefaultAAQualityIndex   = 1;    // Med
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

#pragma mark - Settings persistence (JSON in Documents)
//
// Every control's current value round-trips through a small JSON file
// in the app's own Documents directory so it survives relaunches. This
// is entirely separate from the game's own LocalGameOptionData save
// system - it only remembers this tweak's panel state.

static NSString *gd_settings_file_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"GraphicsDebugOverlaySettings.json"];
}

NSDictionary *gd_load_settings_dictionary(void) {
    NSString *path = gd_settings_file_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[GDScripts] failed to parse settings JSON: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

void gd_write_settings_dictionary(NSDictionary *dict) {
    NSString *path = gd_settings_file_path();
    if (!path) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (error || !data) {
        ZLog(@"[GDScripts] failed to encode settings JSON: %@", error);
        return;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[GDScripts] failed to write settings JSON: %@", writeError);
    }
}

#pragma mark - Tracked asset paths (Hard Assets Reset)
//
// See GDScripts.h for why this exists. g_trackedAssetPaths is loaded
// lazily (once) from whatever's already on disk rather than assuming
// buildPanel's own settings-load has run first - a bank/bundle swap can
// happen before the graphics panel is ever built.

static void gd_ensure_tracked_asset_paths_loaded(void) {
    if (g_trackedAssetPaths) return;
    NSDictionary *saved = gd_load_settings_dictionary();
    NSArray *savedPaths = [saved[@"trackedAssetPaths"] isKindOfClass:[NSArray class]] ? saved[@"trackedAssetPaths"] : nil;
    g_trackedAssetPaths = [NSMutableArray new];
    for (id path in savedPaths) {
        if ([path isKindOfClass:[NSString class]]) [g_trackedAssetPaths addObject:path];
    }
}

void gd_track_asset_path(NSString *path) {
    if (path.length == 0) return;
    gd_ensure_tracked_asset_paths_loaded();
    if ([g_trackedAssetPaths containsObject:path]) return;
    [g_trackedAssetPaths addObject:path];
    // Persisted immediately (not just held in memory until the next
    // unrelated settings save) - a swap that isn't followed by any
    // graphics-slider change this session still needs to survive a
    // relaunch for Hard Assets Reset to find it later.
    gd_write_settings_dictionary(gd_current_settings_dictionary());
}

NSArray<NSString *> *gd_tracked_asset_paths(void) {
    gd_ensure_tracked_asset_paths_loaded();
    return [g_trackedAssetPaths copy];
}

void gd_clear_tracked_asset_paths(void) {
    gd_ensure_tracked_asset_paths_loaded();
    [g_trackedAssetPaths removeAllObjects];
    gd_write_settings_dictionary(gd_current_settings_dictionary());
}

NSDictionary *gd_current_settings_dictionary(void) {
    // Every snapshot - even one triggered by an unrelated graphics
    // slider - must include whatever's currently tracked, or a save
    // from before any track/clear call this session would silently
    // drop the key gd_write_settings_dictionary() below is about to
    // overwrite the file with (that function is a full replace, not a
    // merge - see its own header).
    gd_ensure_tracked_asset_paths_loaded();

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
    };
}

#pragma mark - FPS120Controller
//
// Replaces the old CADisplayLink-spoofing approach: instead of
// setting a UIKit display link's preferredFramesPerSecond (which
// Unity's own frame pacer just resyncs away on nearly every scene/
// config reload - see README), this writes
// UnityEngine.Application.targetFrameRate directly through the same
// gd_class/gd_method caches every rendering script above already
// uses. There is no more 1s "safety timer" re-asserting a value
// against something fighting it - a single write either lands or it
// doesn't, and the scene-change poll below (gd_reapply_all_settings)
// is what re-lands it after an actual scene reload, rather than
// blindly polling every second regardless of whether anything reset.

static BOOL gd_set_application_target_fps(int32_t fps) {
    void *klass = gd_class("UnityEngine", "Application", "CoreModule");
    const void *setter = gd_method(klass, "set_targetFrameRate", 1);
    if (!setter) return NO;
    void *exc = NULL;
    void *args[1] = { &fps };
    [IL2CppBridge invokeMethod:setter onInstance:NULL args:args outException:&exc];
    return (exc == NULL);
}

// GlobalGameManager.Instance.sceneState - the same scene-change signal
// that originally only existed to flip Menu/Combat FPS on entering/
// leaving a battle node. Field offset is looked up by name (never
// hardcoded) via the same gd_offset cache every rendering script above
// uses, so this survives the field's numeric offset shifting on future
// game updates.
static const int32_t kSceneStateBattle = 1;

// GlobalGameManager.Instance is a true app-lifetime singleton: its
// only GC root is the static field itself, and IL2CPP's GC never
// moves live objects, so once resolved the pointer is stable for as
// long as the singleton exists. Cached here and only revalidated
// every kInstanceRefreshTicks polls (a cheap insurance revalidation)
// so the 0.25s poll is a raw offset read on every other tick instead
// of a fresh il2cpp_runtime_invoke.
static void *g_cachedGameManagerInstance;
static int g_ticksSinceInstanceRefresh;
static const int kInstanceRefreshTicks = 8; // ~2s at the 0.25s poll interval

// gd_try_read_is_loading_screen_present's FindObjectOfType(Type,
// includeInactive:true) call is a full scene-graph walk - by far the
// most expensive thing battleStatePoll does, and calling it on every
// 0.5s tick is what was showing up as a periodic hitch in MetalHUD's
// frametime histogram. Everything else in the poll (the battle-state
// field read, the cached GlobalGameManager instance) is effectively
// free by comparison and doesn't need throttling. This only trades
// away detection latency for a load screen's falling edge - up to
// (kLoadCheckThrottleTicks - 1) extra ticks before gd_reapply_all_settings
// fires - which is inaudible/invisible against a load transition anyway.
static int g_ticksSinceLoadCheck;
static const int kLoadCheckThrottleTicks = 2; // check every ~1s at the 0.5s poll interval

// Cheap-insurance singleton fetch, shared by every poll-tick read below
// (battle state, loading state) - one refresh-or-reuse call instead of
// each read duplicating its own refresh bookkeeping against the same
// underlying instance.
static void *gd_get_cached_game_manager_instance(void) {
    BOOL needsRefresh = (!g_cachedGameManagerInstance || g_ticksSinceInstanceRefresh >= kInstanceRefreshTicks);
    if (needsRefresh) {
        void *instance = gd_get_global_game_manager_instance();
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

static BOOL gd_try_read_is_in_battle(BOOL *outIsBattle) {
    void *klass = gd_class("", "GlobalGameManager", "Assembly-CSharp");
    if (!klass) return NO;
    void *instance = gd_get_cached_game_manager_instance();
    if (!instance) return NO;

    int32_t off = gd_offset(klass, "sceneState");
    if (off < 0) return NO;
    int32_t sceneState = *(int32_t *)((uint8_t *)instance + off);
    *outIsBattle = (sceneState == kSceneStateBattle);
    return YES;
}

// GlobalGameManager.isRunningLoad looked like the right signal (true
// for the duration of a scene load, sitting right next to
// OnSceneLoaded(Scene, LoadSceneMode)) but turned out not to be: the
// ONLY call site that ever clears it is SetRunningLoaded(), reached
// from the login-completion path, not the general LoadScene() path
// every other transition goes through. Polling its falling edge caught
// exactly one loading screen - the first one, at login - and never
// fired again for the rest of the session. sceneState has the same
// blind spot in the other direction: the real SCENE_STATE enum has
// nine values (Login, Battle, Main, Story, Dungeon, MirrorDungeon,
// RailwayDungeon, StoryMirrorDungeon, ProjectGS), so a load between two
// non-battle states (Main -> Story, Story -> Dungeon, etc.) is
// invisible to a wasInBattle && !isBattle check even though it resets
// the same settings a battle exit does.
//
// A Dobby inline hook on LoadingSceneManager.ClearResources() was
// tried in place of both - fires at the exact instruction the loading
// screen tears down, on every transition - but crashed the game before
// it could even reach the login screen (inline-patching a method's
// prologue at a fixed RVA is inherently more failure-prone than
// reading a field; a mismatched offset/instruction-length assumption
// there corrupts the function rather than just returning a wrong
// value). Reverted in favor of this: LoadingSceneManager itself is a
// fresh MonoBehaviour instance for every scene transition (login,
// battle exit/enter, dungeon/story entry, menu navigation, all of it)
// and is destroyed once the next scene is ready, so
// UnityEngine.Object.FindObjectOfType(Type) returning non-null/null is
// a universal "is a loading screen up right now" signal - no hooking,
// same IL2CppBridge reflection calls every other setting in this file
// already uses, just a presence check instead of a field read.
// sceneState is still read here, but only to pick which FPS target
// (menu vs combat) applies.
//
// UnityEngine.Object overloads FindObjectOfType four ways:
//   FindObjectOfType()                          - 0 args, generic
//   FindObjectOfType(Boolean includeInactive)    - 1 arg,  generic
//   FindObjectOfType(Type type)                  - 1 arg,  non-generic  <- wanted this
//   FindObjectOfType(Type type, Boolean)         - 2 args, non-generic
// methodOnClass:name:argCount: only disambiguates by name+argCount, so
// looking up "FindObjectOfType"/1 was ambiguous with the generic
// Boolean-arg overload above it - and it was landing on that one, not
// the Type-arg one. Calling it with a System.Type* in the Boolean slot
// threw on every invoke, silently tripped `if (exc) return NO`, and
// haveLoadState was false on literally every poll tick - which is why
// this never fired. The 2-arg overload is the only "FindObjectOfType"
// with 2 params, so it's unambiguous - use that instead, with
// includeInactive:YES so a loading screen that gets SetActive(false)
// just before being destroyed doesn't get missed between ticks.
static BOOL gd_try_read_is_loading_screen_present(BOOL *outIsLoading) {
    void *objectKlass  = gd_class("UnityEngine", "Object", "CoreModule");
    void *loadingKlass = gd_class("", "LoadingSceneManager", "Assembly-CSharp");
    if (!objectKlass || !loadingKlass) return NO;

    const void *findMethod = gd_method(objectKlass, "FindObjectOfType", 2);
    if (!findMethod) return NO;

    void *typeObj = gd_type_object(loadingKlass);
    if (!typeObj) return NO;

    BOOL includeInactive = YES;
    void *exc = NULL;
    void *args[2] = { typeObj, &includeInactive };
    void *result = [IL2CppBridge invokeMethod:findMethod onInstance:NULL args:args outException:&exc];
    if (exc) {
        static BOOL loggedOnce = NO;
        if (!loggedOnce) {
            ZLog(@"[GDScripts] FindObjectOfType(LoadingSceneManager, true) threw - loading-screen presence detection is not working, falling back to battle-exit heuristic only");
            loggedOnce = YES;
        }
        return NO;
    }

    *outIsLoading = (result != NULL);
    return YES;
}

#pragma mark - Scene-loaded event hook (replaces the LoadingSceneManager poll)
//
// UnityEngine.SceneManagement.SceneManager.sceneLoaded is a real C#
// event Unity's own engine fires on the main thread at the end of
// every scene load - exactly the signal
// gd_try_read_is_loading_screen_present above was approximating via a
// poll. Subscribing directly to it turns "walk the scene graph
// looking for LoadingSceneManager up to twice a second" into "get
// called once, exactly when a load actually finishes" - no poll, no
// FindObjectOfType, no periodic hitch. It's also strictly more correct
// than what it replaces: sceneLoaded fires on every completed load
// unconditionally, so it doesn't share the poll's blind spots (see the
// comment above gd_try_read_is_loading_screen_present - isRunningLoad
// and the battle-exit fallback both missed non-battle transitions).
//
// There's no public "wrap a native function pointer as a C# delegate"
// call in the il2cpp embedding API, but every compiler-generated
// delegate type carries a .ctor(object target, IntPtr methodPtr)
// constructor, and a null target with a native code pointer there is
// the same target-less-native-delegate path
// Marshal.GetDelegateForFunctionPointer relies on for reverse P/Invoke
// - a real, long-standing Mono/IL2CPP interop mechanism, not a
// struct-poking hack. The delegate's exact closed generic type
// (UnityAction<Scene, LoadSceneMode>) is read directly off
// add_sceneLoaded's own parameter list via il2cpp_method_get_param +
// il2cpp_class_from_type instead of guessed at by name, so this
// doesn't depend on spelling out a generic instantiation ourselves.
//
// gd_on_scene_loaded_trampoline deliberately takes zero C parameters
// even though the real call site passes Scene and LoadSceneMode -
// under ARM64's calling convention a callee that never touches its
// incoming registers/stack args is unaffected by whatever's actually
// sitting in them, so this side of the call can't be what's wrong.
// What CAN'T be verified without testing against the live binary is
// whether this specific il2cpp build honors the null-target/native-
// IntPtr constructor path the way described above. If it doesn't, the
// failure shows up as a crash inside this trampoline on the first
// scene load after boot - not at launch, and not gracefully -
// because by then the subscribe call below has already returned
// successfully; a clean subscribe proves the constructor and
// add_sceneLoaded calls didn't throw, not that the invocation path
// they wired up is correct. If the install itself fails for a more
// mundane reason (missing symbols, unexpected overload, an exception
// during either call), that part IS caught cleanly:
// g_sceneLoadedHookInstalled stays NO and battleStatePoll keeps doing
// exactly what it already did.
static BOOL g_sceneLoadedHookInstalled = NO;

static void gd_on_scene_loaded_trampoline(void) {
    ZLog(@"[GDScripts] SceneManager.sceneLoaded fired - reapplying settings");
    gd_reapply_all_settings();
}

static void gd_install_scene_loaded_hook(void) {
    void *sceneManagerClass = gd_class("UnityEngine.SceneManagement", "SceneManager", "CoreModule");
    if (!sceneManagerClass) return;

    const void *addSceneLoaded = gd_method(sceneManagerClass, "add_sceneLoaded", 1);
    if (!addSceneLoaded) return;

    const void *paramType = [IL2CppBridge paramTypeForMethod:addSceneLoaded index:0];
    void *delegateClass = paramType ? [IL2CppBridge classFromType:paramType] : NULL;
    if (!delegateClass) return;

    const void *ctor = [IL2CppBridge methodOnClass:delegateClass name:".ctor" argCount:2];
    if (!ctor) return;

    void *delegateInstance = [IL2CppBridge newObjectForClass:delegateClass];
    if (!delegateInstance) return;

    void *methodPtr = (void *)&gd_on_scene_loaded_trampoline;
    void *ctorExc = NULL;
    void *ctorArgs[2] = { NULL, &methodPtr }; // target: null, methodPtr: &value (IntPtr is a value type)
    [IL2CppBridge invokeMethod:ctor onInstance:delegateInstance args:ctorArgs outException:&ctorExc];
    if (ctorExc) {
        ZLog(@"[GDScripts] scene-loaded delegate construction threw - falling back to polling");
        return;
    }

    void *addExc = NULL;
    void *addArgs[1] = { delegateInstance }; // delegate is a reference type: pass the pointer itself
    [IL2CppBridge invokeMethod:addSceneLoaded onInstance:NULL args:addArgs outException:&addExc];
    if (addExc) {
        ZLog(@"[GDScripts] SceneManager.add_sceneLoaded threw - falling back to polling");
        return;
    }

    g_sceneLoadedHookInstalled = YES;
    ZLog(@"[GDScripts] scene-loaded event hook installed - loading-screen poll disabled");
}

@interface FPS120Controller ()
@property (nonatomic, strong) NSTimer *battleStatePollTimer;
// Last gd_try_read_is_loading_screen_present value read by the poll,
// so it can trigger a reapply on the falling edge (a loading screen
// that was present last tick is gone now) instead of every tick it
// happens to read present.
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
        gd_install_scene_loaded_hook();

        // 0.5s rather than the original 0.25s - halves how often this
        // fires (battle-state read, and - only if the event hook above
        // didn't install - the loading-screen presence check) in
        // exchange for up to 0.5s extra latency between a loading
        // screen ending and settings landing when running on the poll
        // fallback. The battle-state read is cheap regardless; it's
        // the FindObjectOfType-based presence check that this interval
        // was actually sized around - see gd_install_scene_loaded_hook
        // above for why that poll usually isn't running at all anymore.
        self.battleStatePollTimer = [NSTimer timerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(battleStatePoll)
                                                            userInfo:nil
                                                             repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.battleStatePollTimer forMode:NSRunLoopCommonModes];
    }
    return gd_set_application_target_fps((int32_t)self.targetFPS);
}

- (void)battleStatePoll {
    BOOL isBattle = NO;
    BOOL haveBattleState = gd_try_read_is_in_battle(&isBattle);
    BOOL wasInBattle = self.isInBattle;
    if (haveBattleState) self.isInBattle = isBattle;

    // Primary trigger: SceneManager.sceneLoaded, if gd_install_scene_loaded_hook
    // got it wired up (see that function above) - reapply happens
    // directly from gd_on_scene_loaded_trampoline when the engine fires
    // it, nothing to do here. Only fall back to the old
    // LoadingSceneManager poll (throttled - see kLoadCheckThrottleTicks)
    // when the hook didn't install.
    if (!g_sceneLoadedHookInstalled) {
        BOOL shouldCheckLoad = (g_ticksSinceLoadCheck == 0);
        g_ticksSinceLoadCheck = (g_ticksSinceLoadCheck + 1) % kLoadCheckThrottleTicks;

        if (shouldCheckLoad) {
            BOOL isLoading = NO;
            BOOL haveLoadState = gd_try_read_is_loading_screen_present(&isLoading);
            if (haveLoadState) {
                if (self.wasLoading && !isLoading) {
                    ZLog(@"[GDScripts] loading screen torn down (LoadingSceneManager gone, isBattle=%d) - reapplying settings", isBattle);
                    gd_reapply_all_settings();
                }
                self.wasLoading = isLoading;
            } else if (haveBattleState && wasInBattle && !isBattle) {
                // Fallback only: FindObjectOfType/class lookup failed (e.g. a
                // future game update renames/removes LoadingSceneManager).
                // Falls back to the old battle-exit heuristic rather than
                // silently reapplying nothing - narrower coverage, but better
                // than losing the feature outright.
                ZLog(@"[GDScripts] loading screen detected (battle-exit fallback, LoadingSceneManager lookup unavailable) - reapplying settings");
                gd_reapply_all_settings();
            }
        }
    }

    if (!haveBattleState) return;

    // Each mode backs off independently: a manual override on Combat
    // doesn't stop Menu from being auto-driven while out of battle,
    // and vice versa.
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
        gd_set_application_target_fps((int32_t)desired);
    }
}

- (void)setManualMenuFPS:(NSInteger)fps {
    self.menuFPS = fps;
    self.manualOverrideActiveMenu = YES;
    // Only push to the engine if Menu mode is the one currently in
    // effect - otherwise just remember it for next time the scene
    // leaves battle.
    if (!self.isInBattle) {
        self.targetFPS = fps;
        gd_set_application_target_fps((int32_t)fps);
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
        gd_set_application_target_fps((int32_t)fps);
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

// Full apply - every control this tweak owns. Called both once at
// startup (after settings are loaded/the panel is built - see
// GraphicsDebugOverlay.m) and on every isRunningLoad falling edge (see
// battleStatePoll above). Texture mip/render scale/HDR/Post FX are
// currently confirmed to survive a scene load untouched, so this is
// wider than strictly necessary today - but that's deliberate: any new
// setting this tweak grows later is covered automatically, and any
// future game update that starts resetting something else on load
// doesn't need this file touched again to keep working.
void gd_reapply_all_settings(void) {
    [[FPS120Controller shared] setManualMenuFPS:g_menuFPS];
    [[FPS120Controller shared] setManualCombatFPS:g_combatFPS];

    gd_set_texture_mip_limit(g_textureMip);
    gd_set_render_scale(g_renderScale);
    gd_urp_set_int("set_msaaSampleCount", gd_step_value(kMSAASteps, 4, g_msaaIndex));
    gd_urp_set_bool("set_supportsHDR", g_hdrOn);

    gd_apply_motion_blur();
    gd_apply_tonemapping();
    for (NSString *name in g_urpActive) {
        if (g_urpActive[name].boolValue) gd_apply_urp_post_effect(name);
    }

    gd_camera_data_set_int("set_antialiasing", gd_step_value(kAAModeSteps, 4, g_aaModeIndex));
    gd_camera_data_set_int("set_antialiasingQuality", gd_step_value(kAAQualitySteps, 3, g_aaQualityIndex));
    gd_camera_data_set_bool("set_dithering", g_ditheringOn);
}

void gd_reapply_post_fx(void) {
    gd_apply_motion_blur();
    gd_apply_tonemapping();

    for (NSString *name in g_urpActive) {
        if (g_urpActive[name].boolValue) gd_apply_urp_post_effect(name);
    }
}
