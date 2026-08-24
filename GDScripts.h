// GDScripts.h
//
// Dedicated "scripts" file for 120F: every piece of engine-facing logic
// that isn't UI now lives here, in two halves:
//
//   - FPS120Controller: the 120fps target-frame-rate controller.
//     Previously (fps120.m) this drove a spoofed CADisplayLink and
//     fought Unity's own frame pacer with a 1s "safety timer" that
//     kept re-asserting preferredFramesPerSecond. It now writes
//     UnityEngine.Application.targetFrameRate directly through
//     IL2CppBridge - the same "existing IL2CPP hooks" every setting
//     below already uses via the gd_class/gd_method/gd_offset caches
//     - instead of spoofing a link downstream of it. There's no more
//     safety timer: a direct write either lands or it doesn't, and
//     reapplying after a scene reload (see below) is what re-lands it
//     if the engine resets it, rather than blindly polling every
//     second regardless of whether anything actually reset.
//
//   - Every non-UI IL2CPP script GraphicsDebugOverlay.m used to own
//     directly: urpAsset/QualitySettings/Volume/renderer-feature/
//     camera-data plumbing, the hardcoded setting defaults, the
//     current-value globals that back every row, and JSON settings
//     persistence. GraphicsDebugOverlay.m now only builds/lays out UI
//     and calls into the functions below to push a change to the
//     engine - see that file's own header comment for the UI-side
//     picture (panel/row/slider layout, sections, persistence
//     debounce, etc).
//
// FPS120Controller also owns the only scene-change detector in this
// tweak. It originally polled GlobalGameManager.Instance.sceneState
// just to flip Menu/Combat FPS on entering/leaving a battle node, and
// for a while also used a battle-exit edge (wasInBattle && !isBattle)
// as a proxy for "a loading screen just happened, re-push everything."
// That proxy missed loads between two non-battle scenes (Main->Story,
// Story->Dungeon, etc. - sceneState has nine values, not just
// battle/not-battle), so it now instead polls
// GlobalGameManager.Instance.isRunningLoad, which toggles on every
// actual scene load regardless of which states are involved, and
// triggers gd_reapply_all_settings() on its falling edge. sceneState
// is still read, but only to choose which FPS target (menu vs combat)
// applies.
//
// NOTE: GameEngineControl.h/.m is mentioned in README.md as the
// intended home for this logic but was never actually implemented -
// this file (GDScripts.h/.m) is the real thing; nothing here calls
// into anything named GameEngineControl.
//
// isRunningLoad turned out to only ever be cleared by
// GlobalGameManager.SetRunningLoaded() - a single call site tied to
// the login-completion path, not the general LoadScene() path - so
// its falling edge only ever fired once, on the very first
// login->menu load. A Dobby inline hook on
// LoadingSceneManager.ClearResources() was tried as a replacement but
// crashed the game before it could reach the login screen, so this
// now polls for LoadingSceneManager's presence/absence instead - a
// fresh instance exists for every scene transition and is torn down
// once the next scene is ready, so it's a universal signal without
// hooking anything. See gd_try_read_is_loading_screen_present in
// GDScripts.m.

#import <Foundation/Foundation.h>
#import <stdint.h>

#pragma mark - FPS120Controller

@interface FPS120Controller : NSObject
@property (nonatomic, assign) NSInteger targetFPS;
@property (nonatomic, assign) NSInteger combatFPS;
@property (nonatomic, assign) NSInteger menuFPS;
// Independent per-mode overrides: dragging the Normal FPS slider in the
// debug overlay only takes menuFPS out of auto; the Combat FPS slider
// only takes combatFPS out of auto. The battle-state poller keeps
// driving whichever mode is NOT currently overridden.
@property (nonatomic, assign) BOOL manualOverrideActiveMenu;
@property (nonatomic, assign) BOOL manualOverrideActiveCombat;
// Last scene state read by the poller, so the overlay's manual setters
// know whether to push a value straight to the engine or let it apply
// next time that mode becomes active.
@property (nonatomic, assign) BOOL isInBattle;

+ (instancetype)shared;

// Starts the scene-state poll timer (if not already running) and
// makes an initial attempt to push targetFPS to the engine via
// IL2CPP. Safe to call repeatedly - e.g. from fps120.m's startup poll
// - until the engine/Assembly-CSharp is actually up and it starts
// returning YES.
- (BOOL)start;

// Called by the debug overlay when the user drags the Normal FPS
// slider. Sets menuFPS and marks manualOverrideActiveMenu so the
// scene-state poller stops driving menuFPS until cleared.
- (void)setManualMenuFPS:(NSInteger)fps;
- (void)clearManualMenuOverride;
// Same as above, for the Combat FPS slider / combatFPS.
- (void)setManualCombatFPS:(NSInteger)fps;
- (void)clearManualCombatOverride;
@end

#pragma mark - Rendering: urpAsset / QualitySettings

void gd_set_texture_mip_limit(int32_t mipLimit);
void gd_set_render_scale(float scale);
void gd_urp_set_bool(const char *setterName, BOOL value);
void gd_urp_set_int(const char *setterName, int32_t value);
void gd_urp_set_float(const char *setterName, float value);

// Stepped/enum-like properties (MSAA, AA mode/quality) don't take
// arbitrary floats - snap a mode slider's selected index to the
// nearest real step in one of the kXSteps arrays below before handing
// it to a setter above.
int32_t gd_step_value(const int32_t *steps, int count, float sliderValue);
extern const int32_t kMSAASteps[4];

#pragma mark - Post FX (Volume system)

void gd_apply_motion_blur(void);
void gd_apply_tonemapping(void);

typedef struct {
    const char *name;         // UI label AND dictionary/JSON key - can be anything, purely cosmetic
    const char *engineName;   // REAL VolumeComponent class name as it exists in the Unity/URP
                               // assembly (e.g. "ChromaticAberration", "LensDistortion") - this is
                               // what gets handed to reflection via gd_get_volume_component() and
                               // used to build the "<engineName>Renderer" feature-lookup name.
                               // MUST match the actual engine class exactly - renaming `name` alone
                               // for a nicer-fitting UI label silently breaks the component lookup.
    const char *floatField;   // primary float parameter field name, or NULL if none
    float minV, maxV, defaultV;
} GDVolumeEffectDef;

extern const GDVolumeEffectDef kURPPostEffects[];
extern const int kURPPostEffectCount;
void gd_apply_urp_post_effect(NSString *name);

#pragma mark - Camera-level post settings (antialiasing / dithering)
//
// UNVALIDATED: Camera.main requires a camera tagged "MainCamera" in
// the active scene, which a UI-heavy gacha/VN game like this may not
// use for battle/story (dedicated, untagged cameras are common
// there). If every control that goes through these two setters is a
// no-op, this is almost certainly why.

void gd_camera_data_set_int(const char *setterName, int32_t value);
void gd_camera_data_set_bool(const char *setterName, BOOL value);
extern const int32_t kAAModeSteps[4];
extern const int32_t kAAQualitySteps[3];

#pragma mark - Hardcoded setting defaults
//
// Every setting's compile-time starting value - the "current value"
// fallback when there's no save file yet, and what the panel's Reset
// button restores. See GDScripts.m for the history behind the few
// values that differ from what the engine itself defaults to.

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
// URP Post FX defaults come from each entry's own defaultV in
// kURPPostEffects above - not duplicated here.

#pragma mark - Current-value globals
//
// Source of truth for every row's "current value" - mirrored to/from
// the JSON settings file and pushed to the engine by
// gd_reapply_all_settings(). GraphicsDebugOverlay.m reads these when
// building rows and writes them from its slider/switch/mode-slider
// action methods; it never owns the values itself.

extern int32_t  g_textureMip;    // engine value (post-reversal) - see GraphicsDebugOverlay.m header
extern float    g_renderScale;   // fraction, e.g. 1.0 == 100%
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

// Syslog blacklist terms (lowercased substrings), mirrored here purely so
// this participates in gd_current_settings_dictionary()/the same JSON
// save file as every other control - GraphicsDebugOverlay.m still owns
// the actual UI/matching logic via its own syslogBlacklist ivar and just
// keeps this copy in sync whenever an entry is added or removed.
extern NSArray<NSString *> *g_syslogBlacklist;

// Every on-disk path (under +[BankTransplant mobileFMODBuildsDirectory]
// or wherever a bundle's stock location was) that a bank/bundle asset
// has ever actually been swapped into, logged independently of
// BankTransplant's/BundleDoctorInstaller's own backup-directory
// bookkeeping - see gd_track_asset_path() below for why. Mirrors
// g_syslogBlacklist's "global copy kept in sync so it round-trips
// through gd_current_settings_dictionary()" pattern, except this one is
// written to directly by GDScripts.m's own accessors below rather than
// by GraphicsDebugOverlay.m reaching in - callers should use
// gd_track_asset_path()/gd_tracked_asset_paths()/
// gd_clear_tracked_asset_paths(), not this global directly.
extern NSMutableArray<NSString *> *g_trackedAssetPaths;

#pragma mark - Settings persistence (JSON in Documents)

NSDictionary *gd_load_settings_dictionary(void);
void gd_write_settings_dictionary(NSDictionary *dict);
// Snapshots every current-value global above into one dictionary,
// ready to hand to gd_write_settings_dictionary().
NSDictionary *gd_current_settings_dictionary(void);

#pragma mark - Tracked asset paths (Hard Assets Reset)
//
// Independent log of every live game-file path a bank/bundle swap has
// ever written to, stored as its own "trackedAssetPaths" entry inside
// the same GraphicsDebugOverlaySettings.json every other control here
// round-trips through (see gd_current_settings_dictionary()). This
// exists so the Config section's "Hard Assets Reset" doesn't have to
// rediscover what to delete from BankTransplant's/BundleDoctorInstaller's
// own backup-directory manifests - if something else (a failed restore,
// a manual Files.app delete, a future bug) wipes one of those backup
// directories out from under it, this list is untouched and Reset can
// still find and delete the live files.
//
// gd_track_asset_path() is safe to call before the graphics panel has
// ever been built (e.g. from a bundle/bank swap that happens during
// early game startup) - it lazily loads whatever's already on disk into
// g_trackedAssetPaths on first use rather than assuming buildPanel's
// own settings-load has already run.
void gd_track_asset_path(NSString *path);
// Copy of the current list - callers should treat this as a snapshot,
// not something to mutate in place.
NSArray<NSString *> *gd_tracked_asset_paths(void);
// Empties the list (in memory and on disk). Meant to be called once
// Hard Assets Reset has finished deleting everything the list pointed
// to - see GraphicsDebugOverlay.m's -hardAssetsResetTapped.
void gd_clear_tracked_asset_paths(void);

#pragma mark - File index (Mod Loader Pipeline caching - see GDFileIndex.h)
//
// GDFileIndex.h/.m owns building/using the actual index (the CAB map,
// the FMOD filename set, and both folders' change-fingerprints) - this
// file only owns making sure whatever it builds round-trips through the
// same GraphicsDebugOverlaySettings.json every other control here does,
// under its own "fileIndex" entry, with the same "never silently
// dropped by an unrelated settings save" guarantee
// gd_current_settings_dictionary()'s own comment already promises
// trackedAssetPaths above. GDScripts.h/.m never builds or interprets
// this dictionary's contents - it's opaque here, GDFileIndex.m is the
// only reader/writer of what's actually inside it.

// Whatever GDFileIndex last computed - nil until +[GDFileIndex
// ensureIndexUpToDate] has run at least once this session, or
// gd_ensure_file_index_snapshot_loaded() has pulled in whatever a
// previous session left on disk.
extern NSDictionary *g_fileIndexSnapshot;

// Lazily loads g_fileIndexSnapshot from whatever's already in the
// settings JSON exactly once - same "don't assume buildPanel's own load
// has already run" reasoning as gd_ensure_tracked_asset_paths_loaded()
// above, since indexing needs to happen at startup (fps120.m), well
// before the graphics panel is ever built.
void gd_ensure_file_index_snapshot_loaded(void);

// Replaces g_fileIndexSnapshot and persists the full settings dictionary
// immediately - see gd_track_asset_path()'s own comment for why an
// immediate write matters here too: the index needs to survive a
// relaunch for the very next launch's cheap fingerprint check (see
// GDFileIndex.h) to have anything on file to compare against. Pass nil
// to clear it back out (not currently exercised by anything, but kept
// symmetrical with the tracked-asset-paths accessors above).
void gd_set_file_index_snapshot(NSDictionary * _Nullable snapshot);

#pragma mark - Apply-everything entry points

// Full parity with every setting this file knows about - FPS, texture
// mip, render scale, MSAA, HDR, motion blur, tonemapping, every
// extended URP Post FX effect, camera AA mode/quality, and dithering.
// Called once after the panel is built (so a value restored from the
// JSON file, or a fresh default, takes effect even if the panel is
// never opened that session) and again by FPS120Controller whenever
// its scene-state poll detects a transition back to a non-battle
// scene - see the file-level comment above for why a loading screen
// makes that necessary for more than just FPS.
void gd_reapply_all_settings(void);

// Lighter-weight subset for the panel's continuous Post FX reapply
// timer (Volume components re-blend every frame while the panel is
// open - see GraphicsDebugOverlay.m). Deliberately excludes FPS/
// texture mip/render scale/MSAA/camera AA, which only need a single
// write per change and would just be redundant work every tick.
void gd_reapply_post_fx(void);
