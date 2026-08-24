
#import <Foundation/Foundation.h>
#import <stdint.h>

#pragma mark - FPS120Controller

@interface FPS120Controller : NSObject
@property (nonatomic, assign) NSInteger targetFPS;
@property (nonatomic, assign) NSInteger combatFPS;
@property (nonatomic, assign) NSInteger menuFPS;

@property (nonatomic, assign) BOOL manualOverrideActiveMenu;
@property (nonatomic, assign) BOOL manualOverrideActiveCombat;

@property (nonatomic, assign) BOOL isInBattle;

+ (instancetype)shared;

- (BOOL)start;

- (void)setManualMenuFPS:(NSInteger)fps;
- (void)clearManualMenuOverride;

- (void)setManualCombatFPS:(NSInteger)fps;
- (void)clearManualCombatOverride;
@end

#pragma mark - Rendering: urpAsset / QualitySettings

void zs_set_texture_mip_limit(int32_t mipLimit);
void zs_set_render_scale(float scale);
void zs_urp_set_bool(const char *setterName, BOOL value);
void zs_urp_set_int(const char *setterName, int32_t value);
void zs_urp_set_float(const char *setterName, float value);

int32_t zs_step_value(const int32_t *steps, int count, float sliderValue);
extern const int32_t kMSAASteps[4];

#pragma mark - Post FX (Volume system)

void zs_apply_motion_blur(void);
void zs_apply_tonemapping(void);

typedef struct {
    const char *name;
    const char *engineName;

    const char *floatField;
    float minV, maxV, defaultV;
} ZSVolumeEffectDef;

extern const ZSVolumeEffectDef kURPPostEffects[];
extern const int kURPPostEffectCount;
void zs_apply_urp_post_effect(NSString *name);

#pragma mark - Camera-level post settings (antialiasing / dithering)

void zs_camera_data_set_int(const char *setterName, int32_t value);
void zs_camera_data_set_bool(const char *setterName, BOOL value);
extern const int32_t kAAModeSteps[4];
extern const int32_t kAAQualitySteps[3];

#pragma mark - Hardcoded setting defaults

extern const NSInteger kDefaultMenuFPS;
extern const NSInteger kDefaultCombatFPS;
extern const int32_t   kDefaultTextureMipEngine;
extern const float     kDefaultRenderScalePct;
extern const int32_t   kDefaultMSAAIndex;
extern const BOOL      kDefaultHDR;
extern const float     kDefaultMotionBlur;
extern const int32_t   kDefaultTonemapIndex;
extern const int32_t   kDefaultAAModeIndex;
extern const int32_t   kDefaultAAQualityIndex;
extern const BOOL      kDefaultDithering;

#pragma mark - Current-value globals

extern int32_t  g_textureMip;
extern float    g_renderScale;
extern int32_t  g_msaaIndex;
extern BOOL     g_hdrOn;
extern float    g_blurIntensity;
extern int32_t  g_tonemapMode;
extern int32_t  g_aaModeIndex;
extern int32_t  g_aaQualityIndex;
extern BOOL     g_ditheringOn;
extern NSInteger g_menuFPS;
extern NSInteger g_combatFPS;
extern NSMutableDictionary<NSString *, NSNumber *> *g_urpActive;
extern NSMutableDictionary<NSString *, NSNumber *> *g_urpValue;

extern NSArray<NSString *> *g_syslogBlacklist;

extern NSMutableArray<NSString *> *g_trackedAssetPaths;

#pragma mark - Settings persistence (JSON in Documents)

NSDictionary *zs_load_settings_dictionary(void);
void zs_write_settings_dictionary(NSDictionary *dict);

NSDictionary *zs_current_settings_dictionary(void);

#pragma mark - Tracked asset paths (Hard Assets Reset)

void zs_track_asset_path(NSString *path);

NSArray<NSString *> *zs_tracked_asset_paths(void);

void zs_clear_tracked_asset_paths(void);

#pragma mark - File index (Mod Loader Pipeline caching - see ZSFileIndex.h)

extern NSDictionary *g_fileIndexSnapshot;

void zs_ensure_file_index_snapshot_loaded(void);

void zs_set_file_index_snapshot(NSDictionary * _Nullable snapshot);

#pragma mark - Apply-everything entry points

void zs_reapply_all_settings(void);

void zs_reapply_post_fx(void);

