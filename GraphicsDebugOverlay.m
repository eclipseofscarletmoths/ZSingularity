// GraphicsDebugOverlay.m
//
// EXPERIMENTAL. On-screen panel for live-tuning render settings. The UI is
// a full-height right-side Liquid Glass dock with a fused pull tab. Scrolls
// internally so the full panel is reachable even on a short landscape window.
//
// Sections:
//   Display        - Menu FPS / Combat FPS (drives the existing
//                    FPS120Controller singleton, GDScripts.h/.m).
//                    Always manual now - see "AUTO removed" below.
//   Rendering      - Texture mip limit (UI-reversed, see below), render
//                    scale, MSAA (now a preset/mode slider, see below) -
//                    real public properties on the same urpAsset already
//                    used for render scale.
//   Anti-Aliasing  - Moved above Post FX per request. AA mode/quality
//                    (mode sliders, see below) and dithering, from
//                    UniversalAdditionalCameraData on Camera.main.
//                    UNVALIDATED - see caveats.
//   Post FX        - "Bloom" here is a UI-only relabel of the HDR toggle
//                    (still set_supportsHDR under the hood) - it does
//                    NOT revive real bloom controls; see caveats below
//                    for why the game's actual bloom parameters don't
//                    have working sliders. Motion blur and Tonemapping
//                    (the latter now a mode slider) are always active;
//                    Tonemapping's "None" mode already covers "off".
//                    Extended with several native URP Volume components
//                    (Chromatic Aberration, Vignette, Film Grain, Lens
//                    Distortion, White Balance, Color Adjustments) using
//                    the same Volume-stack hook Motion Blur proved out -
//                    these are also toggle-free: each one is always
//                    active and tuned entirely by its own slider. Depth
//                    of Field has been removed entirely - confirmed to
//                    do nothing in-game.
//
// AUTO removed:
// - The old Menu/Combat FPS rows had a two-state AUTO/manual toggle that
//   let the scene-state poller in FPS120Controller keep driving target
//   FPS until the slider was touched. That AUTO button (and the auto
//   state itself) has been removed per request - both FPS sliders are
//   now plain single-line rows, and every drag is an immediate manual
//   override via -setManualMenuFPS:/-setManualCombatFPS: (the "clear
//   override" controller calls are simply never invoked anymore). The
//   controller's underlying manualOverrideActiveMenu/Combat flags still
//   exist (untouched in GDScripts.h/.m) but are effectively always YES
//   once this panel installs, since defaults are pushed to the
//   controller once at startup - see gd_reapply_all_settings() in
//   GDScripts.m, called at the end of -buildPanel: below.
//
// Defaults + snap-to-default:
// - Every setting has a hardcoded starting value - the same ones this
//   file already shipped with (Texture MIP 0, Render Scale 100, MSAA
//   index 0 [1x], Tonemap "None", each URP Post FX's own defaultV,
//   AA Mode "None", AA Quality "Med", Dithering off) - EXCEPT four
//   overridden per request: Menu FPS and Combat FPS both default to 60
//   (was 120/60 read from the watcher), Bloom/HDR defaults to true (was
//   false), Motion Blur defaults to 0 (was 0.5), and MSAA now defaults to
//   index 0 / 1x (was index 2 / 4x). These are compile-
//   time constants (the kDefault* group below), not values read back
//   from the live game - see the "change of plans" note at that group.
// - Every GDCapsuleSlider (every numeric/continuous slider in the panel)
//   gets a thin default-position tick drawn on its track, and drag
//   release now snaps exactly onto that tick when the touch ends close
//   enough to it - see -setValueFromLocation:sendActions: below.
//   GDModeSlider (the new preset-value control, see below) shows its
//   default as a small dot under the corresponding label instead, since
//   its selection is already discrete/snapped by construction.
// - Toggles (Bloom/HDR, Dithering) aren't scroll bars, so they don't get
//   a tick - they just start on their default state and remember it (via
//   an associated object) for the reset button.
//
// Texture MIP reversed:
// - QualitySettings.globalTextureMipmapLimit is Unity's own "how many
//   mip levels to skip" knob: 0 already means no skipping (max texture
//   quality) and larger values mean more skipping (lower quality) - so
//   the ENGINE-facing number was already "0 = max, 4 = min" before this
//   change, matching the request's stated convention. What actually
//   reads backwards is the SLIDER: dragging the pill to the right used
//   to raise that engine number, i.e. dragging right made textures
//   worse, opposite of every other slider in this panel (Render Scale,
//   MSAA, etc. all get "better"/"more" as you drag right). This file
//   now keeps that "more fill = better" feel by reversing the mapping
//   between slider position and the value shown/sent: the slider's own
//   internal `value` is a position from 0 (empty, worst) to 4 (full,
//   best), and the displayed number / the value actually handed to
//   gd_set_texture_mip_limit is (4 - position). See -texChanged:.
//
// Preset-value settings -> mode slider:
// - AA Mode, AA Quality, Tonemap, and MSAA don't represent a number the
//   user is tuning - they pick one of a handful of named presets. These
//   rows all use a GDModeSlider control instead of GDCapsuleSlider: a
//   segmented capsule that visually fills in behind whichever preset
//   label is selected and hard-snaps to the nearest segment on drag/tap,
//   rather than showing a floating numeric value next to a continuous
//   bar. MSAA's labels ("1x"/"2x"/"4x"/"8x") still map onto the same
//   real sample-count steps as before (kMSAASteps) - only the control
//   type changed, matching the preset sliders AA Mode/Quality already
//   use, per request.
//
// Settings persistence:
// - Every control's current value is written to a JSON file in the
//   app's Documents directory (see gd_settings_file_path) a moment after
//   the last change (debounced - see -gd_scheduleSave), and read back at
//   panel-build time so settings survive relaunches. The reset button
//   (bottom of the panel, native Liquid Glass) puts every control back
//   on its hardcoded default and immediately overwrites the save file
//   with that reset state.
//
// IMPORTANT CAVEATS (carried over):
// - None of this touches LocalGameOptionData / the save system. Values
//   here are live/in-memory only (now ALSO mirrored into this tweak's
//   own JSON file, which is a separate thing from the game's own
//   settings/save system) - opening the game's own settings menu and
//   hitting Apply will stomp the live values back to the last saved
//   preset. This tweak's own JSON file is unaffected by that and will
//   simply re-apply its values next launch.
// - Bloom lives in the same Volume system as MotionBlur but its sliders
//   were confirmed to do nothing in-game - the in-game Bloom toggle in
//   LocalGameOptionData is a plain bool with no backing intensity/
//   threshold/scatter fields, so the panel's old Bloom section was
//   writing values nothing ever reads and was removed. The "Bloom" row
//   now visible in Post FX is unrelated to any of that - it's just the
//   HDR toggle under a different label, per request, moved to the front
//   of the section.
//   Root cause for why it LOOKED dead beyond that: dozens of
//   BattleSkillViewEGO_* classes each carry their own scene-local
//   Volume with their own Bloom/DepthOfField/LiftGammaGain/
//   ColorAdjustments/MotionBlur references, driven every frame during
//   EGO skill animations - those local Volumes outrank whatever this
//   file writes to the global default stack while a skill's playing.
//   The extended Post FX controls below are worth testing outside
//   battle (lobby/story) where nothing else is fighting for the same
//   component.
// - Depth of Field was also in the extended Post FX list at one point but
//   has been removed entirely (per request) - confirmed to do nothing
//   in-game, unlike the rest of the extended set above which do work
//   outside battle. Unlike Bloom, no UI-relabeled substitute replaced it.
// - MotionBlur and the extended Post FX components all live in Unity's
//   Volume system, which re-blends every frame from whatever profiles
//   are active in the scene. A one-shot write to the runtime stack's
//   component gets overwritten almost immediately by that blend. To
//   make sliders actually stick, this file re-applies Post FX
//   values on a timer for as long as the panel is open (see
//   kPostFXReapplyInterval below) - a real, if inelegant, cost while
//   open. There's also a single one-shot apply of every setting right
//   after the panel is built (see gd_reapply_all_settings() in
//   GDScripts.m, called at the end of -buildPanel: below), so a
//   value restored from the JSON save file (or a fresh hardcoded
//   default) takes effect even if the person never opens the panel that
//   session - without that one-shot pass, Post FX in particular would
//   only ever reach the engine once the panel had been opened at least
//   once, since the reapply timer only runs while open. Display/
//   Rendering/urpAsset values (FPS, tex limit, render scale, MSAA) are
//   NOT blended and only need a single write per change, same as before.
// - Loading screens reset far more than just the Volume blend above -
//   urpAsset, the Volume stack, and camera components are all
//   recreated by Unity on a scene load, so EVERY setting in this panel
//   can silently revert on any transition through one, not just Post
//   FX. GDScripts.m's FPS120Controller already polled
//   GlobalGameManager.Instance.sceneState every 0.25s (originally just
//   to flip Menu/Combat FPS on entering/leaving a battle node); that
//   same poll now also detects the transition back to a non-battle
//   ("menu") scene and calls gd_reapply_all_settings() again, so a
//   loading screen re-lands every control instead of only FPS.
// - Camera AA is UNVALIDATED against the live binary (unlike the
//   Volume/QualitySettings/urpAsset paths above, which are proven):
//     - Camera.main requires a camera tagged "MainCamera" in the
//       active scene. A UI-heavy gacha/VN game like this may route
//       battle/story scenes through dedicated, untagged cameras
//       instead - if every Camera AA control is a no-op, start here.
//     - General method for checking any setter/method this file calls
//       before trusting it: the dump lists an "// RVA: 0x..." comment
//       above every method that's actually compiled into the binary.
//       A method with no RVA line (or missing from the dump entirely)
//       was stripped and WILL return NULL from gd_method, causing a
//       silent, permanent no-op no matter what the rest of this file
//       does - this is different from (and cheaper to rule out than)
//       a shader-stripping or wrong-Volume problem, and worth checking
//       first for any control that flatly does nothing.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h> // objc_msgSend prototype, for the dynamic UIGlassEffect/UICornerConfiguration/UIButtonConfiguration calls below
#import <string.h>
#import "GDScripts.h"
#import "ZSyslogController.h" // FPS120Controller + every non-UI engine script this file used to own directly - see that file's header
#import "ZTweakLog.h"
#import "BankTransplant.h"
#import "BundleDoctorSettings.h" // BundleDoctorSettings/BundleDoctorConfig - Auth section load/save, see -gd_loadAuthFields/-gd_persistAuthFields below
#import "BundleDoctorService.h"     // send-and-intercept: GitHub Actions doctor-bundle pipeline, see -loadModsTapped below
#import "PatchManifestNetwork.h"    // isZeroingEnabled/setZeroingEnabled: - Config section's "Disable FModManifest zeroing" switch, see -fmodZeroingDisableChanged: below
#import "BundleDoctorInstaller.h"   // backup+swap of the doctored bundle into place, mirrors BankTransplant's own pattern
#import "UnityCacheLocator.h"       // CAB-based auto-match for the doctor pipeline's download/install target - see -gd_doctorLocateInstallTargetForDoctoredURL:entryPath:inFolder:
#import "ModAssetLibrary.h"         // Mods Library accordion (organizational only) - see that file's header
#import "UnityBundleCAB.h"          // isUnityFSBundleAtPath: - content-based bundle detection for Load Mods' picker handler, see -gd_handleLoadModsPickedURLs:intoFolder:
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h> // UTType-based UIDocumentPickerViewController init, for the Mods section's "Import Bank Mod" button

#import "GDEmbeddedFont.h" // kExcelsiorSansTTF / kExcelsiorSansTTFLength - see that file's header

#pragma mark - Window discovery

static UIWindow *gd_key_window(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return [UIApplication sharedApplication].delegate.window;
}

#pragma mark - Accent color

// Single source of truth for the panel's green accent (slider fill, value
// labels, mode slider thumb) - fixed to #30D158 rather than
// UIColor.systemGreenColor so it's deterministic across appearance modes
// instead of tracking the system's light/dark green.
static UIColor *gd_accent_green_color(void) {
    return [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0];
}

// A punchier variant of the accent green, used ONLY for the slider/mode-
// slider fill so the bars pop against the frosted glass material. Derived
// from gd_accent_green_color (same hue) rather than a hand-picked hex value
// so it can't drift out of sync with the brand color, and kept out of
// gd_accent_green_color itself so everything else that reads that color
// (value labels, etc.) is completely unaffected - this only changes the
// bars, not the panel's color hierarchy.
static UIColor *gd_bar_fill_color(void) {
    UIColor *base = gd_accent_green_color();
    CGFloat h = 0, s = 0, b = 0, a = 0;
    [base getHue:&h saturation:&s brightness:&b alpha:&a];
    return [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.15) brightness:MIN(1.0, b * 1.12) alpha:a];
}

#pragma mark - Liquid Glass helpers
//
// iOS 26's UIKit Liquid Glass is shape-aware. For a UI made from two nearby
// glass shapes, Apple specifically provides UIGlassContainerEffect: the child
// UIGlassEffect views keep their own corner geometry, while the container
// blends nearby shapes into one continuous material.
//
// This dock therefore uses:
//   1. one UIGlassContainerEffect as the parent material compositor;
//   2. one rounded UIGlassEffect for the main panel;
//   3. one separately rounded UIGlassEffect for the pull tab.
//
// This is intentionally different from masking one giant glass view into a
// custom union path. A union mask can describe the silhouette, but it throws
// away the individual Liquid Glass shape information that UIKit uses when it
// merges adjacent elements.

static BOOL gd_has_liquid_glass(void) {
    static BOOL has;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        has = NO;
        if (@available(iOS 26.0, *)) {
            has = (NSClassFromString(@"UIGlassEffect") != nil &&
                   NSClassFromString(@"UIGlassContainerEffect") != nil);
        }
    });
    return has;
}

static UIVisualEffect *gd_make_glass_effect_style(NSInteger style, BOOL interactive, UIColor *tintColor) {
    if (gd_has_liquid_glass()) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (!glassClass) return nil;

        // IMPORTANT: use Apple's documented Regular style initializer.
        // Calling -init on UIGlassEffect is not the public construction path
        // for a visible Liquid Glass material.
        SEL factory = NSSelectorFromString(@"effectWithStyle:");
        id effect = nil;
        if ([glassClass respondsToSelector:factory]) {
            // UIGlassEffectStyleRegular == 0 on the current UIKit ABI.
            effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, factory, style);
        }
        if (!effect) {
            // Fallback for a build where the factory selector is unavailable.
            effect = [[glassClass alloc] init];
        }

        SEL setInteractive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:setInteractive]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, interactive);
        }

        // Tint is optional. The dock uses a very subtle neutral tint; the
        // slider pills deliberately use CLEAR glass with no tint so the
        // saturated slider fill remains visible through the material.
        SEL setTint = NSSelectorFromString(@"setTintColor:");
        if ([effect respondsToSelector:setTint]) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, setTint, tintColor);
        }
        return effect;
    }

    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}

static UIVisualEffect *gd_make_glass_effect(BOOL interactive) {
    return gd_make_glass_effect_style(0 /* UIGlassEffectStyleRegular */, interactive,
                                      [UIColor colorWithWhite:1.0 alpha:0.06]);
}

// Ground-truth check, not a guess: dumps every instance method AND
// property UIGlassEffect actually has on THIS device/OS build. tintColor
// is assumed via setTintColor:/respondsToSelector: in
// gd_make_glass_effect_style above, guarded so a missing selector just
// skips the tint rather than crashing - but "guarded against crashing"
// and "actually resolves and does something" are different claims, and
// two tint-alpha changes producing zero visible difference is exactly
// the signature of the former without the latter. Call once, read the
// log, and gd_make_glass_effect_style can be corrected to whatever the
// real selector/property is if setTintColor: isn't it.
static void gd_dump_glass_effect_instance_info(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) {
        ZLog(@"[GraphicsDebugOverlay] UIGlassEffect class not found");
        return;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(glassClass, &methodCount);
    ZLog(@"[GraphicsDebugOverlay] UIGlassEffect instance methods (%u):", methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        ZLog(@"[GraphicsDebugOverlay]   - %@", NSStringFromSelector(method_getName(methods[i])));
    }
    free(methods);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(glassClass, &propCount);
    ZLog(@"[GraphicsDebugOverlay] UIGlassEffect properties (%u):", propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        ZLog(@"[GraphicsDebugOverlay]   @property %s (%s)", property_getName(props[i]), property_getAttributes(props[i]));
    }
    free(props);
}

// Shared by the dock's chrome compositor and the pill compositor - both
// were building this by hand (class lookup, setSpacing: via objc_msgSend)
// with only the spacing value differing between them.
static UIVisualEffect *gd_make_glass_container_effect(CGFloat spacing) {
    if (!gd_has_liquid_glass()) return nil;
    Class containerClass = NSClassFromString(@"UIGlassContainerEffect");
    if (!containerClass) return nil;

    id effect = [[containerClass alloc] init];
    SEL setSpacing = NSSelectorFromString(@"setSpacing:");
    if ([effect respondsToSelector:setSpacing]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(effect, setSpacing, spacing);
    }
    return effect;
}

// Apply UIKit's iOS 26 corner configuration without requiring this tweak to
// compile against a newer SDK. The build currently has a lower deployment
// target, so the symbols are resolved dynamically at runtime.
//
// For the panel we use a container-concentric radius on ALL four corners.
// That means the panel gets proper outer corners at its top/bottom edges and
// still tracks the containing geometry instead of using an iPhone-specific
// hard-coded screen radius.
//
// For the tab we use a fixed radius. It is deliberately much smaller than
// half the 72pt tab height so it remains rectangular with rounded corners,
// rather than turning into the pill shape caused by a capsule/half-height
// radius.
static void gd_configure_glass_corners(UIView *view, CGFloat radius, BOOL concentric) {
    if (!view || !gd_has_liquid_glass()) return;

    Class radiusClass = NSClassFromString(@"UICornerRadius");
    Class configClass = NSClassFromString(@"UICornerConfiguration");
    if (!radiusClass || !configClass) return;

    SEL radiusSelector = concentric
        ? NSSelectorFromString(@"containerConcentricRadiusWithMinimum:")
        : NSSelectorFromString(@"fixedRadius:");

    SEL configSelector = NSSelectorFromString(@"configurationWithRadius:");
    SEL setConfiguration = NSSelectorFromString(@"setCornerConfiguration:");

    if (![radiusClass respondsToSelector:radiusSelector] ||
        ![configClass respondsToSelector:configSelector] ||
        ![view respondsToSelector:setConfiguration]) {
        return;
    }

    id radiusObject = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass,
                                                                radiusSelector,
                                                                radius);
    if (!radiusObject) return;

    id configuration = ((id (*)(id, SEL, id))objc_msgSend)(configClass,
                                                             configSelector,
                                                             radiusObject);
    if (!configuration) return;

    ((void (*)(id, SEL, id))objc_msgSend)(view,
                                           setConfiguration,
                                           configuration);
}

// Reliable custom corner radius for a UIButtonConfiguration-driven glass
// button (+[UIButtonConfiguration glassButtonConfiguration] and friends) -
// see gd_style_auth_verify_button's header comment below for the full
// postmortem of why gd_configure_glass_corners (the UIView.cornerConfiguration
// API that works fine on every plain UIVisualEffectView glass surface in
// this file) does NOT work here.
//
// Short version: a configuration-driven button's glass background is an
// internal subview that UIButton rebuilds from its *configuration object's*
// own -cornerStyle/-background.cornerRadius on every configuration-update
// pass - not from the button view's own cornerConfiguration property, which
// that subview never reads. So the fix has to mutate the configuration
// itself, not the view:
//   1. configuration.cornerStyle = Fixed (== 1) - the one corner style that
//      takes its radius from -background.cornerRadius verbatim, instead of
//      Capsule (glassButtonConfiguration's default), a system Large/Medium/
//      Small constant, or Dynamic's type-size-scaled radius.
//   2. configuration.background.cornerRadius = radius.
//   3. Write the mutated configuration back via -setConfiguration: so
//      UIButton actually picks up the change - configuration structs/objects
//      obtained via the getter are not observed in place.
// Because the radius now lives on the model object every rebuild reads
// from (rather than a view-side property that rebuild never consults), it
// survives taps/highlight/disabled and any other automatic
// configurationUpdateHandler-driven pass without needing to be reasserted -
// though call sites still hook configurationUpdateHandler to call this
// again defensively, since "the button rebuilds its glass shape from
// something other than the property we just set" is exactly the failure
// mode this function exists to route around, and re-deriving from the
// current configuration each time costs nothing.
//
// Resolved dynamically like the rest of this file's Liquid Glass API
// surface (see gd_configure_glass_corners above) - harmless no-op via
// respondsToSelector on anything pre-iOS-26 or if Apple ever renames this.
static void gd_configure_glass_button_fixed_corner_radius(UIButton *button, CGFloat radius) {
    if (!button) return;

    SEL getConfiguration = NSSelectorFromString(@"configuration");
    if (![button respondsToSelector:getConfiguration]) return;
    id configuration = ((id (*)(id, SEL))objc_msgSend)(button, getConfiguration);
    if (!configuration) return;

    // UIButtonConfigurationCornerStyleFixed == 1 on the current UIKit ABI
    // (Dynamic=0, Fixed=1, Capsule=2, Large=3, Medium=4, Small=5).
    SEL setCornerStyle = NSSelectorFromString(@"setCornerStyle:");
    if ([configuration respondsToSelector:setCornerStyle]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(configuration, setCornerStyle, 1 /* Fixed */);
    }

    SEL getBackground = NSSelectorFromString(@"background");
    if ([configuration respondsToSelector:getBackground]) {
        id background = ((id (*)(id, SEL))objc_msgSend)(configuration, getBackground);
        SEL setCornerRadius = NSSelectorFromString(@"setCornerRadius:");
        if (background && [background respondsToSelector:setCornerRadius]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(background, setCornerRadius, radius);
        }
    }

    SEL setConfiguration = NSSelectorFromString(@"setConfiguration:");
    if ([button respondsToSelector:setConfiguration]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, setConfiguration, configuration);
    }
}

// Native Liquid Glass BUTTON styling - distinct from the hand-rolled
// UIGlassEffect/UIGlassContainerEffect compositing used for the dock/pills
// above. iOS 26 gives UIButton a first-class glass look via
// +[UIButtonConfiguration glassButtonConfiguration], which is the actual
// "native Liquid Glass" button API (as opposed to a UIVisualEffectView
// manually parented behind a button). Resolved dynamically for the same
// lower-deployment-target reason as the rest of this file's Liquid Glass
// calls. Falls back to an approximation of the dock's own glass material
// on pre-iOS-26 so the reset button still reads as "glass" there too.
static void gd_style_button_as_native_glass(UIButton *button, NSString *title, UIColor *tintColor) {
    if (@available(iOS 26.0, *)) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        if (configClass && [configClass respondsToSelector:glassSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, glassSel);
            if (configuration) {
                SEL setTitle = NSSelectorFromString(@"setTitle:");
                if ([configuration respondsToSelector:setTitle]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setTitle, title);
                }
                SEL setBaseForeground = NSSelectorFromString(@"setBaseForegroundColor:");
                if (tintColor && [configuration respondsToSelector:setBaseForeground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseForeground, tintColor);
                }
                SEL setConfig = NSSelectorFromString(@"setConfiguration:");
                if ([button respondsToSelector:setConfig]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
                    return;
                }
            }
        }
    }

    // Pre-iOS-26 fallback: approximate glass with the same translucent
    // material style used elsewhere in this file for non-Liquid-Glass
    // devices, since UIButtonConfiguration's native glass style doesn't
    // exist there.
    [button setTitle:title forState:UIControlStateNormal];
    if (tintColor) [button setTitleColor:tintColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

// Icon-only counterpart to gd_style_button_as_native_glass - same native
// +[UIButtonConfiguration glassButtonConfiguration] API, so it gets the
// same free press/release glass animation, but with an image instead of
// a title. Used for the blacklist entry rows' small "x" remove button -
// see gd_make_blacklist_entry_row. Falls back to a small flat translucent
// circle pre-iOS-26, matching the fallback style
// gd_style_button_as_native_glass uses for its own button.
static void gd_style_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
    if (@available(iOS 26.0, *)) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        if (configClass && [configClass respondsToSelector:glassSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, glassSel);
            if (configuration) {
                SEL setImage = NSSelectorFromString(@"setImage:");
                if ([configuration respondsToSelector:setImage]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setImage, image);
                }
                SEL setBaseForeground = NSSelectorFromString(@"setBaseForegroundColor:");
                if (tintColor && [configuration respondsToSelector:setBaseForeground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseForeground, tintColor);
                }
                SEL setConfig = NSSelectorFromString(@"setConfiguration:");
                if ([button respondsToSelector:setConfig]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
                    return;
                }
            }
        }
    }

    // Pre-iOS-26 fallback: small flat translucent circle, same material as
    // gd_style_button_as_native_glass's own pre-26 fallback.
    [button setImage:image forState:UIControlStateNormal];
    if (tintColor) button.tintColor = tintColor;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    button.layer.cornerRadius = 9;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

// Same 6pt radius as the Auth section's own text fields
// (gd_wrap_field_in_native_glass's own cornerRadius argument at its two
// call sites) - kept as a named constant so the Verify button below and
// the fields it sits next to can't drift apart.
static const CGFloat kGDAuthFieldCornerRadius = 6;

// Auth section's "Verify" button - gd_style_button_as_native_glass on
// its own gives every button iOS 26's default fully-rounded glass pill,
// which reads as a mismatched shape sitting directly against the
// square-ish (6pt corner) PAT field beside it. Per the person's spec,
// this reapplies that same 6pt radius on top, via the identical
// gd_configure_glass_corners call the fields themselves use - and does
// it every time the button's glass configuration gets rebuilt, since
// restyling (see -gd_authVerifyTapped:'s "Verifying…"/"Verify" swap)
// replaces the configuration and would otherwise silently revert to
// the pill. Pre-iOS-26, gd_style_button_as_native_glass's own fallback
// never sets a cornerRadius at all (defaults to a plain square corner),
// so the explicit 6pt there is just for consistency across OS versions
// rather than fixing a visible mismatch.
// THE PREVIOUS FIX, AND WHY IT STILL SHOWED A PILL: the original attempt
// called gd_configure_glass_corners on the button itself - the same
// UICornerConfiguration/-setCornerConfiguration: call that reliably
// squares off every plain UIVisualEffectView glass surface elsewhere in
// this file (the dock, the pull tab, every gd_wrap_field_in_native_glass
// field). That's a UIView-level property. But +[UIButtonConfiguration
// glassButtonConfiguration]'s glass material is an internal subview that
// UIButton rebuilds from its *configuration object's* own -cornerStyle
// (Capsule by default) and, only when that's Fixed, -background.cornerRadius
// - never from the button view's own cornerConfiguration, which that
// subview simply doesn't consult. A follow-up attempt reasserted the same
// button-level cornerConfiguration from configurationUpdateHandler (fired
// after every configuration-driven rebuild - any state change included,
// not just this file's two restyle call sites), which is the right hook
// but the wrong property: it kept re-setting something the rebuild never
// reads, so the button still snapped back to the capsule the instant it
// was pressed. Both attempts were "reassert a corner radius after the
// rebuild" - the actual bug was which corner radius.
//
// Fix: gd_configure_glass_button_fixed_corner_radius (above) mutates the
// *configuration's* cornerStyle/background.cornerRadius instead, which is
// what the rebuild actually reads, and writes it back via -setConfiguration:
// so UIButton picks up the change. configurationUpdateHandler is kept as a
// defensive re-assertion on top of that - now calling the corrected
// function - since it costs nothing and this exact class of bug (assuming
// a property is read that isn't) is the one that burned this control twice
// already.
static void gd_style_auth_verify_button(UIButton *button, NSString *title) {
    gd_style_button_as_native_glass(button, title, gd_accent_green_color());
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    gd_configure_glass_button_fixed_corner_radius(button, kGDAuthFieldCornerRadius);
    if (!gd_has_liquid_glass()) {
        button.layer.cornerRadius = kGDAuthFieldCornerRadius;
        button.clipsToBounds = YES;
    }

    SEL setUpdateHandler = NSSelectorFromString(@"setConfigurationUpdateHandler:");
    if ([button respondsToSelector:setUpdateHandler]) {
        void (^reassertCorners)(__kindof UIButton *) = ^(__kindof UIButton *btn) {
            gd_configure_glass_button_fixed_corner_radius(btn, kGDAuthFieldCornerRadius);
        };
        ((void (*)(id, SEL, id))objc_msgSend)(button, setUpdateHandler, reassertCorners);
    }
}

// Swaps the Verify button between "Verify" and "Verifying…" in place -
// same pill, same size, just the label content cross-fading rather than
// snapping instantly. gd_style_auth_verify_button itself has no
// animation of its own (it's a synchronous configuration rebuild), so
// this wraps that same call in a UIView cross-dissolve transition on
// the button rather than duplicating any of its styling logic. Snapshot-
// based (transitionWithView: diffs the view's rendered content before
// and after the animations block runs), so it doesn't matter that
// gd_style_auth_verify_button replaces the button's underlying
// UIButtonConfiguration/title subview wholesale rather than mutating
// existing text in place - the transition only cares about the button's
// rendered appearance before vs. after, not how it got there.
// -gd_authVerifyTapped: calls this instead of gd_style_auth_verify_button
// directly for both the "Verify" -> "Verifying…" swap and the revert
// back, so the label content fades between the two states in the same
// button instead of the earlier behavior of a separate "Verifying…"
// button replacing it outright. The button's very first styling (its
// initial creation in -buildPanel:) still goes through
// gd_style_auth_verify_button directly, with no transition wanted for
// that one-time setup.
static void gd_crossfade_auth_verify_button_title(UIButton *button, NSString *title) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        gd_style_auth_verify_button(button, title);
    }
                     completion:nil];
}

// Associated-object key backing the generic hold-to-confirm gesture
// (see gd_attach_hold_to_confirm and -gd_handleHoldToConfirmGesture:
// below) - stashed per-button so the shared CADisplayLink-driven tick
// handler can run whichever button's own completion block once its
// hold completes, without every call site having to pass it through
// manually.
static void * const kGDHoldConfirmBlockKey = (void *)&kGDHoldConfirmBlockKey; // copied void(^)(void), run once the hold completes

// Associated-object keys backing the capsule-expansion pieces built by
// gd_attach_delete_capsule below - the sibling view appended after the
// X button's trailing edge, the layout constraint driving its width,
// the "Delete" label revealed inside it, and the two red progress-fill
// layers (one in the expansion view, one in the X button itself) that
// together sweep across the WHOLE capsule once expanded. Stashed per
// button (same pattern as kGDHoldConfirmBlockKey) so
// -gd_handleHoldToConfirmGesture:/-gd_holdConfirmTick: can drive them
// without every call site threading them through manually.
static void * const kGDHoldConfirmExpansionViewKey = (void *)&kGDHoldConfirmExpansionViewKey;
static void * const kGDHoldConfirmExpansionWidthKey = (void *)&kGDHoldConfirmExpansionWidthKey;
static void * const kGDHoldConfirmDeleteLabelKey = (void *)&kGDHoldConfirmDeleteLabelKey;
static void * const kGDHoldConfirmExpansionFillKey = (void *)&kGDHoldConfirmExpansionFillKey;
static void * const kGDHoldConfirmButtonFillKey = (void *)&kGDHoldConfirmButtonFillKey;
// Real Liquid Glass backing for the capsule (see gd_attach_delete_capsule
// below) - the actual UIVisualEffectView/UIGlassEffect material, plus the
// shared window-level compositor it's parented in. Same "real glass, not
// a flat colored view" system GDCapsuleSlider's own trackGlass uses (see
// -[GDCapsuleSlider setGlassEnabled:]) - this is that same technique
// applied to a hold-to-confirm capsule instead of a slider pill.
static void * const kGDHoldConfirmGlassViewKey = (void *)&kGDHoldConfirmGlassViewKey;
static void * const kGDHoldConfirmGlassHostKey = (void *)&kGDHoldConfirmGlassHostKey;

// Target width (points) of the revealed "Delete" capsule segment, and
// how long the reveal spring takes to settle - independent of
// kGDHoldConfirmDuration below, which times the red fill instead.
// Duration/damping/velocity deliberately match GDCapsuleSlider's own
// -setPillTouching: spring exactly (same "system"), since this is that
// same press-reacts-immediately capsule-reshape mechanic just applied
// to width instead of height.
static const CGFloat kGDDeleteCapsuleExpandedWidth = 60;
static const NSTimeInterval kGDDeleteCapsuleSnapDuration = 0.28;
static const CGFloat kGDDeleteCapsuleSpringDamping = 0.6;
static const CGFloat kGDDeleteCapsuleSpringVelocity = 0.4;

// Builds the capsule "expansion" companion view for `button` and
// inserts it into `parent` (button's own superview), immediately
// BEFORE button's leading edge. This - not the button itself - is what
// grows when the hold begins: the X button never resizes or
// repositions, so its glyph is pixel-for-pixel stationary throughout,
// while this view (plus the matching fill layer dropped into the
// button itself, see below) is "the glass" that visibly expands to
// form one continuous capsule shape, growing to the LEFT (toward
// lower x) rather than out past the button's trailing edge - the
// button typically sits at its row's own trailing/far-right extreme,
// so growing rightward would just push the capsule off the edge of
// the panel; growing left instead reveals the "Delete" text into
// space the row already has, and reads as "the glass sliding out from
// behind the fixed X" rather than the X itself moving.
//
// Rebuilt from scratch on the same width-constraint + spring-animate
// mechanic GDCapsuleSlider's own fat/thin press animation uses (see
// -setPillTouching: above): a single NSLayoutConstraint drives the
// geometry and -layoutIfNeeded is animated inside a
// usingSpringWithDamping: block, rather than anything frame-based.
// The button's own native-glass chrome already supplies a rounded
// silhouette at rest, so this view only needs a rounded LEADING cap
// (kCALayerMinXMinYCorner/kCALayerMinXMaxYCorner) - its trailing edge
// butts flush against the button with no rounding, so the two read as
// one pill once expanded, rather than two visibly separate shapes.
//
// Starts at zero width, so at rest it's fully invisible and reserves no
// visible space - -gd_handleHoldToConfirmGesture:/-gd_holdConfirmTick:
// own growing it back down again on release.
//
// `glassHost` is the shared window-level UIGlassContainerEffect content
// view (the panel's sliderGlassContent - same one GDCapsuleSlider's own
// trackGlass pills live in) that a real UIGlassEffect view has to be
// parented in to render as actual Liquid Glass material rather than a
// flat translucent rectangle - see the "Liquid Glass helpers" pragma
// mark up top. When nil (pre-iOS-26, or a caller that hasn't wired one
// up), this falls back to the flat CALayer-only look the capsule always
// had - it just doesn't get the real morphing material on top of it.
static void gd_attach_delete_capsule(UIButton *button, UIView *parent, UIView *glassHost) {
    if (!parent) return; // defensive - button should already be in its row by the time this runs

    if (gd_has_liquid_glass() && glassHost) {
        // The actual glass: a real interactive UIGlassEffect, faintly
        // red-tinted so it reads as "danger" material even before the
        // red progress fill (still drawn on top, unchanged - see
        // -gd_holdConfirmTick:) starts sweeping across it. Lives in
        // glassHost, NOT as a subview of `expansion`/`button` - same
        // reasoning as trackGlass: only a view inside the shared
        // UIGlassContainerEffect compositor gets real Liquid Glass
        // shape-aware rendering. Starts at alpha 0/button's own resting
        // frame; -gd_handleHoldToConfirmGesture: fades it in and grows
        // its frame to the union of button+expansion inside the SAME
        // spring-animation block that already drives widthConstraint,
        // so Core Animation interpolates its geometry along with
        // everything else in that block - this is what makes it morph
        // continuously rather than snapping, exactly like trackGlass
        // riding trackHeightConstraint's own animation block.
        UIVisualEffect *effect = gd_make_glass_effect_style(0 /* UIGlassEffectStyleRegular */, YES,
                                                              [UIColor colorWithRed:1.0 green:0.12 blue:0.12 alpha:0.22]);
        UIVisualEffectView *capsuleGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
        capsuleGlass.userInteractionEnabled = NO; // decorative only - button's own long-press gesture owns touches
        capsuleGlass.opaque = NO;
        capsuleGlass.clipsToBounds = YES;
        capsuleGlass.layer.cornerCurve = kCACornerCurveContinuous;
        capsuleGlass.alpha = 0; // invisible at rest - the button's own native glass silhouette reads fine on its own until a hold begins
        [glassHost addSubview:capsuleGlass];
        gd_configure_glass_corners(capsuleGlass, 9, NO); // 9 == half of every delete button's fixed 18pt height, so it always reads as a capsule, at any width
        objc_setAssociatedObject(button, kGDHoldConfirmGlassViewKey, capsuleGlass, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(button, kGDHoldConfirmGlassHostKey, glassHost, OBJC_ASSOCIATION_RETAIN);
    }

    UIView *expansion = [[UIView alloc] init];
    expansion.translatesAutoresizingMaskIntoConstraints = NO;
    expansion.clipsToBounds = YES;
    expansion.userInteractionEnabled = NO; // purely decorative - the long-press stays owned by `button`
    expansion.layer.cornerCurve = kCACornerCurveContinuous;
    [parent addSubview:expansion];
    // Brought to the FRONT (not sent to the back): `button` may share
    // its row with other, unrelated controls sitting further toward
    // the leading edge (e.g. the folder row's Add/rename buttons) -
    // the expanding glass should slide out on top of those while
    // mid-hold, not underneath them, so the red fill and "Delete"
    // label stay legible.
    [parent bringSubviewToFront:expansion];
    parent.clipsToBounds = NO; // let the capsule overhang the row's resting bounds while expanded - see the header comment above

    UILabel *deleteLabel = [[UILabel alloc] init];
    deleteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    deleteLabel.text = @"Delete";
    deleteLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    deleteLabel.textColor = [UIColor whiteColor]; // white, not red - it already sits on the red progress fill, red-on-red had no contrast
    deleteLabel.alpha = 0; // faded in once the capsule has room for it - see -gd_handleHoldToConfirmGesture:
    [expansion addSubview:deleteLabel];

    // Fill layers are still positioned by explicit .frame in
    // -gd_holdConfirmTick:/-gd_resetHoldConfirmButton: (not auto
    // layout - a CADisplayLink-driven per-frame update is cheapest as
    // a raw frame write), so anchorPoint here is cosmetically (0,0)
    // only; it has no effect once .frame starts being set directly.
    CALayer *expansionFill = [CALayer layer];
    expansionFill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor; // same red/alpha as the Syslog button's own fill
    expansionFill.anchorPoint = CGPointMake(0, 0);
    expansionFill.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner; // rounds only the capsule's outer/leading cap
    expansionFill.cornerCurve = kCACornerCurveContinuous;
    [expansion.layer insertSublayer:expansionFill atIndex:0];

    CALayer *buttonFill = [CALayer layer];
    buttonFill.backgroundColor = expansionFill.backgroundColor;
    buttonFill.anchorPoint = CGPointMake(0, 0);
    buttonFill.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner; // rounds only the capsule's trailing cap - now the outer edge, since expansion grows off the button's LEADING side
    buttonFill.cornerCurve = kCACornerCurveContinuous;
    // Same trick as kGDPillHoldConfirmFillLayerKey/syslogButtonFillLayer -
    // inserted directly as a sublayer so it survives
    // gd_style_icon_button_as_native_glass rebuilding the button's own
    // UIButtonConfiguration-owned subviews.
    [button.layer insertSublayer:buttonFill atIndex:0];

    // Pinned by TRAILING anchor to the button's leading edge (not the
    // other way around) - this is what makes the view grow leftward as
    // its width increases: the flush edge against the button stays
    // put, and the free (leading) edge is pushed further left.
    NSLayoutConstraint *widthConstraint = [expansion.widthAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [expansion.trailingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [expansion.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [expansion.heightAnchor constraintEqualToAnchor:button.heightAnchor],
        widthConstraint,

        [deleteLabel.centerYAnchor constraintEqualToAnchor:expansion.centerYAnchor],
        [deleteLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:expansion.leadingAnchor constant:8],
        [deleteLabel.trailingAnchor constraintLessThanOrEqualToAnchor:expansion.trailingAnchor constant:-4],
    ]];

    objc_setAssociatedObject(button, kGDHoldConfirmExpansionViewKey, expansion, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kGDHoldConfirmExpansionWidthKey, widthConstraint, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kGDHoldConfirmDeleteLabelKey, deleteLabel, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kGDHoldConfirmExpansionFillKey, expansionFill, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kGDHoldConfirmButtonFillKey, buttonFill, OBJC_ASSOCIATION_RETAIN);
}

// Wires up `button` so that holding it for 1.5s - not just tapping it -
// runs `onConfirm`. This is the safety net requested for every
// destructive X icon in the Mods Library accordion (folder delete,
// entry delete): -gd_handleHoldToConfirmGesture:/-gd_holdConfirmTick:
// below own the actual timing, the capsule-expand reveal, and the red
// progress-fill (see gd_attach_delete_capsule above) - CADisplayLink-
// driven via a minimumPressDuration:0 long-press so this owns per-frame
// progress rather than only learning the hold completed. A plain quick
// tap/release instead collapses the capsule back down and plays an
// error haptic (see -gd_handleHoldToConfirmGesture:), which does the
// "you need to hold this" job. `onConfirm` is a caller-supplied
// completion block instead of one hardcoded action. `glassHost` is
// forwarded straight to gd_attach_delete_capsule - see its header
// comment for why the capsule needs a shared window-level compositor
// to render real morphing Liquid Glass instead of a flat rectangle.
static void gd_attach_hold_to_confirm(UIButton *button, id target, UIView *glassHost, void (^onConfirm)(void)) {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(gd_handleHoldToConfirmGesture:)];
    press.minimumPressDuration = 0; // -gd_holdConfirmTick: owns the real timing, same reasoning as the Syslog button's hold
    press.cancelsTouchesInView = NO;
    [button addGestureRecognizer:press];
    objc_setAssociatedObject(button, kGDHoldConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
    gd_attach_delete_capsule(button, button.superview, glassHost);
}

// Associated-object keys for gd_attach_pill_hold_to_confirm below -
// same idea as kGDHoldConfirmBlockKey above, plus one for the fill
// layer itself so it's created once per button and reused (mirrors
// syslogButtonFillLayer's own "created lazily on first Began, persists
// after that" comment).
static void * const kGDPillHoldConfirmBlockKey = (void *)&kGDPillHoldConfirmBlockKey;
static void * const kGDPillHoldConfirmFillLayerKey = (void *)&kGDPillHoldConfirmFillLayerKey;

// Per-button hold duration override (NSNumber, seconds), read by
// -gd_pillHoldConfirmTick:. Absent for every button attached via the
// plain gd_attach_pill_hold_to_confirm below, which keeps them all on
// that method's own hardcoded kGDPillHoldConfirmDuration (1.5s) exactly
// as before - this key only ever gets set by
// gd_attach_pill_hold_to_confirm_duration, currently just "Hard Assets
// Reset" (3s, deliberately longer given how much more that one throws
// away - see -hardAssetsResetTapped).
static void * const kGDPillHoldConfirmDurationKey = (void *)&kGDPillHoldConfirmDurationKey;

// Wide-button counterpart to gd_attach_hold_to_confirm above - wires up
// `button` so that holding it for 1.5s runs `onConfirm`, with a red
// fill sweeping left-to-right across the whole button as visual
// progress. This is literally the Syslog button's own hold-to-confirm
// mechanism (see -handleSyslogButtonLongPress:/-gd_syslogHoldTick:),
// factored out so any other wide button - currently just "Restore
// Bundles & Banks" - can reuse the same behavior instead of firing on
// a plain tap. Same minimumPressDuration:0 + CADisplayLink shape as
// gd_attach_hold_to_confirm, and the same "quick tap/early release
// plays an error haptic" contract - see
// -gd_handlePillHoldToConfirmGesture:.
static void gd_attach_pill_hold_to_confirm(UIButton *button, id target, void (^onConfirm)(void)) {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(gd_handlePillHoldToConfirmGesture:)];
    press.minimumPressDuration = 0;
    press.cancelsTouchesInView = NO;
    [button addGestureRecognizer:press];
    objc_setAssociatedObject(button, kGDPillHoldConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
}

// Same wide-button hold-to-confirm as gd_attach_pill_hold_to_confirm
// above, but with a caller-specified hold duration instead of that
// method's hardcoded 1.5s - see kGDPillHoldConfirmDurationKey. Delegates
// to gd_attach_pill_hold_to_confirm for the actual gesture/block wiring
// so the two never drift apart, then stamps the duration override on
// top of it.
static void gd_attach_pill_hold_to_confirm_duration(UIButton *button, id target, NSTimeInterval duration, void (^onConfirm)(void)) {
    gd_attach_pill_hold_to_confirm(button, target, onConfirm);
    objc_setAssociatedObject(button, kGDPillHoldConfirmDurationKey, @(duration), OBJC_ASSOCIATION_RETAIN);
}

#pragma mark - Engine scripts
//
// Every IL2CPP-mediated engine call this panel makes - urpAsset/
// QualitySettings/Volume/renderer-feature/camera-data plumbing, the
// hardcoded setting defaults, the current-value globals that back
// every row below, and JSON settings persistence - lives in
// GDScripts.h/.m now, not in this file. This file only builds/lays
// out UI and calls into that dedicated scripts file (gd_set_*,
// gd_apply_*, gd_camera_data_set_*, gd_reapply_*, the g_* current-
// value globals, the kDefault*/kURPPostEffects/kMSAASteps/
// kAAModeSteps/kAAQualitySteps tables) to actually push a change to
// the engine.

#pragma mark - Capsule slider (Control Center / Now Playing style)
//
// Standard UISlider swapped out for this: a filled rounded-capsule
// track you drag anywhere on, like iOS's volume bar or the scrubber
// on the Lock Screen Now Playing card. No separate thumb knob to eat
// horizontal space, which matters more here now that rows are packed
// tighter to fit a scrolling panel. API surface (minimumValue/
// maximumValue/value + UIControlEventValueChanged) intentionally
// mirrors UISlider so row-building code below barely had to change.
//
// Also owns the default-position tick + snap-to-default behavior:
// every slider in the panel can carry a `defaultValue`; when set, a
// thin tick is drawn on the track at that position, and a drag that
// ends within a small fraction of the track's length from it snaps
// exactly onto it (with a light selection haptic) instead of leaving
// the value slightly off.

// Apple's own pill scrubbers (Music mini-player, Control Center audio
// slider) share one mechanic that plain UISlider doesn't: there's no
// separate thumb knob, you drag anywhere on the pill, and the pill
// itself grows thicker the moment you touch it and relaxes back to a
// thin line on release. That grow/relax + no-thumb behavior - not any
// specific reusable Apple class, since UIKit doesn't expose one to
// third-party apps - is what's being reproduced here. The slider
// already did drag-anywhere; what's new is the thickness animation,
// the continuous corner curve, and haptic feedback on grab/release/
// clamp/snap, all lifted from that same Apple interaction.
static const CGFloat kCapsuleSliderHeight = 18;      // full footprint - shrunk from 22 so rows are more compact
static const CGFloat kCapsuleSliderThinHeight = 6;   // resting thickness
static const CGFloat kCapsuleSliderFatHeight = 18;   // thickness while touched
static const CGFloat kDefaultSnapFraction = 0.035;   // fraction of the slider's range within which a drag release snaps onto the default tick

// Fill view for the capsule slider. Normally rounded on all four corners,
// but its trailing (right) corners become square at a non-extreme default
// value or indicatorValues tick so the fill terminates cleanly at that
// marker. The mask is updated as a discrete state change; there is
// intentionally no transition.
@interface GDFillView : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign, getter=isTrailingSquared) BOOL trailingSquared;
@end

@implementation GDFillView {
    CAShapeLayer *_maskLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _maskLayer = [CAShapeLayer new];
        self.layer.mask = _maskLayer;
    }
    return self;
}

- (UIBezierPath *)gd_pathSquaredTrailing:(BOOL)squared {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return [UIBezierPath bezierPath];
    CGFloat r = MIN(self.cornerRadius, bounds.size.height / 2.0);
    UIRectCorner corners = squared ? (UIRectCornerTopLeft | UIRectCornerBottomLeft) : UIRectCornerAllCorners;
    return [UIBezierPath bezierPathWithRoundedRect:bounds byRoundingCorners:corners cornerRadii:CGSizeMake(r, r)];
}

- (void)gd_applyMask {
    UIBezierPath *path = [self gd_pathSquaredTrailing:self.trailingSquared];
    _maskLayer.frame = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _maskLayer.path = path.CGPath;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self gd_applyMask];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    if (_cornerRadius == cornerRadius) return;
    _cornerRadius = cornerRadius;
    [self gd_applyMask];
}

- (void)setTrailingSquared:(BOOL)squared {
    if (_trailingSquared == squared) return;
    _trailingSquared = squared;
    [self gd_applyMask];
}

@end

@interface GDCapsuleSlider : UIControl
@property (nonatomic, assign) float minimumValue;
@property (nonatomic, assign) float maximumValue;
@property (nonatomic, assign) float value;
@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, assign) float defaultValue;    // only meaningful once hasDefaultValue is YES
@property (nonatomic, assign) BOOL hasDefaultValue;  // controls both tick visibility and snap-on-release
@property (nonatomic, assign) float step;            // 0 = continuous; otherwise value snaps to minimumValue + N*step
// Extra always-visible marks drawn with the exact same styling as the
// default-position tick above, for sliders that want more than one
// reference point on the track (e.g. Render Scale's low/med/high). These
// are independent of defaultValue/hasDefaultValue, so a slider can carry
// both its own default tick and any number of these.
@property (nonatomic, copy) NSArray<NSNumber *> *indicatorValues;
@end

@interface GDCapsuleSlider ()
@property (nonatomic, strong) UIView *track;                  // lightweight track; do NOT allocate a Liquid Glass effect per slider
@property (nonatomic, strong) GDFillView *fill;
@property (nonatomic, strong) UIView *defaultTick;             // thin marker above the track at the default position; sibling of track
@property (nonatomic, strong) NSMutableArray<UIView *> *indicatorTicks; // one per entry in indicatorValues, styled like defaultTick
@property (nonatomic, strong) NSLayoutConstraint *fillWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *trackHeightConstraint;
@property (nonatomic, assign) BOOL touching;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;  // real UIGlassEffect in the dedicated pill compositor
@property (nonatomic, assign) BOOL glassEnabled;               // set by the panel controller based on scroll position
@property (nonatomic, weak) UIView *glassHost;                 // dedicated pill-glass container contentView
@end

@implementation GDCapsuleSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimumValue = 0;
        _maximumValue = 1;
        _value = 0;
        _fillColor = gd_bar_fill_color();
        _hasDefaultValue = NO;
        _step = 0;
        _indicatorTicks = [NSMutableArray new];

        // Apple explicitly warns that too many Liquid Glass effects can degrade
        // performance. This tweak can display a large number of sliders at once,
        // so the slider track is deliberately a normal translucent view. The
        // expensive Liquid Glass material is reserved for the dock chrome.
        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        self.track.backgroundColor = UIColor.clearColor;
        self.track.userInteractionEnabled = NO;
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
        self.track.clipsToBounds = YES;
        [self addSubview:self.track];

        self.fill = [[GDFillView alloc] init];
        self.fill.translatesAutoresizingMaskIntoConstraints = NO;
        self.fill.backgroundColor = [_fillColor colorWithAlphaComponent:1.0];
        self.fill.userInteractionEnabled = NO;
        [self.track addSubview:self.fill];

        [NSLayoutConstraint activateConstraints:@[
            [self.track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [self.fill.leadingAnchor constraintEqualToAnchor:self.track.leadingAnchor],
            [self.fill.topAnchor constraintEqualToAnchor:self.track.topAnchor],
            [self.fill.bottomAnchor constraintEqualToAnchor:self.track.bottomAnchor],
        ]];
        self.trackHeightConstraint = [self.track.heightAnchor constraintEqualToConstant:kCapsuleSliderThinHeight];
        self.trackHeightConstraint.active = YES;
        self.fillWidthConstraint = [self.fill.widthAnchor constraintEqualToConstant:0];
        self.fillWidthConstraint.active = YES;

        // Default-position tick: a thin mark hovering just above the track,
        // the way Apple's own Control Center sliders show their default
        // position, rather than a bar bisecting the pill. Frame-based (not
        // constraint-based) since its x position is a function of
        // defaultValue/min/max that's cheapest to recompute in
        // -layoutSubviews alongside the corner-radius updates that already
        // happen there. Added directly to `self` (not `track`) so its
        // position is independent of the track's thin/fat animation.
        self.defaultTick = [[UIView alloc] init];
        self.defaultTick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.defaultTick.userInteractionEnabled = NO;
        self.defaultTick.hidden = YES;
        [self addSubview:self.defaultTick];

        // A single long-press recognizer with zero minimum duration fires its
        // Began state the instant a finger touches down - before any
        // movement - which is what makes the fat/thin expand animation react
        // to a press rather than waiting for a drag to be recognized. It
        // then tracks Changed while held (drag-anywhere) and Ended/Cancelled
        // on lift, so it replaces the old separate pan + tap recognizers.
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0;
        [self addGestureRecognizer:press];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.trackHeightConstraint.constant;
    self.track.layer.cornerRadius = h / 2.0;
    self.fill.cornerRadius = h / 2.0;
    if (@available(iOS 13.0, *)) {
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
    }
    if (self.trackGlass) {
        // trackGlass.effect is a real UIGlassEffect (see -setGlassEnabled:),
        // not a plain translucency blur. Genuine Liquid Glass material is
        // shaped declaratively through UICornerConfiguration - the same API
        // used for panelGlass/handleGlass above - not through a CALayer
        // cornerRadius mask. A plain cornerRadius still clips the backing
        // UIVisualEffectView's layer, but it does not reshape the glass
        // material itself, so the pill kept its square silhouette until a
        // touch forced UIKit to re-resolve the glass shape. Configuring the
        // real corner shape here, every layout pass, fixes that.
        gd_configure_glass_corners(self.trackGlass, h / 2.0, NO);
        self.trackGlass.layer.cornerRadius = h / 2.0;
        self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;

        // trackGlass is a sibling of panelGlass inside the
        // UIGlassContainerEffect, so keep its geometry in the container's
        // coordinate space as the slider grows/shrinks while pressed.
        UIView *host = self.trackGlass.superview ?: self.glassHost;
        if (host) {
            self.trackGlass.frame = [self.track convertRect:self.track.bounds toView:host];
        }
    }
    [self updateFillForCurrentValue];
    [self updateDefaultTickPosition];
    [self updateIndicatorTickPositions];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kCapsuleSliderHeight);
}

- (void)setValue:(float)value {
    float clamped = MAX(self.minimumValue, MIN(self.maximumValue, value));
    if (self.step > 0) {
        clamped = self.minimumValue + roundf((clamped - self.minimumValue) / self.step) * self.step;
        clamped = MAX(self.minimumValue, MIN(self.maximumValue, clamped));
    }
    _value = clamped;
    [self updateFillForCurrentValue];
}

- (void)setStep:(float)step {
    _step = step;
    self.value = self.value; // re-quantize the current value onto the new grid
}

- (void)setMinimumValue:(float)minimumValue {
    _minimumValue = minimumValue;
    [self updateFillForCurrentValue];
    [self updateDefaultTickPosition];
    [self updateIndicatorTickPositions];
}

- (void)setMaximumValue:(float)maximumValue {
    _maximumValue = maximumValue;
    [self updateFillForCurrentValue];
    [self updateDefaultTickPosition];
    [self updateIndicatorTickPositions];
}

- (void)setIndicatorValues:(NSArray<NSNumber *> *)indicatorValues {
    _indicatorValues = [indicatorValues copy];
    for (UIView *tick in self.indicatorTicks) [tick removeFromSuperview];
    [self.indicatorTicks removeAllObjects];
    for (NSUInteger i = 0; i < _indicatorValues.count; i++) {
        UIView *tick = [[UIView alloc] init];
        tick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        tick.userInteractionEnabled = NO;
        [self addSubview:tick];
        [self.indicatorTicks addObject:tick];
    }
    [self updateIndicatorTickPositions];
}

- (void)setDefaultValue:(float)defaultValue {
    if (self.step > 0) {
        defaultValue = self.minimumValue + roundf((defaultValue - self.minimumValue) / self.step) * self.step;
    }
    _defaultValue = defaultValue;
    [self updateDefaultTickPosition];
    [self updateFillForCurrentValue];
}

- (void)setHasDefaultValue:(BOOL)hasDefaultValue {
    _hasDefaultValue = hasDefaultValue;
    [self updateDefaultTickPosition];
    [self updateFillForCurrentValue];
}

// Tolerance for "value == defaultValue" comparisons below. Values arrive
// pre-quantized onto the step grid (see setValue:/setDefaultValue:), so an
// exact-match check would be sufficient, but a small epsilon keeps this
// robust for the (step == 0) continuous sliders too.
static const float kDefaultValueEpsilon = 0.0005f;

- (void)updateFillForCurrentValue {
    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat fraction = range > 0 ? (self.value - self.minimumValue) / range : 0;
    fraction = MAX(0, MIN(1, fraction));
    self.fillWidthConstraint.constant = self.bounds.size.width * fraction;

    // At a non-extreme default, or a non-extreme indicatorValues tick,
    // square only the fill's trailing/right edge - same treatment for
    // both, since visually they're the same kind of reference point.
    // There is deliberately no animation: the shape is a discrete state.
    BOOL atSquaringPoint = self.hasDefaultValue &&
        self.defaultValue > self.minimumValue && self.defaultValue < self.maximumValue &&
        fabsf(self.value - self.defaultValue) <= kDefaultValueEpsilon;
    if (!atSquaringPoint) {
        for (NSNumber *indicatorNumber in self.indicatorValues) {
            float indicatorValue = indicatorNumber.floatValue;
            if (indicatorValue > self.minimumValue && indicatorValue < self.maximumValue &&
                fabsf(self.value - indicatorValue) <= kDefaultValueEpsilon) {
                atSquaringPoint = YES;
                break;
            }
        }
    }
    self.fill.trailingSquared = atSquaringPoint;
    [self.fill setNeedsLayout];
    [self.fill layoutIfNeeded];
}

static const CGFloat kDefaultTickWidth = 1;   // half of the previous 2pt width
static const CGFloat kDefaultTickHeight = 4;
static const CGFloat kDefaultTickGap = 3;     // gap between the tick and the top of the track

- (void)updateDefaultTickPosition {
    if (self.bounds.size.width <= 0) return;

    // Previously hidden when the default sat at either extreme of the
    // range, on the theory that there was nothing useful to mark since the
    // bar is already fully empty/full at that end. Walked back per
    // request - the tick now always shows whenever a default is set, even
    // at the min/max ends of the track.
    self.defaultTick.hidden = !self.hasDefaultValue;
    if (self.defaultTick.hidden) return;

    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat fraction = range > 0 ? (self.defaultValue - self.minimumValue) / range : 0;
    fraction = MAX(0, MIN(1, fraction));
    CGFloat x = self.bounds.size.width * fraction - (kDefaultTickWidth / 2.0);
    x = MAX(0, MIN(self.bounds.size.width - kDefaultTickWidth, x));

    // Sits above the track's current top edge (which itself moves as the
    // track animates between its thin/fat states) rather than spanning
    // through/behind the pill.
    CGFloat trackTop = CGRectGetMinY(self.track.frame);
    CGFloat y = trackTop - kDefaultTickGap - kDefaultTickHeight;
    self.defaultTick.frame = CGRectMake(x, y, kDefaultTickWidth, kDefaultTickHeight);
    self.defaultTick.layer.cornerRadius = kDefaultTickWidth / 2.0;
}

// Positions the extra indicatorValues ticks - same shape/gap/styling as
// the single default tick above, just one per entry in the array instead
// of being tied to defaultValue/hasDefaultValue.
- (void)updateIndicatorTickPositions {
    if (self.bounds.size.width <= 0 || self.indicatorTicks.count == 0) return;

    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat trackTop = CGRectGetMinY(self.track.frame);
    CGFloat y = trackTop - kDefaultTickGap - kDefaultTickHeight;

    for (NSUInteger i = 0; i < self.indicatorTicks.count; i++) {
        float indicatorValue = self.indicatorValues[i].floatValue;
        CGFloat fraction = range > 0 ? (indicatorValue - self.minimumValue) / range : 0;
        fraction = MAX(0, MIN(1, fraction));
        CGFloat x = self.bounds.size.width * fraction - (kDefaultTickWidth / 2.0);
        x = MAX(0, MIN(self.bounds.size.width - kDefaultTickWidth, x));

        UIView *tick = self.indicatorTicks[i];
        tick.frame = CGRectMake(x, y, kDefaultTickWidth, kDefaultTickHeight);
        tick.layer.cornerRadius = kDefaultTickWidth / 2.0;
    }
}

// The colored fill is normal foreground content, not part of the glass
// compositor. Keep its authored alpha at 1.0 in every state so Liquid Glass
// does not suppress the accent by compositing over it.
static const CGFloat kFillAlpha = 1.0;

- (void)setGlassEnabled:(BOOL)glassEnabled {
    UIView *host = self.glassHost;

    if (!gd_has_liquid_glass() || !host) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        if (!self.trackGlass) {
            UIVisualEffect *effect = gd_make_glass_effect(YES);
            self.trackGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.trackGlass.userInteractionEnabled = NO;
            self.trackGlass.opaque = NO;
            self.trackGlass.clipsToBounds = YES;
            self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
        }

        // The pill glass lives in a dedicated window-level compositor. The
        // setting content is rendered separately in contentOverlay, above
        // this material, so its colors keep their normal alpha.
        if (self.trackGlass.superview != host) {
            [self.trackGlass removeFromSuperview];
            [host addSubview:self.trackGlass];
        }

        UIView *overlay = host.superview;
        UIView *window = overlay.window;
        if (window) {
            self.trackGlass.frame = [self.track convertRect:self.track.bounds toView:host];
        }

        // Configure the real glass shape right away - -layoutSubviews isn't
        // guaranteed to re-run just because glass got enabled, and without
        // this the pill stays square until an unrelated layout pass (or a
        // touch) happens to trigger it.
        CGFloat h = self.trackHeightConstraint.constant;
        gd_configure_glass_corners(self.trackGlass, h / 2.0, NO);

        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
        [host bringSubviewToFront:self.trackGlass];
        [self.trackGlass setNeedsLayout];
        [self.trackGlass layoutIfNeeded];
    } else {
        [self.trackGlass removeFromSuperview];
        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
    }
}

- (void)setPillTouching:(BOOL)touching {
    if (self.touching == touching) return;
    self.touching = touching;
    self.trackHeightConstraint.constant = touching ? kCapsuleSliderFatHeight : kCapsuleSliderThinHeight;
    // BeginFromCurrentState matters here: without it, pressing again before
    // the previous release/press spring has finished settling makes the new
    // animation restart from the pre-animation model value instead of the
    // layer's current, still-mid-flight presentation value. The corner
    // radius (set from trackHeightConstraint.constant in -layoutSubviews,
    // both for the plain track/fill layers and for trackGlass's real Liquid
    // Glass shape) then jumps to interpolate across a bigger, wrong range
    // for a frame or two - visible as the pill's rounded ends briefly
    // shrinking down toward a squared-off rectangle on repeated presses.
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.6
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self layoutIfNeeded];
     } completion:^(BOOL finished) {
        [self updateFillForCurrentValue];
        [self updateDefaultTickPosition];
    }];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:touching ? UIImpactFeedbackStyleLight : UIImpactFeedbackStyleSoft];
    [haptic impactOccurred];
}

- (void)setValueFromLocation:(CGPoint)location sendActions:(BOOL)send {
    CGFloat fraction = self.bounds.size.width > 0 ? location.x / self.bounds.size.width : 0;
    BOOL clampedAtEdge = (fraction <= 0 || fraction >= 1);
    fraction = MAX(0, MIN(1, fraction));
    float previous = self.value;
    float rawValue = self.minimumValue + fraction * (self.maximumValue - self.minimumValue);

    // Snap onto the default tick, or onto any indicatorValues tick, when
    // the raw drag position lands close enough to one of them - the same
    // magnetic snap-to-default behavior, extended to indicatorValues so
    // a slider like Render Scale (low/med/high) snaps onto all three
    // reference points, not just whichever one also happens to be
    // defaultValue. When two candidates' thresholds overlap, the nearest
    // one wins. Checked before the edge-clamp haptic below so a snap that
    // also happens to land at an edge only fires one haptic, not two.
    BOOL snapped = NO;
    CGFloat range = self.maximumValue - self.minimumValue;
    if (range > 0) {
        CGFloat threshold = range * kDefaultSnapFraction;
        BOOL haveCandidate = NO;
        float bestCandidate = 0;
        CGFloat bestDistance = 0;
        if (self.hasDefaultValue) {
            CGFloat distance = fabsf(rawValue - self.defaultValue);
            if (distance <= threshold) {
                haveCandidate = YES;
                bestDistance = distance;
                bestCandidate = self.defaultValue;
            }
        }
        for (NSNumber *indicatorNumber in self.indicatorValues) {
            float indicatorValue = indicatorNumber.floatValue;
            CGFloat distance = fabsf(rawValue - indicatorValue);
            if (distance <= threshold && (!haveCandidate || distance < bestDistance)) {
                haveCandidate = YES;
                bestDistance = distance;
                bestCandidate = indicatorValue;
            }
        }
        if (haveCandidate) {
            rawValue = bestCandidate;
            snapped = (previous != rawValue);
        }
    }

    self.value = rawValue;

    if (snapped) {
        UISelectionFeedbackGenerator *snapHaptic = [UISelectionFeedbackGenerator new];
        [snapHaptic selectionChanged];
    } else if (clampedAtEdge && self.value != previous) {
        UISelectionFeedbackGenerator *edgeHaptic = [UISelectionFeedbackGenerator new];
        [edgeHaptic selectionChanged];
    }

    if (send) [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            // Touch-down, before any movement - the expand animation reacts
            // to the press itself, not to a drag starting.
            [self setPillTouching:YES];
            [self setValueFromLocation:location sendActions:YES];
            break;
        case UIGestureRecognizerStateChanged:
            [self setValueFromLocation:location sendActions:YES];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self setPillTouching:NO];
            break;
        default:
            break;
    }
}

@end

#pragma mark - Mode slider (segmented, preset-value control)
//
// For settings that pick one of a handful of named presets rather than
// tuning a number (AA Mode, AA Quality, Tonemap) - a capsule divided
// into N equal segments, each carrying its own label; the segment
// behind the current selection is filled solid, and dragging/tapping
// anywhere snaps immediately (hard, not proportionally) to whichever
// segment was touched. Shares the same drag-anywhere long-press
// mechanic as GDCapsuleSlider but has no continuous "value" - only a
// selectedIndex - so it's a distinct control rather than a GDCapsuleSlider
// subclass.
//
// Like GDCapsuleSlider, carries a default indicator - same tick styling
// and the same gap above the track, but drawn as a horizontal mark (75%
// longer than the capsule slider's vertical one) centered above whichever
// segment `defaultIndex` points to, since there's no single x position to
// hang a vertical tick off of here. `defaultIndex` also remains the data
// the Reset button snaps back to (see resetSettingsTapped).
//
// The track itself IS real Liquid Glass (matching GDCapsuleSlider's
// pills), hosted the same way: lazily created and parented into the
// panel's dedicated glass compositor content view rather than allocating
// a UIGlassEffect per-instance up front - see -setGlassEnabled: and
// gd_updateSliderGlassVisibility.

@interface GDModeSlider : UIControl
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) NSInteger defaultIndex; // -1 = no default; used only by Reset, not drawn
@property (nonatomic, strong) UIColor *fillColor;
- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated;
@end

@interface GDModeSlider ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, strong) UIView *defaultIndicator;  // horizontal default-position mark; sibling of track, like GDCapsuleSlider's defaultTick
@property (nonatomic, strong) NSMutableArray<UILabel *> *segmentLabels;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;  // real UIGlassEffect in the dedicated pill compositor
@property (nonatomic, assign) BOOL glassEnabled;
@property (nonatomic, weak) UIView *glassHost;                 // dedicated pill-glass container contentView
@end

@implementation GDModeSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _selectedIndex = 0;
        _defaultIndex = -1;
        _fillColor = gd_bar_fill_color();
        _segmentLabels = [NSMutableArray new];

        // This translucent bordered look is the pre-iOS-26 fallback
        // appearance (and the initial appearance before glass is enabled
        // by the panel controller); once real Liquid Glass is attached in
        // -setGlassEnabled:, the border/fill are cleared so the material
        // reads through cleanly instead of double-compositing.
        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.userInteractionEnabled = NO;
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
        self.track.layer.borderWidth = 1;
        self.track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        self.track.clipsToBounds = YES;
        [self addSubview:self.track];

        self.thumb = [[UIView alloc] init];
        self.thumb.backgroundColor = [_fillColor colorWithAlphaComponent:1.0];
        self.thumb.userInteractionEnabled = NO;
        self.thumb.layer.cornerCurve = kCACornerCurveContinuous;
        [self.track addSubview:self.thumb];

        // Hovers above the track's top edge, the same way GDCapsuleSlider's
        // defaultTick does, rather than living inside/behind the segments.
        self.defaultIndicator = [[UIView alloc] init];
        self.defaultIndicator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.defaultIndicator.userInteractionEnabled = NO;
        self.defaultIndicator.hidden = YES;
        [self addSubview:self.defaultIndicator];

        [NSLayoutConstraint activateConstraints:@[
            [self.track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.track.heightAnchor constraintEqualToConstant:kCapsuleSliderHeight],
        ]];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0;
        [self addGestureRecognizer:press];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kCapsuleSliderHeight);
}

// Mirrors GDCapsuleSlider's -setGlassEnabled: exactly: the glass sits BEHIND
// the track's own content (thumb + labels) in a separate window-level
// compositor, so those stay in the normal panel hierarchy on top while the
// pill itself reads as real Liquid Glass.
- (void)setGlassEnabled:(BOOL)glassEnabled {
    UIView *host = self.glassHost;

    if (!gd_has_liquid_glass() || !host) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        if (!self.trackGlass) {
            UIVisualEffect *effect = gd_make_glass_effect(YES);
            self.trackGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.trackGlass.userInteractionEnabled = NO;
            self.trackGlass.opaque = NO;
            self.trackGlass.clipsToBounds = YES;
            self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
        }

        if (self.trackGlass.superview != host) {
            [self.trackGlass removeFromSuperview];
            [host addSubview:self.trackGlass];
        }

        UIView *overlay = host.superview;
        UIView *window = overlay.window;
        if (window) {
            self.trackGlass.frame = [self.track convertRect:self.track.bounds toView:host];
        }

        // Configure the real glass shape right away - -layoutSubviews isn't
        // guaranteed to re-run just because glass got enabled, and without
        // this the pill stays square until an unrelated layout pass (or a
        // touch) happens to trigger it.
        CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
        gd_configure_glass_corners(self.trackGlass, h / 2.0, NO);

        // Hand-rolled fallback material is no longer needed once the real
        // glass is behind it - clearing it avoids compositing translucency
        // on top of translucency.
        self.track.backgroundColor = UIColor.clearColor;
        self.track.layer.borderWidth = 0;
        [host bringSubviewToFront:self.trackGlass];
        [self.trackGlass setNeedsLayout];
        [self.trackGlass layoutIfNeeded];
    } else {
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
    }
}

- (void)setLabels:(NSArray<NSString *> *)labels {
    _labels = [labels copy];
    for (UILabel *l in self.segmentLabels) [l removeFromSuperview];
    [self.segmentLabels removeAllObjects];
    for (NSString *text in _labels) {
        UILabel *l = [[UILabel alloc] init];
        l.text = text;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        l.userInteractionEnabled = NO;
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.7;
        [self.track addSubview:l];
        [self.segmentLabels addObject:l];
    }
    [self setNeedsLayout];
}

- (void)setDefaultIndex:(NSInteger)defaultIndex {
    _defaultIndex = defaultIndex;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
    self.track.layer.cornerRadius = h / 2.0;
    self.thumb.layer.cornerRadius = MAX(0, (h / 2.0) - 2);

    if (self.trackGlass) {
        // Same fix as GDCapsuleSlider above: trackGlass carries a real
        // UIGlassEffect, so its shape has to be set with
        // gd_configure_glass_corners (UICornerConfiguration), not a plain
        // CALayer cornerRadius - the latter clips the view but never
        // reshapes the actual Liquid Glass material, leaving it square
        // until a touch forces UIKit to re-resolve it.
        gd_configure_glass_corners(self.trackGlass, h / 2.0, NO);
        self.trackGlass.layer.cornerRadius = h / 2.0;
        self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *host = self.trackGlass.superview ?: self.glassHost;
        if (host) {
            self.trackGlass.frame = [self.track convertRect:self.track.bounds toView:host];
        }
    }

    NSInteger count = (NSInteger)self.labels.count;
    if (count == 0) {
        self.defaultIndicator.hidden = YES;
        return;
    }
    CGFloat segmentWidth = self.track.bounds.size.width / (CGFloat)count;

    NSInteger clampedIndex = MAX(0, MIN(count - 1, self.selectedIndex));
    for (NSInteger i = 0; i < count; i++) {
        UILabel *l = self.segmentLabels[i];
        l.frame = CGRectMake(segmentWidth * i, 0, segmentWidth, self.track.bounds.size.height);
        l.textColor = (i == clampedIndex) ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.6];
        [self.track bringSubviewToFront:l];
    }

    self.thumb.frame = CGRectMake(segmentWidth * clampedIndex + 2, 2, MAX(0, segmentWidth - 4), MAX(0, self.track.bounds.size.height - 4));
    [self.track sendSubviewToBack:self.thumb];

    // Default indicator: GDCapsuleSlider's default tick rotated 90deg -
    // width/height swapped so the mark reads as a horizontal dash instead
    // of a vertical one - and lengthened 75% per request. Centered above
    // whichever segment defaultIndex points to, with the same gap above
    // the track's top edge that the vertical tick uses.
    BOOL hasDefault = self.defaultIndex >= 0 && self.defaultIndex < count;
    self.defaultIndicator.hidden = !hasDefault;
    if (hasDefault) {
        CGFloat length = kDefaultTickHeight * 1.75;   // vertical tick's length, rotated to run horizontally, +75%
        CGFloat thickness = kDefaultTickWidth;        // stays the vertical tick's thin dimension
        CGFloat centerX = segmentWidth * self.defaultIndex + segmentWidth / 2.0;
        CGFloat x = centerX - length / 2.0;
        x = MAX(0, MIN(self.bounds.size.width - length, x));
        CGFloat trackTop = CGRectGetMinY(self.track.frame);
        CGFloat y = trackTop - kDefaultTickGap - thickness;
        self.defaultIndicator.frame = CGRectMake(x, y, length, thickness);
        self.defaultIndicator.layer.cornerRadius = thickness / 2.0;
    }
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    [self setSelectedIndex:selectedIndex animated:NO];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated {
    NSInteger count = (NSInteger)self.labels.count;
    if (count == 0) { _selectedIndex = 0; return; }
    selectedIndex = MAX(0, MIN(count - 1, selectedIndex));
    _selectedIndex = selectedIndex;
    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self setNeedsLayout];
            [self layoutIfNeeded];
        } completion:nil];
    } else {
        [self setNeedsLayout];
    }
}

- (void)selectIndexForLocation:(CGPoint)location sendActions:(BOOL)send {
    NSInteger count = (NSInteger)self.labels.count;
    if (count == 0 || self.bounds.size.width <= 0) return;
    CGFloat segmentWidth = self.bounds.size.width / (CGFloat)count;
    NSInteger idx = (NSInteger)floorf(location.x / MAX((CGFloat)1, segmentWidth));
    idx = MAX(0, MIN(count - 1, idx));
    if (idx != self.selectedIndex) {
        [self setSelectedIndex:idx animated:YES];
        UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
        [haptic selectionChanged];
        if (send) [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            [self selectIndexForLocation:location sendActions:YES];
            break;
        default:
            break;
    }
}

@end

#pragma mark - Compact row control
//
// NOTE on the layout bug this replaced: rows used to be built with
// fixed CGRect frames sized against a constant panel width, then
// dropped into a UIStackView via addArrangedSubview:. UIStackView is
// documented to force translatesAutoresizingMaskIntoConstraints = NO
// on anything you hand it, which silently threw away every one of
// those manual frames. With no constraints of its own, a row had no
// way to report its size to Auto Layout, so the stack collapsed every
// row to zero/ambiguous size and rendered them stacked on top of each
// other - exactly the garbled overlap in the screenshot.
//
// Fix: every row is now a real constraint-based view. Each row's
// subviews are pinned edge-to-edge from the row's top anchor to its
// bottom anchor and leading to trailing, so the row's own size falls
// out of the constraint graph with nothing ambiguous left for the
// stack view to guess at.

@interface GDRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) GDCapsuleSlider *slider;   // nil for switch/mode-slider/button rows
@property (nonatomic, strong) GDModeSlider *modeSlider;  // nil unless this is a preset-value row
@property (nonatomic, strong) UISwitch *toggle;          // nil unless this is a switch row
@end

@implementation GDRow
@end

// Auto-scrolling ("marquee") label for text that's wider than its
// container - used for the Info dropdown's Path/CAB lines, which
// should stay fully readable rather than middle-truncated (per
// request). Only animates when the text actually overflows the
// view's own width; sits perfectly still otherwise, so this is safe
// to use unconditionally without checking text length up front.
//
// Ping-pongs left/right rather than wrapping around - a seamless
// infinite-scroll wraparound needs two copies of the label side by
// side and careful modulo math; a reset-to-start jump cut (the easy
// alternative) reads as a stutter in a small debug-overlay row. A
// smooth reverse direction avoids both problems for one extra line
// of state (the `toEnd` bool passed down the recursive step below).
@interface GDMarqueeLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *textColor;
// Stable identity for this marquee's content (e.g. an entry's path plus
// which line it is - "<path>|path" / "<path>|cab"), used to persist
// scroll phase across a -gd_rebuildModsLibrary rebuild. Without this,
// EVERY rebuild - triggered by toggling ANY dropdown, not just this
// one's own - tore down and recreated every GDMarqueeLabel instance,
// each restarting at frame 0. That's what read as "the marquee resets
// when other dropdowns are triggered": it wasn't this label's own
// dropdown being touched, it was any sibling row's rebuild recreating
// it from scratch. Leave nil for a label that doesn't need to survive
// rebuilds (it'll just always start at frame 0, same as before).
@property (nonatomic, copy) NSString *marqueeKey;
@end

@implementation GDMarqueeLabel {
    UILabel *_label;
    NSLayoutConstraint *_labelLeadingConstraint;
    BOOL _scrolling;
}

// Persists, keyed by -marqueeKey, the CACurrentMediaTime() each
// marquee's ping-pong cycle notionally began. Process-lifetime and
// class-level - deliberately NOT tied to any one GDMarqueeLabel
// instance's lifetime - so a label rebuilt with the same key (e.g.
// every row in the mods list, every time -gd_rebuildModsLibrary runs)
// resumes exactly where its cycle should be instead of restarting.
// CAAnimation's beginTime is honored even when it's in the past at the
// moment the animation is added - the layer just renders as if the
// animation had been running continuously since then - which is
// exactly the "don't reset" behavior wanted here.
static NSMutableDictionary<NSString *, NSNumber *> *gGDMarqueeCycleStartTimes;
static dispatch_once_t gGDMarqueeRegistryToken;
static CFTimeInterval gd_marquee_cycle_start(NSString *key) {
    dispatch_once(&gGDMarqueeRegistryToken, ^{
        gGDMarqueeCycleStartTimes = [NSMutableDictionary dictionary];
    });
    if (!key) return CACurrentMediaTime();
    NSNumber *existing = gGDMarqueeCycleStartTimes[key];
    if (existing) return existing.doubleValue;
    CFTimeInterval now = CACurrentMediaTime();
    gGDMarqueeCycleStartTimes[key] = @(now);
    return now;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _label = [[UILabel alloc] init];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.numberOfLines = 1;
        _label.lineBreakMode = NSLineBreakByClipping; // this view's own scrolling is the "see the rest" mechanism, not ellipsis
        [self addSubview:_label];

        // Stays at constant 0 always now - see -gd_startScrollingWithOverflow:,
        // which animates the label's LAYER (transform) rather than this
        // Auto Layout constraint, so a stray layout pass elsewhere in the
        // panel can never stomp mid-scroll position back to 0.
        _labelLeadingConstraint = [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor];
        [NSLayoutConstraint activateConstraints:@[
            _labelLeadingConstraint,
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setText:(NSString *)text {
    _label.text = text;
    [_label.layer removeAnimationForKey:@"gdMarqueeScroll"];
    _label.layer.transform = CATransform3DIdentity;
    _scrolling = NO;
    [self setNeedsLayout];
}
- (NSString *)text { return _label.text; }
- (void)setFont:(UIFont *)font { _label.font = font; [self setNeedsLayout]; }
- (UIFont *)font { return _label.font; }
- (void)setTextColor:(UIColor *)textColor { _label.textColor = textColor; }
- (UIColor *)textColor { return _label.textColor; }

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, ceil(_label.font.lineHeight));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [_label sizeToFit];
    CGFloat overflow = ceil(CGRectGetWidth(_label.frame)) - CGRectGetWidth(self.bounds);
    if (overflow > 4 && !_scrolling) {
        _scrolling = YES;
        [self gd_startScrollingWithOverflow:overflow];
    } else if (overflow <= 4 && _scrolling) {
        // shrank back under the container's width (e.g. rotation)
        _scrolling = NO;
        [_label.layer removeAnimationForKey:@"gdMarqueeScroll"];
        _label.layer.transform = CATransform3DIdentity;
    }
}

// Builds the full hold/move/hold/move ping-pong as one repeating
// keyframe animation on the label's transform (not its Auto-Layout-
// governed position - see the constraint comment above), timed to have
// begun at -marqueeKey's persisted start time rather than "now". That's
// what lets a freshly (re)created label pick its cycle back up in
// mid-scroll instead of jumping to frame 0.
- (void)gd_startScrollingWithOverflow:(CGFloat)overflow {
    NSTimeInterval moveDuration = MAX(2.5, overflow / 16.0);
    NSTimeInterval holdDuration = 0.9;
    NSTimeInterval cycle = 2 * (moveDuration + holdDuration);

    NSTimeInterval t1 = holdDuration / cycle;                     // arrived back at start, about to move out
    NSTimeInterval t2 = (holdDuration + moveDuration) / cycle;    // arrived at the far end
    NSTimeInterval t3 = (2 * holdDuration + moveDuration) / cycle; // about to move back

    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    anim.keyTimes = @[@0, @(t1), @(t2), @(t3), @1];
    anim.values = @[@0, @0, @(-overflow), @(-overflow), @0];
    CAMediaTimingFunction *linear = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    CAMediaTimingFunction *easeInOut = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    anim.timingFunctions = @[linear, easeInOut, linear, easeInOut];
    anim.duration = cycle;
    anim.repeatCount = HUGE_VALF;
    anim.beginTime = gd_marquee_cycle_start(self.marqueeKey);
    anim.removedOnCompletion = NO;
    [_label.layer addAnimation:anim forKey:@"gdMarqueeScroll"];
}

@end

static const CGFloat kRowHeight = 26;
static const CGFloat kTitleColumnWidth = 92;
static const CGFloat kValueColumnWidth = 34;

// Increment granularity for a slider's range: 0.05 for normalized/bipolar
// ranges that sit within [-1, 1] (intensity/blend-style settings), 5 for
// anything whose top end is past 20 (FPS, render scale, temperature/
// saturation, etc). Anything outside both buckets (e.g. small index-style
// ranges like MSAA/Texture MIP) stays continuous - unspecified by request,
// left as-is.
static float gd_slider_step_for_range(float minV, float maxV) {
    if (minV >= -1.0f && maxV <= 1.0f) return 0.05f;
    if (maxV > 20.0f) return 5.0f;
    return 0.0f;
}

// Compact single-line row: title | slider | value. Used for every
// continuous/numeric setting.
static GDRow *gd_make_slider_row(NSString *title, float minV, float maxV, float val, NSString *(^format)(float)) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    float step = gd_slider_step_for_range(minV, maxV);
    float displayVal = val;
    if (step > 0) {
        displayVal = minV + roundf((val - minV) / step) * step;
        displayVal = MAX(minV, MIN(maxV, displayVal));
    }

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.valueLabel = [[UILabel alloc] init];
    row.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.valueLabel.text = format(displayVal);
    row.valueLabel.textColor = gd_accent_green_color();
    row.valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    row.valueLabel.textAlignment = NSTextAlignmentRight;
    [row addSubview:row.valueLabel];

    row.slider = [[GDCapsuleSlider alloc] init];
    row.slider.translatesAutoresizingMaskIntoConstraints = NO;
    row.slider.minimumValue = minV;
    row.slider.maximumValue = maxV;
    row.slider.step = step;
    row.slider.value = displayVal;
    [row.slider setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:row.slider];

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.widthAnchor constraintEqualToConstant:kTitleColumnWidth],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [row.valueLabel.widthAnchor constraintEqualToConstant:kValueColumnWidth],
        [row.valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.slider.leadingAnchor constraintEqualToAnchor:row.titleLabel.trailingAnchor constant:4],
        [row.slider.trailingAnchor constraintEqualToAnchor:row.valueLabel.leadingAnchor constant:-6],
        [row.slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:row.slider.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:row.slider.bottomAnchor constant:3],
    ]];

    objc_setAssociatedObject(row.slider, "gd_format", format, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(row.slider, "gd_valueLabel", row.valueLabel, OBJC_ASSOCIATION_RETAIN);

    return row;
}

// Compact single-line row: title | mode slider (segmented, self-labeling -
// no separate value label needed since the selected preset name is drawn
// inside the control itself).
static GDRow *gd_make_mode_slider_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.modeSlider = [[GDModeSlider alloc] init];
    row.modeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    row.modeSlider.labels = labels;
    row.modeSlider.defaultIndex = defaultIndex;
    row.modeSlider.selectedIndex = selectedIndex;
    [row addSubview:row.modeSlider];

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.widthAnchor constraintEqualToConstant:kTitleColumnWidth],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.modeSlider.leadingAnchor constraintEqualToAnchor:row.titleLabel.trailingAnchor constant:4],
        [row.modeSlider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [row.modeSlider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:row.modeSlider.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:row.modeSlider.bottomAnchor constant:3],
    ]];

    return row;
}

static GDRow *gd_make_switch_row(NSString *title, BOOL val) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.toggle = [[UISwitch alloc] init];
    row.toggle.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat toggleScale = 0.65;
    row.toggle.transform = CGAffineTransformMakeScale(toggleScale, toggleScale);
    row.toggle.on = val;
    [row addSubview:row.toggle];

    // Auto Layout constrains the switch's UNTRANSFORMED frame, but the
    // scale transform above shrinks what's actually drawn around the same
    // center - so pinning trailingAnchor straight to row.trailingAnchor
    // left the visible switch sitting inset from the row's true right
    // edge, out of step with every other row (slider/button rows pin
    // their trailing content flush to row.trailingAnchor with no
    // transform involved). Compensating the trailing constraint by half
    // the width the scale removes brings the switch's VISIBLE edge back
    // flush with the rest of the panel's margins.
    CGSize toggleIntrinsicSize = row.toggle.intrinsicContentSize;
    CGFloat toggleTrailingCompensation = (toggleIntrinsicSize.width - toggleIntrinsicSize.width * toggleScale) / 2.0;

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:2],
        [row.titleLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-2],
        [row.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:row.toggle.leadingAnchor constant:-6],

        [row.toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:toggleTrailingCompensation],
        [row.toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.toggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.titleLabel.trailingAnchor constant:6],
    ]];

    return row;
}

// Single full-width tappable row - used for one-shot actions rather
// than a persistent setting, so it has no value label/toggle/slider
// state to keep in sync. Vertical inset matches the -3/+3 inset used
// by the slider/mode-slider rows (rather than the tighter -2/+2 used
// by switch rows) so the button sits at the same vertical rhythm as
// the rest of the panel's controls, per request. Styled as native
// Liquid Glass - see gd_style_button_as_native_glass. See
// gd_make_button_pair_row below for the two-buttons-in-one-row variant
// (Config section's Reset/Reapply), and
// gd_make_button_and_glass_field_row further down for the button-plus-
// field variant the Debug section's syslog row now uses instead of this.
//
// Same idea as gd_make_button_row but two equal-width buttons side by
// side with a small gap between them - used for the Config section's
// Reset/Reapply pair so both one-shot actions sit in the same row
// instead of costing a full extra row of vertical space each.
// Associated objects are keyed "gd_button_left"/"gd_button_right" (vs.
// gd_make_button_row's single "gd_button") so callers can tell them
// apart.
static GDRow *gd_make_button_pair_row(NSString *leftTitle, UIColor *leftTint,
                                       NSString *rightTitle, UIColor *rightTint) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *leftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    leftButton.translatesAutoresizingMaskIntoConstraints = NO;
    gd_style_button_as_native_glass(leftButton, leftTitle, leftTint);
    leftButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [row addSubview:leftButton];
    objc_setAssociatedObject(row, "gd_button_left", leftButton, OBJC_ASSOCIATION_RETAIN);

    UIButton *rightButton = [UIButton buttonWithType:UIButtonTypeSystem];
    rightButton.translatesAutoresizingMaskIntoConstraints = NO;
    gd_style_button_as_native_glass(rightButton, rightTitle, rightTint);
    rightButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [row addSubview:rightButton];
    objc_setAssociatedObject(row, "gd_button_right", rightButton, OBJC_ASSOCIATION_RETAIN);

    static const CGFloat kButtonGap = 8;
    [NSLayoutConstraint activateConstraints:@[
        [leftButton.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [leftButton.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
        [leftButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],
        [leftButton.widthAnchor constraintEqualToAnchor:rightButton.widthAnchor],

        [rightButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [rightButton.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
        [rightButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],

        [rightButton.leadingAnchor constraintEqualToAnchor:leftButton.trailingAnchor constant:kButtonGap],
    ]];

    return row;
}

// Full-width single-button counterpart to gd_make_button_pair_row above,
// for actions that don't pair naturally with a second button - the Mods
// section's own "Load Mods" button (BundleDoctorService's send-and-
// intercept pipeline) is the first user of this.
static GDRow *gd_make_single_button_row(NSString *title, UIColor *tint) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    gd_style_button_as_native_glass(button, title, tint);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [row addSubview:button];
    objc_setAssociatedObject(row, "gd_button", button, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
        [button.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],
    ]];

    return row;
}


// Wraps a borderless UITextField in a real interactive UIGlassEffect
// surface - the same gd_make_glass_effect/gd_configure_glass_corners
// plumbing every other glass element in this file uses (trackGlass,
// panelGlass, syslogHandleGlass), rather than the flat translucent-
// rectangle look gd_make_text_field_row builds by hand. UIKit doesn't
// expose a UITextField-specific "glass field" configuration API the way
// it does for buttons (see gd_style_button_as_native_glass) - a real
// UIGlassEffect surface behind a borderless field is the closest native
// equivalent. Returns the UIVisualEffectView to add to the row; on
// pre-iOS-26 devices there is no glass to wrap with, so this styles
// `field` itself with the old flat-rectangle look and returns nil -
// callers should add `field` directly to the row in that case.
static UIVisualEffectView *gd_wrap_field_in_native_glass(UITextField *field, CGFloat cornerRadius) {
    field.borderStyle = UITextBorderStyleNone;
    UIView *leftPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    field.leftView = leftPadding;
    field.leftViewMode = UITextFieldViewModeAlways;

    if (gd_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_effect(YES)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        gd_configure_glass_corners(glass, cornerRadius, NO);

        field.backgroundColor = UIColor.clearColor;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [glass.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
            [field.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
            [field.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
            [field.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],
        ]];
        return glass;
    }

    field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    field.layer.cornerRadius = cornerRadius;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    return nil;
}

#pragma mark Re-Encoding format (Config section)
//
// The Texture2D format BundleDoctorConfig.outputFormat tells the doctor-
// bundle workflow's re-encoder (BundleDoctor/TextureCodec.cs, in the
// re-encoder repo, not this project) to target. Nothing in this file
// ever set config.outputFormat before - it stayed nil on every save, so
// +[BundleDoctorConfig normalizedConfig] silently fell back to its own
// "RGBA32" default (BundleDoctorService.m's kBDSDefaultOutputFormat) on
// every single dispatch, regardless of which formats the repo actually
// supports. This section is the fix: a picker in the Config section
// (see -buildPanel:) that writes straight through
// +[BundleDoctorSettings saveConfig:] - every dispatch call site in this
// file re-loads config fresh immediately before use, so persisting the
// choice here is the only change needed; nothing downstream has to know
// this picker exists.
//
// First pass at this used a single UIButton styled via
// gd_style_button_as_native_glass (+[UIButtonConfiguration
// glassButtonConfiguration]) sized to a fixed 58x28. That's not what
// actually went wrong with it, in hindsight - the real fault was that
// gd_style_button_as_native_glass's default capsule corner style was
// never corrected (every other capsule-defaulting glass button in this
// file re-squares itself via a corner-radius call right after, which
// this one skipped), and its titleLabel didn't match the rest of the
// panel's fields (monospaced/semibold/tinted vs. the Auth/Debug fields'
// plain white system font) - together that's exactly "looks like a
// circular blob, text doesn't match anything else".
//
// Second pass replaced the button entirely with a real (but inert,
// userInteractionEnabled = NO) UITextField wrapped in the same
// gd_wrap_field_in_native_glass glass container the Auth/Debug fields
// use, plus a second, fully transparent UIButtonTypeCustom pinned
// exactly over it to own .menu/.showsMenuAsPrimaryAction - reasoning
// being that a UIButtonConfiguration-driven title can't be independently
// left-aligned next to a trailing chevron the way a UITextField's text +
// rightView can. That's true, but it bought that layout at the cost of
// the actual ask (a real Liquid Glass BUTTON) and two views standing in
// for one, and it's the same underlying capsule-corner problem wearing a
// different hat: gd_wrap_field_in_native_glass's glass is a plain
// UIVisualEffectView, which takes a custom corner radius fine, so it
// never had to solve "give a UIButtonConfiguration glass button a
// non-capsule corner" - it just avoided the button. See the "Verify"
// button's own gd_configure_glass_button_fixed_corner_radius above for
// why that call actually was solvable, and once it's solvable there's no
// reason not to use the real control.
//
// Current approach: back to a single native glass UIButton
// (gd_style_button_as_native_glass), owning .menu/.showsMenuAsPrimaryAction
// itself - no second overlay view needed, since this is the actual tap
// target now, not a decoration sitting under one. Corners are squared via
// gd_configure_glass_button_fixed_corner_radius, the same reliable
// mutate-the-configuration approach the Verify button uses. The
// left-aligned-value / trailing-chevron layout the text-field approach
// was chasing is approximated with contentHorizontalAlignment = .leading
// and a trailing chevron image with a small imagePadding gap - the pair
// reads as a left-anchored value with a small "opens a picker" affordance
// right after it, rather than a value and chevron pulled to opposite
// edges of the control (UIButtonConfiguration has no API for that split
// layout - only UITextField's independent text + rightView slots do, and
// that's not this control anymore). This is much closer to how UIKit's
// own menu buttons look elsewhere in iOS 26 than the field-plus-overlay
// hack was.

// Canonical BundleDoctorConfig.outputFormat strings this picker offers -
// exactly the five the doctor-bundle workflow's own `output_format`
// choice input (.github/workflows/doctor-bundle.yml in the re-encoder
// repo) and Program.cs's ParseOutputTextureFormat both accept verbatim.
// Order here is the order they appear in the field's menu.
static NSArray<NSString *> *gd_reencode_format_options(void) {
    return @[@"ASTC_RGBA_4x4", @"ASTC_RGBA_6x6", @"ASTC_RGBA_8x8", @"RGBA32", @"ETC2"];
}

// Mirrors BundleDoctorService.m's own kBDSDefaultOutputFormat (private to
// that file, so not reusable directly) - only used here to seed this
// field's initial text when nothing's been saved yet. The real
// default-if-unset behavior for an actual dispatch still lives in
// -[BundleDoctorConfig normalizedConfig], not here.
static NSString * const kGDDefaultReencodeFormat = @"RGBA32";

// Full name shown both as the field's own text and as each row's title
// inside the menu - the field is wide enough now (see
// gd_make_reencode_format_row) that there's no need for the old
// abbreviated short-code display this used to fall back to.
static NSString *gd_reencode_format_display_name(NSString *format) {
    if ([format isEqualToString:@"ASTC_RGBA_4x4"]) return @"ASTC 4x4";
    if ([format isEqualToString:@"ASTC_RGBA_6x6"]) return @"ASTC 6x6";
    if ([format isEqualToString:@"ASTC_RGBA_8x8"]) return @"ASTC 8x8";
    if ([format isEqualToString:@"RGBA32"]) return @"RGBA32";
    if ([format isEqualToString:@"ETC2"]) return @"ETC2";
    return format ?: @"RGBA32";
}

// One UIAction per gd_reencode_format_options() entry, with the
// currently-selected format's action given UIMenuElementStateOn so UIKit
// draws its own checkmark next to it - the menu doubles as its own
// "what's selected right now" indicator every time it's opened, no
// separate check-glyph bookkeeping needed. `onSelect` fires with the
// tapped option's canonical string; this function only builds the menu -
// see -gd_reencodeFormatSelected: for what actually happens on a tap.
static UIMenu *gd_build_reencode_format_menu(NSString *selectedFormat, void (^onSelect)(NSString *format)) {
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSString *format in gd_reencode_format_options()) {
        BOOL selected = [format isEqualToString:selectedFormat];
        UIAction *action = [UIAction actionWithTitle:gd_reencode_format_display_name(format)
                                                image:nil
                                           identifier:nil
                                              handler:^(__kindof UIAction * _Nonnull a) {
            if (onSelect) onSelect(format);
        }];
        action.state = selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:actions];
}

// Small chevron.up.chevron.down glyph (two vertically-stacked arrows,
// one up/one down - the standard system "this reveals a picker" glyph),
// baked as a template-rendered UIImage at the field's own dim tint
// (rather than left to the button's baseForegroundColor) so it stays
// visually secondary to the value text next to it regardless of what
// tint the button itself is given. Used as the button's trailing
// configuration.image - see gd_apply_reencode_format_selection below.
static UIImage *gd_make_dropdown_chevron_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:symbolConfig];
    chevronImage = [chevronImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    return chevronImage;
}

// (Re)applies the current selection to the button - title text, trailing
// chevron, and menu - sharing this one place so a fresh build
// (gd_make_reencode_format_row) and a post-tap refresh
// (-gd_reencodeFormatSelected:) can never drift out of sync with each
// other. Corner radius is reapplied here too, defensively - setting a
// fresh .configuration (which this does, via
// gd_style_button_as_native_glass) is exactly the kind of rebuild
// gd_configure_glass_button_fixed_corner_radius's own header comment
// warns resets an unprotected corner style back to the capsule default.
static void gd_apply_reencode_format_selection(UIButton *button, NSString *format, void (^onSelect)(NSString *format)) {
    // Root cause of the vanishing dropdown: UIButton's own
    // -updateConfiguration pass runs automatically on every state change
    // (touch-down => highlighted) whenever the button has a non-nil
    // .configuration, REGARDLESS of whether a call site installs its own
    // configurationUpdateHandler - that part of the "Verify button" theory
    // in this function's header comment is wrong, it's not opt-in. That
    // automatic pass rebuilds this button's UIButtonConfiguration-owned
    // subviews on the same touch-down that showsMenuAsPrimaryAction uses to
    // kick off the menu presentation, tearing the pending presentation down
    // before it appears - the touch itself still lands (hence "interactable,
    // but nothing opens"). automaticallyUpdatesConfiguration = NO is the
    // documented opt-out for exactly this: it stops UIKit from touching
    // .configuration on state changes at all, so the menu's own touch-down
    // handling is never raced by a system-driven rebuild. Safe to set on
    // every call here (idempotent) since this function is the single place
    // that owns this button's full setup/refresh.
    if ([button respondsToSelector:@selector(setAutomaticallyUpdatesConfiguration:)]) {
        button.automaticallyUpdatesConfiguration = NO;
    }

    // Explicit white (not nil) so this matches every other glass field's
    // plain white text on pre-iOS-26 too - gd_style_button_as_native_glass's
    // own fallback only sets a titleColor when it's given a non-nil tint,
    // and would otherwise leave UIButtonTypeSystem's default blue tint.
    gd_style_button_as_native_glass(button, gd_reencode_format_display_name(format), UIColor.whiteColor);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;

    SEL getConfiguration = NSSelectorFromString(@"configuration");
    if ([button respondsToSelector:getConfiguration]) {
        id configuration = ((id (*)(id, SEL))objc_msgSend)(button, getConfiguration);
        if (configuration) {
            // Trailing chevron with a small, fixed gap to the title -
            // the closest a single UIButtonConfiguration gets to the old
            // text-field-plus-rightView look, see this pragma mark's own
            // header comment for why an even leading-value/trailing-
            // chevron-at-the-edge split isn't achievable with one button.
            SEL setImage = NSSelectorFromString(@"setImage:");
            if ([configuration respondsToSelector:setImage]) {
                ((void (*)(id, SEL, id))objc_msgSend)(configuration, setImage, gd_make_dropdown_chevron_image());
            }
            SEL setImagePlacement = NSSelectorFromString(@"setImagePlacement:");
            if ([configuration respondsToSelector:setImagePlacement]) {
                // NSDirectionalRectEdge.trailing == 8 on the current ABI.
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, setImagePlacement, 8 /* trailing */);
            }
            SEL setImagePadding = NSSelectorFromString(@"setImagePadding:");
            if ([configuration respondsToSelector:setImagePadding]) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(configuration, setImagePadding, 6);
            }
            SEL setConfig = NSSelectorFromString(@"setConfiguration:");
            if ([button respondsToSelector:setConfig]) {
                ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
            }
        }
    }

    gd_configure_glass_button_fixed_corner_radius(button, kGDAuthFieldCornerRadius);
    if (!gd_has_liquid_glass()) {
        button.layer.cornerRadius = kGDAuthFieldCornerRadius;
        button.clipsToBounds = YES;
    }

    // CORRECTION (this is what was actually wrong - see the previous "NOT
    // doing the Verify button's defensive configurationUpdateHandler..."
    // reasoning this replaced): the earlier theory was that the vanishing
    // menu was caused by a call site's OWN configurationUpdateHandler
    // rebuilding .configuration mid-touch, and that this button was safe
    // because it never installed one. That's backwards - UIKit runs
    // -updateConfiguration automatically on every UIControlState change
    // (touch-down => highlighted) for ANY button with a non-nil
    // .configuration, whether or not the call site ever hooks
    // configurationUpdateHandler itself. That automatic pass is exactly
    // what was tearing down this button's configuration-driven subviews on
    // the same touch-down showsMenuAsPrimaryAction uses to start presenting
    // the menu, cancelling the presentation before it ever appeared - the
    // tap still registered (the button visibly highlighted), there was just
    // no dropdown left to show by the time the rebuild finished. Fixed at
    // the top of this function with automaticallyUpdatesConfiguration = NO,
    // which stops UIKit from touching .configuration on state changes at
    // all, so nothing races the menu's own touch handling anymore. Corner
    // radius surviving every tap (see gd_configure_glass_button_fixed_corner_radius
    // above) was never actually evidence the automatic pass was harmless -
    // it only shows the automatic pass doesn't touch cornerStyle, not that
    // it doesn't touch anything.
    button.menu = gd_build_reencode_format_menu(format, onSelect);
    button.showsMenuAsPrimaryAction = YES; // tap opens the menu directly - no long-press/context-menu gesture needed
}

// Compact single-line row: title | a real native Liquid Glass button
// (gd_style_button_as_native_glass) showing the current re-encode format
// with a trailing chevron.up.chevron.down indicator, owning
// .menu/.showsMenuAsPrimaryAction itself so a tap presents a native
// pull-down of every format the repo supports - see this pragma mark's
// own header comment above for why this replaced the earlier inert-
// text-field-plus-transparent-overlay-button approach.
static GDRow *gd_make_reencode_format_row(NSString *selectedFormat, void (^onSelect)(NSString *format)) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = @"Re-Encoding format";
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:button];
    objc_setAssociatedObject(row, "gd_button", button, OBJC_ASSOCIATION_RETAIN);

    gd_apply_reencode_format_selection(button, selectedFormat, onSelect);

    static const CGFloat kFieldWidth = 116; // fits the widest label ("ASTC 8x8") left-aligned plus the trailing chevron with room to spare
    static const CGFloat kFieldHeight = 28; // matches every other glass field/button row in this section

    // No fixed width here, unlike the slider/mode-slider rows' shared
    // kTitleColumnWidth (92) - that constant is sized for their own short
    // titles ("MSAA", "HDR", etc.), and forcing "Re-Encoding format" into
    // it tripped adjustsFontSizeToFitWidth's minimumScaleFactor, shrinking
    // it below every other row in this section. Sized off its own intrinsic
    // content instead, exactly like gd_make_switch_row's title (the pattern
    // this section's other two rows already use), so it renders at the
    // panel's normal 11pt instead of scaled down.
    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.leadingAnchor constant:-6],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.widthAnchor constraintEqualToConstant:kFieldWidth],
        [button.heightAnchor constraintEqualToConstant:kFieldHeight],
        [button.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:3],
    ]];

    return row;
}

// Debug section's Toggle Syslog button + blacklist entry field, sharing
// one row at a fixed 33%/66% width split (button:field) per request -
// see -buildPanel:'s Debug section. The field is a real native Liquid
// Glass surface (gd_wrap_field_in_native_glass) rather than the plain
// title|field layout gd_make_text_field_row uses elsewhere, since this
// row has no title label of its own (the "Blacklisted keywords" label
// lives below, over the running list of already-added terms).
static GDRow *gd_make_button_and_glass_field_row(NSString *buttonTitle, UIColor *buttonTint, NSString *placeholder) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    gd_style_button_as_native_glass(button, buttonTitle, buttonTint);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    [row addSubview:button];
    objc_setAssociatedObject(row, "gd_button", button, OBJC_ASSOCIATION_RETAIN);

    UITextField *field = [[UITextField alloc] init];
    field.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    field.textColor = UIColor.whiteColor;
    field.tintColor = gd_accent_green_color();
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    objc_setAssociatedObject(row, "gd_textfield", field, OBJC_ASSOCIATION_RETAIN);

    UIVisualEffectView *fieldGlass = gd_wrap_field_in_native_glass(field, 6);
    UIView *fieldContainer = fieldGlass ?: field;
    fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fieldContainer];

    static const CGFloat kGap = 8;
    [NSLayoutConstraint activateConstraints:@[
        [fieldContainer.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [fieldContainer.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:28],
        [row.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor constant:3],

        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:fieldContainer.centerYAnchor],
        [button.heightAnchor constraintEqualToAnchor:fieldContainer.heightAnchor],

        [fieldContainer.leadingAnchor constraintEqualToAnchor:button.trailingAnchor constant:kGap],
        // 33%/66% split: button width pinned to half the field's width,
        // so across the row (ignoring the small fixed kGap) the two land
        // at roughly a 1:2 - i.e. 33%:66% - ratio, as requested.
        [button.widthAnchor constraintEqualToAnchor:fieldContainer.widthAnchor multiplier:0.5],
    ]];

    return row;
}

// Parses the Auth section's free-form "GitHub Repository Link" field
// into the separate repoOwner/repoName BundleDoctorConfig actually
// stores (see BundleDoctorSettings.h's SPLIT STORAGE note). Accepts
// everything a person is likely to paste or type:
//   owner/repo
//   owner/repo.git
//   github.com/owner/repo
//   https://github.com/owner/repo(.git)(/)
//   git@github.com:owner/repo(.git)
// Returns NO (outOwner/outName left untouched) if `raw` doesn't
// reduce to a plausible "owner/repo" shape - callers should treat
// that as "couldn't parse", not "empty repo name".
static BOOL gd_parse_github_repo_link(NSString *raw, NSString **outOwner, NSString **outName) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return NO;

    if ([s hasPrefix:@"git@github.com:"]) {
        s = [s substringFromIndex:@"git@github.com:".length];
    } else {
        // Strip a scheme (if any), then an optional "github.com/" host -
        // covers "https://github.com/owner/repo", "http://github.com/...",
        // and a bare "github.com/owner/repo" all the same way.
        NSRange schemeRange = [s rangeOfString:@"://"];
        if (schemeRange.location != NSNotFound) {
            s = [s substringFromIndex:NSMaxRange(schemeRange)];
        }
        if ([s.lowercaseString hasPrefix:@"github.com/"]) {
            s = [s substringFromIndex:@"github.com/".length];
        }
    }

    if ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    if ([s.lowercaseString hasSuffix:@".git"]) s = [s substringToIndex:s.length - @".git".length];

    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"/"];
    if (parts.count != 2) return NO;

    NSString *owner = parts[0];
    NSString *name = parts[1];
    if (owner.length == 0 || name.length == 0) return NO;

    if (outOwner) *outOwner = owner;
    if (outName) *outName = name;
    return YES;
}

// Canonical display form the repo link field is reformatted to after a
// successful parse/save (see -gd_persistAuthFields) - collapses whatever
// shape the person pasted (full URL, SSH form, etc.) down to the same
// short "owner/repo" form the field's own placeholder shows.
static NSString *gd_format_github_repo_link(NSString *owner, NSString *name) {
    if (owner.length == 0 || name.length == 0) return @"";
    return [NSString stringWithFormat:@"%@/%@", owner, name];
}

// Strips a redundant leading HTTP auth scheme ("Bearer " or "token ",
// GitHub accepts either for a classic PAT) from whatever was typed or
// pasted into the Personal Access Token field, case-insensitively.
// +[BundleDoctorService bds_requestForPath:config:] always adds its own
// "Bearer " prefix when it builds the Authorization header - a token
// saved with one already on it (someone pasting a full curl -H
// "Authorization: Bearer ghp_xxx" line, or just typing "Bearer" out of
// habit, is an easy mistake) would otherwise round-trip into a literal
// "Bearer Bearer ghp_xxx" header, which GitHub rejects as bad
// credentials. Only ever strips ONE such prefix - if that leaves
// something that still starts with "bearer "/"token " (someone pasted
// the scheme twice themselves), that's left alone rather than guessed
// at further.
static NSString *gd_sanitize_personal_access_token(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray<NSString *> *schemePrefixes = @[@"bearer ", @"token "];
    for (NSString *prefix in schemePrefixes) {
        if (s.length > prefix.length && [[s substringToIndex:prefix.length].lowercaseString isEqualToString:prefix]) {
            return [[s substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return s;
}

// Associated-object keys stashed on the UITextField itself by
// gd_make_labeled_glass_field_row below - the field's real glass-wrapped
// container, the row it originally lives in, and the exact constraints
// that pin it there. -gd_floatAuthField:/-gd_restoreAuthField: use these
// to lift the field out of the scrolling panel and back again while it's
// being edited, without having to rebuild any of that geometry from
// scratch. Only ever set on authRepoLinkField/authTokenField in
// practice (the only two fields built via this row), but keyed
// per-field rather than hardcoded so the mechanism isn't tied to those
// two specifically.
static void * const kGDAuthFieldContainerKey = (void *)&kGDAuthFieldContainerKey;   // the glass view (or bare field, pre-iOS-26) that visually IS the field
static void * const kGDAuthFieldRowKey = (void *)&kGDAuthFieldRowKey;               // fieldContainer's original superview
static void * const kGDAuthFieldRowConstraintsKey = (void *)&kGDAuthFieldRowConstraintsKey; // the constraints pinning fieldContainer inside that row - deactivated while floated, reactivated on restore
// Set only while the field is actually floated (nil the rest of the
// time) - the constraints pinning it above the keyboard, so
// -gd_restoreAuthField: knows what to tear down.
static void * const kGDAuthFieldFloatingConstraintsKey = (void *)&kGDAuthFieldFloatingConstraintsKey;

// Bare native-glass field row - the Auth section's GitHub Repository
// Link and Personal Access Token fields use this instead of
// gd_make_button_and_glass_field_row's button+field split, since
// neither of these two has a paired action button of its own (except
// the PAT field's Verify button, see `trailingButton` below). Reuses
// gd_wrap_field_in_native_glass so the field is the exact same real
// UIGlassEffect surface the Debug section's blacklist entry field uses
// (see that function's own header comment above) - same corner radius,
// same borderless UITextField underneath, same pre-iOS-26 flat-
// rectangle fallback. `secure` masks the field's entry (used for the
// PAT field so a shoulder-surf doesn't leak it). No longer takes a
// `title` - the "GitHub Repository Link"/"Personal Access Token"
// labels that used to sit above each field were dropped per request;
// the placeholder text alone identifies each field now. `trailingButton`,
// when non-nil, is placed to the right of the field within the same
// row - the field is narrowed to ~65% of the row's width (down from
// the full width it takes when trailingButton is nil) to make room for
// it. Only the PAT row passes one (its Verify button, see -buildPanel:'s
// Auth section below).
static GDRow *gd_make_labeled_glass_field_row(NSString *placeholder, BOOL secure, UIButton *trailingButton) {
    GDRow *row = [[GDRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UITextField *field = [[UITextField alloc] init];
    field.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    field.textColor = UIColor.whiteColor;
    field.tintColor = gd_accent_green_color();
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    field.secureTextEntry = secure;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    objc_setAssociatedObject(row, "gd_textfield", field, OBJC_ASSOCIATION_RETAIN);

    UIVisualEffectView *fieldGlass = gd_wrap_field_in_native_glass(field, 6);
    UIView *fieldContainer = fieldGlass ?: field;
    fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fieldContainer];

    // Named/kept as their own array (rather than folded into a single
    // activateConstraints: call) so -gd_floatAuthField: can deactivate
    // exactly these later - see kGDAuthFieldRowConstraintsKey above.
    NSMutableArray<NSLayoutConstraint *> *fieldConstraints = [NSMutableArray arrayWithArray:@[
        [fieldContainer.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [fieldContainer.topAnchor constraintEqualToAnchor:row.topAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:28],
        [row.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],
    ]];

    if (trailingButton) {
        trailingButton.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:trailingButton];
        // ~35% shrink off the field, handed straight to the button in
        // the freed space - matches gd_make_button_pair_row's 8pt gap.
        [fieldConstraints addObjectsFromArray:@[
            [fieldContainer.widthAnchor constraintEqualToAnchor:row.widthAnchor multiplier:0.65],
            [trailingButton.leadingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor constant:8],
            [trailingButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [trailingButton.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor],
            [trailingButton.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],
        ]];
    } else {
        [fieldConstraints addObject:[fieldContainer.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]];
    }

    NSArray<NSLayoutConstraint *> *finalFieldConstraints = [fieldConstraints copy];
    [NSLayoutConstraint activateConstraints:finalFieldConstraints];

    objc_setAssociatedObject(field, kGDAuthFieldContainerKey, fieldContainer, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(field, kGDAuthFieldRowKey, row, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(field, kGDAuthFieldRowConstraintsKey, finalFieldConstraints, OBJC_ASSOCIATION_RETAIN);

    return row;
}

// One row per already-added blacklisted term: the term itself, left-
// aligned, with a small "x" button pinned to the row's right extreme
// that removes just that entry - see -gd_removeBlacklistEntryTapped:.
// Replaces the old single "Ignoring: a, b, c" status label so each term
// is independently removable instead of only being clearable all at once.
static UIView *gd_make_blacklist_entry_row(NSString *term, id target, SEL removeAction) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = term;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:label];

    UIButton *removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    removeButton.translatesAutoresizingMaskIntoConstraints = NO;
    // Plain "xmark" (not .circle.fill) - the native glass configuration
    // below already supplies the round chrome, so a filled circle glyph
    // on top of it would double up the shape. Small symbol point size to
    // match the button's own compact footprint.
    UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:6 weight:UIImageSymbolWeightSemibold];
    UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
    gd_style_icon_button_as_native_glass(removeButton, xImage, [UIColor colorWithWhite:1 alpha:0.55]);
    [removeButton addTarget:target action:removeAction forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(removeButton, "gd_blacklistTerm", term, OBJC_ASSOCIATION_RETAIN);
    [row addSubview:removeButton];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:4],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:removeButton.leadingAnchor constant:-6],

        // Right extreme of the row, per request. A bit smaller than the
        // row's line height so it doesn't visually dominate a single
        // short term.
        [removeButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [removeButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [removeButton.widthAnchor constraintEqualToConstant:16],
        [removeButton.heightAnchor constraintEqualToConstant:16],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:3],
    ]];
    return row;
}

#pragma mark - Mods Library accordion rows

// Width (points) of the folder row's Add button - widened from the
// other 18x18 icon buttons on this row so it reads as a capsule/pill
// rather than a circle, while staying the same 18pt tall as its
// neighbors so it lines up with them.
static const CGFloat kGDFolderAddButtonWidth = 32;

// Folder header row for the Mods Library accordion: [chevron][folder
// icon][name] .... [Add pill][pencil][X]. The whole row is tappable
// for expand/collapse via a tap gesture wired to `target`/`action` - a
// bigger hit target beats a precise one for a disclosure control - but
// that gesture only covers the row's own background; the three
// trailing controls are real buttons the tap gesture doesn't intercept
// (UIKit routes a touch to the deepest hit-testing view first). The
// folder name is stashed as an associated object on the row itself
// (for the tap gesture) AND on each of the trailing buttons (for their
// own handlers) since each is wired up independently by the caller
// (see -gd_rebuildModsLibrary).
//
// Add/Rename are plain buttons the caller wires with target/action.
// Delete is NOT wired with target/action here - like every other X
// icon in this accordion, its hold-to-confirm gesture (and capsule-
// expand animation) is attached by the caller via the
// "gd_button_delete" associated object (see gd_attach_hold_to_confirm).
static UIView *gd_make_mods_folder_row(NSString *folderName, BOOL expanded, id target, SEL tapAction, SEL addAction, SEL renameAction) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);

    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:(expanded ? @"chevron.down" : @"chevron.right") withConfiguration:chevronConfig]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
    chevron.contentMode = UIViewContentModeCenter;
    [row addSubview:chevron];

    UIImageSymbolConfiguration *folderConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
    UIImageView *folderIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"folder.fill" withConfiguration:folderConfig]];
    folderIcon.translatesAutoresizingMaskIntoConstraints = NO;
    folderIcon.tintColor = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    folderIcon.contentMode = UIViewContentModeCenter;
    [row addSubview:folderIcon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = folderName;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:label];

    // X - delete, at the row's absolute far right extreme. Not wired
    // with addTarget:action: here - see this function's own header.
    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:6 weight:UIImageSymbolWeightSemibold];
    UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
    UIColor *xTint = [UIColor colorWithWhite:1 alpha:0.55];
    gd_style_icon_button_as_native_glass(deleteButton, xImage, xTint);
    objc_setAssociatedObject(deleteButton, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
    [row addSubview:deleteButton];
    objc_setAssociatedObject(row, "gd_button_delete", deleteButton, OBJC_ASSOCIATION_RETAIN);

    // Pencil - rename, immediately to the left of delete.
    UIButton *renameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    renameButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *pencilConfig = [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightSemibold];
    UIImage *pencilImage = [UIImage systemImageNamed:@"pencil" withConfiguration:pencilConfig];
    gd_style_icon_button_as_native_glass(renameButton, pencilImage, [UIColor colorWithWhite:1 alpha:0.6]);
    [renameButton addTarget:target action:renameAction forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(renameButton, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
    [row addSubview:renameButton];

    // Add - icon-only plus glyph, immediately to the left of the
    // pencil - adds more files into this already-existing folder
    // without going through the New Folder prompt again. Widened
    // (kGDFolderAddButtonWidth, vs. the 18pt-square pencil/X either
    // side of it) so its native-glass silhouette resolves as a capsule
    // rather than a circle - height stays 18pt like its neighbors so
    // it lines up with them.
    UIButton *addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *plusConfig = [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightSemibold];
    UIImage *plusImage = [UIImage systemImageNamed:@"plus" withConfiguration:plusConfig];
    gd_style_icon_button_as_native_glass(addButton, plusImage, [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [addButton addTarget:target action:addAction forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(addButton, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
    [row addSubview:addButton];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:tapAction];
    [row addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [chevron.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:2],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:14],

        [folderIcon.leadingAnchor constraintEqualToAnchor:chevron.trailingAnchor constant:4],
        [folderIcon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [folderIcon.widthAnchor constraintEqualToConstant:18],

        [label.leadingAnchor constraintEqualToAnchor:folderIcon.trailingAnchor constant:6],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:addButton.leadingAnchor constant:-6],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [deleteButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [deleteButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [deleteButton.widthAnchor constraintEqualToConstant:18],
        [deleteButton.heightAnchor constraintEqualToConstant:18],

        [renameButton.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-3],
        [renameButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [renameButton.widthAnchor constraintEqualToConstant:18],
        [renameButton.heightAnchor constraintEqualToConstant:18],

        [addButton.trailingAnchor constraintEqualToAnchor:renameButton.leadingAnchor constant:-3],
        [addButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [addButton.widthAnchor constraintEqualToConstant:kGDFolderAddButtonWidth],
        [addButton.heightAnchor constraintEqualToConstant:18],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-5],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:5],
    ]];
    return row;
}

// One tracked file's row, indented under its folder: [doc icon] [name]
// .... [Delete - only when expanded]. Tapping anywhere on the row
// (same whole-row tap-target approach as the folder row above) toggles
// the path/size/date-added dropdown the caller (see
// -gd_rebuildModsLibrary) inserts right after this row when the
// entry's path is in modsLibraryExpandedInfoEntries.
//
// Icon is a plain waveform glyph for a .bank file, a generic document
// glyph for anything else - there's no CAB-based bundle detection
// anymore (see ModAssetLibrary.h), so this is just an extension sniff
// for display, nothing more.
//
// Delete lives on THIS row, gated to only exist while `expanded` is
// true (i.e. only once the dropdown is actually open) - same "confirm
// you're looking at the right file before you can even reach delete"
// safety idea as the folder row's always-visible X. (This row used to
// also carry a per-entry Reset/restore button here, but it had no
// actual per-file restore target to call - see ModAssetLibrary.h's
// header - and only ever fell back to the panel's existing all-file
// "Restore Originals" action, same as it already runs on every backed-
// up bank/bundle; redundant with that section-level button, so it's
// been removed.) When YES, the returned view's "gd_button_delete"
// associated object is that button - the caller reads it the same way
// it always has to wire hold-to-confirm (see -gd_rebuildModsLibrary).
//
// --- Doctor-pipeline dispatch slot (dispatch/upload/process/download) ---
// Section 2 of the bundle-dispatch-UX rework (see progress.md). Only
// rows for a bundle-kind file get this slot at all - matched the same
// way -gd_handleLoadModsPickedURLs: already partitions picked files by
// kind (case-insensitive compare against "__data", not a re-derived
// pathExtension check - .bank rows never had a dispatch pipeline and
// still don't). ModAssetLibrary itself doesn't gate on file kind (see
// its own header) - this row-building function is where that decision
// actually lives, same as it already was for the bank/generic-doc icon
// choice a few lines up.
//
// UNLIKE Delete, this slot is NOT gated behind `showActions` - it
// renders regardless of whether the row's info dropdown is open.
// ModAssetLibraryDoctorStatusNotDispatched's own header comment ("default
// - dispatch capsule shown, nothing sent yet") reads as this being the
// row's normal at-rest affordance, not something buried behind an extra
// tap - and unlike Delete it isn't destructive, so there's no "protect
// against a stray tap" reason to hide it. When showActions is also YES
// (dropdown open, delete present), this slot sits immediately to the
// LEFT of the delete button, per the spec ("right next to the delete
// button ... on its left"). When showActions is NO, this is simply the
// row's trailing-most control.
//
// NotDispatched/ReadyToDownload render a small glass capsule button
// (gd_style_button_as_native_glass - same native-glass text-button API
// the panel's other one-shot actions use, just sized down to fit this
// row's compact chrome) titled "dispatch"/"download" and wired to
// `dispatchAction`/`downloadAction`. Uploading/Processing render plain
// percentage subtext instead - there's nothing to tap mid-transfer.
// Failed renders a small red "retry" capsule (wired to `retryAction`,
// the obvious "tap to go back to NotDispatched" behavior flagged in
// progress.md as not yet confirmed by the person) - the full
// doctorLastError text itself is NOT crammed into this row; it's
// added as an extra line in the entry's expandable info panel instead
// (see gd_make_mods_entry_info_panel) so a one-line row layout doesn't
// have to reflow around an arbitrarily long error string.
//
// dispatchAction/downloadAction/retryAction are only ever invoked with
// `entry` already stashed on the control via the same "gd_modsEntry"
// associated-object convention deleteButton uses above, so the
// target's handler can look the entry up the same way.
static const CGFloat kGDModsDoctorCapsuleHeight = 18;    // matches the row's existing 18pt icon-button footprint
static const CGFloat kGDModsDoctorCapsuleMinWidth = 54;  // enough for "dispatch"/"download"/"retry" at kGDModsDoctorCapsuleFontSize
// 40% smaller than the original 9pt, per the person's spec - the
// capsule's own kGDModsDoctorCapsuleMinWidth/Height aren't shrunk to
// match, so the text just sits smaller inside the same-size capsule.
static const CGFloat kGDModsDoctorCapsuleFontSize = 9 * 0.6;

static UIView *gd_make_mods_entry_row(ModAssetLibraryEntry *entry, id target, SEL tapAction,
                                       SEL dispatchAction, SEL downloadAction, SEL retryAction, BOOL showActions,
                                       BOOL downloadInFlight) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
    // entry.isAssetBundle is set once, at import time, from the file's
    // own UnityFS header bytes (see +[ModAssetLibrary
    // importFileURLs:intoFolder:error:]) - not re-derived from
    // entry.fileName here. A bundle-kind entry's fileName is always
    // literally "__data" (Unity's own loader requires that exact name),
    // but that's a consequence of being a bundle, not what identifies
    // one - see UnityBundleCAB.h's isUnityFSBundleAtPath: header comment.
    BOOL isDoctorEligible = entry.isAssetBundle;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:(isBank ? @"waveform" : @"doc.fill") withConfiguration:iconConfig]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    icon.contentMode = UIViewContentModeCenter;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = entry.fileName;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:tapAction];
    [row addGestureRecognizer:tap];

    UIButton *deleteButton = nil;
    if (showActions) {
        UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:6 weight:UIImageSymbolWeightSemibold];
        UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
        UIColor *xTint = [UIColor colorWithWhite:1 alpha:0.55];
        deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
        gd_style_icon_button_as_native_glass(deleteButton, xImage, xTint);
        objc_setAssociatedObject(deleteButton, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
        [row addSubview:deleteButton];
        objc_setAssociatedObject(row, "gd_button_delete", deleteButton, OBJC_ASSOCIATION_RETAIN);
    }

    // Doctor-pipeline slot - built after reset/delete so its leading
    // constraint can anchor against whichever of them (if either) is
    // actually present this pass.
    UIView *doctorView = nil;      // whichever view ends up in the slot - button or subtext label
    UIButton *doctorButton = nil;  // non-nil only for the tappable states (NotDispatched/ReadyToDownload/Failed)
    if (isDoctorEligible) {
        switch (entry.doctorStatus) {
            case ModAssetLibraryDoctorStatusNotDispatched: {
                // downloadInFlight doubles as "an iOS(9)-targeted
                // bundle's direct-to-disk install is running" here (see
                // -gd_doctorStartOrInstallForEntry:folderName:) - that
                // path never moves doctorStatus off NotDispatched (there's
                // no upload/process to track), so this is the only signal
                // this state has that something's actually in flight.
                // Same non-interactive subtext style Uploading/Processing/
                // downloading already use, for the same reason.
                if (downloadInFlight) {
                    UILabel *progressLabel = [[UILabel alloc] init];
                    progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
                    progressLabel.text = @"installing…";
                    progressLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                    progressLabel.textColor = gd_accent_green_color();
                    progressLabel.textAlignment = NSTextAlignmentRight;
                    objc_setAssociatedObject(row, "gd_label_doctorProgress", progressLabel, OBJC_ASSOCIATION_RETAIN);
                    doctorView = progressLabel;
                    break;
                }
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                gd_style_button_as_native_glass(doctorButton, @"dispatch", gd_accent_green_color());
                doctorButton.titleLabel.font = [UIFont systemFontOfSize:kGDModsDoctorCapsuleFontSize weight:UIFontWeightSemibold];
                [doctorButton addTarget:target action:dispatchAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "gd_button_dispatch", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
            case ModAssetLibraryDoctorStatusUploading: {
                NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, entry.doctorUploadProgress)) * 100.0);
                UILabel *progressLabel = [[UILabel alloc] init];
                progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
                progressLabel.text = [NSString stringWithFormat:@"%ld%% uploaded", (long)percent];
                progressLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                progressLabel.textColor = gd_accent_green_color();
                progressLabel.textAlignment = NSTextAlignmentRight;
                objc_setAssociatedObject(row, "gd_label_doctorProgress", progressLabel, OBJC_ASSOCIATION_RETAIN);
                doctorView = progressLabel;
                break;
            }
            case ModAssetLibraryDoctorStatusProcessing: {
                NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, entry.doctorProcessProgress)) * 100.0);
                UILabel *progressLabel = [[UILabel alloc] init];
                progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
                progressLabel.text = [NSString stringWithFormat:@"%ld%% processed", (long)percent];
                progressLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                progressLabel.textColor = gd_accent_green_color();
                progressLabel.textAlignment = NSTextAlignmentRight;
                objc_setAssociatedObject(row, "gd_label_doctorProgress", progressLabel, OBJC_ASSOCIATION_RETAIN);
                doctorView = progressLabel;
                break;
            }
            case ModAssetLibraryDoctorStatusReadyToDownload: {
                // downloadInFlight: the fetch+install for THIS row is
                // already running (see -gd_modsLibraryEntryDownloadTapped:'s
                // doctorDownloadInFlightPaths) - doctorStatus itself
                // stays ReadyToDownload for the whole thing (nothing to
                // persist mid-flight, see that method's own header), so
                // this is the one doctor-pipeline row state that isn't
                // driven by entry.doctorStatus alone. Render the same
                // non-interactive subtext style Uploading/Processing use
                // rather than a disabled button, so it doesn't look like
                // a still-tappable control that's simply not responding.
                if (downloadInFlight) {
                    UILabel *progressLabel = [[UILabel alloc] init];
                    progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
                    progressLabel.text = @"downloading…";
                    progressLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                    progressLabel.textColor = gd_accent_green_color();
                    progressLabel.textAlignment = NSTextAlignmentRight;
                    objc_setAssociatedObject(row, "gd_label_doctorProgress", progressLabel, OBJC_ASSOCIATION_RETAIN);
                    doctorView = progressLabel;
                    break;
                }
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                gd_style_button_as_native_glass(doctorButton, @"download", gd_accent_green_color());
                doctorButton.titleLabel.font = [UIFont systemFontOfSize:kGDModsDoctorCapsuleFontSize weight:UIFontWeightSemibold];
                [doctorButton addTarget:target action:downloadAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "gd_button_download", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
            case ModAssetLibraryDoctorStatusInstalled: {
                // No row-level capsule/subtext for this state anymore -
                // "installed" now surfaces as this entry's own Status
                // line in the Info dropdown instead (see
                // gd_make_mods_entry_info_panel), so there's nothing to
                // render in the dispatch slot itself. Terminal state,
                // same as before - just no view for it here.
                break;
            }
            case ModAssetLibraryDoctorStatusFailed: {
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                UIColor *failTint = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
                gd_style_button_as_native_glass(doctorButton, @"retry", failTint);
                doctorButton.titleLabel.font = [UIFont systemFontOfSize:kGDModsDoctorCapsuleFontSize weight:UIFontWeightSemibold];
                [doctorButton addTarget:target action:retryAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "gd_button_retry", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
        }
        if (doctorView) {
            objc_setAssociatedObject(doctorView, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
            [row addSubview:doctorView];
            objc_setAssociatedObject(row, "gd_view_doctor", doctorView, OBJC_ASSOCIATION_RETAIN);
        }
    }

    UIView *labelTrailingNeighbor = doctorView ?: (deleteButton ?: row);
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:22], // indented under the folder icon above
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:5],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:3],
    ]];

    if (deleteButton) {
        [NSLayoutConstraint activateConstraints:@[
            [deleteButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [deleteButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [deleteButton.widthAnchor constraintEqualToConstant:18],
            [deleteButton.heightAnchor constraintEqualToConstant:18],
        ]];
        if (doctorView) {
            [NSLayoutConstraint activateConstraints:@[
                [doctorView.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-3],
            ]];
        }
    } else if (doctorView) {
        // No delete this pass (row collapsed) - the doctor slot is
        // simply the row's own trailing-most control.
        [NSLayoutConstraint activateConstraints:@[
            [doctorView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        ]];
    }

    if (doctorView) {
        [NSLayoutConstraint activateConstraints:@[
            [doctorView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [doctorView.widthAnchor constraintGreaterThanOrEqualToConstant:kGDModsDoctorCapsuleMinWidth],
        ]];
        if (doctorButton) {
            [doctorView.heightAnchor constraintEqualToConstant:kGDModsDoctorCapsuleHeight].active = YES;
        }
    }

    return row;
}

// Expandable "Info" panel for one entry - full on-disk library path,
// bundle identity/platform (bundle-kind entries only), doctor-pipeline
// install status (bundle-kind entries only - see isDoctorEligible's own
// note in gd_make_mods_entry_row on why this class doesn't gate itself
// on file kind but this panel does), human-readable size, and date
// added. Path uses GDMarqueeLabel so a long value scrolls into view
// instead of getting truncated.
static UIView *gd_make_mods_entry_info_panel(ModAssetLibraryEntry *entry, BOOL downloadInFlight) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(container, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    UIStackView *panel = [[UIStackView alloc] init];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 2;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layoutMarginsRelativeArrangement = YES;
    panel.layoutMargins = UIEdgeInsetsMake(2, 38, 2, 4); // lines up under the entry name, past the folder/doc icon indent
    [container addSubview:panel];

    UIFont *subtextFont = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    UIColor *subtextColor = [UIColor colorWithWhite:1 alpha:0.4];

    // entry.path is this file's own on-disk library copy - shown as-is,
    // whether or not it's ever been swapped into the game. (This used to
    // show entry.livePathDescription - "where this would live within the
    // game's own files" - with a "not automatically routed" placeholder
    // for anything that field couldn't resolve; that's gone in favor of
    // always showing the one path this class actually knows for certain.)
    GDMarqueeLabel *pathLabel = [[GDMarqueeLabel alloc] init];
    pathLabel.text = [NSString stringWithFormat:@"Filepath: %@", entry.path];
    pathLabel.font = subtextFont;
    pathLabel.textColor = subtextColor;
    // Keyed by entry path so this marquee's scroll phase survives a
    // -gd_rebuildModsLibrary triggered by some OTHER row's dropdown -
    // see GDMarqueeLabel.marqueeKey.
    pathLabel.marqueeKey = [entry.path stringByAppendingString:@"|path"];
    [panel addArrangedSubview:pathLabel];

    // Bundle-only fields - a .bank entry has no CAB id, no Unity target
    // platform, and no doctor-pipeline install status (see
    // ModAssetLibraryDoctorStatus's own header on that last one being
    // meaningless for anything that never enters the doctor pipeline).
    if (entry.isAssetBundle) {
        if (entry.cabIdentifier.length > 0) {
            UILabel *identifierLabel = [[UILabel alloc] init];
            identifierLabel.text = [NSString stringWithFormat:@"Identifier: %@", entry.cabIdentifier];
            identifierLabel.font = subtextFont;
            identifierLabel.textColor = subtextColor;
            [panel addArrangedSubview:identifierLabel];
        }

        if (entry.targetPlatform) {
            int32_t platform = entry.targetPlatform.intValue;
            UILabel *platformLabel = [[UILabel alloc] init];
            platformLabel.text = [NSString stringWithFormat:@"Target Platform: %@(%d)", [UnityBundleCAB nameForTargetPlatform:platform], platform];
            platformLabel.font = subtextFont;
            platformLabel.textColor = subtextColor;
            [panel addArrangedSubview:platformLabel];
        }

        // Uploading/Processing show their live percent right in this
        // Status line now, instead of just a static "Not installed" -
        // same underlying doctorUploadProgress/doctorProcessProgress
        // the compact row capsule already reads (see
        // gd_make_mods_entry_row), just surfaced here too per the
        // person's spec. ReadyToDownload/NotDispatched-in-flight have no
        // byte-level percent to show (a single Contents API GET and a
        // direct on-disk install respectively - see
        // -gd_modsLibraryEntryDownloadTapped:'s and
        // -gd_doctorStartOrInstallForEntry:folderName:'s own headers), so
        // those just say what's happening instead of a percentage.
        NSString *statusText;
        switch (entry.doctorStatus) {
            case ModAssetLibraryDoctorStatusUploading: {
                NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, entry.doctorUploadProgress)) * 100.0);
                statusText = [NSString stringWithFormat:@"%ld%% Uploaded", (long)percent];
                break;
            }
            case ModAssetLibraryDoctorStatusProcessing: {
                NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, entry.doctorProcessProgress)) * 100.0);
                statusText = [NSString stringWithFormat:@"%ld%% Processed", (long)percent];
                break;
            }
            case ModAssetLibraryDoctorStatusReadyToDownload:
                statusText = downloadInFlight ? @"Downloading…" : @"Not installed";
                break;
            case ModAssetLibraryDoctorStatusNotDispatched:
                statusText = downloadInFlight ? @"Installing…" : @"Not installed";
                break;
            case ModAssetLibraryDoctorStatusInstalled:
                statusText = @"Installed";
                break;
            case ModAssetLibraryDoctorStatusFailed:
                statusText = @"Not installed";
                break;
        }
        UILabel *statusLabel = [[UILabel alloc] init];
        statusLabel.text = [NSString stringWithFormat:@"Status: %@", statusText];
        statusLabel.font = subtextFont;
        statusLabel.textColor = subtextColor;
        [panel addArrangedSubview:statusLabel];
    }

    UILabel *sizeLabel = [[UILabel alloc] init];
    sizeLabel.text = [NSString stringWithFormat:@"Size: %@", [NSByteCountFormatter stringFromByteCount:(long long)entry.byteSize countStyle:NSByteCountFormatterCountStyleFile]];
    sizeLabel.font = subtextFont;
    sizeLabel.textColor = subtextColor;
    [panel addArrangedSubview:sizeLabel]; // short enough it never needs to scroll - plain UILabel is fine

    UILabel *dateLabel = [[UILabel alloc] init];
    dateLabel.text = [NSString stringWithFormat:@"Date Added: %@", entry.dateAdded.length ? entry.dateAdded : @"unknown"];
    dateLabel.font = subtextFont;
    dateLabel.textColor = subtextColor;
    [panel addArrangedSubview:dateLabel];

    // Doctor-pipeline failure detail - only ever present when the row's
    // compact "retry" capsule (see gd_make_mods_entry_row) is showing,
    // i.e. doctorStatus == Failed. The full message lives here rather
    // than in the row itself so the row's own layout never has to
    // reflow around an arbitrarily long error string - see that
    // function's header comment for the rest of this reasoning.
    if (entry.doctorStatus == ModAssetLibraryDoctorStatusFailed && entry.doctorLastError.length) {
        GDMarqueeLabel *errorLabel = [[GDMarqueeLabel alloc] init];
        errorLabel.text = [NSString stringWithFormat:@"Error: %@", entry.doctorLastError];
        errorLabel.font = subtextFont;
        errorLabel.textColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:0.85];
        errorLabel.marqueeKey = [entry.path stringByAppendingString:@"|doctorError"];
        [panel addArrangedSubview:errorLabel];
    }

    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

static UILabel *gd_make_section_header(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [text uppercaseString];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    return label;
}

#pragma mark - Panel title block
//
// Sits at the very top of the scrollable stack, above the Display section -
// a small branding header for the panel itself rather than a setting row.
// "ZSingularity" with "ZS" set larger than the rest of the word (built as
// two runs in one attributed string, not two separate labels, so the
// baseline stays shared), plus a muted one-line credit underneath.
//
// Header font: Excelsior Sans, embedded in the binary and registered with
// Core Text at runtime - see GDEmbeddedFont.h and gd_excelsior_sans_font
// below. NOTE: the .ttf this was built from is a fan-made typeface (its
// own name table lists a "Trek, Classic Credits" copyright) that happens
// to share the name "Excelsior Sans" - it is NOT confirmed to be the same
// font asset the game itself uses internally (that one is a TextMeshPro
// SDF atlas, "ExcelsiorSans SDF", which isn't a real installed font and
// can't be loaded through UIFont at all - see the global-metadata strings
// this was cross-checked against). If a real copy of the game's font ever
// surfaces, swap kExcelsiorSansTTF's source .ttf and nothing else here
// needs to change.

// Registers the embedded Excelsior Sans data with Core Text exactly once,
// process-wide (kCTFontManagerScopeProcess - no plist entry, no on-disk
// file, nothing that outlives this process, which is the right lifetime
// for a tweak that's injected rather than installed). Safe to call this
// more than once; the dispatch_once below guarantees it only actually
// happens on the first call.
static void gd_register_embedded_fonts(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, kExcelsiorSansTTF, (CFIndex)kExcelsiorSansTTFLength);
        if (!data) return;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CFRelease(data);
        if (!provider) return;

        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            ZLog(@"[GraphicsDebugOverlay] Failed to parse embedded Excelsior Sans data");
            return;
        }

        CFErrorRef error = NULL;
        BOOL registered = CTFontManagerRegisterGraphicsFont(cgFont, &error);
        CGFontRelease(cgFont);

        if (!registered) {
            // Also treated as success: a prior run of this same process (or
            // -installIfNeeded firing twice) may have already registered it,
            // which Core Text reports as a duplicate-name error rather than
            // silently no-oping.
            NSError *nsError = (__bridge NSError *)error;
            ZLog(@"[GraphicsDebugOverlay] Excelsior Sans registration result: %@", nsError.localizedDescription ?: @"(already registered)");
        }
        if (error) CFRelease(error);
    });
}

// Confirmed via the embedded font's own 'name' table (nameID 6 / PostScript
// name): "EXCELSIORSANS". Family is "EXCELSIOR SANS", Regular weight only -
// there is no separate bold face in this file, so a bold request is
// synthesized from the regular face via UIFontDescriptor's symbolic bold
// trait rather than looked up under a second (nonexistent) PostScript name.
static UIFont *gd_excelsior_sans_font(CGFloat size, UIFontWeight weight) {
    gd_register_embedded_fonts();

    UIFont *regular = [UIFont fontWithName:@"EXCELSIORSANS" size:size];
    if (!regular) {
        ZLog(@"[GraphicsDebugOverlay] Excelsior Sans did not resolve after registration - falling back to system font");
        return [UIFont systemFontOfSize:size weight:weight];
    }
    if (weight < UIFontWeightSemibold) return regular;

    UIFontDescriptor *boldDescriptor =
        [regular.fontDescriptor fontDescriptorWithSymbolicTraits:regular.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold];
    return boldDescriptor ? [UIFont fontWithDescriptor:boldDescriptor size:size] : regular;
}

// Build number auto-injected by CI via -DZS_BUILD_NUMBER=<run number> on
// the "Compile tweak dylib" step in .github/workflows/build.yml (which
// already tags each release build-<run number>, so this reuses that same
// counter rather than introducing a second one). Falls back to 0 for a
// plain local `clang` invocation with no -D passed, so the panel still
// builds/runs outside CI - just labeled as a local build instead of a
// numbered one.
#ifndef ZS_BUILD_NUMBER
#define ZS_BUILD_NUMBER 0
#endif

static NSString *gd_version_string(void) {
    if (ZS_BUILD_NUMBER == 0) {
        return @"v0.0.1 (local build)";
    }
    return [NSString stringWithFormat:@"v0.0.1 build %d", ZS_BUILD_NUMBER];
}

// Shared by the version-tag badge (riding the wordmark's baseline) and
// the "Developed by trilliance" line below it - the two are meant to
// read as the same size, so both pull from this one constant instead
// of two separately-hardcoded numbers drifting apart later.
static const CGFloat kGDSubtitleFontSize = 10;

static UIView *gd_make_title_block(void) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.textAlignment = NSTextAlignmentNatural;

    NSString *fullTitle = @"ZSingularity";
    NSString *emphasized = @"ZS"; // larger prefix within the same word
    // 25% smaller across the board per request (was 60/45).
    UIFont *bigFont = gd_excelsior_sans_font(45, UIFontWeightBold);
    UIFont *restFont = gd_excelsior_sans_font(33.75, UIFontWeightBold);
    UIColor *titleColor = gd_accent_green_color();

    NSMutableAttributedString *titleString =
        [[NSMutableAttributedString alloc] initWithString:fullTitle
                                                 attributes:@{
            NSFontAttributeName: restFont,
            NSForegroundColorAttributeName: titleColor,
        }];
    [titleString addAttribute:NSFontAttributeName
                         value:bigFont
                         range:NSMakeRange(0, emphasized.length)];

    // Version tag, moved here from the subtitle line (per request) and
    // now sized to match the "Developed by trilliance" subtitle line
    // below (kGDSubtitleFontSize) rather than being derived from the
    // wordmark's own point size, so it reads as a small badge riding
    // the wordmark's own baseline rather than a second line of text.
    // Same accent green as the wordmark itself (per request) rather
    // than muted/white, so it reads as part of the header rather than
    // separate secondary detail. gd_version_string() below pulls the
    // build number CI stamps in at compile time, so this updates on
    // its own with every new build - no manual edit needed here.
    //
    // No NSBaselineOffsetAttributeName here (previously
    // restFont.descender - versionFont.descender): mixed-font runs
    // within one NSAttributedString/UILabel line already share a
    // single baseline by default, so that offset was actively pushing
    // the tag off the wordmark's own baseline rather than keeping it
    // there - it's what caused the Y-axis misalignment. Leaving
    // baseline alignment at its default puts this tag on exactly the
    // same line placement as "ZSingularity" itself.
    NSString *versionTag = [@" " stringByAppendingString:gd_version_string()];
    UIFont *versionFont = gd_excelsior_sans_font(kGDSubtitleFontSize, UIFontWeightMedium);
    NSAttributedString *versionString =
        [[NSAttributedString alloc] initWithString:versionTag
                                         attributes:@{
            NSFontAttributeName: versionFont,
            NSForegroundColorAttributeName: titleColor,
        }];
    [titleString appendAttributedString:versionString];

    headerLabel.attributedText = titleString;
    [container addSubview:headerLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = @"Developed by trilliance";
    subtitleLabel.textAlignment = NSTextAlignmentNatural; 
    subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    subtitleLabel.font = [UIFont systemFontOfSize:kGDSubtitleFontSize weight:UIFontWeightMedium];
    [container addSubview:subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [headerLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [headerLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],

        [subtitleLabel.topAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:2],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

#pragma mark - Overlay

@interface GraphicsDebugOverlay : NSObject <UIGestureRecognizerDelegate, UIScrollViewDelegate, UITextFieldDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIVisualEffectView *glassContainer; // UIGlassContainerEffect compositor for the dock.
@property (nonatomic, strong) UIVisualEffectView *panelGlass;         // Rounded Liquid Glass panel element.
@property (nonatomic, strong) UIVisualEffectView *handleGlass;        // Rounded Liquid Glass pull-tab element.
@property (nonatomic, strong) UIVisualEffectView *sliderGlassContainer; // Dedicated Liquid Glass compositor for slider pills.
@property (nonatomic, strong) UIView *sliderGlassContent;              // Contains only UIGlassEffect pill elements.
@property (nonatomic, strong) UIView *contentOverlay;                    // Setting content rendered above all glass compositors.
@property (nonatomic, strong) UIView *glassContainerContent;    // chrome.contentView.
@property (nonatomic, strong) UIView *panel;                    // transparent content/gesture host inside the glass surface.
@property (nonatomic, strong) UIView *handle;                   // transparent hit target inside the same glass surface.
@property (nonatomic, strong) UILabel *chevron;
@property (nonatomic, strong) UIView *scrollViewport;          // fixed viewport; owns the static edge mask so scrolling never moves the mask.
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) CGFloat panelWidth;
@property (nonatomic, strong) NSTimer *postFXReapplyTimer;
@property (nonatomic, strong) NSTimer *saveDebounceTimer;      // coalesces rapid slider-drag changes into one JSON write
@property (nonatomic, strong) UIVisualEffectView *syslogHandleGlass;
@property (nonatomic, strong) UIView *syslogHandle;
@property (nonatomic, strong) UILabel *syslogHandleLabel;
@property (nonatomic, strong) UIScrollView *syslogOverlay;       // scrollable window-level log viewport
@property (nonatomic, strong) UILabel *syslogTextLabel;
@property (nonatomic, assign) BOOL syslogTabEnabled;
@property (nonatomic, assign) BOOL syslogVisible;
@property (nonatomic, strong) NSMutableArray<NSString *> *syslogLines;
@property (nonatomic, strong) UITextField *syslogBlacklistField;
@property (nonatomic, strong) UILabel *syslogBlacklistStatusLabel;   // empty-state placeholder only - see -gd_rebuildSyslogBlacklistEntries
@property (nonatomic, strong) UIStackView *syslogBlacklistEntriesStack; // one removable row per blacklisted term
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *syslogBlacklist; // lowercased substrings to drop
@property (nonatomic, assign) CGFloat syslogHandleHeight; // recomputed whenever syslogHandleLabel's text changes (SYSLOG vs VERBOSE need different vertical run length) - see -gd_updateSyslogHandleLabelLayout

// Mods section's Auth sub-section - GitHub repo link + PAT for
// BundleDoctorService's doctor-bundle workflow (see BundleDoctorSettings.h).
// Loaded/saved via -gd_loadAuthFields/-gd_persistAuthFields (see the
// "Auth" pragma mark below); not yet wired to the actual send/intercept
// path - that's still a later checklist step.
@property (nonatomic, strong) UITextField *authRepoLinkField;
@property (nonatomic, strong) UITextField *authTokenField;
@property (nonatomic, strong) UIButton *authVerifyButton; // "Verify" - see -gd_authVerifyTapped:

// Config section's "Re-Encoding format" picker - see
// gd_make_reencode_format_row and -gd_reencodeFormatSelected: below.
// Kept so a selection can refresh the control (title text + menu
// checkmark) in place without rebuilding the whole panel. A single real
// native Liquid Glass button now - it owns .menu/.showsMenuAsPrimaryAction
// itself, no separate overlay view needed.
@property (nonatomic, strong) UIButton *reencodeFormatButton;

// Load Mods is a single button that routes each picked file to its own
// pipeline by kind (see -gd_handleLoadModsPickedURLs:intoFolder:): a
// .bank goes straight through BankTransplant (synchronous, batched); an
// "__data" asset bundle is just imported into the Mod Asset Library like
// any other file - it no longer auto-uploads to the doctor pipeline at
// import time (see "#pragma mark Mods (doctor pipeline)" below for the
// per-entry dispatch/poll/download flow that replaced that). There's no
// import-time picker/queue for the doctor pipeline anymore as a result -
// the old queue-shaped doctorTargetPicker/pendingDoctoredBundleURL
// (upload-then-pick-a-target-file) and loadModsDoctorQueue/
// loadModsCurrentDoctorSourceURL (one-at-a-time drain queue) are gone
// for good. The target-file-pick step they used to do at the tail of
// that queue is back, but reshaped per-entry rather than per-queue-item -
// see doctorInstallTargetPicker below and "#pragma mark Mods (doctor
// pipeline)"'s download handler.
@property (nonatomic, weak) UIDocumentPickerViewController *loadModsPicker;
@property (nonatomic, copy) NSString *loadModsTargetFolder;

// One line per file submitted through Load Mods this run - unrecognized-
// kind, bank-swap result, and "landed in the library" doctor-eligible
// files alike - flushed into one combined alert by
// -gd_presentLoadModsFinalSummary once -gd_processLoadModsBankURLs:
// finishes (there's no queue left to drain after it - see above).
@property (nonatomic, strong) NSMutableArray<NSString *> *loadModsSummaryLines;

// Mods Library (ModAssetLibrary.h) - bookkeeping shelf of tracked mod
// files, organized into named folders, rendered as an accordion in the
// same Mods section directly under the Load Mods / Restore Originals
// row (no section of its own). A folder is only ever created as part
// of -loadModsTapped now - there's no standalone "New Folder" control
// - and Load Mods is what imports files into it (see
// -gd_handleLoadModsPickedURLs:intoFolder: above). A folder's own
// "+" pill (gd_make_mods_folder_row) still adds more files into it
// later without going through Load Mods again.
@property (nonatomic, strong) UIStackView *modsLibraryStack;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedFolders;      // folder names currently expanded
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedInfoEntries;  // entry paths whose Info dropdown is open
// Generic "Add Asset" picker flow, separate from Load Mods' own picker
// and the doctor target picker above - weak ref to the live picker (so
// -documentPicker:didPickDocumentsAtURLs: can tell it apart from those)
// plus which folder it's importing into.
@property (nonatomic, weak) UIDocumentPickerViewController *libraryImportPicker;
@property (nonatomic, copy) NSString *libraryImportTargetFolder;

// Section 3 runtime state for the doctor-pipeline dispatch/poll flow
// (see "#pragma mark Mods (doctor pipeline)" below) - none of this is
// persisted itself (doctorStatus/doctorUploadProgress/etc. on the
// manifest entry are the actual source of truth, via
// +[ModAssetLibrary updateDoctorStateForEntry:inFolder:applyBlock:error:])
// - this is just the in-memory bookkeeping needed to drive it. Every
// dictionary here is keyed by ModAssetLibraryEntry.path, which is
// stable across a -gd_rebuildModsLibrary rebuild the way a stashed
// entry object itself isn't (a fresh array is read back from the
// manifest every rebuild).
//
// doctorPollTimers - one repeating 6s NSTimer per entry currently in
// ModAssetLibraryDoctorStatusProcessing, polling that run's status.
// Stopped (and removed) the moment that entry leaves Processing, for
// any reason (succeeded, failed, or reset via Retry).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTimer *> *doctorPollTimers;
// doctorUploadProgressLastPercent/doctorProcessProgressLastPercent -
// last rounded 0-100 percent actually written to the manifest (and
// rebuilt onto screen) for each entry, so a burst of upload-progress
// callbacks or a poll tick that reports the same percentage as last
// time is a no-op rather than another read-modify-write manifest
// write plus a full accordion rebuild.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorUploadProgressLastPercent;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorProcessProgressLastPercent;
// Entries (by path) whose "download" tap is currently being handled -
// fetch from GitHub, then (CAB match failing) a target-file pick, then
// install, all of which is NOT a manifest-persisted doctorStatus the
// way Uploading/Processing are (see -gd_modsLibraryEntryDownloadTapped:'s
// own header comment on why: a fetch is one un-resumable request, so
// there's nothing to recover on relaunch the way a killed upload's
// state needs -gd_recoverStaleDoctorStateForThisLaunch to handle - the
// row just falls back to a plain, re-tappable "download" capsule if the
// app dies mid-flight). Purely in-memory, same purpose as
// doctorUploadProgressLastPercent above: gd_make_mods_entry_row checks
// this set to render a non-interactive "downloading…" label instead of
// the button while a path is in it, and -gd_modsLibraryEntryDownloadTapped:
// checks it first to ignore a second tap on the same row mid-flight.
@property (nonatomic, strong) NSMutableSet<NSString *> *doctorDownloadInFlightPaths;
// Target-bundle picker for the download/install flow's manual fallback
// (see -gd_presentDoctorInstallTargetPickerForDoctoredURL:entryPath:
// inFolder: below) - separate from loadModsPicker/libraryImportPicker
// for the same reason those are separate from each other: so
// -documentPicker:didPickDocumentsAtURLs: can tell which flow a result
// belongs to. Only one of these can be presented at a time (it's a
// modal), so - unlike doctorDownloadInFlightPaths above, which can
// legitimately hold more than one entry mid-fetch at once - the pending
// fields below are singular, not dictionaries; a second entry reaching
// the "need a manual pick" branch while one is already up is turned
// away with an alert rather than queued (see that method).
@property (nonatomic, weak) UIDocumentPickerViewController *doctorInstallTargetPicker;
@property (nonatomic, copy) NSURL *doctorInstallPendingDoctoredURL;
@property (nonatomic, copy) NSString *doctorInstallPendingEntryPath;
@property (nonatomic, copy) NSString *doctorInstallPendingFolderName;
// Set once the very first time -gd_rebuildModsLibrary runs after this
// launch - gates -gd_recoverStaleDoctorStateForThisLaunch so it only
// ever inspects the manifest for leftover Uploading/Processing rows
// once per process lifetime, not on every one of the many rebuilds a
// normal session triggers (which would otherwise re-flip an upload
// that's actively in flight RIGHT NOW, in this same session, straight
// to Failed the instant its first progress callback rebuilds the row).
@property (nonatomic, assign) BOOL doctorStateRecoveredThisLaunch;

// Generic press-and-hold-to-confirm state, shared by every X (delete)
// icon in the Mods Library accordion (folder rows and entry rows
// alike) - see gd_attach_hold_to_confirm/-gd_handleHoldToConfirmGesture:.
// Only one hold can be in progress at a time, which is all a touch
// screen can physically drive anyway, so this is a handful of scalar
// properties rather than a per-button table.
@property (nonatomic, weak) UIButton *holdConfirmActiveButton;
@property (nonatomic, assign) NSTimeInterval holdConfirmStartTime;
@property (nonatomic, assign) BOOL holdConfirmTriggered;
@property (nonatomic, strong) CADisplayLink *holdConfirmDisplayLink;

// Auth section GitHub repo link / PAT fields: floated above the
// keyboard while being edited (see -gd_floatAuthField:/
// -gd_restoreAuthField:), since the panel sits low enough on screen
// that the system keyboard otherwise fully covers both fields. nil
// whenever neither auth field is being edited. gd_lastKeyboardFrame is
// updated on every -gd_keyboardWillChangeFrame: (in window coordinates)
// so a field can be positioned correctly the moment it's floated,
// without waiting on a fresh notification; authFieldFloatingBottomConstraint
// is the one constraint that same notification handler nudges directly
// (no fade) to track keyboard height changes - e.g. the predictive text
// bar - while a field is already floated.
@property (nonatomic, weak) UITextField *authFieldCurrentlyFloated;
@property (nonatomic, weak) NSLayoutConstraint *authFieldFloatingBottomConstraint;
@property (nonatomic, assign) CGRect gd_lastKeyboardFrame;

// Same idea as the block above, but for wide pill/text buttons that
// confirm a hold with a left-to-right fill sweeping across the whole
// button - i.e. literally the Syslog button's own hold mechanism (see
// -handleSyslogButtonLongPress:/-gd_syslogHoldTick:), generalized the
// same way the icon version above generalizes it for small X icons.
// Currently just the "Restore Bundles & Banks" button, but written to
// take any button + a completion block. Kept as its own separate set
// of state (rather than reusing holdConfirm* above) since the two
// button styles animate completely differently (a growing icon vs. a
// growing fill layer) and could, in principle, both be mid-hold at
// once (different sections of the panel).
@property (nonatomic, weak) UIButton *pillHoldConfirmActiveButton;
@property (nonatomic, assign) NSTimeInterval pillHoldConfirmStartTime;
@property (nonatomic, assign) BOOL pillHoldConfirmTriggered;
@property (nonatomic, strong) CADisplayLink *pillHoldConfirmDisplayLink;

// Verbose (tweak-only log) mode: engaged by holding the Debug section's
// "Syslog" button for kSyslogHoldDuration seconds - see
// -handleSyslogButtonLongPress: and -gd_enterSyslogVerboseMode.
@property (nonatomic, strong) UIButton *syslogButton;
@property (nonatomic, assign) BOOL syslogVerboseEnabled;
@property (nonatomic, strong) CALayer *syslogButtonFillLayer;   // red hold-progress fill, drawn directly on syslogButton.layer so it survives gd_style_button_as_native_glass rebuilding the button's UIButtonConfiguration-owned subviews
@property (nonatomic, strong) CADisplayLink *syslogHoldDisplayLink;
@property (nonatomic, assign) NSTimeInterval syslogHoldStartTime;
@property (nonatomic, assign) BOOL syslogHoldTriggered; // set once the 3s hold fires, so the touchUpInside from finger-lift doesn't also run the normal tap handler

// refs needed outside the generic builder (their actions do more than
// update a label).
@property (nonatomic, strong) GDCapsuleSlider *normalFpsSlider;
@property (nonatomic, strong) UILabel *normalFpsValueLabel;
@property (nonatomic, strong) GDCapsuleSlider *combatFpsSlider;
@property (nonatomic, strong) UILabel *combatFpsValueLabel;

+ (instancetype)shared;
- (void)installIfNeeded;
@end

static const NSTimeInterval kPostFXReapplyInterval = 1.0;
static const NSTimeInterval kSaveDebounceInterval = 0.4;

@implementation GraphicsDebugOverlay

+ (instancetype)shared {
    static GraphicsDebugOverlay *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [GraphicsDebugOverlay new]; });
    return instance;
}

- (void)installIfNeeded {
    if (self.panel) return;
    UIWindow *window = gd_key_window();
    if (!window) return;

    [self buildPanel:window];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(deviceOrientationChanged)
                                                  name:UIDeviceOrientationDidChangeNotification
                                                object:nil];

    // Drives the Auth section's floating-field-above-the-keyboard
    // behavior - see -gd_keyboardWillChangeFrame: and the
    // authFieldCurrentlyFloated/gd_lastKeyboardFrame property comments
    // above. WillChangeFrame (not WillShow/WillHide separately) covers
    // show, hide, and in-place height changes (e.g. the predictive text
    // bar toggling) through the one handler.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(gd_keyboardWillChangeFrame:)
                                                  name:UIKeyboardWillChangeFrameNotification
                                                object:nil];

    // The very first successful gd_key_window() call, right after the
    // game finishes launching, isn't a reliable place to read final
    // geometry from - safeAreaInsets in particular can still report 0
    // (or the window's bounds can still reflect a launch/placeholder
    // state) before the game's own window hierarchy has finished
    // settling. -deviceOrientationChanged is otherwise the only thing
    // that ever re-runs -layoutPanelForWindow:, so a bad first pass
    // here would silently stick for the entire session if the person
    // never rotates their device - which on a portrait-locked game
    // they may never do. Two cheap delayed re-layouts catch that
    // without needing to guess exactly when the window settles.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = gd_key_window();
        if (w && weakSelf.panel) [weakSelf layoutPanelForWindow:w];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = gd_key_window();
        if (w && weakSelf.panel) [weakSelf layoutPanelForWindow:w];
    });
}

- (void)toggleTapped {
    self.panelOpen = !self.panelOpen;
    [self positionPanel];
    [UIView animateWithDuration:0.25 animations:^{
        self.chevron.transform = self.panelOpen ? CGAffineTransformMakeRotation(M_PI) : CGAffineTransformIdentity;
    }];
}

// Swipe-right-to-close, requested as an alternative to re-tapping the
// handle. Lives on the whole panel (not just the handle) so it works
// wherever you happen to be scrolled to, but shouldRecognizeSimultaneously
// + shouldReceiveTouch below make sure it never steals a touch that's
// actually meant for a capsule slider, mode slider, switch, or button, and
// never blocks the scroll view's own vertical pan.
- (void)panelSwiped:(UIPanGestureRecognizer *)gesture {
    if (!self.panelOpen) return;
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint translation = [gesture translationInView:self.contentOverlay ?: gesture.view];
    BOOL mostlyHorizontal = fabs(translation.x) > fabs(translation.y) * 1.5;
    if (mostlyHorizontal && translation.x > 40) {
        [self toggleTapped];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // Let sliders/mode sliders/switches/buttons own touches that start on
    // them instead of the close-swipe recognizer racing them for it.
    if ([touch.view isKindOfClass:[GDCapsuleSlider class]]) return NO;
    if ([touch.view isKindOfClass:[GDModeSlider class]]) return NO;
    if ([touch.view isKindOfClass:[UISwitch class]]) return NO;
    if ([touch.view isKindOfClass:[UIButton class]]) return NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES; // coexist with the scroll view's own vertical pan
}

#pragma mark Panel

// The dock is a full-height right-side Liquid Glass container. The main
// panel is a rounded rectangle aligned to the physical right edge; the pull
// tab is another rounded rectangle immediately beside it. UIKit merges the
// two glass shapes rather than requiring a custom union mask.
static const CGFloat kPanelWidth = 320;
static const CGFloat kPanelPadding = 16;

// Vertical rhythm: kRowSpacing is the gap between two ordinary rows inside
// the same section (also the gap between a header and its first row).
// kSectionSpacing is the gap inserted BEFORE every section header via
// -setCustomSpacing:afterView: below, so every section-to-section boundary
// gets the same, deliberately larger gap regardless of what kind of row
// (slider/switch/button) happens to precede that header - previously every
// pair of arranged subviews shared the same stack.spacing, so the visual
// gap before a header quietly inherited whatever padding was baked into
// the preceding row's own layout (switch rows are inset less than slider
// rows), making some section boundaries look tighter than others.
static const CGFloat kRowSpacing = 4;
static const CGFloat kSectionSpacing = 20;

// Adds a section header to the stack, first widening the gap between it
// and whatever row precedes it (if any) so every section boundary reads
// with the same, larger break - see kSectionSpacing above.
static void gd_add_section_header(UIStackView *stack, NSString *title) {
    UIView *previous = stack.arrangedSubviews.lastObject;
    UILabel *header = gd_make_section_header(title);
    [stack addArrangedSubview:header];
    if (previous) {
        [stack setCustomSpacing:kSectionSpacing afterView:previous];
    }
}

// The panel and pull tab are separate Liquid Glass shapes inside one
// UIGlassContainerEffect. UIKit merges them when they are close enough.
//
// The panel keeps a normal rounded-rectangle geometry. The tab is intentionally
// rectangular-with-rounded-corners, not a capsule: 14pt is far below half of
// its 72pt height. The container's spacing is what makes their touching inner
// edges visually fuse into one continuous glass silhouette.
static const CGFloat kHandleWidth = 27; // 20% thinner than the original 34pt
static const CGFloat kHandleHeight = 72;
static const CGFloat kPanelCornerRadiusMinimum = 20;
static const CGFloat kHandleCornerRadius = 10;
static const CGFloat kGlassMergeSpacing = 16;
static const CGFloat kSyslogHandleHeight = 34;
static const CGFloat kSyslogHandleGap = 6; // small on purpose - lets the two shapes fuse together instead of staying visually separate.
static const CGFloat kContentFadeHeight = 22;

- (void)buildPanel:(UIWindow *)window {
    self.panelWidth = kPanelWidth;

    // UIKit's intended composition for nearby Liquid Glass shapes:
    // UIGlassContainerEffect merges its descendant UIGlassEffect views and
    // keeps their appearance uniform as their geometry changes.
    UIVisualEffectView *chrome = nil;

    if (gd_has_liquid_glass()) {
        chrome = [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_container_effect(kGlassMergeSpacing)];
    } else {
        // Older iOS fallback: retain the existing single-material behavior.
        chrome = [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_effect(NO)];
    }

    self.glassContainer = chrome;
    self.glassContainerContent = chrome.contentView;
    self.glassContainer.userInteractionEnabled = YES;
    [window addSubview:self.glassContainer];

    if (gd_has_liquid_glass()) {
        // Main panel: all four corners are rounded. UIKit resolves the
        // concentric radius from this glass element's container geometry.
        // interactive:YES is what turns on the system's built-in touch
        // response for a raw UIGlassEffect surface (the glow/bounce/stretch
        // as you touch and drag it) - it was off for every dock element
        // except the slider pills, which is why the panel/tab/log button
        // felt static compared to the rest of Liquid Glass.
        self.panelGlass = [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_effect(YES)];
        self.panelGlass.userInteractionEnabled = YES;
        gd_configure_glass_corners(self.panelGlass, kPanelCornerRadiusMinimum, YES);
        [self.glassContainerContent addSubview:self.panelGlass];

        // Pull tab: its four corners are rounded independently. Because this
        // element meets the panel inside the glass container, the touching
        // inner edges are merged rather than leaving a squared notch.
        self.handleGlass = [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_effect(YES)];
        self.handleGlass.userInteractionEnabled = YES;
        gd_configure_glass_corners(self.handleGlass, kHandleCornerRadius, NO);
        [self.glassContainerContent addSubview:self.handleGlass];

        self.panel = self.panelGlass.contentView;
        self.handle = self.handleGlass.contentView;
    } else {
        // Pre-iOS-26 fallback: there is no container compositor or
        // cornerConfiguration API, so keep the legacy hierarchy.
        self.panel = [[UIView alloc] init];
        self.handle = [[UIView alloc] init];
        self.panel.backgroundColor = UIColor.clearColor;
        self.handle.backgroundColor = UIColor.clearColor;
        [self.glassContainerContent addSubview:self.panel];
        [self.glassContainerContent addSubview:self.handle];
    }

    // Dedicated pill compositor. This is deliberately separate from the
    // dock compositor: UIGlassContainerEffect renders its glass behind its
    // contentView, so the container must not also contain the scroll hierarchy.
    // The pill glass therefore sits above the already-glassed dock surface,
    // producing the intended glass-on-glass result.
    if (gd_has_liquid_glass()) {
        self.sliderGlassContainer =
            [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_container_effect(0.0)];
        self.sliderGlassContainer.userInteractionEnabled = NO;
        self.sliderGlassContainer.opaque = NO;
        self.sliderGlassContent = self.sliderGlassContainer.contentView;
        self.sliderGlassContent.backgroundColor = UIColor.clearColor;
        [window addSubview:self.sliderGlassContainer];
    }

    // Foreground content lives in its own transparent window-level overlay.
    // This is the important z-order boundary: panel/slider Liquid Glass is
    // rendered first, then the actual labels, controls, green fills and
    // default markers are drawn above it at their normal alpha values.
    self.contentOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentOverlay.backgroundColor = UIColor.clearColor;
    self.contentOverlay.opaque = NO;
    self.contentOverlay.clipsToBounds = YES;
    self.contentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
    self.contentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentOverlay.userInteractionEnabled = YES;
    [window addSubview:self.contentOverlay];

    UIPanGestureRecognizer *closeSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelSwiped:)];
    closeSwipe.delegate = self;
    [self.contentOverlay addGestureRecognizer:closeSwipe];

    self.panel.backgroundColor = UIColor.clearColor;
    self.panel.clipsToBounds = NO;
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // The tab view itself is the contentView of handleGlass on iOS 26.
    // It remains transparent; handleGlass owns the visible material and shape.
    self.handle.backgroundColor = UIColor.clearColor;
    self.handle.clipsToBounds = NO;

    self.chevron = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kHandleWidth, 24)];
    self.chevron.textAlignment = NSTextAlignmentCenter;
    self.chevron.textColor = [UIColor colorWithWhite:1 alpha:0.66];
    self.chevron.font = [UIFont systemFontOfSize:15 weight:UIFontWeightLight];
    self.chevron.text = @"‹";
    self.chevron.center = CGPointMake(kHandleWidth * 0.5, kHandleHeight * 0.5);
    [self.handle addSubview:self.chevron];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleTapped)];
    [self.handle addGestureRecognizer:tap];
    self.handle.userInteractionEnabled = YES;

    // Secondary syslog pull tab. It is a small glass shape that lives in the
    // SAME UIGlassContainerEffect compositor as panelGlass/handleGlass
    // (glassContainerContent) rather than being added straight to the
    // window. Two things follow from that:
    //
    //  1. Being a subview of glassContainerContent means it moves for free
    //     whenever glassContainer's frame is animated open/closed in
    //     -positionPanelAnimated: - it no longer needs (or gets) its own
    //     window-space repositioning during that animation, which is why it
    //     used to look "stuck" on screen while the rest of the dock slid.
    //  2. Sharing the container is what makes it eligible to fuse with the
    //     other glass shapes at all. It's pinned to the same left column as
    //     the main handle (x in [0, kHandleWidth]), so its trailing edge
    //     runs flush against the panel's leading edge - that's the union
    //     with the panel. It sits immediately above the pull tab with a
    //     small kSyslogHandleGap, close enough to fuse into the same
    //     continuous glass silhouette as the tab too.
    self.syslogLines = [NSMutableArray array];
    self.syslogBlacklist = [NSMutableOrderedSet orderedSet];

    if (gd_has_liquid_glass()) {
        self.syslogHandleGlass =
            [[UIVisualEffectView alloc] initWithEffect:gd_make_glass_effect(YES)];
        self.syslogHandleGlass.userInteractionEnabled = YES;
        gd_configure_glass_corners(self.syslogHandleGlass, 8, NO);
        [self.glassContainerContent addSubview:self.syslogHandleGlass];
        self.syslogHandle = self.syslogHandleGlass.contentView;
    } else {
        self.syslogHandle = [[UIView alloc] init];
        self.syslogHandle.backgroundColor = UIColor.clearColor;
        self.syslogHandle.userInteractionEnabled = YES;
        [self.glassContainerContent addSubview:self.syslogHandle];
    }

    self.syslogHandle.backgroundColor = UIColor.clearColor;
    self.syslogHandle.clipsToBounds = NO;

    self.syslogHandleHeight = kSyslogHandleHeight;
    // Placeholder frame only - -gd_updateSyslogHandleLabelLayout (called
    // right below) immediately replaces this with correctly-sized
    // geometry for the real "SYSLOG" text, so the exact numbers here
    // don't matter.
    self.syslogHandleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kSyslogHandleHeight, kHandleWidth)];
    self.syslogHandleLabel.text = @"SYSLOG";
    self.syslogHandleLabel.textAlignment = NSTextAlignmentCenter;
    self.syslogHandleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.syslogHandleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    self.syslogHandleLabel.transform = CGAffineTransformMakeRotation(-((CGFloat)M_PI_2));
    self.syslogHandleLabel.center = CGPointMake(kHandleWidth * 0.5, kSyslogHandleHeight * 0.5);
    [self.syslogHandle addSubview:self.syslogHandleLabel];
    // Resolves the real height for "SYSLOG" (now that the label has its
    // real font) instead of relying on kSyslogHandleHeight's old
    // hand-picked-for-"LOG" value - see -gd_updateSyslogHandleLabelLayout.
    [self gd_updateSyslogHandleLabelLayout];

    UITapGestureRecognizer *syslogTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(syslogTabTapped)];
    [self.syslogHandle addGestureRecognizer:syslogTap];

    // Transparent, window-level text-only log renderer. This is a
    // UIScrollView (not a plain UIView) so the log can be scrolled once it
    // grows past the visible viewport - see -layoutSyslogOverlayForWindow:.
    self.syslogOverlay = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.syslogOverlay.backgroundColor = UIColor.clearColor;
    self.syslogOverlay.opaque = NO;
    self.syslogOverlay.userInteractionEnabled = YES;
    self.syslogOverlay.showsVerticalScrollIndicator = YES;
    self.syslogOverlay.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.syslogOverlay.alwaysBounceVertical = YES;
    // The scroll view's own frame is the interactable/touchable zone -
    // clipsToBounds is off so the (wider) text column drawn inside it
    // still renders in full rather than getting visually cut off at the
    // narrower hit-testable edge. See -layoutSyslogOverlayForWindow: for
    // where the two widths are set independently.
    self.syslogOverlay.clipsToBounds = NO;
    [window addSubview:self.syslogOverlay];

    self.syslogTextLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.syslogTextLabel.backgroundColor = UIColor.clearColor;
    self.syslogTextLabel.opaque = NO;
    self.syslogTextLabel.numberOfLines = 0;
    self.syslogTextLabel.textAlignment = NSTextAlignmentLeft;
    self.syslogTextLabel.lineBreakMode = NSLineBreakByClipping;
    self.syslogTextLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:11.0]
        ?: [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    [self.syslogOverlay addSubview:self.syslogTextLabel];
    self.syslogHandle.hidden = YES;
    self.syslogHandleGlass.hidden = YES;
    self.syslogOverlay.hidden = YES;

    __weak typeof(self) weakSelf = self;
    [ZSyslogController sharedController].lineHandler = ^(NSString *line) {
        [weakSelf appendSyslogLine:line];
    };

    // Fixed viewport. The content mask is attached to this non-scrolling view,
    // so scrolling never moves or recomputes the fade geometry.
    self.scrollViewport = [[UIView alloc] init];
    self.scrollViewport.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollViewport.backgroundColor = UIColor.clearColor;
    self.scrollViewport.clipsToBounds = NO;
    [self.contentOverlay addSubview:self.scrollViewport];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.scrollView.delegate = self; // drives on-screen-only slider Liquid Glass, see gd_updateSliderGlassVisibility
    // Default UIScrollView behavior holds every touch for a beat before
    // delivering it to a subview, so its own pan gesture gets first
    // refusal on anything that turns into a drag. Ordinary buttons don't
    // notice - a touchUpInside still fires once the touch ends, delay or
    // not - which is why Verify/Reset/Reapply/etc. all work fine as-is.
    // The Config section's Re-Encoding format field (see
    // gd_make_reencode_format_row) is the one control in this panel that
    // presents its UIMenu via .showsMenuAsPrimaryAction rather than a
    // plain target-action tap, and that presentation is driven by a far
    // more timing-sensitive touch-down interaction than a normal button -
    // held back by the scroll view's default delay, it loses the race
    // and never gets to present, even though the button still visibly
    // highlights (the touch itself was never in doubt, only the menu).
    // Every row's own button already owns its taps correctly (see
    // -panelSwiped:'s shouldReceiveTouch: above, which keeps the close-
    // swipe gesture off of them) - it's specifically this scroll view's
    // built-in pan gesture, not that custom one, that was never told to
    // let go immediately.
    self.scrollView.delaysContentTouches = NO;
    [self.scrollViewport addSubview:self.scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollViewport.topAnchor constraintEqualToAnchor:self.contentOverlay.topAnchor],
        [self.scrollViewport.leadingAnchor constraintEqualToAnchor:self.contentOverlay.leadingAnchor],
        [self.scrollViewport.trailingAnchor constraintEqualToAnchor:self.contentOverlay.trailingAnchor],
        [self.scrollViewport.bottomAnchor constraintEqualToAnchor:self.contentOverlay.bottomAnchor],

        [self.scrollView.topAnchor constraintEqualToAnchor:self.scrollViewport.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.scrollViewport.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.scrollViewport.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.scrollViewport.bottomAnchor],
    ]];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = kRowSpacing;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:kPanelPadding],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:kPanelPadding],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-kPanelPadding],
        [self.stack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-(kPanelPadding * 2)],
    ]];

    if (!g_urpActive) g_urpActive = [NSMutableDictionary new];
    if (!g_urpValue) g_urpValue = [NSMutableDictionary new];

    // --- Load any persisted settings, falling back to the hardcoded
    // kDefault* constants (and each URP effect's own defaultV) for
    // anything missing or on first launch. The loaded/fallback value
    // becomes each control's CURRENT value; the kDefault* constant is
    // always what's shown as the default tick/dot and what the reset
    // button restores, regardless of what's loaded here.
    NSDictionary *saved = gd_load_settings_dictionary();
    NSNumber *(^num)(NSString *) = ^NSNumber *(NSString *key) {
        id v = saved[key];
        return [v isKindOfClass:[NSNumber class]] ? (NSNumber *)v : nil;
    };

    g_menuFPS      = num(@"menuFPS") ? num(@"menuFPS").integerValue : kDefaultMenuFPS;
    g_combatFPS    = num(@"combatFPS") ? num(@"combatFPS").integerValue : kDefaultCombatFPS;
    g_textureMip   = num(@"textureMip") ? num(@"textureMip").intValue : kDefaultTextureMipEngine;
    g_renderScale  = (num(@"renderScalePercent") ? num(@"renderScalePercent").floatValue : kDefaultRenderScalePct) / 100.0f;
    g_msaaIndex    = num(@"msaaIndex") ? num(@"msaaIndex").intValue : kDefaultMSAAIndex;
    g_hdrOn        = num(@"hdr") ? num(@"hdr").boolValue : kDefaultHDR;
    g_blurIntensity = num(@"motionBlur") ? num(@"motionBlur").floatValue : kDefaultMotionBlur;
    g_tonemapMode  = num(@"tonemapIndex") ? num(@"tonemapIndex").intValue : kDefaultTonemapIndex;
    g_aaModeIndex  = num(@"aaModeIndex") ? num(@"aaModeIndex").intValue : kDefaultAAModeIndex;
    g_aaQualityIndex = num(@"aaQualityIndex") ? num(@"aaQualityIndex").intValue : kDefaultAAQualityIndex;
    g_ditheringOn  = num(@"dithering") ? num(@"dithering").boolValue : kDefaultDithering;

    // Syslog blacklist round-trips through the same JSON file as every
    // other control above - see gd_current_settings_dictionary() in
    // GDScripts.m. self.syslogBlacklist already exists (created empty
    // earlier in this method); just repopulate it here, then mirror it
    // into g_syslogBlacklist so it isn't dropped the next time some
    // unrelated control's change triggers a save.
    NSArray *savedBlacklist = [saved[@"syslogBlacklist"] isKindOfClass:[NSArray class]] ? saved[@"syslogBlacklist"] : nil;
    for (id term in savedBlacklist) {
        if ([term isKindOfClass:[NSString class]]) [self.syslogBlacklist addObject:term];
    }
    g_syslogBlacklist = self.syslogBlacklist.array;

    NSDictionary *savedUrp = [saved[@"urpEffects"] isKindOfClass:[NSDictionary class]] ? saved[@"urpEffects"] : nil;
    for (int i = 0; i < kURPPostEffectCount; i++) {
        const GDVolumeEffectDef *def = &kURPPostEffects[i];
        NSString *name = [NSString stringWithUTF8String:def->name];
        g_urpActive[name] = @YES; // no toggle anymore - permanently active, tuned by its own slider
        if (def->floatField) {
            NSNumber *savedVal = [savedUrp[name] isKindOfClass:[NSNumber class]] ? savedUrp[name] : nil;
            g_urpValue[name] = @(savedVal ? savedVal.floatValue : def->defaultV);
        }
    }

    NSString *(^fpsFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%d", (int)roundf(v)]; };
    NSString *(^twoDecimalFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.2f", v]; };
    NSString *(^wholeNumberFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f", v]; };
    NSString *(^texFormat)(float) = ^NSString *(float position) {
        // position is slider-space (0 empty/worst .. 4 full/best); the
        // displayed/engine number is reversed from that - see header note.
        int32_t engineValue = 4 - (int32_t)roundf(position);
        return [NSString stringWithFormat:@"%d", (int)engineValue];
    };

    // --- Title block ---
    // Branding header for the panel itself, sitting above every section -
    // added first so it renders at the very top of the scroll content.
    UIView *titleBlock = gd_make_title_block();
    [self.stack addArrangedSubview:titleBlock];
    [self.stack setCustomSpacing:kSectionSpacing afterView:titleBlock];

    // --- Display ---
    gd_add_section_header(self.stack, @"Display");

    GDRow *normalRow = gd_make_slider_row(@"Menu FPS", 10, 120, g_menuFPS, fpsFormat);
    self.normalFpsSlider = normalRow.slider;
    self.normalFpsValueLabel = normalRow.valueLabel;
    normalRow.slider.defaultValue = kDefaultMenuFPS;
    normalRow.slider.hasDefaultValue = YES;
    [normalRow.slider addTarget:self action:@selector(normalFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:normalRow];

    GDRow *combatRow = gd_make_slider_row(@"Combat FPS", 10, 120, g_combatFPS, fpsFormat);
    self.combatFpsSlider = combatRow.slider;
    self.combatFpsValueLabel = combatRow.valueLabel;
    combatRow.slider.defaultValue = kDefaultCombatFPS;
    combatRow.slider.hasDefaultValue = YES;
    [combatRow.slider addTarget:self action:@selector(combatFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:combatRow];

    // --- Rendering ---
    gd_add_section_header(self.stack, @"Rendering");

    // Texture MIP: slider position 0..4, position 4 = full/best, position
    // 0 = empty/worst; displayed + engine value is (4 - position) so "0"
    // (max) sits at the full end and "4" (min) at the empty end - see
    // header note "Texture MIP reversed".
    float texInitialPosition = 4.0f - (float)g_textureMip;
    float texDefaultPosition = 4.0f - (float)kDefaultTextureMipEngine;
    GDRow *texRow = gd_make_slider_row(@"Texture MIP", 0, 4, texInitialPosition, texFormat);
    texRow.slider.defaultValue = texDefaultPosition;
    texRow.slider.hasDefaultValue = YES;
    [texRow.slider addTarget:self action:@selector(texChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:texRow];

    // Render Scale carries three reference points - 0.50/0.75/1.00 - each
    // marked with the same tick styling as every other slider's default
    // indicator (1.00 is already the actual default, so that one comes
    // from defaultValue below; 0.50/0.75 are added via indicatorValues).
    // Landing exactly on one swaps the numeric readout for its low/med/
    // high name instead.
    GDRow *scaleRow = gd_make_slider_row(@"Render Scale", 25, 100, g_renderScale * 100.0f, ^NSString *(float v) {
        if (fabsf(v - 50.0f) <= kDefaultValueEpsilon) return @"low";
        if (fabsf(v - 75.0f) <= kDefaultValueEpsilon) return @"med";
        if (fabsf(v - 100.0f) <= kDefaultValueEpsilon) return @"high";
        return [NSString stringWithFormat:@"%.2f", v / 100.0];
    });
    scaleRow.slider.defaultValue = kDefaultRenderScalePct;
    scaleRow.slider.hasDefaultValue = YES;
    scaleRow.slider.indicatorValues = @[@50.0f, @75.0f];
    [scaleRow.slider addTarget:self action:@selector(scaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:scaleRow];

    GDRow *msaaRow = gd_make_mode_slider_row(@"MSAA", @[@"1x", @"2x", @"4x", @"8x"], g_msaaIndex, kDefaultMSAAIndex);
    [msaaRow.modeSlider addTarget:self action:@selector(msaaChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:msaaRow];

    // --- Anti-Aliasing ---
    // Moved above Post FX (per request) - was previously the last section
    // before Reset.
    gd_add_section_header(self.stack, @"Anti-Aliasing");

    GDRow *aaModeRow = gd_make_mode_slider_row(@"AA Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], g_aaModeIndex, kDefaultAAModeIndex);
    [aaModeRow.modeSlider addTarget:self action:@selector(cameraAAModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaModeRow];

    GDRow *aaQualityRow = gd_make_mode_slider_row(@"AA Quality", @[@"Low", @"Med", @"High"], g_aaQualityIndex, kDefaultAAQualityIndex);
    [aaQualityRow.modeSlider addTarget:self action:@selector(cameraAAQualityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaQualityRow];

    GDRow *ditherRow = gd_make_switch_row(@"Dithering", g_ditheringOn);
    objc_setAssociatedObject(ditherRow.toggle, "gd_defaultBool", @(kDefaultDithering), OBJC_ASSOCIATION_RETAIN);
    [ditherRow.toggle addTarget:self action:@selector(cameraDitheringChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:ditherRow];

    // --- Post FX ---
    // "Bloom" is a UI-only relabel of the HDR toggle (still
    // set_supportsHDR under the hood) - moved to the front of this
    // section per request. It does not revive real bloom controls; see
    // file header for why the game's actual bloom parameters don't have
    // working sliders. HDR keeps its toggle since it has no paired
    // slider to fold into. Motion blur is a single slider (its old on/off
    // toggle was removed), and Tonemapping is now a mode slider (None/
    // Neutral/ACES - "None" already covers "off"). Every extended URP
    // effect is permanently active, tuned entirely by its own slider.
    gd_add_section_header(self.stack, @"Post FX");

    GDRow *hdrRow = gd_make_switch_row(@"Bloom", g_hdrOn);
    objc_setAssociatedObject(hdrRow.toggle, "gd_defaultBool", @(kDefaultHDR), OBJC_ASSOCIATION_RETAIN);
    [hdrRow.toggle addTarget:self action:@selector(hdrChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:hdrRow];

    GDRow *blurIntensityRow = gd_make_slider_row(@"Motion Blur", 0, 1, g_blurIntensity, twoDecimalFormat);
    blurIntensityRow.slider.defaultValue = kDefaultMotionBlur;
    blurIntensityRow.slider.hasDefaultValue = YES;
    [blurIntensityRow.slider addTarget:self action:@selector(blurIntensityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:blurIntensityRow];

    GDRow *tonemapRow = gd_make_mode_slider_row(@"Tonemap", @[@"None", @"Neutral", @"ACES"], g_tonemapMode, kDefaultTonemapIndex);
    [tonemapRow.modeSlider addTarget:self action:@selector(tonemapModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:tonemapRow];

    for (int i = 0; i < kURPPostEffectCount; i++) {
        const GDVolumeEffectDef *def = &kURPPostEffects[i];
        NSString *name = [NSString stringWithUTF8String:def->name];
        if (!def->floatField) continue;
        float currentVal = g_urpValue[name] ? g_urpValue[name].floatValue : def->defaultV;
        // Settings whose max magnitude is 20 or more (White Balance, Color/
        // ColorAdjustments - both +/-100) read as whole numbers, e.g. "-100"
        // rather than "-100.00" - decimals of a hundred-point range aren't
        // meaningful and just add visual noise. Smaller-range effects
        // (Chroma Aberration, Vignette, Film Grain, Lens Distortion, all
        // within +/-1) keep two-decimal precision since fractions matter
        // there.
        NSString *(^rowFormat)(float) = (def->maxV >= 20.0f) ? wholeNumberFormat : twoDecimalFormat;
        GDRow *sliderRow = gd_make_slider_row(name, def->minV, def->maxV, currentVal, rowFormat);
        sliderRow.slider.defaultValue = def->defaultV;
        sliderRow.slider.hasDefaultValue = YES;
        objc_setAssociatedObject(sliderRow.slider, "gd_urp_name", name, OBJC_ASSOCIATION_RETAIN);
        [sliderRow.slider addTarget:self action:@selector(urpEffectValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.stack addArrangedSubview:sliderRow];
    }

    // --- Debug ---
    // Moved above Config per request - this is now the last section
    // before Config's Reset/Reapply row.
    gd_add_section_header(self.stack, @"Debug");

    // Toggle Syslog + the blacklist entry field share one row, native
    // Liquid Glass field included - see gd_make_button_and_glass_field_row
    // for the 33%/66% width split. Typing a word/phrase and hitting
    // return adds it to the blacklist; any syslog line containing a
    // blacklisted substring (case-insensitive) is dropped before it's
    // ever added to the on-screen buffer - see -gd_syslogLineIsBlacklisted:
    // and -appendSyslogLine:.
    GDRow *syslogRow = gd_make_button_and_glass_field_row(@"Syslog",
                                                            [UIColor colorWithWhite:1 alpha:0.88],
                                                            @"Blacklist keywords");
    UIButton *syslogButton = objc_getAssociatedObject(syslogRow, "gd_button");
    self.syslogButton = syslogButton;
    [syslogButton addTarget:self action:@selector(toggleSyslogTapped) forControlEvents:UIControlEventTouchUpInside];

    // Hold-for-3-seconds -> Verbose mode. minimumPressDuration is 0
    // on purpose - see -handleSyslogButtonLongPress:'s comment for why
    // this recognizer owns the timing itself instead of using the
    // recognizer's own duration threshold. cancelsTouchesInView must be
    // NO or UIKit cancels the button's own touch tracking the instant
    // this recognizer enters UIGestureRecognizerStateBegan, which would
    // silently kill touchUpInside (and therefore -toggleSyslogTapped)
    // for every tap on this button, not just held ones.
    UILongPressGestureRecognizer *syslogHold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleSyslogButtonLongPress:)];
    syslogHold.minimumPressDuration = 0;
    syslogHold.cancelsTouchesInView = NO;
    [syslogButton addGestureRecognizer:syslogHold];

    self.syslogBlacklistField = objc_getAssociatedObject(syslogRow, "gd_textfield");
    self.syslogBlacklistField.delegate = self;
    [self.stack addArrangedSubview:syslogRow];
    [self.stack setCustomSpacing:8 afterView:syslogRow];

    UILabel *blacklistHeader = [[UILabel alloc] init];
    blacklistHeader.translatesAutoresizingMaskIntoConstraints = NO;
    blacklistHeader.text = @"Blacklisted keywords";
    blacklistHeader.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    blacklistHeader.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    [self.stack addArrangedSubview:blacklistHeader];

    // Empty-state placeholder - only ever the sole arranged subview of
    // syslogBlacklistEntriesStack when the blacklist is empty; otherwise
    // swapped out for one gd_make_blacklist_entry_row per term. See
    // -gd_rebuildSyslogBlacklistEntries.
    self.syslogBlacklistStatusLabel = [[UILabel alloc] init];
    self.syslogBlacklistStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.syslogBlacklistStatusLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
    self.syslogBlacklistStatusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.syslogBlacklistStatusLabel.text = @"No blacklisted terms";

    self.syslogBlacklistEntriesStack = [[UIStackView alloc] init];
    self.syslogBlacklistEntriesStack.axis = UILayoutConstraintAxisVertical;
    self.syslogBlacklistEntriesStack.spacing = 2;
    self.syslogBlacklistEntriesStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.syslogBlacklistEntriesStack];

    // self.syslogBlacklist was already restored from disk earlier in this
    // method (see the settings-load block above) - render whatever that
    // loaded now that the entries stack exists.
    [self gd_rebuildSyslogBlacklistEntries];

    // --- Mods ---
    // Load Mods is a single button - see -loadModsTapped and
    // -gd_handleLoadModsPickedURLs:intoFolder: - that prompts for a
    // folder name, then presents one file picker and routes each
    // picked file to its own pipeline by kind: BankTransplant.h does
    // the actual splice/backup/swap for a .bank; an "__data" asset
    // bundle is queued through BundleDoctorService's cloud doctor
    // pipeline instead (re-platformed to iOS + textures re-encoded via
    // the GitHub Actions workflow configured in the Auth section
    // below, then slotted in via BundleDoctorInstaller). Every
    // submitted file is also imported into the named folder in the
    // Mod Asset Library right below this row, regardless of which
    // pipeline (if any) it routed to. Restore Originals reverts every
    // backed-up .bank/bundle to its stock bytes, skipping (and not
    // counting) anything whose live bytes already match its backup
    // byte-for-byte - see -restoreOriginalsTapped /
    // -gd_performRestoreOriginalsForce:.
    gd_add_section_header(self.stack, @"Mods");
    GDRow *modsRow = gd_make_button_pair_row(
        @"Load Mods", [UIColor colorWithRed:0.55 green:0.42 blue:1.0 alpha:1.0],
        @"Restore Originals", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    UIButton *loadModsButton = objc_getAssociatedObject(modsRow, "gd_button_left");
    [loadModsButton addTarget:self action:@selector(loadModsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *restoreOriginalsButton = objc_getAssociatedObject(modsRow, "gd_button_right");
    // Hold-to-confirm (1.5s, same red-fill mechanism as the Syslog
    // button's own hold - see gd_attach_pill_hold_to_confirm) rather
    // than a plain tap - this is a destructive-ish bulk action, a
    // stray tap shouldn't run it. A quick tap now just plays an error
    // haptic instead of doing anything - see
    // -gd_handlePillHoldToConfirmGesture:. Reuses the `weakSelf`
    // already declared above for the Syslog line handler - still in
    // scope here, same method body.
    gd_attach_pill_hold_to_confirm(restoreOriginalsButton, self, ^{
        [weakSelf restoreOriginalsTapped];
    });
    [self.stack addArrangedSubview:modsRow];

    // Mod Asset Library - bookkeeping shelf of tracked mod files (see
    // ModAssetLibrary.h), rendered as an accordion directly under the
    // row above. Lives in the same Mods section rather than one of its
    // own - there's no header here. A folder is only ever created as
    // part of -loadModsTapped now (no standalone "New Folder" control);
    // each folder's own "+" pill (gd_make_mods_folder_row) still adds
    // more files into it later without going through Load Mods again.
    // modsLibraryExpandedFolders/modsLibraryExpandedInfoEntries persist
    // which folders/entries are expanded across a -gd_rebuildModsLibrary
    // rebuild, the same way syslogBlacklist's own entries survive
    // rebuilds.
    self.modsLibraryExpandedFolders = [NSMutableSet set];
    self.modsLibraryExpandedInfoEntries = [NSMutableSet set];
    self.modsLibraryStack = [[UIStackView alloc] init];
    self.modsLibraryStack.axis = UILayoutConstraintAxisVertical;
    self.modsLibraryStack.spacing = 2;
    self.modsLibraryStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.modsLibraryStack];
    [self gd_rebuildModsLibrary];

    // --- Auth (Mods sub-section) ---
    // GitHub repo link + PAT for BundleDoctorService's doctor-bundle
    // workflow: the tweak forwards a modded desktop bundle to this
    // repo's GitHub Actions workflow, which re-platforms/re-encodes it
    // with AssetsTools.NET and hands the doctored bundle back - see
    // BundleDoctorSettings.h/.m for the persistence side of this (JSON
    // file for repoOwner/repoName, Keychain for the token). Two stacked
    // rows, each using the exact same native Liquid Glass field surface
    // as the Debug section's blacklist entry field
    // (gd_wrap_field_in_native_glass) via gd_make_labeled_glass_field_row
    // above, rather than gd_add_section_header's own full section-title
    // sizing - the per-field "GitHub Repository Link"/"Personal Access
    // Token" labels that used to sit above each of these two fields have
    // been dropped, so the placeholder text is now the only thing
    // identifying each field. Values are persisted via BundleDoctorSettings
    // on blur (see -gd_persistAuthFields) and pre-filled from it below;
    // the actual send/intercept wiring is still a later checklist step.
    gd_add_section_header(self.stack, @"Auth");

    GDRow *repoLinkRow = gd_make_labeled_glass_field_row(@"owner/repo", NO, nil);
    self.authRepoLinkField = objc_getAssociatedObject(repoLinkRow, "gd_textfield");
    self.authRepoLinkField.keyboardType = UIKeyboardTypeURL;
    self.authRepoLinkField.delegate = self;
    [self.stack addArrangedSubview:repoLinkRow];
    [self.stack setCustomSpacing:8 afterView:repoLinkRow];

    // PAT field is narrowed to make room for a "Verify" button
    // alongside it (see -gd_authVerifyTapped:) - a quick round-trip to
    // the GitHub API to confirm the repo link + token actually
    // authenticate, without having to load/dispatch a mod bundle just
    // to find out a stale token is the problem.
    self.authVerifyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.authVerifyButton.translatesAutoresizingMaskIntoConstraints = NO;
    gd_style_auth_verify_button(self.authVerifyButton, @"Verify");
    [self.authVerifyButton addTarget:self action:@selector(gd_authVerifyTapped:) forControlEvents:UIControlEventTouchUpInside];

    GDRow *authTokenRow = gd_make_labeled_glass_field_row(@"ghp_xxxxxxxxxxxxxxxxxxxx", YES, self.authVerifyButton);
    self.authTokenField = objc_getAssociatedObject(authTokenRow, "gd_textfield");
    self.authTokenField.delegate = self;
    [self.stack addArrangedSubview:authTokenRow];

    // Both fields now exist - pre-fill from whatever's already stored
    // (JSON file for the repo link, Keychain for the token; see
    // BundleDoctorSettings.h). +loadConfig always returns a non-nil
    // config even when nothing was ever saved, so this is safe to call
    // unconditionally on every panel build.
    [self gd_loadAuthFields];

    // --- Config ---
    // Native Liquid Glass, sized to match every other row/button on the
    // panel (see gd_make_button_row). This section is deliberately the
    // very last one added to the stack, so it renders at the bottom of
    // the scroll content, per request - that's still true with
    // Re-Encoding format now sitting first WITHIN the section (see
    // below), it's only Reset/Reapply/Hard Assets Reset that moved down
    // a row. Reset and Reapply share one row via
    // gd_make_button_pair_row - Reset puts every control back on its
    // hardcoded default and pushes that to the engine; Reapply re-pushes
    // whatever the panel's current values already are, without touching
    // any of them - the same manual escape hatch as the isRunningLoad
    // poll in GDScripts.m, for a load the poll missed or a value that
    // got stomped by opening the game's own settings menu (see this
    // file's header caveat on that). Hard Assets Reset (see below) is a
    // third, unrelated one-shot action tacked onto the same section
    // rather than getting a section of its own - it's still config-ish
    // ("housekeeping for this tweak's own state"), just a different
    // scope of action from Reset/Reapply's graphics-settings-only
    // scope.
    gd_add_section_header(self.stack, @"Config");

    // Re-Encoding format - first row in the section per request. See
    // this file's "Re-Encoding format (Config section)" pragma mark
    // above (gd_make_reencode_format_row / -gd_reencodeFormatSelected:)
    // for why this exists: config.outputFormat was never set by
    // anything in this file before, so every dispatch silently used
    // the re-encoder's own RGBA32 default regardless of what the repo
    // could actually target. Reads whatever's currently saved (falling
    // back to kGDDefaultReencodeFormat only for the field's initial
    // display, same "RGBA32" the re-encoder itself defaults to) so the
    // field's text always matches what the NEXT
    // dispatch would use.
    NSString *currentReencodeFormat = [BundleDoctorSettings loadConfig].outputFormat;
    if (currentReencodeFormat.length == 0) currentReencodeFormat = kGDDefaultReencodeFormat;
    GDRow *reencodeFormatRow = gd_make_reencode_format_row(currentReencodeFormat, ^(NSString *selectedFormat) {
        [weakSelf gd_reencodeFormatSelected:selectedFormat];
    });
    self.reencodeFormatButton = objc_getAssociatedObject(reencodeFormatRow, "gd_button");
    [self.stack addArrangedSubview:reencodeFormatRow];

    // Both switches below gate existing behavior elsewhere in the
    // project (PatchManifestNetwork.m / BundleDoctorService.m) rather
    // than anything this file owns itself - each is read live off
    // NSUserDefaults at the point of use, so flipping either here takes
    // effect immediately, no relaunch needed. Deliberately NOT given a
    // "gd_defaultBool" association (see -resetSettingsTapped above):
    // these are dispatch/network behavior, not graphics settings, so
    // "Reset Settings" leaves them alone.
    GDRow *fmodZeroingRow = gd_make_switch_row(@"Disable FModManifest zeroing", !PatchManifestNetwork.isZeroingEnabled);
    [fmodZeroingRow.toggle addTarget:self action:@selector(fmodZeroingDisableChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:fmodZeroingRow];

    GDRow *lz4hcRow = gd_make_switch_row(@"Disable LZ4HC compression on dispatch", !BundleDoctorService.isUploadCompressionEnabled);
    [lz4hcRow.toggle addTarget:self action:@selector(lz4hcCompressionDisableChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:lz4hcRow];

    GDRow *configRow = gd_make_button_pair_row(
        @"Reset Settings", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0],
        @"Reapply Settings", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    UIButton *resetButton = objc_getAssociatedObject(configRow, "gd_button_left");
    [resetButton addTarget:self action:@selector(resetSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reapplyButton = objc_getAssociatedObject(configRow, "gd_button_right");
    [reapplyButton addTarget:self action:@selector(reapplySettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:configRow];

    // Hard Assets Reset - full-width, below the Reset/Reapply pair
    // (gd_make_single_button_row, same as Load Mods used to be) rather
    // than sharing a pair row with either of them, since it's a
    // different scope of action entirely (mods/game-files bookkeeping,
    // not graphics settings) and deserves its own visual weight. Deep
    // red rather than the softer red Reset Settings/Restore Originals
    // use - this is the most destructive single action in the panel:
    // it deletes, outright, every asset this tweak ever swapped into
    // the game's own files (not a restore - see -hardAssetsResetTapped),
    // plus every backup and the entire Mod Asset Library. Gated behind
    // a 3s hold instead of the usual 1.5s (gd_attach_pill_hold_to_confirm_duration)
    // for exactly that reason. Still `weakSelf` from above, same scope
    // as restoreOriginalsButton's own hold-to-confirm block.
    GDRow *hardResetRow = gd_make_single_button_row(@"Hard Assets Reset", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    UIButton *hardResetButton = objc_getAssociatedObject(hardResetRow, "gd_button");
    gd_attach_pill_hold_to_confirm_duration(hardResetButton, self, 3.0, ^{
        [weakSelf hardAssetsResetTapped];
    });
    [self.stack addArrangedSubview:hardResetRow];

    [self layoutPanelForWindow:window];

    // One-shot push of every restored/default value to the engine, so a
    // relaunch (or a fresh install with no save file yet) actually takes
    // effect immediately rather than waiting for the panel to be opened -
    // see header caveat on the Post FX reapply timer only running while
    // the panel is open. The actual work (and the FPS side of it) lives
    // in GDScripts.m - see that file for why this same call also runs
    // from FPS120Controller's scene-state poll after a loading screen.
    gd_reapply_all_settings();
}

#pragma mark Settings persistence
//
// gd_current_settings_dictionary()/gd_load_settings_dictionary()/
// gd_write_settings_dictionary() live in GDScripts.m - this section is
// just the debounce plumbing that decides WHEN to call them from UI
// events.

// Debounced so a slider drag (many UIControlEventValueChanged per second)
// coalesces into a single JSON write shortly after the finger lifts,
// rather than hammering the filesystem on every intermediate value.
- (void)gd_scheduleSave {
    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kSaveDebounceInterval
                                                                target:self
                                                              selector:@selector(gd_writeSettingsNow)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)gd_writeSettingsNow {
    self.saveDebounceTimer = nil;
    gd_write_settings_dictionary(gd_current_settings_dictionary());
}

#pragma mark Reset

// Puts every control back on its hardcoded default (kDefault* / each URP
// effect's own defaultV), re-applies everything to the engine, and
// overwrites the save file immediately (bypassing the debounce, since this
// is a deliberate one-shot action rather than a drag in progress).
- (void)resetSettingsTapped {
    for (UIView *arranged in self.stack.arrangedSubviews) {
        if (![arranged isKindOfClass:[GDRow class]]) continue;
        GDRow *row = (GDRow *)arranged;
        if (row.slider && row.slider.hasDefaultValue) {
            row.slider.value = row.slider.defaultValue;
            gd_update_value_label(row.slider);
            [row.slider sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.modeSlider) {
            NSInteger def = row.modeSlider.defaultIndex >= 0 ? row.modeSlider.defaultIndex : 0;
            [row.modeSlider setSelectedIndex:def animated:YES];
            [row.modeSlider sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.toggle) {
            NSNumber *def = objc_getAssociatedObject(row.toggle, "gd_defaultBool");
            if (def) {
                row.toggle.on = def.boolValue;
                [row.toggle sendActionsForControlEvents:UIControlEventValueChanged];
            }
        }
    }

    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = nil;
    gd_write_settings_dictionary(gd_current_settings_dictionary());

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
}

// Manual counterpart to the isRunningLoad-triggered reapply in
// GDScripts.m - re-pushes every current panel value to the engine
// as-is, without changing any of them or touching the save file. Covers
// the same case that button exists for by hand: a load the poll's
// isRunningLoad read missed (or read before this build had that fix),
// or values getting stomped by opening the game's own settings menu and
// hitting Apply (see this file's header caveat on that).
- (void)reapplySettingsTapped {
    gd_reapply_all_settings();

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

#pragma mark Config (Hard Assets Reset)
//
// The nuclear option - NOT a restore. Every live asset this tweak has
// ever swapped into the game's own files is deleted outright (forcing
// a fresh fetch next time the game needs it), every backup this tweak
// has ever made is cleared, and the entire Mod Asset Library is wiped.
// Three separate classes each own the piece of this that matches what
// they already track, same "each class owns its own directory" split
// this project already uses everywhere else:
//   - BankTransplant: deletes every live .bank under
//     +mobileFMODBuildsDirectory that has a backup under
//     +bankBackupDirectory (that backup's existence IS the log of
//     "this bank's live path was touched"), then clears
//     +bankBackupDirectory itself.
//   - BundleDoctorInstaller: same idea, but the log is explicit -
//     its manifest.json under +bundleBackupDirectory maps a doctored
//     bundle's name to the exact original path it was installed over
//     (see that class's header on why an explicit manifest is needed
//     there and not for banks). Deletes the live file at every logged
//     path, then clears +bundleBackupDirectory itself.
//   - ModAssetLibrary: wipes +modLibraryRootDirectory entirely - this
//     is bookkeeping only and was never a "live" game file to begin
//     with, but it's still one of the four things this button promises
//     to clear.
// Gated behind a 3s hold (gd_attach_pill_hold_to_confirm_duration, see
// where hardResetButton is wired up in -buildPanel:) rather than the
// 1.5s every other hold-to-confirm control in this panel uses - this
// single action can throw away more than any other button here, so it
// gets a longer, more deliberate hold.
- (void)hardAssetsResetTapped {
    NSError *bankError = nil;
    NSInteger banksDeleted = [BankTransplant deleteAllTrackedBanksAndBackupsWithError:&bankError];

    NSError *bundleError = nil;
    NSInteger bundlesDeleted = [BundleDoctorInstaller deleteAllTrackedBundlesAndBackupsWithError:&bundleError];

    NSError *libraryError = nil;
    BOOL libraryCleared = [ModAssetLibrary deleteAllFoldersWithError:&libraryError];

    // The library's own accordion needs to reflect the wipe regardless
    // of how the rest of this went - it's rebuilt from whatever's on
    // disk, and that's now empty (or unaffected, if libraryCleared
    // failed and nothing actually changed).
    [self gd_rebuildModsLibrary];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (banksDeleted < 0 || bundlesDeleted < 0 || !libraryCleared) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = bankError.localizedDescription ?: bundleError.localizedDescription ?: libraryError.localizedDescription ?: @"Unknown error.";
        [self gd_presentModsAlertWithTitle:@"Hard Reset Failed" message:reason];
        return;
    }

    if (banksDeleted == 0 && bundlesDeleted == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self gd_presentModsAlertWithTitle:@"Nothing to Reset"
                                    message:@"No tracked banks or bundles were found. The Mod Asset Library has been cleared regardless."];
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSString *message = [NSString stringWithFormat:
        @"Deleted %ld bank%@ and %ld bundle%@ from the game's own files, cleared every backup, and emptied the Mod Asset Library. Restart the game for it to take effect.",
        (long)banksDeleted, banksDeleted == 1 ? @"" : @"s",
        (long)bundlesDeleted, bundlesDeleted == 1 ? @"" : @"s"];
    [self gd_presentModsAlertWithTitle:@"Hard Assets Reset" message:message];
}

#pragma mark Mods (Load Mods - single entry point, routes by file kind)
//
// UI-side glue only. Two swap-in pipelines live behind this one
// button: BankTransplant.h does the actual splice/backup/swap for a
// .bank (see that file's header for what "transplant" means there);
// an "__data" asset bundle goes through the separate BundleDoctorService
// cloud pipeline further down (see "#pragma mark Mods (doctor
// pipeline)"). Every file submitted through Load Mods is also imported
// into the Mod Asset Library folder created for this run, regardless
// of which (if either) pipeline it routed to - see
// -gd_handleLoadModsPickedURLs:intoFolder:. The Mods Library accordion
// itself (organizational bookkeeping only, doesn't swap anything in)
// is handled by its own "#pragma mark Mods Library" section further
// down.

// Load Mods' entry point: prompts for a folder name first (reusing the
// same compact one-field prompt the old standalone "New Folder"
// control used), creates that folder, then presents the file picker.
// Every file the person submits in that picker goes into the
// just-created folder - see -gd_handleLoadModsPickedURLs:intoFolder:.
- (void)loadModsTapped {
    __weak typeof(self) weakSelf = self;
    [self gd_promptForModFolderNameWithTitle:@"New Mod Folder"
                                  actionTitle:@"Create"
                                   completion:^(NSString *trimmedName) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *error = nil;
        BOOL created = [ModAssetLibrary createFolderNamed:trimmedName error:&error];
        if (!created) {
            [strongSelf gd_presentModsAlertWithTitle:@"Couldn't Create Folder" message:error.localizedDescription ?: @"Unknown error."];
            return;
        }
        [strongSelf gd_rebuildModsLibrary];
        [strongSelf gd_presentLoadModsPickerIntoFolder:trimmedName];
    }];
}

// Presents the system file picker so the person can hand-pick one or
// more mod files of either recognized kind (.bank or "__data") in a
// single pass. There's no registered UTI for either (an FMOD-specific
// container and an extensionless Unity asset bundle, not system
// types), so this opens on the generic "any file" content type rather
// than filtering.
- (void)gd_presentLoadModsPickerIntoFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods] no root view controller to present the file picker from");
        return;
    }
    self.loadModsPicker = picker;
    self.loadModsTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    if (controller == self.loadModsPicker) {
        NSString *folderName = self.loadModsTargetFolder;
        self.loadModsTargetFolder = nil;
        if (folderName) [self gd_handleLoadModsPickedURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.libraryImportPicker) {
        NSString *folderName = self.libraryImportTargetFolder;
        self.libraryImportTargetFolder = nil;
        if (folderName) [self gd_handlePickedLibraryImportURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.doctorInstallTargetPicker) {
        NSURL *doctoredURL = self.doctorInstallPendingDoctoredURL;
        NSString *entryPath = self.doctorInstallPendingEntryPath;
        NSString *folderName = self.doctorInstallPendingFolderName;
        self.doctorInstallPendingDoctoredURL = nil;
        self.doctorInstallPendingEntryPath = nil;
        self.doctorInstallPendingFolderName = nil;
        if (doctoredURL && entryPath && folderName) {
            [self gd_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:urls.firstObject entryPath:entryPath inFolder:folderName];
        }
        return;
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller == self.libraryImportPicker) {
        self.libraryImportTargetFolder = nil;
    }
    if (controller == self.doctorInstallTargetPicker) {
        NSString *entryPath = self.doctorInstallPendingEntryPath;
        NSString *folderName = self.doctorInstallPendingFolderName;
        self.doctorInstallPendingDoctoredURL = nil;
        self.doctorInstallPendingEntryPath = nil;
        self.doctorInstallPendingFolderName = nil;
        if (entryPath && folderName) {
            [self gd_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
                [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                     code:BundleDoctorInstallerErrorNoInstallTarget
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cancelled - no stock bundle was picked to install into."}]];
        }
    }
}

// Single entry point for everything Load Mods' picker returned.
// Imports every submitted file into the Mod Asset Library folder named
// moments earlier (tracked regardless of routing outcome - per spec,
// anything submitted lands in that folder), then partitions the files
// by kind: .bank files are swapped synchronously as one batch (see
// -gd_processLoadModsBankURLs:), "__data" files get one summary line
// noting they're sitting in the library ready to dispatch (dispatching
// is now a manual per-entry action - see "#pragma mark Mods (doctor
// pipeline)" below, there's no queue to feed here anymore), and
// anything else is reported as unrecognized. All three sets land in
// one combined end-of-run alert - see -gd_presentLoadModsFinalSummary.
- (void)gd_handleLoadModsPickedURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    if (urls.count == 0) return;

    NSError *importError = nil;
    BOOL imported = [ModAssetLibrary importFileURLs:urls intoFolder:folderName error:&importError];
    if (!imported) {
        ZLog(@"[Mods] couldn't add picked files to Mod Asset Library folder \"%@\": %@", folderName, importError);
    }
    [self gd_rebuildModsLibrary];

    NSMutableArray<NSURL *> *bankURLs = [NSMutableArray array];
    NSMutableArray<NSString *> *summaryLines = [NSMutableArray array];

    for (NSURL *url in urls) {
        if ([url.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
            [bankURLs addObject:url];
        } else if ([UnityBundleCAB isUnityFSBundleAtPath:url.path]) {
            // Identified by the file's own UnityFS header bytes, not its
            // name - any file can be handed to this picker regardless of
            // what it's called, and this project no longer requires an
            // asset bundle to specifically be named "__data" to be
            // recognized as one (see ModAssetLibrary.m's importer, which
            // uses the same check and gives each bundle its own
            // CAB-named subfolder).
            [summaryLines addObject:[NSString stringWithFormat:@"%@: added to Mods Library - tap Dispatch when ready to send it for processing", url.lastPathComponent]];
        } else {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: not a recognized bank or bundle", url.lastPathComponent]];
        }
    }

    self.loadModsSummaryLines = summaryLines;

    [self gd_processLoadModsBankURLs:bankURLs];
}

// Swaps every picked .bank on a background queue as one batch, appends
// one result line per file to loadModsSummaryLines, then closes out the
// run - see -gd_presentLoadModsFinalSummary. (There's no doctor queue
// to hand off to anymore - "__data" files already got their own
// summary line in -gd_handleLoadModsPickedURLs:intoFolder: above and
// don't do anything further until their entry's own Dispatch button is
// tapped.)
- (void)gd_processLoadModsBankURLs:(NSArray<NSURL *> *)bankURLs {
    if (bankURLs.count == 0) {
        [self gd_presentLoadModsFinalSummary];
        return;
    }

    UIViewController *presenter = gd_key_window().rootViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:@"Swapping Files\u2026"
                                                                       message:@"Matching modded banks against stock originals and swapping them in."
                                                                preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [working.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:working.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:working.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:working animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];

        for (NSURL *url in bankURLs) {
            NSError *bankErr = nil;
            BOOL ok = [BankTransplant transplantAndSwapModdedBankAtURL:url error:&bankErr];
            if (ok) {
                [lines addObject:[NSString stringWithFormat:@"%@: swapped", url.lastPathComponent]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, bankErr.localizedDescription ?: @"failed"]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            void (^afterDismiss)(void) = ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.loadModsSummaryLines addObjectsFromArray:lines];
                [strongSelf gd_presentLoadModsFinalSummary];
            };
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

// Restores every backed-up .bank/bundle to its original state - see
// +[BankTransplant restoreAllBackedUpBanksForce:error:] and
// +[BundleDoctorInstaller restoreAllBackedUpBundlesForce:error:]. A
// plain tap uses force:NO, so a bank/bundle whose live bytes already
// match its backup byte-for-byte is left alone and not counted -
// see -gd_performRestoreOriginalsForce: for what happens when that
// leaves nothing to restore.
- (void)restoreOriginalsTapped {
    [self gd_performRestoreOriginalsForce:NO];
}

// Bypasses the byte-identical check entirely - the "Force Restore"
// action offered on the "Nothing to Restore" alert (see
// -gd_presentRestoreNothingToRestoreAlertWithForceOption), for rewriting
// every backed-up bank/bundle regardless of whether it currently
// matches its backup already.
- (void)gd_forceRestoreOriginalsTapped {
    [self gd_performRestoreOriginalsForce:YES];
}

// Shared by both of the above - `force` is forwarded straight through
// to BankTransplant/BundleDoctorInstaller's own force switch on each
// class's restore-all method. See those methods' header comments for
// exactly what force:YES skips (only the byte-for-byte identical
// check - backup lookup/selection is unaffected either way).
- (void)gd_performRestoreOriginalsForce:(BOOL)force {
    NSError *bankError = nil;
    NSInteger banksRestored = [BankTransplant restoreAllBackedUpBanksForce:force error:&bankError];

    NSError *bundleError = nil;
    NSInteger bundlesRestored = [BundleDoctorInstaller restoreAllBackedUpBundlesForce:force error:&bundleError];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (banksRestored < 0 || bundlesRestored < 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = bankError.localizedDescription ?: bundleError.localizedDescription ?: @"Unknown error.";
        [self gd_presentModsAlertWithTitle:@"Restore Failed" message:reason];
        return;
    }

    if (banksRestored == 0 && bundlesRestored == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        if (force) {
            // Already forced through once and still nothing came back -
            // there's genuinely no backup for either kind, not just
            // everything already matching. Nothing further to offer.
            [self gd_presentModsAlertWithTitle:@"Nothing to Restore" message:@"No backed-up banks or bundles found."];
        } else {
            [self gd_presentRestoreNothingToRestoreAlertWithForceOption];
        }
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (banksRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld bank%@", (long)banksRestored, banksRestored == 1 ? @"" : @"s"]];
    }
    if (bundlesRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld bundle%@", (long)bundlesRestored, bundlesRestored == 1 ? @"" : @"s"]];
    }
    NSString *message = [NSString stringWithFormat:
        @"Restored %@ to their original state. Restart the game for it to take effect.",
        [parts componentsJoinedByString:@" and "]];
    [self gd_presentModsAlertWithTitle:@"Restore Originals" message:message];
}

// "Nothing to Restore" outcome of a plain (non-forced) restore - every
// backed-up bank/bundle's live bytes already matched its backup
// byte-for-byte, so nothing was actually rewritten. Offers "Force
// Restore" as an explicit escape hatch to rewrite them anyway, just in
// case something's still wrong in-game despite the bytes matching on
// disk (a "just in case" lever, not something a plain restore should
// ever need on its own).
- (void)gd_presentRestoreNothingToRestoreAlertWithForceOption {
    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] Nothing to Restore: every backed-up bank/bundle already matches its backup.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nothing to Restore"
                                                                     message:@"Every backed-up bank/bundle already matches its backup byte-for-byte. Force Restore rewrites them anyway, just in case."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Force Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf gd_forceRestoreOriginalsTapped];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Mods (doctor pipeline)
//
// send-and-intercept, client side, per-entry and opt-in: a "__data"
// bundle sits in the Mod Asset Library at ModAssetLibraryDoctorStatus
// NotDispatched (just like any other imported file) until the person
// taps that entry's own "dispatch" capsule (see gd_make_mods_entry_row)
// - there's no auto-upload-on-import and no blocking popup anymore (see
// progress.md's "Section 3 - Wiring / state machine" for the full
// before/after). From there BundleDoctorService's four decoupled phases
// (see that header) drive the entry through Uploading -> Processing ->
// ReadyToDownload -> Installed, with every transition persisted onto
// the manifest row via +[ModAssetLibrary updateDoctorStateForEntry:
// inFolder:applyBlock:error:] so it survives the app being backgrounded
// or killed mid-flight - see -gd_recoverStaleDoctorStateForThisLaunch
// below for what happens on the next launch after that (Installed isn't
// mentioned there - it's a terminal state with nothing left in flight
// to recover).
//
// Dispatch, Retry, and Download are all wired below (Section 3 is done,
// per progress.md's own split into first/second half). Download's own
// target-file-pick step - CAB-auto-match via UnityCacheLocator first,
// falling back to a manual UIDocumentPickerViewController pick - is the
// old queue-based flow's target-picker machinery, reintroduced adapted
// to a per-entry (rather than per-queue-item) shape; see
// -gd_modsLibraryEntryDownloadTapped:'s own header for the full three
// steps.

// ModAssetLibraryEntry doesn't carry the name of the folder it lives in
// (see ModAssetLibrary.h's own header on why - it's bookkeeping the
// panel itself owns) but every call into
// +updateDoctorStateForEntry:inFolder:applyBlock:error: below needs
// one, and a tap handler only ever gets the entry back (via the
// "gd_modsEntry" associated object - see gd_make_mods_entry_row).
// entry.path is always root/folderName/fileName for a flat (e.g. .bank)
// entry, but root/folderName/<CAB id>/__data for a bundle-kind one (see
// +[ModAssetLibrary importFileURLs:intoFolder:error:]) - so the owning
// folder is NOT reliably just the path's parent directory's last
// component anymore (that would return the CAB id for a bundle entry).
// Instead, strip +[ModAssetLibrary modLibraryRootDirectory] off the
// front and take the first remaining path component, which is
// folderName regardless of how many components follow it.
static NSString *gd_mods_folder_name_for_entry(ModAssetLibraryEntry *entry) {
    NSString *root = [ModAssetLibrary modLibraryRootDirectory];
    NSString *path = entry.path;
    if (root.length > 0 && [path hasPrefix:root]) {
        NSString *relative = [path substringFromIndex:root.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        NSString *first = relative.pathComponents.firstObject;
        if (first.length > 0) return first;
    }
    // Shouldn't normally happen (every entry's path is rooted under
    // modLibraryRootDirectory) - fall back to the old assumption rather
    // than returning nil.
    return path.stringByDeletingLastPathComponent.lastPathComponent;
}

// Lightweight stand-in for +updateDoctorStateForEntry:inFolder:
// applyBlock:error:'s `entry` argument, needed by every async callback
// below (upload progress, poll ticks) that only has an entry PATH
// (captured at dispatch time, stable across a rebuild) rather than a
// live entry object - that method only ever uses entry.path to find
// the manifest row it's mutating, per its own header, so this is all
// it needs.
static ModAssetLibraryEntry *gd_mods_entry_placeholder_for_path(NSString *path) {
    ModAssetLibraryEntry *placeholder = [ModAssetLibraryEntry new];
    placeholder.path = path;
    return placeholder;
}

static const NSTimeInterval kDoctorPollInterval = 6.0; // person's own spec: "polls the GitHub repo every 6 seconds"

// Wired to an entry row's "dispatch" capsule (NotDispatched state only
// - see gd_make_mods_entry_row). Flips the entry to Uploading, then
// kicks off BundleDoctorService's phase 1 (upload + commit + branch +
// workflow_dispatch). uploadProgress ticks are throttled to one
// manifest write + rebuild per whole-number percent (see
// -gd_doctorHandleUploadProgress:forEntryPath:inFolder:) rather than
// hammering both on every callback, which can fire many times a
// second per BundleDoctorService's own header.
- (void)gd_modsLibraryEntryDispatchTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "gd_modsEntry");
    if (!entry) return;
    NSString *folderName = gd_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Dispatch tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    [self gd_doctorStartOrInstallForEntry:entry folderName:folderName];
}

// Shared by Dispatch (NotDispatched state) and Retry (once it's reset
// an entry back to NotDispatched, below) - the actual "start moving
// this bundle toward Installed" decision, so both capsules go through
// exactly one place instead of Retry re-deriving it.
//
// An iOS(9)-targeted bundle (entry.targetPlatform - already sniffed at
// import time and shown in this entry's own info dropdown, see
// gd_make_mods_entry_info_panel) is already the platform the game
// itself expects, so the doctor pipeline's whole upload/re-platform/
// download round trip is pointless for it - there's nothing to
// re-target. Per the person's spec, that case skips straight to an
// on-disk install: no GitHub repo/token needed at all, just steps 2-3
// of the normal download flow (CAB-match-then-picker, then the actual
// swap - see -gd_modsLibraryEntryDownloadTapped:'s own header),
// treating the library's own already-iOS(9) file as the "doctored"
// source the exact same way a .bank mod is a direct file swap with no
// re-encoding (see BankTransplant.m). doctorDownloadInFlightPaths is
// reused as this path's in-flight marker too, since
// gd_doctorLocateInstallTargetForDoctoredURL:.../gd_doctorInstallDoctoredURL:...
// already add/remove from it on completion - see
// gd_make_mods_entry_row's NotDispatched case for how that reflects in
// the row itself ("installing…" instead of the dispatch capsule).
//
// Anything else goes through the normal pipeline via
// -gd_doctorBeginDispatchForEntry:folderName:.
- (void)gd_doctorStartOrInstallForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName {
    if (entry.targetPlatform && entry.targetPlatform.intValue == 9) {
        if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
        if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) return; // already installing - ignore the double-tap
        [self.doctorDownloadInFlightPaths addObject:entry.path];
        [self gd_rebuildModsLibrary];
        [self gd_doctorLocateInstallTargetForDoctoredURL:[NSURL fileURLWithPath:entry.path]
                                                entryPath:entry.path
                                                 inFolder:folderName];
        return;
    }

    [self gd_doctorBeginDispatchForEntry:entry folderName:folderName];
}

// The pipeline's actual phase-1 kickoff (upload + commit + branch +
// workflow_dispatch) - pulled out of -gd_modsLibraryEntryDispatchTapped:
// unchanged so -gd_modsLibraryEntryRetryTapped: can call the exact same
// thing once it's reset the entry, instead of just dropping back to the
// dispatch capsule and waiting for a second tap.
- (void)gd_doctorBeginDispatchForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName {
    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self gd_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    NSString *entryPath = entry.path; // captured now - stays valid as a manifest lookup key even once `entry` itself is stale
    [self.doctorUploadProgressLastPercent removeObjectForKey:entryPath];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusUploading;
        entryToMutate.doctorUploadProgress = 0.0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorLastError = nil;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't flip %@ to Uploading: %@", entry.fileName, stateError);
        return;
    }
    [self gd_rebuildModsLibrary];

    NSURL *bundleURL = [NSURL fileURLWithPath:entryPath];
    __weak typeof(self) weakSelf = self;
    [BundleDoctorService dispatchBundleAtURL:bundleURL
                                        config:config
                                uploadProgress:^(double fractionComplete) {
        [weakSelf gd_doctorHandleUploadProgress:fractionComplete forEntryPath:entryPath inFolder:folderName];
    }
                                    completion:^(BundleDoctorHandle * _Nullable handle, NSError * _Nullable error) {
        [weakSelf gd_doctorDispatchCompletedForEntryPath:entryPath inFolder:folderName handle:handle error:error];
    }];
}

// Wired to an entry row's "retry" capsule (Failed state only - see
// gd_make_mods_entry_row). Resets every doctor-pipeline field back to
// its NotDispatched default, same as before, but no longer stops
// there waiting for a second tap on a dispatch capsule that would then
// reappear - it immediately restarts the pipeline itself (or, for an
// iOS(9)-targeted bundle, goes straight to on-disk install) via
// -gd_doctorStartOrInstallForEntry:folderName:, the same routing
// Dispatch itself uses.
- (void)gd_modsLibraryEntryRetryTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "gd_modsEntry");
    if (!entry) return;
    NSString *folderName = gd_mods_folder_name_for_entry(entry);
    if (!folderName) return;

    [self gd_stopDoctorPollTimerForEntryPath:entry.path];
    [self.doctorUploadProgressLastPercent removeObjectForKey:entry.path];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entry.path];

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusNotDispatched;
        entryToMutate.doctorUploadProgress = 0.0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorScratchBranch = nil;
        entryToMutate.doctorRunID = nil;
        entryToMutate.doctorRunURL = nil;
        entryToMutate.doctorLastError = nil;
    }
                                                                           error:&error];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't reset %@ back to NotDispatched: %@", entry.fileName, error);
        return;
    }

    [self gd_doctorStartOrInstallForEntry:updated folderName:folderName];
}

// Throttled write-back for phase 1's uploadProgress callback - skips
// the manifest read-modify-write (and the accordion rebuild it would
// otherwise trigger) unless the rounded whole-number percent actually
// moved since the last call, since uploadProgress can fire many times
// a second per BundleDoctorService's own header.
- (void)gd_doctorHandleUploadProgress:(double)fractionComplete forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, fractionComplete)) * 100.0);
    if (!self.doctorUploadProgressLastPercent) self.doctorUploadProgressLastPercent = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorUploadProgressLastPercent[entryPath];
    if (last && last.integerValue == percent) return;
    self.doctorUploadProgressLastPercent[entryPath] = @(percent);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorUploadProgress = fractionComplete;
    }
                                                                           error:&error];
    if (!updated) return; // entry deleted mid-upload - nothing left to show progress on
    [self gd_rebuildModsLibrary];
}

// Phase 1 completion: on success, persists the handle's scratchBranch
// (runID/runURL are still nil at this point - phase 2 fills those in),
// flips the entry to Processing, and arms its poll timer. On failure,
// flips to Failed with the error surfaced via doctorLastError (full
// text goes in the entry's info-panel Error line - see
// gd_make_mods_entry_info_panel - the compact row itself just shows a
// "retry" capsule).
- (void)gd_doctorDispatchCompletedForEntryPath:(NSString *)entryPath
                                        inFolder:(NSString *)folderName
                                          handle:(BundleDoctorHandle *)handle
                                           error:(NSError *)error {
    [self.doctorUploadProgressLastPercent removeObjectForKey:entryPath];

    if (!handle) {
        [self gd_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
        return;
    }

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusProcessing;
        entryToMutate.doctorUploadProgress = 1.0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorScratchBranch = handle.scratchBranch;
        entryToMutate.doctorRunID = handle.runID;
        entryToMutate.doctorRunURL = handle.runURL;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] dispatch finished for %@ but its manifest entry is gone (deleted mid-upload?) - not arming a poll timer.", entryPath.lastPathComponent);
        return;
    }
    [self gd_rebuildModsLibrary];
    [self gd_armDoctorPollTimerForEntryPath:entryPath inFolder:folderName];
}

// Shared by every failure path below (upload failure, run resolve/
// status error, credentials pulled mid-poll) - stops this entry's poll
// timer (if any) and records the failure onto the manifest so the row
// falls back to a "retry" capsule.
- (void)gd_doctorFailEntryAtPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self gd_stopDoctorPollTimerForEntryPath:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
        entryToMutate.doctorLastError = error.localizedDescription ?: @"Unknown error.";
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't record doctor failure for %@ (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
        return;
    }
    [self gd_rebuildModsLibrary];
}

#pragma mark Mods (doctor pipeline) - 6s poll loop

// Arms a repeating kDoctorPollInterval-second timer for one Processing
// entry - same "timerWithTimeInterval:repeats:block: added to the main
// run loop in common modes" convention -startPostFXReapply already
// uses, so the poll keeps firing while the person is actively
// scrolling/dragging elsewhere in the panel. Fires once immediately
// (rather than waiting a full 6s for the first check) since the run is
// least likely to have shown up in the runs list yet right after
// dispatch anyway - see +resolveRunForHandle:config:completion:'s own
// header on why `found == NO` there is normal, not an error.
- (void)gd_armDoctorPollTimerForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorPollTimers) self.doctorPollTimers = [NSMutableDictionary dictionary];
    [self.doctorPollTimers[entryPath] invalidate]; // shouldn't already exist, but never double-arm

    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kDoctorPollInterval
                                              repeats:YES
                                                block:^(NSTimer *timer) {
        [weakSelf gd_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.doctorPollTimers[entryPath] = timer;

    [self gd_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
}

- (void)gd_stopDoctorPollTimerForEntryPath:(NSString *)entryPath {
    NSTimer *timer = self.doctorPollTimers[entryPath];
    [timer invalidate];
    [self.doctorPollTimers removeObjectForKey:entryPath];
}

// One poll tick for one entry: reads the entry's current on-disk state
// fresh (rather than trusting anything captured at arm-time, per
// +updateDoctorStateForEntry:...'s own "safe to call repeatedly from a
// timer even if the entry is stale" contract), bails out quietly if
// it's been deleted or has moved off Processing some other way, then
// runs phase 2 (resolve the run ID, if not already known) or phase 3
// (status + percent, once it is).
- (void)gd_pollDoctorRunForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *readError = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&readError];
    ModAssetLibraryEntry *current = nil;
    for (ModAssetLibraryEntry *candidate in entries) {
        if ([candidate.path isEqualToString:entryPath]) { current = candidate; break; }
    }
    if (!current || current.doctorStatus != ModAssetLibraryDoctorStatusProcessing) {
        // Deleted mid-flight, folder itself gone, or already resolved
        // (succeeded/failed/reset) through some other path - either
        // way, nothing left here for this timer to do.
        [self gd_stopDoctorPollTimerForEntryPath:entryPath];
        return;
    }

    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self gd_doctorFailEntryAtPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                 code:BundleDoctorServiceErrorInvalidConfig
                             userInfo:@{NSLocalizedDescriptionKey: @"GitHub auth was cleared while this bundle was still processing."}]];
        return;
    }

    BundleDoctorHandle *handle = [BundleDoctorHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": current.doctorScratchBranch ?: @"",
        @"runID": current.doctorRunID ?: @"",
        @"runURL": current.doctorRunURL ?: @"",
    }];
    if (!handle) {
        [self gd_doctorFailEntryAtPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:BundleDoctorServiceErrorDomain
                                 code:BundleDoctorServiceErrorRunNotFound
                             userInfo:@{NSLocalizedDescriptionKey: @"Lost track of this submission's scratch branch."}]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (current.doctorRunID.length == 0) {
        // Phase 2 - the run this dispatch created hasn't been resolved
        // yet. found == NO is normal (not an error) for the first few
        // seconds after a dispatch - just try again next tick.
        [BundleDoctorService resolveRunForHandle:handle config:config completion:^(BOOL found, NSError * _Nullable error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf gd_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
                return;
            }
            if (!found) return;
            [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                inFolder:folderName
                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorRunID = handle.runID;
                entryToMutate.doctorRunURL = handle.runURL;
            }
                                                   error:nil];
            [strongSelf gd_rebuildModsLibrary];
        }];
        return;
    }

    // Phase 3 - runID is known, check status + percent.
    [BundleDoctorService fetchRunStatusForHandle:handle config:config completion:^(BundleDoctorRunStatus status, double percentComplete, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (status == BundleDoctorRunStatusFailed) {
            [strongSelf gd_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
            return;
        }
        if (status == BundleDoctorRunStatusSucceeded) {
            [strongSelf gd_stopDoctorPollTimerForEntryPath:entryPath];
            [strongSelf.doctorProcessProgressLastPercent removeObjectForKey:entryPath];
            NSError *stateError = nil;
            ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                                                inFolder:folderName
                                                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusReadyToDownload;
                entryToMutate.doctorProcessProgress = 1.0;
            }
                                                                                   error:&stateError];
            if (updated) [strongSelf gd_rebuildModsLibrary];
            return;
        }
        // Queued/InProgress - just the percentage moved (or didn't).
        [strongSelf gd_doctorHandleProcessProgress:percentComplete forEntryPath:entryPath inFolder:folderName];
    }];
}

// Same whole-number-percent throttle as -gd_doctorHandleUploadProgress:
// forEntryPath:inFolder: above, applied to phase 3's percentComplete
// instead of phase 1's uploadProgress.
- (void)gd_doctorHandleProcessProgress:(double)fractionComplete forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, fractionComplete)) * 100.0);
    if (!self.doctorProcessProgressLastPercent) self.doctorProcessProgressLastPercent = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorProcessProgressLastPercent[entryPath];
    if (last && last.integerValue == percent) return;
    self.doctorProcessProgressLastPercent[entryPath] = @(percent);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorProcessProgress = fractionComplete;
    }
                                                                           error:&error];
    if (!updated) return;
    [self gd_rebuildModsLibrary];
}

// Runs once per process launch, the first time -gd_rebuildModsLibrary
// is called (see that method) - NOT on every rebuild, since that would
// re-inspect (and potentially misjudge) an entry that's actively
// mid-upload/mid-processing RIGHT NOW in this same session the instant
// its own first progress callback triggers a rebuild.
//
// Processing entries just get their poll timer re-armed (their
// scratchBranch/runID/runURL survive on the manifest, so polling can
// resume exactly where it left off - see ModAssetLibrary.h's own header
// on why those three fields are persisted at all).
//
// Uploading entries can't be resumed the same way - the in-flight
// NSURLSessionUploadTask (if any) died along with the process that
// launched it, so there's no partial upload left to continue. Per
// progress.md's own flag on this ("the honest thing to do... is almost
// certainly to flip it back to Failed... rather than pretend it's
// still uploading" - called out there as a real product decision, not
// a given): this flips those to Failed with a message explaining why,
// rather than either leaving a stuck "XX% uploaded" that will never
// move again, or silently resetting straight back to NotDispatched
// without a trace. Worth confirming with the person once this is
// actually reachable on a device.
- (void)gd_recoverStaleDoctorStateForThisLaunch {
    if (self.doctorStateRecoveredThisLaunch) return;
    self.doctorStateRecoveredThisLaunch = YES;

    for (NSString *folderName in [ModAssetLibrary folderNames]) {
        NSError *error = nil;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&error];
        for (ModAssetLibraryEntry *entry in entries) {
            if (entry.doctorStatus == ModAssetLibraryDoctorStatusUploading) {
                [ModAssetLibrary updateDoctorStateForEntry:entry
                                                    inFolder:folderName
                                                  applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                    entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
                    entryToMutate.doctorLastError = @"Upload was interrupted (the app was closed or backgrounded mid-upload). Tap Retry to send it again.";
                }
                                                       error:nil];
            } else if (entry.doctorStatus == ModAssetLibraryDoctorStatusProcessing) {
                if (!self.doctorPollTimers[entry.path]) {
                    [self gd_armDoctorPollTimerForEntryPath:entry.path inFolder:folderName];
                }
            }
        }
    }
}


// Flushes loadModsSummaryLines into one combined alert covering
// everything submitted through Load Mods this run - unrecognized
// files, every bank swap result, and every "added to the library, tap
// Dispatch when ready" line for a doctor-eligible file alike - then
// clears the run's state. -gd_processLoadModsBankURLs: calls straight
// through to this once its own batch is done, so this is always the
// last thing to run in a given Load Mods pass.
- (void)gd_presentLoadModsFinalSummary {
    NSArray<NSString *> *lines = self.loadModsSummaryLines ?: @[];
    self.loadModsSummaryLines = nil;

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    if (lines.count == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self gd_presentModsAlertWithTitle:@"No Files Loaded" message:@"No files were submitted."];
        return;
    }

    BOOL anySucceeded = NO;
    for (NSString *line in lines) {
        if ([line rangeOfString:@": swapped"].location != NSNotFound || [line rangeOfString:@": installed"].location != NSNotFound) {
            anySucceeded = YES;
            break;
        }
    }
    [haptic notificationOccurred:anySucceeded ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];
    NSString *message = [lines componentsJoinedByString:@"\n"];
    if (anySucceeded) {
        message = [message stringByAppendingString:@"\n\nRestart the game for swapped/installed files to take effect."];
    }
    [self gd_presentModsAlertWithTitle:@"Load Mods" message:message];
}

- (void)gd_presentModsAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] %@: %@", title, message);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// Recomputes syslogHandleHeight from the label's current text ("SYSLOG"
// vs "VERBOSE" need different vertical run lengths on screen) and
// re-applies the label's frame/transform/center to match.
//
// IMPORTANT axis note (this was backwards before and caused text to
// truncate as "SYS…"): UILabel lays text out along its PRE-rotation
// WIDTH, not its height - textAlignment/line-breaking all operate on
// bounds.width. The -90deg rotation then maps that width axis onto the
// TAB'S VERTICAL (long, on-screen) axis, and maps the label's
// pre-rotation HEIGHT onto the tab's fixed narrow physical WIDTH
// (kHandleWidth - basically the rotated text's font-row thickness).
// So the value that has to grow to fit "SYSLOG"/"VERBOSE" without
// truncating is the label's pre-rotation WIDTH, and it has to be the
// same number as the tab's on-screen height (self.syslogHandleHeight,
// consumed by -layoutPanelForWindow: for the tab's actual on-screen
// frame) - not kHandleWidth, which stays fixed as the tab's physical
// thickness.
- (void)gd_updateSyslogHandleLabelLayout {
    if (!self.syslogHandleLabel) return;
    CGSize textSize = [self.syslogHandleLabel.text sizeWithAttributes:@{NSFontAttributeName: self.syslogHandleLabel.font}];
    CGFloat height = MAX(kSyslogHandleHeight, ceil(textSize.width) + 14.0);
    self.syslogHandleHeight = height;

    // The label carries a rotation transform - reset it before touching
    // frame/bounds (resizing a transformed view's frame directly is
    // undefined), then reapply centered on the new size.
    self.syslogHandleLabel.transform = CGAffineTransformIdentity;
    self.syslogHandleLabel.frame = CGRectMake(0, 0, height, kHandleWidth);
    self.syslogHandleLabel.transform = CGAffineTransformMakeRotation(-((CGFloat)M_PI_2));
    self.syslogHandleLabel.center = CGPointMake(kHandleWidth * 0.5, height * 0.5);
}

#pragma mark Mods Library
//
// UI-side glue for ModAssetLibrary.h's folders/entries - see that
// header for what this bookkeeping shelf is and isn't (it does NOT
// swap anything into the game). Everything below either renders the
// accordion (-gd_rebuildModsLibrary and friends) or drives one of
// ModAssetLibrary's class methods from a tap/hold.

// Compact one-field name prompt, reused by "New Folder" and each
// folder row's own Rename button. Deliberately terse (no descriptive
// message under the title) - on a small phone, title + message + text
// field + two buttons could push the alert tall enough that the
// keyboard covered the field itself before the person had even typed
// anything. completion only runs with a validated (non-empty,
// trimmed) name; Cancel or an empty submission just backs out
// silently.
- (void)gd_promptForModFolderNameWithTitle:(NSString *)title
                                actionTitle:(NSString *)actionTitle
                                 completion:(void (^)(NSString *trimmedName))completion {
    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:title
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Folder name";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *trimmed = [(prompt.textFields.firstObject.text ?: @"")
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) return;
        completion(trimmed);
    }]];
    [presenter presentViewController:prompt animated:YES completion:nil];
}

// Full rebuild from +[ModAssetLibrary folderNames]/+entriesInFolder:error: -
// same "just throw the whole stack away and re-render" approach as
// -gd_rebuildSyslogBlacklistEntries, for the same reason (short lists,
// trivial ordering). modsLibraryExpandedFolders/modsLibraryExpandedInfoEntries
// are what survive the rebuild so expand state doesn't reset on every
// add/rename/delete. Entries are sorted A-Z within each folder -
// +entriesInFolder: itself returns oldest-added-first, so this is
// purely a display-order sort, not a manifest rewrite.
- (void)gd_rebuildModsLibrary {
    if (!self.modsLibraryStack) return;

    // One-shot per launch, not per rebuild - see
    // -gd_recoverStaleDoctorStateForThisLaunch's own header comment for
    // why re-running it on every rebuild would be wrong (it would
    // misjudge an entry that's actively mid-upload in THIS session the
    // instant its own progress callback triggers one of these calls).
    [self gd_recoverStaleDoctorStateForThisLaunch];

    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
        // A row's delete button's real-glass capsule (see
        // gd_attach_hold_to_confirm) lives in the shared
        // sliderGlassContent compositor, NOT as a subview of this row -
        // so tearing the row down here doesn't take it with it. Without
        // this it orphans one invisible UIVisualEffectView in
        // sliderGlassContent every time a row with a delete button gets
        // rebuilt (every dropdown toggle), silently piling up for the
        // life of the panel.
        UIButton *deleteButton = objc_getAssociatedObject(view, "gd_button_delete");
        if (deleteButton) {
            UIView *capsuleGlass = objc_getAssociatedObject(deleteButton, kGDHoldConfirmGlassViewKey);
            [capsuleGlass removeFromSuperview];
        }
        [self.modsLibraryStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSArray<NSString *> *folders = [ModAssetLibrary folderNames];
    if (folders.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No mod folders yet.";
        empty.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        empty.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        [self.modsLibraryStack addArrangedSubview:empty];
        return;
    }

    __weak typeof(self) weakSelf = self;

    for (NSString *folderName in folders) {
        BOOL expanded = [self.modsLibraryExpandedFolders containsObject:folderName];
        UIView *folderRow = gd_make_mods_folder_row(folderName, expanded, self,
            @selector(gd_modsLibraryFolderRowTapped:),
            @selector(gd_modsLibraryFolderAddTapped:),
            @selector(gd_modsLibraryFolderRenameTapped:));
        [self.modsLibraryStack addArrangedSubview:folderRow];

        // Delete lives on the always-visible header row itself, so this
        // is wired for every folder row, not just expanded ones.
        UIButton *folderDeleteButton = objc_getAssociatedObject(folderRow, "gd_button_delete");
        NSString *folderNameForDelete = [folderName copy]; // own copy for the block below, independent of the loop variable
        gd_attach_hold_to_confirm(folderDeleteButton, self, self.sliderGlassContent, ^{
            [weakSelf gd_deleteModFolderConfirmed:folderNameForDelete];
        });

        if (!expanded) continue;

        NSError *error = nil;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&error];
        if (!entries || entries.count == 0) {
            UILabel *emptyFolder = [[UILabel alloc] init];
            emptyFolder.text = @"  Empty.";
            emptyFolder.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
            emptyFolder.textColor = [UIColor colorWithWhite:1 alpha:0.4];
            [self.modsLibraryStack addArrangedSubview:emptyFolder];
            continue;
        }

        NSArray<ModAssetLibraryEntry *> *sortedEntries =
            [entries sortedArrayUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
                return [a.fileName localizedStandardCompare:b.fileName];
            }];

        for (ModAssetLibraryEntry *entry in sortedEntries) {
            BOOL entryExpanded = [self.modsLibraryExpandedInfoEntries containsObject:entry.path];
            // Delete is gated to only exist while the dropdown is open
            // (entryExpanded), so it isn't reachable until you've
            // actually looked at the file's info first. The doctor-
            // pipeline dispatch/upload/process/download slot (bundle-
            // kind rows only) is NOT gated the same way - it renders
            // regardless of entryExpanded, since it's non-destructive
            // and is meant to be the row's normal at-rest affordance -
            // see gd_make_mods_entry_row's own header comment.
            UIView *entryRow = gd_make_mods_entry_row(entry, self,
                @selector(gd_modsLibraryEntryInfoTapped:),
                @selector(gd_modsLibraryEntryDispatchTapped:),
                @selector(gd_modsLibraryEntryDownloadTapped:),
                @selector(gd_modsLibraryEntryRetryTapped:),
                entryExpanded,
                [self.doctorDownloadInFlightPaths containsObject:entry.path]);
            [self.modsLibraryStack addArrangedSubview:entryRow];

            if (entryExpanded) {
                UIButton *entryDeleteButton = objc_getAssociatedObject(entryRow, "gd_button_delete");
                ModAssetLibraryEntry *entryForDelete = entry;
                NSString *folderNameForEntry = [folderName copy];
                gd_attach_hold_to_confirm(entryDeleteButton, self, self.sliderGlassContent, ^{
                    [weakSelf gd_deleteModEntryConfirmed:entryForDelete inFolder:folderNameForEntry];
                });

                UIView *infoPanel = gd_make_mods_entry_info_panel(entry,
                    [self.doctorDownloadInFlightPaths containsObject:entry.path]);
                [self.modsLibraryStack addArrangedSubview:infoPanel];
            }
        }
    }
}

// Wired to every folder row's whole-row tap gesture (see
// gd_make_mods_folder_row) - toggles that one folder's membership in
// modsLibraryExpandedFolders and re-renders.
- (void)gd_modsLibraryFolderRowTapped:(UITapGestureRecognizer *)gesture {
    NSString *folderName = objc_getAssociatedObject(gesture.view, "gd_modsFolderName");
    if (!folderName) return;
    if ([self.modsLibraryExpandedFolders containsObject:folderName]) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
    } else {
        [self.modsLibraryExpandedFolders addObject:folderName];
    }
    [self gd_rebuildModsLibrary];
}

// Wired to a folder row's "Add" pill - the folder already exists, so
// this skips straight to the picker (see
// -gd_presentModImportPickerForFolder:) rather than prompting for a
// name again.
- (void)gd_modsLibraryFolderAddTapped:(UIButton *)sender {
    NSString *folderName = objc_getAssociatedObject(sender, "gd_modsFolderName");
    if (!folderName) return;
    [self gd_presentModImportPickerForFolder:folderName];
}

// Wired to a folder row's pencil button - prompts for a new name (same
// compact prompt "New Folder" uses) and renames the folder's directory
// in place via +[ModAssetLibrary renameFolderNamed:to:error:].
- (void)gd_modsLibraryFolderRenameTapped:(UIButton *)sender {
    NSString *folderName = objc_getAssociatedObject(sender, "gd_modsFolderName");
    if (!folderName) return;
    __weak typeof(self) weakSelf = self;
    [self gd_promptForModFolderNameWithTitle:@"Rename Folder"
                                  actionTitle:@"Rename"
                                   completion:^(NSString *trimmedName) {
        [weakSelf gd_renameModFolderNamed:folderName to:trimmedName];
    }];
}

- (void)gd_renameModFolderNamed:(NSString *)folderName to:(NSString *)newName {
    NSError *error = nil;
    if (![ModAssetLibrary renameFolderNamed:folderName to:newName error:&error]) {
        [self gd_presentModsAlertWithTitle:@"Couldn't Rename Folder" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    if ([self.modsLibraryExpandedFolders containsObject:folderName]) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
        [self.modsLibraryExpandedFolders addObject:newName];
    }
    [self gd_rebuildModsLibrary];
}

// Wired to an entry row's own tap gesture (see gd_make_mods_entry_row) -
// toggles that one entry's dropdown (path/size/added, see
// gd_make_mods_entry_info_panel) open or closed, keyed by the entry's
// own on-disk path since that's stable across a rebuild the way the
// entry object itself isn't (a fresh array of entries is read back
// from the manifest on every -gd_rebuildModsLibrary call).
- (void)gd_modsLibraryEntryInfoTapped:(UITapGestureRecognizer *)gesture {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(gesture.view, "gd_modsEntry");
    if (!entry) return;
    if ([self.modsLibraryExpandedInfoEntries containsObject:entry.path]) {
        [self.modsLibraryExpandedInfoEntries removeObject:entry.path];
    } else {
        [self.modsLibraryExpandedInfoEntries addObject:entry.path];
    }
    [self gd_rebuildModsLibrary];
}

// --- Doctor-pipeline download handler (Section 3, second half) ---
//
// Wired to an entry row's "download" capsule (ReadyToDownload state
// only - see gd_make_mods_entry_row). Three steps, in order:
//   1. +[BundleDoctorService fetchDoctoredBundleForHandle:config:
//      completion:] - pulls the doctored bytes back from the scratch
//      branch to a local temp file. No byte-level progress is reported
//      here (it's a single Contents API GET, unlike phase 1's blob
//      POST) - see doctorDownloadInFlightPaths' own header comment on
//      why that means this state isn't persisted onto doctorStatus the
//      way Uploading/Processing are.
//   2. Figure out which on-disk stock bundle to overwrite.
//      BundleDoctorInstaller.h deliberately doesn't guess this itself -
//      see that file's header - so this tries UnityCacheLocator's
//      CAB-based auto-match first (silent, no picker) and only falls
//      back to a manual UIDocumentPickerViewController pass, per the
//      spec, if that comes up empty.
//   3. +[BundleDoctorInstaller installDoctoredBundleAtURL:
//      toStockBundleURL:error:] - the actual on-disk swap. Per the
//      person's own spec ("automatically slot it in place once it's
//      fully downloaded") there's no separate confirm step once a
//      target is known - auto-match or manual pick, either one goes
//      straight to install.
- (void)gd_modsLibraryEntryDownloadTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "gd_modsEntry");
    if (!entry) return;
    NSString *folderName = gd_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Download tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
    if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) return; // already in flight - ignore the double-tap

    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self gd_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    BundleDoctorHandle *handle = [BundleDoctorHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": entry.doctorScratchBranch ?: @"",
        @"runID": entry.doctorRunID ?: @"",
        @"runURL": entry.doctorRunURL ?: @"",
    }];
    if (!handle) {
        [self gd_presentModsAlertWithTitle:@"Can't Download"
                                    message:@"Lost track of this submission's scratch branch - try Retry to send it again."];
        return;
    }

    NSString *entryPath = entry.path; // captured now, same reasoning as the dispatch handler's own entryPath capture
    [self.doctorDownloadInFlightPaths addObject:entryPath];
    [self gd_rebuildModsLibrary];

    __weak typeof(self) weakSelf = self;
    [BundleDoctorService fetchDoctoredBundleForHandle:handle config:config completion:^(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!doctoredBundleURL) {
            [strongSelf gd_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:error];
            return;
        }
        [strongSelf gd_doctorLocateInstallTargetForDoctoredURL:doctoredBundleURL entryPath:entryPath inFolder:folderName];
    }];
}

// Shared failure tail for the download/install flow - clears the
// in-flight marker and surfaces an alert. Deliberately does NOT touch
// entry.doctorStatus (stays ReadyToDownload) - per this method's own
// callers, every failure here (fetch failed, no cache match AND the
// person cancelled the manual picker, install itself failed) is
// retryable by just tapping "download" again, same reasoning
// +fetchDoctoredBundleForHandle:...'s own header gives for being safe
// to call more than once.
- (void)gd_doctorDownloadFailedForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self.doctorDownloadInFlightPaths removeObject:entryPath];
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeError];
    [self gd_presentModsAlertWithTitle:@"Download Failed"
                                message:error.localizedDescription ?: @"Unknown error."];
    [self gd_rebuildModsLibrary];
}

// Step 2 of the download flow (see -gd_modsLibraryEntryDownloadTapped:'s
// own header) - tries UnityCacheLocator's CAB match before falling back
// to a manual pick. doctoredURL's CAB (not the pre-doctor modded file
// still sitting in the library at entryPath) is used, per
// UnityCacheLocator.h's own note that doctoring doesn't touch a
// bundle's directory-table CAB, so either file reads the same one -
// doctoredURL is what's actually about to be installed, so reading its
// own CAB is one fewer file this has to reason about being in sync.
- (void)gd_doctorLocateInstallTargetForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *cabError = nil;
    NSString *cab = [UnityCacheLocator cabForBundleAtPath:doctoredURL.path error:&cabError];
    if (cab) {
        NSError *locateError = nil;
        NSString *matchPath = [UnityCacheLocator locateBundlePathForCAB:cab error:&locateError];
        if (matchPath) {
            [self gd_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:matchPath] entryPath:entryPath inFolder:folderName];
            return;
        }
        ZLog(@"[Mods Library] no UnityCache match for %@'s CAB (%@) - falling back to the manual picker: %@", entryPath.lastPathComponent, cab, locateError.localizedDescription);
    } else {
        ZLog(@"[Mods Library] couldn't read a CAB off the doctored bundle for %@ - falling back to the manual picker: %@", entryPath.lastPathComponent, cabError.localizedDescription);
    }

    [self gd_presentDoctorInstallTargetPickerForDoctoredURL:doctoredURL entryPath:entryPath inFolder:folderName];
}

// Manual fallback for step 2 - same picker shape as
// -gd_presentLoadModsPickerIntoFolder:/-gd_presentModImportPickerForFolder:
// (generic "any file" content type, no registered UTI for a stock Unity
// bundle any more than a modded one), single selection since exactly
// one stock file is being replaced. Routed back through
// -documentPicker:didPickDocumentsAtURLs: like those two.
- (void)gd_presentDoctorInstallTargetPickerForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (self.doctorInstallTargetPicker) {
        // Only one modal document picker can be on screen at a time -
        // another entry's download already claimed it. Turn this one
        // away rather than silently dropping or queuing it; tapping
        // download again once the other picker is dismissed retries
        // cleanly (fetchDoctoredBundleForHandle:... is safe to re-call).
        [self gd_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                 code:BundleDoctorInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Another download is already waiting on a file pick - finish that one, then try this download again."}]];
        return;
    }

    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        // initForOpeningContentTypes: (as opposed to the -init...
        // variant the Import-mode fallback below uses) already means
        // "give me a reference to the file where it lives" rather than
        // "copy it in" - exactly what's needed here, since the whole
        // point is to write the doctored bytes back to the STOCK
        // bundle's own real location, not to a copy of it.
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {
        // Deliberately UIDocumentPickerModeOpen here, NOT
        // UIDocumentPickerModeImport (unlike -gd_presentLoadModsPickerIntoFolder:/
        // -gd_presentModImportPickerForFolder:, which both want a COPY
        // of the picked file dropped into this app's own sandbox).
        // Import mode would hand back a URL to a copy living somewhere
        // under this app's container - writing the doctored bytes there
        // would never touch the actual stock bundle the game reads
        // from. Open mode returns (a security-scoped reference to) the
        // original file at its real location, which is what
        // BundleDoctorInstaller needs to overwrite in place.
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the doctor install target picker from");
        [self gd_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:BundleDoctorInstallerErrorDomain
                                 code:BundleDoctorInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Couldn't present the file picker."}]];
        return;
    }

    self.doctorInstallTargetPicker = picker;
    self.doctorInstallPendingDoctoredURL = doctoredURL;
    self.doctorInstallPendingEntryPath = entryPath;
    self.doctorInstallPendingFolderName = folderName;
    // No explanatory alert first (unlike some other failure paths in
    // this section) - presenting one here would just be a second modal
    // fighting the picker for the same presenter one run-loop turn
    // later. Same "just present the picker" convention
    // -gd_presentLoadModsPickerIntoFolder:/-gd_presentModImportPickerForFolder:
    // already use; a file-picker sheet appearing is self-explanatory
    // enough without a preamble.
    [presenter presentViewController:picker animated:YES completion:nil];
}

// Step 3 - the actual on-disk swap, then final bookkeeping.
- (void)gd_doctorInstallDoctoredURL:(NSURL *)doctoredURL toStockBundleURL:(NSURL *)stockBundleURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *installError = nil;
    BOOL installed = [BundleDoctorInstaller installDoctoredBundleAtURL:doctoredURL toStockBundleURL:stockBundleURL error:&installError];
    [self.doctorDownloadInFlightPaths removeObject:entryPath];

    if (!installed) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self gd_presentModsAlertWithTitle:@"Install Failed"
                                    message:installError.localizedDescription ?: @"Unknown error."];
        [self gd_rebuildModsLibrary];
        return;
    }

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:gd_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusInstalled;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] installed %@ but couldn't record it as Installed on the manifest (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self gd_rebuildModsLibrary];
}

// Best-effort restore of one tracked entry's swapped-in file back to
// stock before it's forgotten (as part of a per-entry delete OR a
// whole-folder delete - see -gd_deleteModEntryConfirmed:inFolder:/
// -gd_deleteModFolderConfirmed: below). Only a .bank filename can
// actually match a real backup (+[BankTransplant
// restoreBackedUpBankNamed:error:]) now that CAB-based bundle restore
// is gone - calling it for anything else is a harmless no-op (0
// restored), which isn't worth surfacing here; the delete itself
// should never be blocked by that.
- (void)gd_restoreModEntryBestEffort:(ModAssetLibraryEntry *)entry {
    NSError *error = nil;
    [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&error];
    if (error) {
        ZLog(@"[Mods Library] couldn't restore %@ before removing it from the library: %@", entry.fileName, error.localizedDescription);
    }
}

// Drives the 1.5s hold-to-confirm capsule reveal + red progress fill
// wired up by gd_attach_hold_to_confirm/gd_attach_delete_capsule above,
// for every destructive X icon in the Mods Library accordion. Same
// minimumPressDuration:0 + CADisplayLink shape as
// -handleSyslogButtonLongPress:/-gd_syslogHoldTick: - this only learns
// began/ended, -gd_holdConfirmTick: owns the actual per-frame timing so
// the capsule and fill can animate continuously instead of snapping
// once the hold completes. gesture.view is the button itself, since
// gd_attach_hold_to_confirm adds this recognizer directly to it.
- (void)gd_handleHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (![button isKindOfClass:[UIButton class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.holdConfirmActiveButton = button;
            self.holdConfirmStartTime = CACurrentMediaTime();
            self.holdConfirmTriggered = NO;

            UIView *expansion = objc_getAssociatedObject(button, kGDHoldConfirmExpansionViewKey);
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kGDHoldConfirmExpansionWidthKey);
            UILabel *deleteLabel = objc_getAssociatedObject(button, kGDHoldConfirmDeleteLabelKey);
            UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kGDHoldConfirmGlassViewKey);
            UIView *glassHost = objc_getAssociatedObject(button, kGDHoldConfirmGlassHostKey);

            widthConstraint.constant = kGDDeleteCapsuleExpandedWidth;
            [UIView animateWithDuration:kGDDeleteCapsuleSnapDuration
                                   delay:0
                  usingSpringWithDamping:kGDDeleteCapsuleSpringDamping
                   initialSpringVelocity:kGDDeleteCapsuleSpringVelocity
                                 options:UIViewAnimationOptionAllowUserInteraction
                              animations:^{
                deleteLabel.alpha = 1;
                if (capsuleGlass && glassHost) {
                    capsuleGlass.alpha = 1;
                    CGRect buttonFrameInHost = [button convertRect:button.bounds toView:glassHost];
                    CGRect expansionFrameInHost = [expansion convertRect:expansion.bounds toView:glassHost];
                    capsuleGlass.frame = CGRectUnion(buttonFrameInHost, expansionFrameInHost);
                }
                [button.superview layoutIfNeeded];
            }
                              completion:nil];

            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gd_holdConfirmTick:)];
            [self.holdConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = nil;

            if (!self.holdConfirmTriggered) {
                // Released before the 1.5s mark - spring the capsule back
                // down instead of leaving it stranded partway, and play
                // the "you needed to hold this" error haptic.
                [self gd_collapseHoldConfirmButton:button];

                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
            }
            self.holdConfirmActiveButton = nil;
            break;
        }
        default:
            break;
    }
}

- (void)gd_holdConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kGDHoldConfirmDuration = 1.5;

    UIButton *button = self.holdConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    NSTimeInterval elapsed = CACurrentMediaTime() - self.holdConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kGDHoldConfirmDuration);

    UIView *expansion = objc_getAssociatedObject(button, kGDHoldConfirmExpansionViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kGDHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kGDHoldConfirmButtonFillKey);

    CGFloat expansionWidth = expansion.bounds.size.width;
    CGFloat buttonWidth = button.bounds.size.width;
    CGFloat filledWidth = (expansionWidth + buttonWidth) * pct;

    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // no implicit animation - the per-tick updates ARE the animation
    // Sweeps left-to-right across the WHOLE capsule: expansion is the
    // leading/left segment so it fills first, the button's own fill picks
    // up whatever's left once expansion is fully covered.
    expansionFill.frame = CGRectMake(0, 0, MIN(filledWidth, expansionWidth), expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, MAX(0, filledWidth - expansionWidth), buttonWidth);
    [CATransaction commit];

    if (pct >= 1.0 && !self.holdConfirmTriggered) {
        self.holdConfirmTriggered = YES;
        [link invalidate];
        self.holdConfirmDisplayLink = nil;

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        void (^onConfirm)(void) = objc_getAssociatedObject(button, kGDHoldConfirmBlockKey);
        if (onConfirm) onConfirm();
    }
}

// Springs the capsule back down to zero width (same duration/damping as
// the expand in -gd_handleHoldToConfirmGesture:) and fades the "Delete"
// label/glass back out - used when a hold is released early.
- (void)gd_collapseHoldConfirmButton:(UIButton *)button {
    UIView *expansion = objc_getAssociatedObject(button, kGDHoldConfirmExpansionViewKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kGDHoldConfirmExpansionWidthKey);
    UILabel *deleteLabel = objc_getAssociatedObject(button, kGDHoldConfirmDeleteLabelKey);
    UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kGDHoldConfirmGlassViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kGDHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kGDHoldConfirmButtonFillKey);

    widthConstraint.constant = 0;
    [UIView animateWithDuration:kGDDeleteCapsuleSnapDuration
                           delay:0
          usingSpringWithDamping:kGDDeleteCapsuleSpringDamping
           initialSpringVelocity:kGDDeleteCapsuleSpringVelocity
                         options:UIViewAnimationOptionAllowUserInteraction
                      animations:^{
        deleteLabel.alpha = 0;
        capsuleGlass.alpha = 0;
        [button.superview layoutIfNeeded];
    }
                      completion:nil];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    expansionFill.frame = CGRectMake(0, 0, 0, expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
    [CATransaction commit];
}

// Wide-button counterpart to -gd_handleHoldToConfirmGesture: above - same
// minimumPressDuration:0 + CADisplayLink shape, but drives a single
// left-to-right fill layer across the whole button instead of a
// capsule reveal. This is literally -handleSyslogButtonLongPress:'s own
// mechanism, generalized via gd_attach_pill_hold_to_confirm - currently
// only "Restore Bundles & Banks" uses it.
- (void)gd_handlePillHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (![button isKindOfClass:[UIButton class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.pillHoldConfirmActiveButton = button;
            self.pillHoldConfirmStartTime = CACurrentMediaTime();
            self.pillHoldConfirmTriggered = NO;

            CALayer *fill = objc_getAssociatedObject(button, kGDPillHoldConfirmFillLayerKey);
            if (!fill) {
                fill = [CALayer layer];
                fill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
                fill.anchorPoint = CGPointMake(0, 0);
                fill.cornerRadius = button.bounds.size.height / 2.0;
                fill.cornerCurve = kCACornerCurveContinuous;
                [button.layer insertSublayer:fill atIndex:0];
                objc_setAssociatedObject(button, kGDPillHoldConfirmFillLayerKey, fill, OBJC_ASSOCIATION_RETAIN);
            }

            [self.pillHoldConfirmDisplayLink invalidate];
            self.pillHoldConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gd_pillHoldConfirmTick:)];
            [self.pillHoldConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.pillHoldConfirmDisplayLink invalidate];
            self.pillHoldConfirmDisplayLink = nil;

            if (!self.pillHoldConfirmTriggered) {
                [self gd_resetPillHoldConfirmFillForButton:button];

                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
            }
            self.pillHoldConfirmActiveButton = nil;
            break;
        }
        default:
            break;
    }
}

// Springs the pill's fill layer back down to zero width. Used both by an
// early-released hold in -gd_handlePillHoldToConfirmGesture: above, and
// by -gd_pillHoldConfirmTick: once a completed hold's onConfirm block has
// run - without this second call site, a completed hold left the fill
// stranded at 100% (full red) until the button was pressed again, since
// nothing else ever wrote its frame back down.
- (void)gd_resetPillHoldConfirmFillForButton:(UIButton *)button {
    CALayer *fill = objc_getAssociatedObject(button, kGDPillHoldConfirmFillLayerKey);
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    fill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
    fill.cornerRadius = button.bounds.size.height / 2.0;
    [CATransaction commit];
}

- (void)gd_pillHoldConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kGDPillHoldConfirmDuration = 1.5;

    UIButton *button = self.pillHoldConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    // Per-button override (see kGDPillHoldConfirmDurationKey /
    // gd_attach_pill_hold_to_confirm_duration) - falls back to this
    // method's own 1.5s default for every button that never set one,
    // so this is a no-op change for every existing caller.
    NSNumber *durationOverride = objc_getAssociatedObject(button, kGDPillHoldConfirmDurationKey);
    NSTimeInterval duration = durationOverride ? durationOverride.doubleValue : kGDPillHoldConfirmDuration;

    NSTimeInterval elapsed = CACurrentMediaTime() - self.pillHoldConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / duration);

    CALayer *fill = objc_getAssociatedObject(button, kGDPillHoldConfirmFillLayerKey);
    CGRect bounds = button.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    fill.frame = CGRectMake(0, 0, bounds.size.width * pct, bounds.size.height);
    fill.cornerRadius = bounds.size.height / 2.0;
    [CATransaction commit];

    if (pct >= 1.0 && !self.pillHoldConfirmTriggered) {
        self.pillHoldConfirmTriggered = YES;
        [link invalidate];
        self.pillHoldConfirmDisplayLink = nil;

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        void (^onConfirm)(void) = objc_getAssociatedObject(button, kGDPillHoldConfirmBlockKey);
        if (onConfirm) onConfirm();

        // Done - the fill has done its job signaling "hold complete", it
        // shouldn't stay red until the next press. See the method comment
        // on -gd_resetPillHoldConfirmFillForButton: above.
        [self gd_resetPillHoldConfirmFillForButton:button];
    }
}

// Fires once an entry row's X has been held for the full 1.5s (see
// gd_attach_hold_to_confirm) - best-effort restores that one file (see
// -gd_restoreModEntryBestEffort:) and forgets it via
// +[ModAssetLibrary removeEntry:fromFolder:error:].
- (void)gd_deleteModEntryConfirmed:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    [self gd_restoreModEntryBestEffort:entry];

    NSError *error = nil;
    BOOL ok = [ModAssetLibrary removeEntry:entry fromFolder:folderName error:&error];
    [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self gd_presentModsAlertWithTitle:@"Couldn't Remove File" message:error.localizedDescription ?: @"Unknown error."];
    }
    [self gd_rebuildModsLibrary];
}

// Fires once a folder row's X has been held for the full 1.5s -
// best-effort restores every entry still tracked in the folder (see
// -gd_restoreModEntryBestEffort:), then deletes the folder itself
// (manifest and every file under it) via
// +[ModAssetLibrary deleteFolderNamed:error:].
- (void)gd_deleteModFolderConfirmed:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    for (ModAssetLibraryEntry *entry in entries) {
        [self gd_restoreModEntryBestEffort:entry];
    }

    NSError *deleteErr = nil;
    BOOL ok = [ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr];

    [self.modsLibraryExpandedFolders removeObject:folderName];
    for (ModAssetLibraryEntry *entry in entries) [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self gd_presentModsAlertWithTitle:@"Couldn't Delete Folder" message:deleteErr.localizedDescription ?: @"Unknown error."];
    }
    [self gd_rebuildModsLibrary];
}

// "Add Asset" picker flow - bookkeeping only, see ModAssetLibrary.h.
// Deliberately separate from Load Mods' own picker (different
// UIDocumentPickerViewController instance, tracked via
// libraryImportPicker rather than loadModsPicker)
// so -documentPicker:didPickDocumentsAtURLs: can route the result here
// instead of into either swap-in pipeline. No registered UTI
// restriction, same reasoning as Load Mods' own picker: a mod file can
// be anything.
- (void)gd_presentModImportPickerForFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the file picker from");
        return;
    }
    self.libraryImportPicker = picker;
    self.libraryImportTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

// Handles the result of -gd_presentModImportPickerForFolder: - copies
// every picked file into the target folder via +[ModAssetLibrary
// importFileURLs:intoFolder:error:] and re-renders. See
// -documentPicker:didPickDocumentsAtURLs: for how this gets routed here
// instead of -gd_handleLoadModsPickedURLs:intoFolder:.
- (void)gd_handlePickedLibraryImportURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary importFileURLs:urls intoFolder:folderName error:&error];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self gd_presentModsAlertWithTitle:@"Couldn't Add File(s)" message:error.localizedDescription ?: @"Unknown error."];
    }
    [self gd_rebuildModsLibrary];
}

#pragma mark Syslog

- (void)toggleSyslogTapped {
    // A completed 3-second hold on this same button already switched it
    // into Verbose mode (see -handleSyslogButtonLongPress:); the
    // touchUpInside that fires when the finger finally lifts is just the
    // tail end of that same touch, not a separate tap, so swallow it
    // here instead of also toggling the tab's visibility underneath the
    // user.
    if (self.syslogHoldTriggered) {
        self.syslogHoldTriggered = NO;
        return;
    }

    // Per spec: tapping the button while it's showing "Verbose" resets
    // it back to the plain "Syslog" state instead of toggling tab
    // visibility - hold-to-activate, tap-to-deactivate.
    if (self.syslogVerboseEnabled) {
        [self gd_resetSyslogVerboseMode];
        return;
    }

    self.syslogTabEnabled = !self.syslogTabEnabled;
    self.syslogHandle.hidden = !self.syslogTabEnabled;
    self.syslogHandleGlass.hidden = !self.syslogTabEnabled;

    if (!self.syslogTabEnabled) {
        [self stopSyslog];
    }

    UIWindow *window = gd_key_window();
    if (window) {
        [self layoutPanelForWindow:window];
    }

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

// Drives the red hold-progress fill on the Debug section's Syslog
// button. minimumPressDuration is deliberately 0 (not 3.0) so -Began
// fires on touch-down and this method owns the 3-second timing itself
// via CADisplayLink - see kSyslogHoldDuration. A UILongPressGestureRecognizer
// with minimumPressDuration:3.0 would only ever tell us the hold
// *completed*, with no per-frame progress to animate a fill against.
//
// cancelsTouchesInView is set to NO on this gesture recognizer (see
// where it's attached in -buildPanel:) so the button's own touchUpInside
// still fires normally alongside this - -toggleSyslogTapped is what
// actually swallows/handles the resulting tap, via syslogHoldTriggered.
- (void)handleSyslogButtonLongPress:(UILongPressGestureRecognizer *)gesture {
    static const NSTimeInterval kSyslogHoldDuration = 1.0;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.syslogHoldStartTime = CACurrentMediaTime();
            self.syslogHoldTriggered = NO;

            if (!self.syslogButtonFillLayer) {
                CALayer *fill = [CALayer layer];
                // More saturated/opaque than a first pass at this
                // (0.95/0.16/0.16 @ 0.55 alpha) - that read as faint pink
                // against the glass button rather than a clear "this is
                // filling up" red.
                fill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
                fill.anchorPoint = CGPointMake(0, 0);
                // Rounded to match the button's own pill silhouette -
                // without this the fill's square corners poke out past
                // the button's rounded ends since a raw CALayer doesn't
                // inherit the native glass configuration's corner shape.
                // Corrected to bounds.size.height/2 on every tick below
                // (button height isn't known for certain until the first
                // real bounds is available here at touch-down).
                fill.cornerRadius = self.syslogButton.bounds.size.height / 2.0;
                fill.cornerCurve = kCACornerCurveContinuous;
                // Inserted directly as a sublayer (not addSubview:) so it
                // sits behind whatever UIButtonConfiguration's native
                // glass style is managing as the button's real subviews
                // (title label included) - see the syslogButtonFillLayer
                // property comment. gd_style_button_as_native_glass
                // rebuilds the button's configuration on every state
                // change but never touches button.layer's sublayers
                // directly, so this persists across those rebuilds.
                [self.syslogButton.layer insertSublayer:fill atIndex:0];
                self.syslogButtonFillLayer = fill;
            }

            [self.syslogHoldDisplayLink invalidate];
            self.syslogHoldDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gd_syslogHoldTick:)];
            [self.syslogHoldDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.syslogHoldDisplayLink invalidate];
            self.syslogHoldDisplayLink = nil;

            if (!self.syslogHoldTriggered) {
                // Released before the 3s mark - snap the fill back down
                // instead of leaving it stranded partway.
                [CATransaction begin];
                [CATransaction setAnimationDuration:0.18];
                self.syslogButtonFillLayer.frame = CGRectMake(0, 0, 0, self.syslogButton.bounds.size.height);
                self.syslogButtonFillLayer.cornerRadius = self.syslogButton.bounds.size.height / 2.0;
                [CATransaction commit];
            }
            break;
        }
        default:
            break;
    }
}

- (void)gd_syslogHoldTick:(CADisplayLink *)link {
    static const NSTimeInterval kSyslogHoldDuration = 3.0;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.syslogHoldStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kSyslogHoldDuration);

    CGRect bounds = self.syslogButton.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // no implicit animation - the per-tick updates ARE the animation
    self.syslogButtonFillLayer.frame = CGRectMake(0, 0, bounds.size.width * pct, bounds.size.height);
    self.syslogButtonFillLayer.cornerRadius = bounds.size.height / 2.0;
    [CATransaction commit];

    if (pct >= 1.0 && !self.syslogHoldTriggered) {
        self.syslogHoldTriggered = YES;
        [link invalidate];
        self.syslogHoldDisplayLink = nil;
        [self gd_enterSyslogVerboseMode];
    }
}

// Entered once the 3-second hold on the Syslog button completes. Turns
// the button red (fill layer only - title text stays white, see the
// tint color passed below) and shows "Verbose". Forces the SYSLOG/
// VERBOSE pull tab open if it wasn't already: holding the button is now
// the primary way into Verbose, and the tab has to actually be visible
// for that to be useful in one motion - previously this left
// syslogTabEnabled untouched, so a hold from the default (tab hidden)
// state silently relabeled a tab nobody could see, and the tab only
// appeared after an unrelated separate tap-to-enable step.
- (void)gd_enterSyslogVerboseMode {
    self.syslogVerboseEnabled = YES;
    // White (not red) title text per spec - the red fill layer alone is
    // what signals "Verbose is active" now.
    gd_style_button_as_native_glass(self.syslogButton, @"Verbose", [UIColor colorWithWhite:1 alpha:0.95]);

    self.syslogTabEnabled = YES;
    self.syslogHandle.hidden = NO;
    self.syslogHandleGlass.hidden = NO;

    self.syslogHandleLabel.text = @"VERBOSE";
    [self gd_updateSyslogHandleLabelLayout];

    UIWindow *window = gd_key_window();
    if (window) {
        [self layoutPanelForWindow:window];
    }
    [self gd_renderSyslogBuffer];

    // A distinct feedback type from the Light impact used everywhere
    // else in the Debug section, per spec ("a distinct haptic feedback
    // happens to alert the user").
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];

    ZLog(@"Verbose syslog mode enabled - filtering to tweak-only log lines");
}

// Reached only via a tap on the button while it's showing "Verbose" -
// see -toggleSyslogTapped. Leaves the pull tab exactly as visible as it
// was (doesn't auto-hide it) - only -toggleSyslogTapped's normal,
// non-Verbose tap path hides it again.
- (void)gd_resetSyslogVerboseMode {
    self.syslogVerboseEnabled = NO;
    gd_style_button_as_native_glass(self.syslogButton, @"Syslog", [UIColor colorWithWhite:1 alpha:0.88]);

    self.syslogHandleLabel.text = @"SYSLOG";
    [self gd_updateSyslogHandleLabelLayout];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.syslogButtonFillLayer.frame = CGRectMake(0, 0, 0, self.syslogButton.bounds.size.height);
    self.syslogButtonFillLayer.cornerRadius = self.syslogButton.bounds.size.height / 2.0;
    [CATransaction commit];

    UIWindow *window = gd_key_window();
    if (window) {
        [self layoutPanelForWindow:window];
    }
    [self gd_renderSyslogBuffer];

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ZLog(@"Verbose syslog mode disabled");
}

- (void)syslogTabTapped {
    if (!self.syslogTabEnabled) return;

    self.syslogVisible = !self.syslogVisible;
    if (self.syslogVisible) {
        BOOL started = [[ZSyslogController sharedController] start];
        self.syslogOverlay.hidden = NO;
        UIWindow *window = gd_key_window();
        if (window) {
            [window bringSubviewToFront:self.syslogOverlay];
        }

        // Re-render immediately from whatever is already buffered (or the
        // "listening" placeholder if the buffer is empty) instead of
        // waiting for the next pipe write. Previously -stopSyslog wiped
        // syslogLines/attributedText on every hide, so showing the tab
        // again looked blank until a fresh line happened to arrive - see
        // -pauseSyslogCapture below, which now keeps that buffer intact.
        [self gd_renderSyslogBuffer];

        if (!started) {
            [self appendSyslogLine:@"[syslog] Unable to start stdout/stderr capture"];
        }
    } else {
        [self pauseSyslogCapture];
    }
}

// Hides the log view and pauses stdout/stderr capture, but keeps the
// buffered lines around so toggling the tab back on is instant. Used for
// the ordinary show/hide tap. Compare -stopSyslog, which additionally
// clears everything and is only used when the syslog feature itself is
// switched off from the settings row.
- (void)pauseSyslogCapture {
    [[ZSyslogController sharedController] stop];
    self.syslogVisible = NO;
    self.syslogOverlay.hidden = YES;
}

- (void)stopSyslog {
    [self pauseSyslogCapture];
    [self.syslogLines removeAllObjects];
    self.syslogTextLabel.attributedText = nil;
}

// Case-insensitive substring match against every blacklisted term. A line
// containing any blacklisted word/phrase is ignored entirely - it never
// makes it into syslogLines, so it never renders.
- (BOOL)gd_syslogLineIsBlacklisted:(NSString *)line {
    if (self.syslogBlacklist.count == 0) return NO;
    NSString *lower = line.lowercaseString;
    for (NSString *term in self.syslogBlacklist) {
        if (term.length > 0 && [lower containsString:term]) return YES;
    }
    return NO;
}

- (void)appendSyslogLine:(NSString *)line {
    if (!line.length) return;
    if ([self gd_syslogLineIsBlacklisted:line]) return;

    // Keep this intentionally small and allocation-friendly. The renderer is
    // text-only and should never become an unbounded log database.
    [self.syslogLines addObject:line];
    static const NSUInteger kMaxSyslogLines = 80;
    if (self.syslogLines.count > kMaxSyslogLines) {
        NSUInteger removeCount = self.syslogLines.count - kMaxSyslogLines;
        [self.syslogLines removeObjectsInRange:NSMakeRange(0, removeCount)];
    }

    [self gd_renderSyslogBuffer];
}

// Verbose mode narrows the same underlying syslogLines buffer down to
// lines the tweak itself emitted via ZLog(...) (see ZTweakLog.h) -
// everything else captured off stdout/stderr (the game/engine's own
// output) is filtered out of the *display* without being dropped from
// the buffer, so toggling Verbose off shows the full capture again
// without needing to restart it.
- (NSArray<NSString *> *)gd_syslogDisplayLines {
    if (!self.syslogVerboseEnabled) return self.syslogLines;

    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *line in self.syslogLines) {
        if ([line containsString:kZLogTag]) [filtered addObject:line];
    }
    return filtered;
}

// Shared by -appendSyslogLine: (new line arrived), -syslogTabTapped
// (re-show from the existing buffer), and -reapplySyslogBlacklistFilter
// (a newly blacklisted term just removed lines already on screen).
- (void)gd_renderSyslogBuffer {
    NSArray<NSString *> *displayLines = [self gd_syslogDisplayLines];
    NSString *joined = displayLines.count > 0
        ? [displayLines componentsJoinedByString:@"\n"]
        : (self.syslogVisible
           ? (self.syslogVerboseEnabled ? @"[syslog] Listening for tweak output\u2026" : @"[syslog] Listening for output\u2026")
           : @"");

    // Faint drop shadow under the text, on top of the existing stroke
    // outline, for readability against whatever's rendering behind it.
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0 alpha:0.55];
    shadow.shadowOffset = CGSizeMake(0, 1.0);
    shadow.shadowBlurRadius = 2.0;

    NSMutableAttributedString *styled =
        [[NSMutableAttributedString alloc] initWithString:joined
                                               attributes:@{
        NSFontAttributeName: self.syslogTextLabel.font,
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSStrokeColorAttributeName: UIColor.blackColor,
        NSStrokeWidthAttributeName: @(-2.5),
        NSShadowAttributeName: shadow,
    }];

    self.syslogTextLabel.attributedText = styled;
    [self layoutSyslogOverlayForWindow:gd_key_window()];
}

- (void)layoutSyslogOverlayForWindow:(UIWindow *)window {
    if (!window || !self.syslogOverlay || !self.syslogTextLabel) return;

    // Shifted right of a flat 8pt edge inset: in landscape (this overlay is
    // built for a landscape game) the sensor housing/Dynamic Island safe
    // area lands on the left or right edge, not the top, so a fixed 8pt
    // inset let it clip the first few characters of every line.
    // safeAreaInsets.left already reflects that (it's 0 in portrait, so
    // this still hugs the edge there), plus a little extra breathing room.
    CGFloat leftInset = window.safeAreaInsets.left + 16.0;
    // Text column width - unchanged from before, so the log itself still
    // reads at full size.
    CGFloat width = MIN(window.bounds.size.width * 0.72, 700.0);
    // Interactable zone: the scroll view's own frame width, kept separate
    // from the text column above. Reduced to 1/3 of the text width - this
    // is what was covering too much of the screen and blocking touches to
    // whatever's underneath it. clipsToBounds = NO (set at creation) means
    // the full-width text still renders past this narrower hit-testable
    // strip; only the touchable/scrollable area shrinks.
    CGFloat interactWidth = width / 3.0;
    CGFloat top = window.safeAreaInsets.top + 6.0;
    CGFloat height = MIN(window.bounds.size.height * 0.48, 420.0);

    self.syslogOverlay.frame = CGRectMake(leftInset, top, interactWidth, height);

    CGSize fitSize = [self.syslogTextLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGFloat textHeight = MAX(height, ceil(fitSize.height) + 8.0);
    self.syslogTextLabel.frame = CGRectMake(0, 0, width, textHeight);
    self.syslogOverlay.contentSize = CGSizeMake(interactWidth, textHeight);

    // Tail the log like a console - keep the newest lines in view unless
    // the person is actively scrolled up reading back through history.
    if (textHeight > height && !self.syslogOverlay.isDragging && !self.syslogOverlay.isDecelerating) {
        self.syslogOverlay.contentOffset = CGPointMake(0, textHeight - height);
    }
}

#pragma mark Auth

// Pre-fills authRepoLinkField/authTokenField from whatever's already
// stored - called once, right after both fields are created in
// -buildPanel:. +loadConfig reads the JSON file for repoOwner/repoName
// and Keychain for authToken (see BundleDoctorSettings.h) and always
// returns a non-nil config, so nil fields here just mean "nothing was
// ever saved" rather than a failure worth surfacing.
- (void)gd_loadAuthFields {
    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];
    self.authRepoLinkField.text = gd_format_github_repo_link(config.repoOwner, config.repoName);
    self.authTokenField.text = config.authToken ?: @"";
}

// Writes authRepoLinkField/authTokenField back out via
// +[BundleDoctorSettings saveConfig:error:] - called from
// -textFieldDidEndEditing: below, i.e. once per field per edit (on
// blur/Return), not per keystroke. +saveConfig: is a full replace (see
// that method's own header comment), so this loads the current config
// first and only overwrites the two fields this section owns, leaving
// ref/workflowFile/outputFormat exactly as BundleDoctorService/a future
// settings flow last set them.
- (void)gd_persistAuthFields {
    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];

    NSString *linkRaw = [self.authRepoLinkField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (linkRaw.length == 0) {
        config.repoOwner = nil;
        config.repoName = nil;
    } else {
        NSString *owner = nil, *name = nil;
        if (gd_parse_github_repo_link(linkRaw, &owner, &name)) {
            config.repoOwner = owner;
            config.repoName = name;
            // Collapse whatever shape was typed/pasted (full URL, SSH
            // form, trailing .git, ...) down to the canonical owner/repo
            // form now that it's parsed successfully.
            self.authRepoLinkField.text = gd_format_github_repo_link(owner, name);
        } else {
            // Unparseable - leave the previously stored repoOwner/
            // repoName untouched (don't clobber a good saved value with
            // garbage) and leave the field exactly as typed so nothing
            // the person entered is silently discarded; they can fix it
            // and blur again.
            ZLog(@"[GraphicsDebugOverlay] Auth: couldn't parse GitHub repo link \"%@\" - keeping previously saved repo, if any", linkRaw);
        }
    }

    // Strip a redundant "Bearer "/"token " scheme prefix before this
    // ever reaches Keychain - see gd_sanitize_personal_access_token's own
    // header comment for why a token saved with one already on it broke
    // every doctor-bundle request with a bad-credentials response.
    NSString *tokenSanitized = gd_sanitize_personal_access_token(self.authTokenField.text ?: @"");
    config.authToken = tokenSanitized.length > 0 ? tokenSanitized : nil;
    self.authTokenField.text = tokenSanitized;

    NSError *error = nil;
    if (![BundleDoctorSettings saveConfig:config error:&error]) {
        ZLog(@"[GraphicsDebugOverlay] Auth: failed to save BundleDoctor config: %@", error);
    }
}

#pragma mark Re-Encoding format

// Wired to every UIAction in the Re-Encoding format button's menu (see
// gd_build_reencode_format_menu / gd_make_reencode_format_row, and the
// Config section in -buildPanel:). Same load-then-overwrite-one-field
// pattern as -gd_persistAuthFields above: +saveConfig: is a full
// replace, so this loads the current config first and only touches
// outputFormat, leaving repoOwner/repoName/ref/workflowFile/authToken
// exactly as the Auth section (or a previous selection here) last set
// them. Every dispatch call site in this file re-loads config fresh via
// +[BundleDoctorSettings loadConfig] immediately before it dispatches,
// so persisting here is the entire fix - nothing else in the pipeline
// needs to change for a non-default selection to actually reach the
// workflow.
- (void)gd_reencodeFormatSelected:(NSString *)format {
    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];
    config.outputFormat = format;

    NSError *error = nil;
    if (![BundleDoctorSettings saveConfig:config error:&error]) {
        ZLog(@"[GraphicsDebugOverlay] Config: failed to save Re-Encoding format: %@", error);
        return;
    }

    // Refresh the button in place - new title, and the menu's own
    // checkmark moved onto the newly-selected option - so opening it
    // again immediately reflects what just got saved.
    if (self.reencodeFormatButton) {
        __weak typeof(self) weakSelf = self;
        gd_apply_reencode_format_selection(self.reencodeFormatButton, format, ^(NSString *selectedFormat) {
            [weakSelf gd_reencodeFormatSelected:selectedFormat];
        });
    }

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

// Wired to the PAT field's "Verify" button (see -buildPanel:'s Auth
// section above). Persists whatever's currently in the fields first
// (same as a blur would) so this always checks exactly what's actually
// saved, then asks BundleDoctorService to confirm the repo link + token
// authenticate against the GitHub API - see
// +[BundleDoctorService verifyCredentialsForConfig:completion:]. Button
// is disabled and relabeled for the duration of the check so a second
// tap can't stack a duplicate request on top of the first.
- (void)gd_authVerifyTapped:(UIButton *)sender {
    [self gd_persistAuthFields];

    BundleDoctorConfig *config = [BundleDoctorSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self gd_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token above first."];
        return;
    }

    sender.enabled = NO;
    gd_crossfade_auth_verify_button_title(sender, @"Verifying\u2026");

    __weak typeof(self) weakSelf = self;
    [BundleDoctorService verifyCredentialsForConfig:config completion:^(BOOL valid, NSError *verifyError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        sender.enabled = YES;
        gd_crossfade_auth_verify_button_title(sender, @"Verify");

        if (valid) {
            [strongSelf gd_presentModsAlertWithTitle:@"Credentials Verified"
                                              message:@"The GitHub Repository Link and Personal Access Token are valid."];
        } else {
            [strongSelf gd_presentModsAlertWithTitle:@"Verification Failed"
                                              message:verifyError.localizedDescription ?: @"Couldn't verify the repository link and token."];
        }
    }];
}

// Tracks the keyboard's current frame (window coordinates) at all times
// - -gd_floatAuthField: reads gd_lastKeyboardFrame rather than waiting
// on a fresh notification, since switching first responder directly
// between the two Auth fields (same keyboard type, so the frame doesn't
// actually change) doesn't reliably re-post this notification. If a
// field is already floated when this fires - a height change mid-edit,
// e.g. the predictive text bar appearing, or a rotation - just nudge
// its bottom constraint to the new position instead of a full fade
// cycle; if the keyboard has gone away entirely while a field is still
// marked floated (e.g. the person swiped it down without blurring,
// which iPadOS allows), restore defensively rather than leaving it
// stranded.
- (void)gd_keyboardWillChangeFrame:(NSNotification *)note {
    UIWindow *window = gd_key_window();
    if (!window) return;

    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endFrameInWindow = [window convertRect:endFrame fromView:nil];
    self.gd_lastKeyboardFrame = endFrameInWindow;

    BOOL keyboardVisible = CGRectGetMinY(endFrameInWindow) < CGRectGetMaxY(window.bounds);

    if (self.authFieldCurrentlyFloated && keyboardVisible) {
        NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        if (duration <= 0) duration = 0.25;
        CGFloat bottomInset = CGRectGetHeight(window.bounds) - CGRectGetMinY(endFrameInWindow);
        self.authFieldFloatingBottomConstraint.constant = -(bottomInset + 8);
        [UIView animateWithDuration:duration animations:^{
            [window layoutIfNeeded];
        }];
    } else if (self.authFieldCurrentlyFloated && !keyboardVisible) {
        [self gd_restoreAuthField:self.authFieldCurrentlyFloated];
    }
}

// Lifts `field`'s real glass-wrapped container out of its row in the
// scrolling panel and parents it directly in the key window, right-
// aligned and pinned just above the keyboard - see
// kGDAuthFieldContainerKey and friends above for how the container/row/
// constraints were stashed at build time. The move itself is a simple
// cross-fade per spec (fade out at the row position, reparent, fade in
// at the floating position), not a slide/morph - see -gd_restoreAuthField:
// for the reverse. No-op if `field` is already the floated one.
- (void)gd_floatAuthField:(UITextField *)field {
    if (!field || self.authFieldCurrentlyFloated == field) return;
    if (self.authFieldCurrentlyFloated) {
        // Shouldn't normally happen - -textFieldDidEndEditing: restores
        // the previous field before this ever runs for a new one - but
        // don't leave a stale floated field stranded if it does.
        [self gd_restoreAuthField:self.authFieldCurrentlyFloated];
    }

    UIView *fieldContainer = objc_getAssociatedObject(field, kGDAuthFieldContainerKey);
    NSArray<NSLayoutConstraint *> *rowConstraints = objc_getAssociatedObject(field, kGDAuthFieldRowConstraintsKey);
    UIWindow *window = gd_key_window();
    if (!fieldContainer || !rowConstraints || !window) return; // defensive - only ever set by gd_make_labeled_glass_field_row

    CGFloat savedWidth = fieldContainer.bounds.size.width;
    self.authFieldCurrentlyFloated = field;

    [UIView animateWithDuration:0.15 animations:^{
        fieldContainer.alpha = 0;
    } completion:^(BOOL finished) {
        [NSLayoutConstraint deactivateConstraints:rowConstraints];

        // Reparent via -addSubview: directly rather than calling
        // -removeFromSuperview first. field is `field`'s live
        // UITextField and is still first responder at this point - an
        // explicit -removeFromSuperview momentarily detaches
        // fieldContainer (and therefore `field`) from any window before
        // the follow-up -addSubview: reattaches it, and UIKit resigns
        // first-responder status the instant a responder's view goes
        // windowless. That resignation fires -textFieldDidEndEditing:
        // mid-float, which calls -gd_restoreAuthField: right back
        // (since authFieldCurrentlyFloated is already set to `field` -
        // see above) - undoing this exact move a frame after it starts
        // and dropping the keyboard. window here is the same UIWindow
        // fieldContainer's row already lives in (see gd_key_window()),
        // so -addSubview: below reparents it in one atomic step without
        // ever making it windowless, and first-responder status survives.
        fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [window addSubview:fieldContainer];
        [window bringSubviewToFront:fieldContainer];

        // gd_lastKeyboardFrame is normally already correct by the time
        // this runs (see the header comment above) - the fallback below
        // only matters if this is somehow reached before the keyboard's
        // very first WillChangeFrame notification of the session.
        CGFloat bottomInset = CGRectGetHeight(window.bounds) - CGRectGetMinY(self.gd_lastKeyboardFrame);
        if (CGRectIsEmpty(self.gd_lastKeyboardFrame) || bottomInset < 8) {
            bottomInset = window.safeAreaInsets.bottom + 291; // typical current-generation iPhone portrait keyboard height
        }

        NSLayoutConstraint *bottomConstraint =
            [fieldContainer.bottomAnchor constraintEqualToAnchor:window.bottomAnchor constant:-(bottomInset + 8)];
        NSArray<NSLayoutConstraint *> *floatConstraints = @[
            [fieldContainer.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-16],
            bottomConstraint,
            [fieldContainer.widthAnchor constraintEqualToConstant:savedWidth],
            [fieldContainer.heightAnchor constraintEqualToConstant:28],
        ];
        [NSLayoutConstraint activateConstraints:floatConstraints];
        objc_setAssociatedObject(field, kGDAuthFieldFloatingConstraintsKey, floatConstraints, OBJC_ASSOCIATION_RETAIN);
        self.authFieldFloatingBottomConstraint = bottomConstraint;
        [window layoutIfNeeded];

        [UIView animateWithDuration:0.15 animations:^{
            fieldContainer.alpha = 1;
        }];
    }];
}

// Reverse of -gd_floatAuthField: above - fades `field`'s container out
// of its floating window-level position, reparents it back into its
// original row using the exact constraints -gd_floatAuthField: deactivated
// (not rebuilt from scratch), and fades it back in there. No-op if
// `field` isn't the currently-floated one.
- (void)gd_restoreAuthField:(UITextField *)field {
    if (!field || self.authFieldCurrentlyFloated != field) return;

    UIView *fieldContainer = objc_getAssociatedObject(field, kGDAuthFieldContainerKey);
    UIView *originalRow = objc_getAssociatedObject(field, kGDAuthFieldRowKey);
    NSArray<NSLayoutConstraint *> *rowConstraints = objc_getAssociatedObject(field, kGDAuthFieldRowConstraintsKey);
    NSArray<NSLayoutConstraint *> *floatConstraints = objc_getAssociatedObject(field, kGDAuthFieldFloatingConstraintsKey);
    if (!fieldContainer || !originalRow || !rowConstraints) {
        self.authFieldCurrentlyFloated = nil;
        self.authFieldFloatingBottomConstraint = nil;
        return;
    }

    self.authFieldCurrentlyFloated = nil;
    self.authFieldFloatingBottomConstraint = nil;

    [UIView animateWithDuration:0.15 animations:^{
        fieldContainer.alpha = 0;
    } completion:^(BOOL finished) {
        if (floatConstraints) [NSLayoutConstraint deactivateConstraints:floatConstraints];
        objc_setAssociatedObject(field, kGDAuthFieldFloatingConstraintsKey, nil, OBJC_ASSOCIATION_RETAIN);

        // Same atomic-reparent reasoning as -gd_floatAuthField: above -
        // -addSubview: directly instead of -removeFromSuperview then
        // -addSubview:, so `field` never goes windowless if it's still
        // first responder here (e.g. a defensive restore from
        // -gd_keyboardWillChangeFrame: while the person is still typing).
        fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [originalRow addSubview:fieldContainer];
        [NSLayoutConstraint activateConstraints:rowConstraints];
        [originalRow layoutIfNeeded];

        [UIView animateWithDuration:0.15 animations:^{
            fieldContainer.alpha = 1;
        }];
    }];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField == self.authRepoLinkField || textField == self.authTokenField) {
        [self gd_floatAuthField:textField];
    }
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == self.authRepoLinkField || textField == self.authTokenField) {
        [self gd_restoreAuthField:textField];
        [self gd_persistAuthFields];
    }
}

#pragma mark Syslog blacklist

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // Return just dismisses the keyboard for the Auth fields - resigning
    // first responder is what actually triggers the save, via
    // -textFieldDidEndEditing: above (see -gd_persistAuthFields).
    if (textField == self.authRepoLinkField || textField == self.authTokenField) {
        [textField resignFirstResponder];
        return YES;
    }
    if (textField != self.syslogBlacklistField) return YES;

    NSString *raw = textField.text ?: @"";
    BOOL added = NO;
    for (NSString *piece in [raw componentsSeparatedByString:@","]) {
        NSString *term = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if (term.length == 0) continue;
        if (![self.syslogBlacklist containsObject:term]) added = YES;
        [self.syslogBlacklist addObject:term]; // NSMutableOrderedSet: no-op if already present
    }

    textField.text = @"";
    if (added) {
        g_syslogBlacklist = self.syslogBlacklist.array;
        [self gd_rebuildSyslogBlacklistEntries];
        [self gd_scheduleSave]; // same debounced JSON save every other control uses
        [self reapplySyslogBlacklistFilter];
    }
    [textField resignFirstResponder];
    return YES;
}

// Re-renders syslogBlacklistEntriesStack from self.syslogBlacklist: one
// removable row per term, or the "No blacklisted terms" placeholder when
// empty. Called after every add/remove instead of patching individual
// rows in place, since the list is short and this keeps ordering trivial.
- (void)gd_rebuildSyslogBlacklistEntries {
    if (!self.syslogBlacklistEntriesStack) return;

    for (UIView *view in self.syslogBlacklistEntriesStack.arrangedSubviews) {
        [self.syslogBlacklistEntriesStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (self.syslogBlacklist.count == 0) {
        [self.syslogBlacklistEntriesStack addArrangedSubview:self.syslogBlacklistStatusLabel];
        return;
    }

    for (NSString *term in self.syslogBlacklist) {
        [self.syslogBlacklistEntriesStack addArrangedSubview:
            gd_make_blacklist_entry_row(term, self, @selector(gd_removeBlacklistEntryTapped:))];
    }
}

// Wired to every entry row's "x" button (see gd_make_blacklist_entry_row).
// Removes just that one term, persists via the normal debounced save, and
// re-renders the list - there is no un-hiding of previously-dropped syslog
// lines on removal, same as before this rework.
- (void)gd_removeBlacklistEntryTapped:(UIButton *)sender {
    NSString *term = objc_getAssociatedObject(sender, "gd_blacklistTerm");
    if (!term) return;

    [self.syslogBlacklist removeObject:term];
    g_syslogBlacklist = self.syslogBlacklist.array;
    [self gd_rebuildSyslogBlacklistEntries];
    [self gd_scheduleSave];
}

// Purges any already-buffered lines that match a term just added to the
// blacklist, so the effect is immediate rather than only applying to
// future lines.
- (void)reapplySyslogBlacklistFilter {
    if (self.syslogLines.count == 0) return;
    NSIndexSet *toRemove = [self.syslogLines indexesOfObjectsPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
        return [self gd_syslogLineIsBlacklisted:line];
    }];
    if (toRemove.count == 0) return;
    [self.syslogLines removeObjectsAtIndexes:toRemove];
    [self gd_renderSyslogBuffer];
}

#pragma mark Pull tab

// The pull tab is NOT a sibling of the panel anymore. It is a child of the
// same single Liquid Glass surface, so the tab and panel always move as one.

// Lays out the fixed-height glass dock. The glass itself reaches the physical
// top/bottom of the window; only the scrolling content is inset around safe
// areas so the panel keeps the keyboard-like edge-to-edge silhouette.
- (void)layoutPanelForWindow:(UIWindow *)window {
    if (!self.glassContainer || !self.panel || !self.handle) return;

    CGFloat width = self.panelWidth > 0 ? self.panelWidth : kPanelWidth;
    CGFloat height = window.bounds.size.height;
    CGFloat chromeWidth = width + kHandleWidth;

    self.glassContainer.frame = CGRectMake(window.bounds.size.width - kHandleWidth,
                                            0,
                                            chromeWidth,
                                            height);

    // Keep the panel and tab in one coordinate space so they always move
    // together. Their edges touch exactly, and UIGlassContainerEffect uses
    // kGlassMergeSpacing to merge their adjacent Liquid Glass shapes.
    UIView *panelElement = self.panelGlass ?: self.panel;
    UIView *handleElement = self.handleGlass ?: self.handle;

    panelElement.frame = CGRectMake(kHandleWidth,
                                     0,
                                     width,
                                     height);
    handleElement.frame = CGRectMake(0,
                                     (height - kHandleHeight) * 0.5,
                                     kHandleWidth,
                                     kHandleHeight);

    // Re-resolve the Liquid Glass corner shape now that panelGlass/handleGlass
    // have their real, final frames. gd_configure_glass_corners was already
    // called once in -buildPanel: right after these views were created, but
    // at that point they were still CGRectZero (frames are only established
    // here, on the first -layoutPanelForWindow: pass). UIKit resolves the
    // glass shape's rounded-corner geometry against the view's size at the
    // time UICornerConfiguration is set, so a configuration applied against a
    // zero-size view renders as a plain rectangle - it only self-corrects
    // once something else (e.g. a touch) forces UIKit to redo the glass
    // shape resolution. Reapplying here, after the frame is correct, makes
    // the rounded corners appear on the very first frame instead of only
    // after interaction. This runs on every layout pass so rotations/size
    // changes stay correct too.
    if (self.panelGlass) {
        gd_configure_glass_corners(self.panelGlass, kPanelCornerRadiusMinimum, YES);
    }
    if (self.handleGlass) {
        gd_configure_glass_corners(self.handleGlass, kHandleCornerRadius, NO);
    }

    self.panel.frame = self.panelGlass ? self.panelGlass.bounds : self.panel.bounds;
    self.handle.frame = self.handleGlass ? self.handleGlass.bounds : self.handle.bounds;

    if (self.syslogHandle) {
        // Local coordinates within glassContainerContent: x=0 is the same
        // left column the main handle occupies, so this element's trailing
        // edge (x = kHandleWidth) runs exactly along the panel's leading
        // edge for the button's whole height - that edge contact is the
        // fuse with the panel. y is positioned immediately above the main
        // handle with a small kSyslogHandleGap, close enough that the two
        // glass shapes fuse into one continuous silhouette too.
        CGFloat mainHandleY = CGRectGetMinY(handleElement.frame);
        CGFloat syslogY = MAX(window.safeAreaInsets.top + 2.0,
                              mainHandleY - kSyslogHandleGap - self.syslogHandleHeight);
        CGRect syslogFrame = CGRectMake(0,
                                         syslogY,
                                         kHandleWidth,
                                         self.syslogHandleHeight);
        if (self.syslogHandleGlass) {
            self.syslogHandleGlass.frame = syslogFrame;
            gd_configure_glass_corners(self.syslogHandleGlass, 8, NO);
            self.syslogHandle.frame = self.syslogHandleGlass.bounds;
        } else {
            self.syslogHandle.frame = syslogFrame;
        }

        self.syslogHandle.hidden = !self.syslogTabEnabled;
        self.syslogHandleGlass.hidden = !self.syslogTabEnabled;

        [self.glassContainerContent bringSubviewToFront:self.syslogHandleGlass ?: self.syslogHandle];
    }

    [self layoutSyslogOverlayForWindow:window];

    if (self.contentOverlay) {
        CGRect panelRect = [panelElement convertRect:panelElement.bounds toView:window];
        self.contentOverlay.frame = panelRect;
        self.contentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
        self.contentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentOverlay setNeedsLayout];
        [self.contentOverlay layoutIfNeeded];
    }

    if (self.sliderGlassContainer) {
        // sliderGlassContainer is a WINDOW-level sibling of glassContainer,
        // not a child of the dock compositor. Its frame therefore has to be
        // expressed in the window's coordinate space. Using
        // glassContainer.bounds here puts the pill compositor at (0,0),
        // which leaves the actual Liquid Glass pills outside the compositor
        // and makes the effect appear to be missing.
        self.sliderGlassContainer.frame = [self.glassContainer convertRect:self.glassContainer.bounds
                                                                    toView:window];
        [window bringSubviewToFront:self.sliderGlassContainer];
        // The content overlay is intentionally above the slider glass.
        if (self.contentOverlay) [window bringSubviewToFront:self.contentOverlay];
    }

    // Keep the content below system UI while allowing the glass itself to
    // run behind it. These insets are constant for a given window geometry,
    // so they do not participate in scroll callbacks.
    self.scrollView.contentInset = UIEdgeInsetsMake(window.safeAreaInsets.top + 12,
                                                    0,
                                                    window.safeAreaInsets.bottom + 12,
                                                    0);
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;

    [self.glassContainer setNeedsLayout];
    [self.glassContainer layoutIfNeeded];
    [self.panel setNeedsLayout];
    [self.panel layoutIfNeeded];
    [self.scrollViewport setNeedsLayout];
    [self.scrollViewport layoutIfNeeded];

    [self installStaticContentFadeMask];
    [self positionPanelAnimated:NO];
    [self gd_updateSliderGlassVisibility];
}

#pragma mark Scroll-linked slider glass
//
// Every pill is a real UIGlassEffect in a dedicated compositor. The setting
// content itself is rendered by contentOverlay above this material, so the
// green fill and labels are never dimmed by the pill glass.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self gd_updateSliderGlassVisibility];
}

- (void)gd_updateSliderGlassVisibility {
    if (!gd_has_liquid_glass() || !self.stack) return;

    // These are the visible scroll pills of the panel. Keep the material
    // attached continuously; removing/recreating UIGlassEffect views during
    // scrolling can cause UIKit's glass compositor to miss a frame or retain
    // a stale shape cache. The number of sliders here is small enough that the
    // deterministic path is preferable. Mode sliders (AA Mode/Quality,
    // Tonemap) now get the same real Liquid Glass treatment as the
    // continuous sliders - see the GDModeSlider class comment.
    for (UIView *arranged in self.stack.arrangedSubviews) {
        if (![arranged isKindOfClass:[GDRow class]]) continue;
        GDRow *row = (GDRow *)arranged;
        if (row.slider) {
            row.slider.glassHost = self.sliderGlassContent;
            [row.slider setGlassEnabled:YES];
        } else if (row.modeSlider) {
            row.modeSlider.glassHost = self.sliderGlassContent;
            [row.modeSlider setGlassEnabled:YES];
        }
    }
}


#pragma mark Content edge mask

// The old implementation put a CAGradientLayer mask directly on UIScrollView
// and moved that mask on every scroll tick because UIScrollView changes its
// bounds origin while scrolling. That created needless per-frame work and
// made the fade fight the scrolling content. The new mask belongs to a
// NON-SCROLLING viewport. Its geometry is established only when the panel is
// laid out or resized, so scrolling produces zero mask updates.
- (void)installStaticContentFadeMask {
    if (!self.scrollViewport || CGRectIsEmpty(self.scrollViewport.bounds)) return;

    CAGradientLayer *mask = (CAGradientLayer *)self.scrollViewport.layer.mask;
    if (![mask isKindOfClass:[CAGradientLayer class]]) {
        mask = [CAGradientLayer layer];
        mask.startPoint = CGPointMake(0.5, 0);
        mask.endPoint = CGPointMake(0.5, 1);
        self.scrollViewport.layer.mask = mask;
    }

    CGFloat height = CGRectGetHeight(self.scrollViewport.bounds);
    CGFloat fadeFraction = height > 0 ? MIN(0.25, kContentFadeHeight / height) : 0;
    mask.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    mask.locations = @[@0, @(fadeFraction), @(1 - fadeFraction), @1];
    mask.frame = self.scrollViewport.bounds;
}

- (void)deviceOrientationChanged {
    UIWindow *window = gd_key_window();
    if (!window || !self.panel) return;
    [self layoutPanelForWindow:window];
}

- (void)positionPanel {
    [self positionPanelAnimated:YES];
}

- (void)positionPanelAnimated:(BOOL)animated {
    UIWindow *window = gd_key_window();
    if (!window || !self.glassContainer) return;

    CGFloat chromeWidth = self.panelWidth + kHandleWidth;
    CGFloat targetX = self.panelOpen
        ? (window.bounds.size.width - chromeWidth)
        : (window.bounds.size.width - kHandleWidth);

    void (^changes)(void) = ^{
        // Move the dock and the independent slider-glass compositor together.
        // They are deliberately separate compositors so the pills do NOT fuse
        // with panelGlass/handleGlass, but they must still share the same
        // screen-space geometry.
        CGRect dockFrame = CGRectMake(targetX,
                                      0,
                                      chromeWidth,
                                      window.bounds.size.height);
        self.glassContainer.frame = dockFrame;
        if (self.sliderGlassContainer) {
            self.sliderGlassContainer.frame = dockFrame;
        }
        if (self.contentOverlay) {
            self.contentOverlay.frame = CGRectMake(targetX + kHandleWidth,
                                                   0,
                                                   self.panelWidth,
                                                   window.bounds.size.height);
        }
    };

    if (!animated) {
        changes();
    } else {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:nil];
    }

    if (self.panelOpen) {
        [self startPostFXReapply];
    } else {
        [self stopPostFXReapply];
    }

    [self gd_updateSliderGlassVisibility];
}

#pragma mark Post FX continuous reapply
//
// URP re-blends Volume component values from active profiles every
// frame, so a single write to the runtime stack gets overwritten
// almost immediately. Re-applying on a timer while the panel is open
// is the practical workaround - see file header caveats. Renderer
// features don't need this - their settings aren't re-blended per
// frame the way Volume components are, so a single write on change
// is enough; only the Volume-side active/value writes need repeating
// here.

- (void)startPostFXReapply {
    if (self.postFXReapplyTimer) return;
    self.postFXReapplyTimer = [NSTimer timerWithTimeInterval:kPostFXReapplyInterval
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        gd_reapply_post_fx();
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.postFXReapplyTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPostFXReapply {
    [self.postFXReapplyTimer invalidate];
    self.postFXReapplyTimer = nil;
}

#pragma mark Slider/switch/mode-slider actions

static void gd_update_value_label(GDCapsuleSlider *slider) {
    UILabel *label = objc_getAssociatedObject(slider, "gd_valueLabel");
    NSString *(^format)(float) = objc_getAssociatedObject(slider, "gd_format");
    if (label && format) label.text = format(slider.value);
}

- (void)normalFpsChanged:(GDCapsuleSlider *)slider {
    NSInteger fps = (NSInteger)roundf(slider.value);
    g_menuFPS = fps;
    self.normalFpsValueLabel.text = [NSString stringWithFormat:@"%d", (int)fps];
    [[FPS120Controller shared] setManualMenuFPS:fps];
    [self gd_scheduleSave];
}

- (void)combatFpsChanged:(GDCapsuleSlider *)slider {
    NSInteger fps = (NSInteger)roundf(slider.value);
    g_combatFPS = fps;
    self.combatFpsValueLabel.text = [NSString stringWithFormat:@"%d", (int)fps];
    [[FPS120Controller shared] setManualCombatFPS:fps];
    [self gd_scheduleSave];
}

- (void)texChanged:(GDCapsuleSlider *)slider {
    gd_update_value_label(slider);
    // slider.value is a POSITION (0 empty/worst .. 4 full/best); the value
    // actually sent to the engine is reversed - see header note.
    int32_t engineValue = 4 - (int32_t)roundf(slider.value);
    g_textureMip = engineValue;
    gd_set_texture_mip_limit(engineValue);
    [self gd_scheduleSave];
}

- (void)scaleChanged:(GDCapsuleSlider *)slider {
    gd_update_value_label(slider);
    float scale = slider.value / 100.0f;
    g_renderScale = scale;
    gd_set_render_scale(scale);
    [self gd_scheduleSave];
}

- (void)msaaChanged:(GDModeSlider *)slider {
    int32_t idx = (int32_t)slider.selectedIndex;
    g_msaaIndex = idx;
    int32_t v = gd_step_value(kMSAASteps, 4, (float)idx);
    gd_urp_set_int("set_msaaSampleCount", v);
    [self gd_scheduleSave];
}

- (void)hdrChanged:(UISwitch *)toggle {
    g_hdrOn = toggle.on;
    gd_urp_set_bool("set_supportsHDR", toggle.on);
    [self gd_scheduleSave];
}

// "Disable FModManifest zeroing" - inverted switch (ON means the
// zeroing patch is turned OFF), so this negates before persisting.
// See PatchManifestNetwork.isZeroingEnabled/setZeroingEnabled: for what
// actually reads this.
- (void)fmodZeroingDisableChanged:(UISwitch *)toggle {
    [PatchManifestNetwork setZeroingEnabled:!toggle.on];
}

// "Disable LZ4HC compression on dispatch" - same inverted-switch
// convention as fmodZeroingDisableChanged: above. See
// BundleDoctorService.isUploadCompressionEnabled/
// setUploadCompressionEnabled: for what actually reads this.
- (void)lz4hcCompressionDisableChanged:(UISwitch *)toggle {
    [BundleDoctorService setUploadCompressionEnabled:!toggle.on];
}

- (void)blurIntensityChanged:(GDCapsuleSlider *)slider {
    gd_update_value_label(slider);
    g_blurIntensity = slider.value;
    gd_apply_motion_blur();
    [self gd_scheduleSave];
}

- (void)tonemapModeChanged:(GDModeSlider *)slider {
    g_tonemapMode = (int32_t)slider.selectedIndex;
    gd_apply_tonemapping();
    [self gd_scheduleSave];
}

- (void)urpEffectValueChanged:(GDCapsuleSlider *)slider {
    gd_update_value_label(slider);
    NSString *name = objc_getAssociatedObject(slider, "gd_urp_name");
    if (!name) return;
    g_urpValue[name] = @(slider.value);
    gd_apply_urp_post_effect(name);
    [self gd_scheduleSave];
}

- (void)cameraAAModeChanged:(GDModeSlider *)slider {
    g_aaModeIndex = (int32_t)slider.selectedIndex;
    int32_t v = gd_step_value(kAAModeSteps, 4, (float)slider.selectedIndex);
    gd_camera_data_set_int("set_antialiasing", v);
    [self gd_scheduleSave];
}

- (void)cameraAAQualityChanged:(GDModeSlider *)slider {
    g_aaQualityIndex = (int32_t)slider.selectedIndex;
    int32_t v = gd_step_value(kAAQualitySteps, 3, (float)slider.selectedIndex);
    gd_camera_data_set_int("set_antialiasingQuality", v);
    [self gd_scheduleSave];
}

- (void)cameraDitheringChanged:(UISwitch *)toggle {
    g_ditheringOn = toggle.on;
    gd_camera_data_set_bool("set_dithering", toggle.on);
    [self gd_scheduleSave];
}

@end

#pragma mark - Startup

__attribute__((constructor))
static void graphics_debug_overlay_init(void) {
    __block NSTimer *installTimer;
    installTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [[GraphicsDebugOverlay shared] installIfNeeded];
        if ([GraphicsDebugOverlay shared].panel) {
            gd_dump_glass_effect_instance_info();
            [timer invalidate];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:installTimer forMode:NSRunLoopCommonModes];
}
