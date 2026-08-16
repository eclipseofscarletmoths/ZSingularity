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
#import "BundleTransplant.h"
#import "ModAssetLibrary.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h> // UTType-based UIDocumentPickerViewController init, for the Mods section's "Import Bank Mod"/"Import Bundle Mod(s)" buttons
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

// Target width (points) of the revealed "Delete" capsule segment, and
// how long the quick open/close snap takes - independent of
// kGDHoldConfirmDuration below, which times the red fill instead.
static const CGFloat kGDDeleteCapsuleExpandedWidth = 60;
static const NSTimeInterval kGDDeleteCapsuleSnapDuration = 0.16;

// Builds the capsule "expansion" companion view for `button` and
// inserts it into `parent` (button's own superview), immediately after
// button's trailing edge. This - not the button itself - is what grows
// when the hold begins: the X button never resizes or repositions, so
// its glyph is pixel-for-pixel stationary throughout, while this view
// (plus the matching fill layer dropped into the button itself, see
// below) is "the glass" that visibly expands to form one continuous
// capsule shape. The button's own native-glass chrome already supplies
// a rounded silhouette at rest, so this view only needs a rounded
// TRAILING cap (kCALayerMaxXMinYCorner/kCALayerMaxXMaxYCorner) - its
// leading edge butts flush against the button with no rounding, so the
// two read as one pill once expanded, rather than two visibly separate
// shapes.
//
// Starts at zero width, so at rest it's fully invisible and reserves no
// visible space - -gd_handleHoldToConfirmGesture:/-gd_holdConfirmTick:
// own growing it back down again on release.
static void gd_attach_delete_capsule(UIButton *button, UIView *parent) {
    if (!parent) return; // defensive - button should already be in its row by the time this runs

    UIView *expansion = [[UIView alloc] init];
    expansion.translatesAutoresizingMaskIntoConstraints = NO;
    expansion.clipsToBounds = YES;
    expansion.userInteractionEnabled = NO; // purely decorative - the long-press stays owned by `button`
    expansion.layer.cornerCurve = kCACornerCurveContinuous;
    [parent addSubview:expansion];
    [parent sendSubviewToBack:expansion]; // sits visually behind the button's own trailing edge so there's no seam
    parent.clipsToBounds = NO; // let the capsule overhang the row's resting bounds while expanded - see the header comment above

    UILabel *deleteLabel = [[UILabel alloc] init];
    deleteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    deleteLabel.text = @"Delete";
    deleteLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    deleteLabel.textColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
    deleteLabel.alpha = 0; // faded in once the capsule has room for it - see -gd_handleHoldToConfirmGesture:
    [expansion addSubview:deleteLabel];

    CALayer *expansionFill = [CALayer layer];
    expansionFill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor; // same red/alpha as the Syslog button's own fill
    expansionFill.anchorPoint = CGPointMake(0, 0);
    expansionFill.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner; // rounds only the capsule's outer/trailing cap
    expansionFill.cornerCurve = kCACornerCurveContinuous;
    [expansion.layer insertSublayer:expansionFill atIndex:0];

    CALayer *buttonFill = [CALayer layer];
    buttonFill.backgroundColor = expansionFill.backgroundColor;
    buttonFill.anchorPoint = CGPointMake(0, 0);
    buttonFill.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner; // rounds only the capsule's leading cap
    buttonFill.cornerCurve = kCACornerCurveContinuous;
    // Same trick as kGDPillHoldConfirmFillLayerKey/syslogButtonFillLayer -
    // inserted directly as a sublayer so it survives
    // gd_style_icon_button_as_native_glass rebuilding the button's own
    // UIButtonConfiguration-owned subviews.
    [button.layer insertSublayer:buttonFill atIndex:0];

    NSLayoutConstraint *widthConstraint = [expansion.widthAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [expansion.leadingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [expansion.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [expansion.heightAnchor constraintEqualToAnchor:button.heightAnchor],
        widthConstraint,

        [deleteLabel.centerYAnchor constraintEqualToAnchor:expansion.centerYAnchor],
        [deleteLabel.trailingAnchor constraintLessThanOrEqualToAnchor:expansion.trailingAnchor constant:-8],
        [deleteLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:expansion.leadingAnchor constant:4],
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
// completion block instead of one hardcoded action.
static void gd_attach_hold_to_confirm(UIButton *button, id target, void (^onConfirm)(void)) {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(gd_handleHoldToConfirmGesture:)];
    press.minimumPressDuration = 0; // -gd_holdConfirmTick: owns the real timing, same reasoning as the Syslog button's hold
    press.cancelsTouchesInView = NO;
    [button addGestureRecognizer:press];
    objc_setAssociatedObject(button, kGDHoldConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
    gd_attach_delete_capsule(button, button.superview);
}

// Associated-object keys for gd_attach_pill_hold_to_confirm below -
// same idea as kGDHoldConfirmBlockKey above, plus one for the fill
// layer itself so it's created once per button and reused (mirrors
// syslogButtonFillLayer's own "created lazily on first Began, persists
// after that" comment).
static void * const kGDPillHoldConfirmBlockKey = (void *)&kGDPillHoldConfirmBlockKey;
static void * const kGDPillHoldConfirmFillLayerKey = (void *)&kGDPillHoldConfirmFillLayerKey;

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

// Folder header row for the Mods Library accordion: [chevron][folder
// icon][name] .... [Add pill][pencil][X], left-to-right per request.
// The whole row (not just the chevron) is tappable for expand/collapse
// via a tap gesture wired to `target`/`action` - a bigger hit target
// beats a precise one for a disclosure control - but that gesture only
// covers the row's own background; the three trailing controls are
// real buttons the tap gesture doesn't intercept (UIKit routes a touch
// to the deepest hit-testing view first). The folder name is stashed
// as an associated object on the row itself (for the tap gesture) AND
// on each of the three trailing buttons (for their own handlers) since
// each is wired up independently by the caller (see -gd_rebuildModsLibrary).
//
// Add/Rename are plain buttons the caller wires with target/action.
// Delete is no longer built here at all - it now lives inside this
// folder's own dropdown (its expanded child list) instead of on this
// always-visible row, see gd_make_mods_folder_delete_row - so there's
// no "gd_button_delete" associated object on this row anymore.
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

    // Pencil - rename, now at the row's far right extreme (X used to be
    // here; it's moved into the dropdown, see above).
    UIButton *renameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    renameButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *pencilConfig = [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightSemibold];
    UIImage *pencilImage = [UIImage systemImageNamed:@"pencil" withConfiguration:pencilConfig];
    gd_style_icon_button_as_native_glass(renameButton, pencilImage, [UIColor colorWithWhite:1 alpha:0.6]);
    [renameButton addTarget:target action:renameAction forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(renameButton, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
    [row addSubview:renameButton];

    // Add - icon-only plus glyph now (was a wider "Add" text pill),
    // sized the same as the other icon buttons on this row (pencil/X
    // elsewhere), immediately to the left of the pencil - adds more
    // files into this already-existing folder without going through
    // the New Mod Folder prompt again.
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

        [renameButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [renameButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [renameButton.widthAnchor constraintEqualToConstant:18],
        [renameButton.heightAnchor constraintEqualToConstant:18],

        [addButton.trailingAnchor constraintEqualToAnchor:renameButton.leadingAnchor constant:-3],
        [addButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [addButton.widthAnchor constraintEqualToConstant:18],
        [addButton.heightAnchor constraintEqualToConstant:18],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-5],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:5],
    ]];
    return row;
}

// Small standalone row holding just the folder's delete (X) control -
// lives inside the folder's own dropdown (its expanded child list) now,
// instead of out on the always-visible header row above (per request).
// First thing shown once a folder is expanded. Kept at the same 18x18
// size/glyph the X always had, and centered on this row using the exact
// same -5/+5 top/bottom margin convention gd_make_mods_folder_row uses,
// so it sits at the same Y position within its row that it always did -
// just in a row of its own now, inside the dropdown, rather than
// sharing the folder header row. Delete is NOT wired here - the caller
// attaches the hold-to-confirm gesture via "gd_button_delete", same
// pattern as before.
static UIView *gd_make_mods_folder_delete_row(NSString *folderName) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Delete Folder";
    label.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    [row addSubview:label];

    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:6 weight:UIImageSymbolWeightSemibold];
    UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
    UIColor *xTint = [UIColor colorWithWhite:1 alpha:0.55];
    gd_style_icon_button_as_native_glass(deleteButton, xImage, xTint);
    objc_setAssociatedObject(deleteButton, "gd_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
    [row addSubview:deleteButton];
    objc_setAssociatedObject(row, "gd_button_delete", deleteButton, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:38], // same indent as the entry rows below it
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [deleteButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [deleteButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [deleteButton.widthAnchor constraintEqualToConstant:18],
        [deleteButton.heightAnchor constraintEqualToConstant:18],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-5],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:5],
    ]];
    return row;
}

// One tracked file's row, indented under its folder: [zip/doc icon]
// [name]. No separate Info button - tapping anywhere on the row (same
// whole-row tap-target approach as the folder row above) toggles the
// filepath/CAB/size dropdown the caller (see -gd_rebuildModsLibrary)
// inserts right after this row when the entry's path is in
// modsLibraryExpandedInfoEntries. Delete now lives INSIDE that dropdown
// (see gd_make_mods_entry_info_panel) rather than out on this
// always-visible row - per request, so the row itself no longer owns a
// delete button. The entry is stashed on the row for the tap gesture.
static UIView *gd_make_mods_entry_row(ModAssetLibraryEntry *entry, id target, SEL tapAction) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    BOOL isBundle = (entry.cab != nil);
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:(isBundle ? @"doc.zipper" : @"doc.fill") withConfiguration:iconConfig]];
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

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:22], // indented under the folder icon above
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:5],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-8],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:3],
    ]];
    return row;
}

// Expandable "Info" panel for one entry - filepath (where the file
// lives WITHIN THE GAME's own files, not this tweak's own tracked-copy
// storage - resolved once at import time, see
// ModAssetLibraryEntry.livePathDescription), CAB (bundles only), and
// human-readable size. Path/CAB use GDMarqueeLabel so a long value
// scrolls into view instead of getting truncated.
// Returns a container whose "gd_button_delete" associated object is the
// entry's X (delete) button - the caller (-gd_rebuildModsLibrary) reads
// that the same way it always has, to attach hold-to-confirm. The X
// itself now lives inside this dropdown instead of on the always-visible
// entry row above it (per request) - same 18x18 size/glyph it always
// had, and centered on the Path line so it sits at the same Y position
// it used to occupy on the row (the row's one line of text, now this
// dropdown's first line).
static UIView *gd_make_mods_entry_info_panel(ModAssetLibraryEntry *entry) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(container, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    UIStackView *panel = [[UIStackView alloc] init];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 2;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layoutMarginsRelativeArrangement = YES;
    // Right margin widened (4 -> 26) to reserve room for the delete
    // button that now lives in this corner instead of out on the row.
    panel.layoutMargins = UIEdgeInsetsMake(2, 38, 2, 26); // lines up under the entry name, past the folder/doc icon indent
    [container addSubview:panel];

    UIFont *subtextFont = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    UIColor *subtextColor = [UIColor colorWithWhite:1 alpha:0.4];

    // livePathDescription is resolved ONCE, at import time (see
    // +[ModAssetLibrary importFileURLs:intoFolder:error:]) - not
    // recomputed here. For a bundle, computing this means reading every
    // cached __data's CAB header to find this entry's match (see
    // BundleTransplant.h's own MATCHING note), which is exactly the
    // full-directory rescan that used to make opening this dropdown
    // hang: doing that on every tap instead of once at import was the
    // bug. nil only for entries imported before this field existed.
    NSString *pathText = entry.livePathDescription ?: @"(unknown - imported before this was tracked)";

    GDMarqueeLabel *pathLabel = [[GDMarqueeLabel alloc] init];
    pathLabel.text = [NSString stringWithFormat:@"Path: %@", pathText];
    pathLabel.font = subtextFont;
    pathLabel.textColor = subtextColor;
    // Keyed by entry path so this marquee's scroll phase survives a
    // -gd_rebuildModsLibrary triggered by some OTHER row's dropdown -
    // see GDMarqueeLabel.marqueeKey.
    pathLabel.marqueeKey = [entry.path stringByAppendingString:@"|path"];
    [panel addArrangedSubview:pathLabel];

    if (entry.cab) {
        GDMarqueeLabel *cabLabel = [[GDMarqueeLabel alloc] init];
        cabLabel.text = [NSString stringWithFormat:@"CAB: %@", entry.cab];
        cabLabel.font = subtextFont;
        cabLabel.textColor = subtextColor;
        cabLabel.marqueeKey = [entry.path stringByAppendingString:@"|cab"];
        [panel addArrangedSubview:cabLabel];
    }

    UILabel *sizeLabel = [[UILabel alloc] init];
    sizeLabel.text = [NSString stringWithFormat:@"Size: %@", [NSByteCountFormatter stringFromByteCount:(long long)entry.byteSize countStyle:NSByteCountFormatterCountStyleFile]];
    sizeLabel.font = subtextFont;
    sizeLabel.textColor = subtextColor;
    [panel addArrangedSubview:sizeLabel]; // short enough it never needs to scroll - plain UILabel is fine

    // X - delete + restore. Same glyph/style/size it had on the entry
    // row; hold-to-confirm is attached by the caller, same as before.
    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:6 weight:UIImageSymbolWeightSemibold];
    UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
    UIColor *xTint = [UIColor colorWithWhite:1 alpha:0.55];
    gd_style_icon_button_as_native_glass(deleteButton, xImage, xTint);
    objc_setAssociatedObject(deleteButton, "gd_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
    [container addSubview:deleteButton];
    objc_setAssociatedObject(container, "gd_button_delete", deleteButton, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],

        [deleteButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-4],
        [deleteButton.centerYAnchor constraintEqualToAnchor:pathLabel.centerYAnchor], // same Y the row's own X used to sit at
        [deleteButton.widthAnchor constraintEqualToConstant:18],
        [deleteButton.heightAnchor constraintEqualToConstant:18],
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

static UIView *gd_make_title_block(void) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.textAlignment = NSTextAlignmentNatural;

    NSString *fullTitle = @"ZSingularity";
    NSString *emphasized = @"ZS"; // larger prefix within the same word
    // 50% bigger across the board per request (was 40/30).
    UIFont *bigFont = gd_excelsior_sans_font(60, UIFontWeightBold);
    UIFont *restFont = gd_excelsior_sans_font(45, UIFontWeightBold);
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
    // sized 150% smaller than the wordmark it now sits beside - i.e.
    // restFont's point size divided by 1.5 - so it reads as a small
    // badge riding the wordmark's own baseline rather than a second
    // line of text. Muted/white like the old subtitle rather than the
    // wordmark's green, so it stays legible as secondary detail.
    // gd_version_string() below pulls the build number CI stamps in at
    // compile time, so this updates on its own with every new build -
    // no manual edit needed here.
    NSString *versionTag = [@" " stringByAppendingString:gd_version_string()];
    UIFont *versionFont = gd_excelsior_sans_font(restFont.pointSize / 1.5, UIFontWeightMedium);
    NSAttributedString *versionString =
        [[NSAttributedString alloc] initWithString:versionTag
                                         attributes:@{
            NSFontAttributeName: versionFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45],
            NSBaselineOffsetAttributeName: @(restFont.descender - versionFont.descender), // keeps the smaller text sitting on the wordmark's own baseline instead of the shared line's midpoint
        }];
    [titleString appendAttributedString:versionString];

    headerLabel.attributedText = titleString;
    [container addSubview:headerLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = @"Developed by trilliance";
    subtitleLabel.textAlignment = NSTextAlignmentNatural; 
    subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    subtitleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
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

// Mods Library accordion (see ModAssetLibrary.h) - one folder row per
// +[ModAssetLibrary folderNames], expandable to show that folder's own
// tracked entries. modsLibraryExpandedFolders just remembers which
// folder names are currently expanded across a -gd_rebuildModsLibrary
// call (the whole stack is thrown away and rebuilt on every change,
// same pattern as syslogBlacklistEntriesStack above - this is what
// keeps that from collapsing every row back closed on every rebuild).
@property (nonatomic, strong) UIStackView *modsLibraryStack;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedFolders;
// Which entries (keyed by ModAssetLibraryEntry.path) currently have
// their "Info" dropdown open - see gd_make_mods_entry_row/
// -gd_modsLibraryEntryInfoTapped: and gd_make_mods_entry_info_panel.
// Same survives-a-rebuild pattern as modsLibraryExpandedFolders above.
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedInfoEntries;

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
    // BankTransplant.h/BundleTransplant.h do the actual splice/swap - see
    // those files' headers. Import Mod(s) sniffs each picked file (RIFF/
    // FEV magic -> bank, UnityFS magic -> bundle - see
    // -gd_kindForFileAtURL:) and routes it to whichever transplant class
    // actually handles that file type, and immediately prompts for a
    // folder name so every import also lands in the Mods Library
    // accordion below (see -gd_beginModImportIntoFolder:) - Import Mod(s)
    // both swaps files in AND tracks them, in one action.
    //
    // Restore Bundles/Restore Originals used to be two separate buttons
    // (different directories, see BankTransplant.h/BundleTransplant.h);
    // now one "Restore Bundles & Banks" button drives both restores
    // together, since from the person's side there was never a reason
    // to run one without the other. Force Restore (the escape hatch for
    // a same-size coincidence masking a real bundle change - see
    // +[BundleTransplant restoreAllBackedUpBundlesWithForce:error:])
    // moved into the "No Assets to Restore" alert this button shows
    // when there's nothing the soft restore could do - see
    // -restoreOriginalsTapped/-gd_presentNoAssetsToRestoreAlert.
    //
    // The Mods Library accordion (ModAssetLibrary.h) - named folders of
    // tracked mod files, on top of (not instead of) the swap-in-place
    // flow above - no longer gets its own section header or a separate
    // "Add Asset" entry point; it just lives directly under this
    // section's two buttons, since Import Mod(s) is now the only way
    // into it.
    gd_add_section_header(self.stack, @"Mods");
    GDRow *modsRow = gd_make_button_pair_row(
        @"Import Mod(s)", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0],
        @"Restore Bundles & Banks", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    UIButton *importModButton = objc_getAssociatedObject(modsRow, "gd_button_left");
    [importModButton addTarget:self action:@selector(importModTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *restoreOriginalsButton = objc_getAssociatedObject(modsRow, "gd_button_right");
    // Hold-to-confirm (1.5s, same red-fill mechanism as the Syslog
    // button's own hold - see gd_attach_pill_hold_to_confirm) rather than
    // a plain tap, same reasoning as every X icon in the accordion below:
    // this is a destructive-ish bulk action, a stray tap shouldn't run
    // it. A quick tap now just plays an error haptic instead of doing
    // anything - see -gd_handlePillHoldToConfirmGesture:. Reuses the
    // `weakSelf` already declared above for the Syslog line handler -
    // still in scope here, same method body.
    gd_attach_pill_hold_to_confirm(restoreOriginalsButton, self, ^{
        [weakSelf restoreOriginalsTapped];
    });
    [self.stack addArrangedSubview:modsRow];

    self.modsLibraryExpandedFolders = [NSMutableSet set];
    self.modsLibraryExpandedInfoEntries = [NSMutableSet set];
    self.modsLibraryStack = [[UIStackView alloc] init];
    self.modsLibraryStack.axis = UILayoutConstraintAxisVertical;
    self.modsLibraryStack.spacing = 2;
    self.modsLibraryStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.modsLibraryStack];
    [self gd_rebuildModsLibrary];

    // --- Config ---
    // Native Liquid Glass, sized to match every other row/button on the
    // panel (see gd_make_button_row). Deliberately the very last thing
    // added to the stack so it renders at the bottom of the scroll
    // content, per request. Reset and Reapply share one row via
    // gd_make_button_pair_row - Reset puts every control back on its
    // hardcoded default and pushes that to the engine; Reapply re-pushes
    // whatever the panel's current values already are, without touching
    // any of them - the same manual escape hatch as the isRunningLoad
    // poll in GDScripts.m, for a load the poll missed or a value that
    // got stomped by opening the game's own settings menu (see this
    // file's header caveat on that).
    gd_add_section_header(self.stack, @"Config");
    GDRow *configRow = gd_make_button_pair_row(
        @"Reset Settings", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0],
        @"Reapply Settings", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    UIButton *resetButton = objc_getAssociatedObject(configRow, "gd_button_left");
    [resetButton addTarget:self action:@selector(resetSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reapplyButton = objc_getAssociatedObject(configRow, "gd_button_right");
    [reapplyButton addTarget:self action:@selector(reapplySettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:configRow];

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

// Associated-object key on a UIDocumentPickerViewController instance,
// tagging which folder the picked files should be tracked into once
// swapped: "modImport:<folderName>", used by both the main Import
// Mod(s) button (-importModTapped prompts for the folder name first,
// creating it if needed) and each folder row's own "Add" pill
// (-gd_modsLibraryFolderAddTapped: already knows the folder, no prompt
// needed) - see -documentPicker:didPickDocumentsAtURLs:.
static void * const kGDModsPickerKindKey = (void *)&kGDModsPickerKindKey;

#pragma mark Mods (import)
//
// UI-side glue only - the actual splice/backup/swap logic lives in
// BankTransplant.h/BundleTransplant.h. See those files' headers for what
// "transplant" means here.

// Prompts for a folder name first (see -gd_promptForModFolderNameWithTitle:
// message:completion: - the same compact prompt the folder rows'
// "Add"/pencil paths reuse), so every import is tracked in the Mods
// Library accordion as well as swapped in place, then opens the picker
// tagged "modImport:<name>" - see -documentPicker:didPickDocumentsAtURLs:.
// A name matching an already-existing folder just imports into that
// folder instead of erroring, since re-using a folder for a follow-up
// batch of files for the same mod is a completely normal thing to want.
- (void)importModTapped {
    __weak typeof(self) weakSelf = self;
    [self gd_promptForModFolderNameWithTitle:@"Import Mod(s)"
                                  actionTitle:@"Next"
                                   completion:^(NSString *trimmedName) {
        [weakSelf gd_beginModImportIntoFolder:trimmedName];
    }];
}

- (void)gd_beginModImportIntoFolder:(NSString *)folderName {
    NSError *error = nil;
    BOOL created = [ModAssetLibrary createFolderNamed:folderName error:&error];
    if (!created && error.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self gd_presentModsAlertWithTitle:@"Couldn't Create Folder" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }

    [self.modsLibraryExpandedFolders addObject:folderName]; // open it right away - about to add files into it
    [self gd_rebuildModsLibrary];
    [self gd_presentModImportPickerForFolder:folderName];
}

// Presents the system file picker so the person can hand-pick one or
// more modded files - banks and bundles alike, mixed in the same
// selection if they want. There's no registered UTI for ".bank" (an
// FMOD-specific container, not a system type) and cached bundles carry
// no extension at all, so this opens on the generic "any file" content
// type rather than filtering - UIDocumentPickerViewController doesn't
// offer filename-extension filtering separately from UTType anyway.
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
    objc_setAssociatedObject(picker, kGDModsPickerKindKey, [@"modImport:" stringByAppendingString:folderName], OBJC_ASSOCIATION_COPY);

    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods] no root view controller to present the file picker from");
        return;
    }
    [presenter presentViewController:picker animated:YES completion:nil];
}

// First 12 bytes are enough to tell the two apart without reading the
// whole file: RIFF/FEV is BankTransplant's wrapper (see
// bt_find_wrapper_info's own check), UnityFS is BundleTransplant's
// (see UnityBundleCAB.h's format note). Returns nil for anything that
// matches neither - reported to the person as unrecognized rather than
// guessed at.
- (nullable NSString *)gd_kindForFileAtURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:url.path];
    NSData *head = [fh readDataOfLength:12];
    [fh closeFile];
    if (accessing) [url stopAccessingSecurityScopedResource];
    if (head.length < 12) return nil;

    const uint8_t *b = head.bytes;
    if (memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "FEV ", 4) == 0) return @"bank";
    if (memcmp(b, "UnityFS", 7) == 0) return @"bundle";
    return nil;
}

// Every picker this panel presents is now tagged "modImport:<folder>" -
// see kGDModsPickerKindKey's own comment - so this just pulls the
// folder name back out and hands the whole selection to
// -gd_handlePickedModURLs:intoFolder:.
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSString *kind = objc_getAssociatedObject(controller, kGDModsPickerKindKey);
    NSString *folderName = [kind hasPrefix:@"modImport:"] ? [kind substringFromIndex:@"modImport:".length] : nil;
    [self gd_handlePickedModURLs:urls intoFolder:folderName];
}

// Sniffs every picked file, splits into bank-kind/bundle-kind/
// unrecognized, shows one generic working alert (re-encoding turned out
// to not be worth calling out specially in the UI - both flows just
// read as "swapping files" to the person waiting on it), does both
// transplant calls on a background queue, then reports one combined
// summary. Both transplant calls are genuinely independent (different
// files, different directories) so there's no ordering requirement
// between them. Once the swap side is done, the same URLs are also
// handed to +[ModAssetLibrary importFileURLs:intoFolder:error:] so
// they're tracked in the Mods Library accordion - a swap with no
// matching folder to import into shouldn't be possible anymore (every
// caller now supplies one - see kGDModsPickerKindKey), but folderName
// is nullable here anyway as a defensive fallback.
- (void)gd_handlePickedModURLs:(NSArray<NSURL *> *)urls intoFolder:(nullable NSString *)folderName {
    UIViewController *presenter = gd_key_window().rootViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:@"Swapping Files…"
                                                                       message:@"Matching modded files against stock/cached originals and swapping them in. This can take a while."
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

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSURL *> *bankURLs = [NSMutableArray array];
        NSMutableArray<NSURL *> *bundleURLs = [NSMutableArray array];
        NSMutableArray<NSString *> *unrecognized = [NSMutableArray array];
        for (NSURL *url in urls) {
            NSString *kind = [self gd_kindForFileAtURL:url];
            if ([kind isEqualToString:@"bank"]) {
                [bankURLs addObject:url];
            } else if ([kind isEqualToString:@"bundle"]) {
                [bundleURLs addObject:url];
            } else {
                [unrecognized addObject:url.lastPathComponent];
            }
        }

        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSInteger totalSwapped = 0;

        for (NSURL *bankURL in bankURLs) {
            NSError *bankErr = nil;
            BOOL ok = [BankTransplant transplantAndSwapModdedBankAtURL:bankURL error:&bankErr];
            if (ok) {
                totalSwapped++;
                [lines addObject:[NSString stringWithFormat:@"%@: swapped", bankURL.lastPathComponent]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"%@: %@", bankURL.lastPathComponent, bankErr.localizedDescription ?: @"failed"]];
            }
        }

        if (bundleURLs.count > 0) {
            NSError *bundleErr = nil;
            NSArray<BundleTransplantResult *> *results = [BundleTransplant transplantAndSwapModdedBundlesAtURLs:bundleURLs error:&bundleErr];
            if (!results) {
                [lines addObject:[NSString stringWithFormat:@"Bundle scan failed: %@", bundleErr.localizedDescription ?: @"unknown error"]];
            } else {
                for (BundleTransplantResult *r in results) {
                    totalSwapped += r.swappedCount;
                    if (r.error) {
                        [lines addObject:[NSString stringWithFormat:@"%@: %@", r.moddedFileName, r.error.localizedDescription]];
                    } else if (r.swappedCount == 0) {
                        [lines addObject:[NSString stringWithFormat:@"%@ (%@): no match in cache", r.moddedFileName, r.cab ?: @"?"]];
                    } else {
                        [lines addObject:[NSString stringWithFormat:@"%@ (%@): swapped %ld", r.moddedFileName, r.cab, (long)r.swappedCount]];
                    }
                }
            }
        }

        for (NSString *name in unrecognized) {
            [lines addObject:[NSString stringWithFormat:@"%@: not a recognized bank or bundle", name]];
        }

        // Track every picked file (recognized or not) in the Mods
        // Library folder, independent of whether the swap side actually
        // matched anything - the accordion is bookkeeping of what was
        // imported, not just what successfully swapped.
        BOOL trackedInLibrary = NO;
        if (folderName.length > 0) {
            NSError *libraryErr = nil;
            trackedInLibrary = [ModAssetLibrary importFileURLs:urls intoFolder:folderName error:&libraryErr];
            if (!trackedInLibrary) {
                ZLog(@"[Mods] couldn't track imported files in \"%@\": %@", folderName, libraryErr.localizedDescription);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            void (^showResult)(void) = ^{
                if (trackedInLibrary) [self gd_rebuildModsLibrary];

                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:(totalSwapped > 0) ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];
                NSString *title = totalSwapped > 0 ? @"Files Swapped" : @"No Matches";
                NSString *message = [lines componentsJoinedByString:@"\n"];
                if (totalSwapped > 0) {
                    message = [message stringByAppendingString:@"\n\nRestart the game for swapped files to take effect."];
                }
                [self gd_presentModsAlertWithTitle:title message:message];
            };
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:showResult];
            } else {
                showResult();
            }
        });
    });
}

// Combined "Restore Bundles & Banks" handler - the merged counterpart
// to the old separate Restore Bundles / Restore Originals (banks)
// buttons (see this method's own header comment on the "Mods" section
// build code above for why they're one button now). Runs the soft
// (non-forcing) bundle restore - +[BundleTransplant
// restoreAllBackedUpBundlesWithForce:NO error:] skips any entry
// already the same byte size as its own backup, same as before - and
// the unconditional bank restore, and reports one combined total. If
// NEITHER restore actually did anything, shows the "No Assets to
// Restore" alert with Force Restore as the red-text escape hatch
// instead of a plain "nothing happened" message, per request.
- (void)restoreOriginalsTapped {
    NSError *bundleError = nil;
    NSInteger bundlesRestored = [BundleTransplant restoreAllBackedUpBundlesWithForce:NO error:&bundleError];

    NSError *bankError = nil;
    NSInteger banksRestored = [BankTransplant restoreAllBackedUpBanksWithError:&bankError];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (bundlesRestored < 0 || banksRestored < 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *message = bundlesRestored < 0
            ? (bundleError.localizedDescription ?: @"Unknown error.")
            : (bankError.localizedDescription ?: @"Unknown error.");
        [self gd_presentModsAlertWithTitle:@"Restore Failed" message:message];
        return;
    }

    NSInteger totalRestored = bundlesRestored + banksRestored;
    if (totalRestored == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self gd_presentNoAssetsToRestoreAlert];
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSString *message = [NSString stringWithFormat:
        @"Restored %ld bundle%@ and %ld bank%@ to their original state. Restart the game for it to take effect.",
        (long)bundlesRestored, bundlesRestored == 1 ? @"" : @"s",
        (long)banksRestored, banksRestored == 1 ? @"" : @"s"];
    [self gd_presentModsAlertWithTitle:@"Restore Bundles & Banks" message:message];
}

// Shown when -restoreOriginalsTapped's soft pass restores nothing at
// all - either nothing's ever been swapped, or every bundle backup
// already matches its live file's size (banks have no such skip - if a
// bank backup exists and didn't restore, something else is wrong and
// force wouldn't help there anyway, so Force Restore only re-runs the
// bundle side). Force Restore is styled destructive (native red action
// text), per request.
- (void)gd_presentNoAssetsToRestoreAlert {
    UIViewController *presenter = gd_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods] No Assets to Restore (no root view controller to present from)");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Assets to Restore"
        message:@"Nothing needed restoring - either nothing's been swapped, or every bundle backup already matches its live file's size."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Force Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf forceRestoreOriginalBundlesTapped];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// Same restore as the soft pass above, but unconditional - see
// +[BundleTransplant restoreAllBackedUpBundlesWithForce:error:]'s force:
// parameter. The explicit escape hatch for a same-size coincidence
// masking a real change the byte check can't see.
- (void)forceRestoreOriginalBundlesTapped {
    NSError *error = nil;
    NSInteger restored = [BundleTransplant restoreAllBackedUpBundlesWithForce:YES error:&error];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    if (restored < 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self gd_presentModsAlertWithTitle:@"Restore Failed"
                                    message:error.localizedDescription ?: @"Unknown error."];
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSString *message = restored == 0
        ? @"No backed-up bundles found - nothing to restore."
        : [NSString stringWithFormat:@"Force-restored %ld bundle%@ to its cached stock state. Restart the game for it to take effect.",
              (long)restored, restored == 1 ? @"" : @"s"];
    [self gd_presentModsAlertWithTitle:@"Force Restore Bundles" message:message];
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

// Handler for every gesture gd_attach_hold_to_confirm attaches (folder
// X icons and entry X icons alike). minimumPressDuration:0 so -Began
// fires on touch-down and -gd_holdConfirmTick: owns the real 1.5s
// timing per-frame - see that method and gd_attach_hold_to_confirm's
// own header comment for why (same shape as -handleSyslogButtonLongPress:).
- (void)gd_handleHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            // A second finger landing on a different X while one hold is
            // already in flight shouldn't hijack it - only the first
            // touch-down starts a hold; every button not already mid-
            // hold reports Began as normal touch handling, but a stray
            // interruption here can't happen without another button
            // stealing the run loop tick, so this is mostly defensive.
            if (self.holdConfirmActiveButton && self.holdConfirmActiveButton != button) break;

            self.holdConfirmActiveButton = button;
            self.holdConfirmStartTime = CACurrentMediaTime();
            self.holdConfirmTriggered = NO;

            // Snap the capsule open right away - the fill (driven by
            // -gd_holdConfirmTick: below) is what actually times out the
            // 1.5s hold, so the reveal itself just needs to feel quick,
            // not track the hold duration.
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kGDHoldConfirmExpansionWidthKey);
            UILabel *deleteLabel = objc_getAssociatedObject(button, kGDHoldConfirmDeleteLabelKey);
            widthConstraint.constant = kGDDeleteCapsuleExpandedWidth;
            [UIView animateWithDuration:kGDDeleteCapsuleSnapDuration
                                   delay:0
                  usingSpringWithDamping:0.8
                   initialSpringVelocity:0.4
                                 options:UIViewAnimationOptionCurveEaseOut
                              animations:^{
                [button.superview layoutIfNeeded];
                deleteLabel.alpha = 1;
            } completion:nil];

            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gd_holdConfirmTick:)];
            [self.holdConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (self.holdConfirmActiveButton != button) break;
            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = nil;
            if (!self.holdConfirmTriggered) {
                // Released before the 1.5s mark - collapse the capsule
                // back down instead of leaving it stranded mid-animation,
                // and play an error haptic: this covers a plain quick tap
                // too (Began immediately followed by Ended), which is
                // exactly the "clicked but didn't hold" case that should
                // tell the person to hold instead.
                [self gd_resetHoldConfirmButton:button animated:YES];
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

// Drives the per-frame red progress-fill across the now-expanded
// capsule - same system as the Syslog button's own hold-to-confirm fill
// (see -gd_syslogHoldTick:) and the pill hold-confirm variant (see
// -gd_pillHoldConfirmTick:), just split across two adjacent layers
// (buttonFill + expansionFill) so it sweeps continuously across the
// whole capsule rather than just one piece of it. Fires the button's
// completion block once the hold reaches kGDHoldConfirmDuration.
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
    CALayer *buttonFill = objc_getAssociatedObject(button, kGDHoldConfirmButtonFillKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kGDHoldConfirmExpansionFillKey);

    CGFloat buttonWidth = button.bounds.size.width;
    CGFloat expansionWidth = expansion.bounds.size.width;
    CGFloat totalWidth = buttonWidth + expansionWidth;
    CGFloat filledWidth = totalWidth * pct;
    CGFloat buttonFillWidth = (CGFloat)MIN(filledWidth, buttonWidth);
    CGFloat expansionFillWidth = (CGFloat)MAX(0, filledWidth - buttonWidth);

    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // per-tick updates ARE the animation, same as the Syslog fill's own tick
    buttonFill.frame = CGRectMake(0, 0, buttonFillWidth, button.bounds.size.height);
    buttonFill.cornerRadius = button.bounds.size.height / 2.0;
    expansionFill.frame = CGRectMake(0, 0, expansionFillWidth, expansion.bounds.size.height);
    expansionFill.cornerRadius = expansion.bounds.size.height / 2.0;
    [CATransaction commit];

    if (elapsed >= kGDHoldConfirmDuration && !self.holdConfirmTriggered) {
        self.holdConfirmTriggered = YES;
        [link invalidate];
        self.holdConfirmDisplayLink = nil;

        void (^completion)(void) = objc_getAssociatedObject(button, kGDHoldConfirmBlockKey);
        [self gd_resetHoldConfirmButton:button animated:NO];
        self.holdConfirmActiveButton = nil;

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];

        if (completion) completion();
    }
}

// Collapses the capsule back down to its resting (zero-width) state -
// used both on an early release (animated, so it visibly retracts) and
// right before the completion block runs on a full hold (unanimated,
// since the row is about to be torn down by the resulting rebuild
// anyway - matches the old scale-reset's own NO/YES split).
- (void)gd_resetHoldConfirmButton:(UIButton *)button animated:(BOOL)animated {
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kGDHoldConfirmExpansionWidthKey);
    UILabel *deleteLabel = objc_getAssociatedObject(button, kGDHoldConfirmDeleteLabelKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kGDHoldConfirmButtonFillKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kGDHoldConfirmExpansionFillKey);
    UIView *expansion = objc_getAssociatedObject(button, kGDHoldConfirmExpansionViewKey);

    void (^apply)(void) = ^{
        widthConstraint.constant = 0;
        deleteLabel.alpha = 0;
        [button.superview layoutIfNeeded];
    };
    void (^resetFills)(void) = ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        buttonFill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
        expansionFill.frame = CGRectMake(0, 0, 0, expansion.bounds.size.height);
        [CATransaction commit];
    };
    if (animated) {
        [UIView animateWithDuration:0.18 animations:apply];
    } else {
        apply();
    }
    resetFills();
}

// Handler for gd_attach_pill_hold_to_confirm's gesture - same shape as
// -handleSyslogButtonLongPress: (this basically IS that method,
// generalized to any button + completion block instead of hardcoding
// the Syslog button and -gd_enterSyslogVerboseMode). minimumPressDuration:0
// so -Began fires on touch-down and -gd_pillHoldConfirmTick: owns the
// real 1.5s timing per-frame, the same reasoning as the icon version's
// own header comment.
- (void)gd_handlePillHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            if (self.pillHoldConfirmActiveButton && self.pillHoldConfirmActiveButton != button) break;

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
                // Inserted directly as a sublayer, same reasoning as
                // syslogButtonFillLayer's own comment - sits behind
                // whatever UIButtonConfiguration's native glass style is
                // managing as the button's real subviews, and survives
                // gd_style_button_as_native_glass never touching
                // button.layer's sublayers directly.
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
            if (self.pillHoldConfirmActiveButton != button) break;
            [self.pillHoldConfirmDisplayLink invalidate];
            self.pillHoldConfirmDisplayLink = nil;

            if (!self.pillHoldConfirmTriggered) {
                // Released before the 1.5s mark (a plain tap included) -
                // snap the fill back down and play an error haptic, same
                // contract as the icon X buttons' own early-release path.
                CALayer *fill = objc_getAssociatedObject(button, kGDPillHoldConfirmFillLayerKey);
                [CATransaction begin];
                [CATransaction setAnimationDuration:0.18];
                fill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
                fill.cornerRadius = button.bounds.size.height / 2.0;
                [CATransaction commit];

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

- (void)gd_pillHoldConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kGDPillHoldConfirmDuration = 1.5;
    UIButton *button = self.pillHoldConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    NSTimeInterval elapsed = CACurrentMediaTime() - self.pillHoldConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kGDPillHoldConfirmDuration);

    CALayer *fill = objc_getAssociatedObject(button, kGDPillHoldConfirmFillLayerKey);
    CGRect bounds = button.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // no implicit animation - the per-tick updates ARE the animation
    fill.frame = CGRectMake(0, 0, bounds.size.width * pct, bounds.size.height);
    fill.cornerRadius = bounds.size.height / 2.0;
    [CATransaction commit];

    if (pct >= 1.0 && !self.pillHoldConfirmTriggered) {
        self.pillHoldConfirmTriggered = YES;
        [link invalidate];
        self.pillHoldConfirmDisplayLink = nil;

        void (^completion)(void) = objc_getAssociatedObject(button, kGDPillHoldConfirmBlockKey);

        // Snap the fill back down now that the hold has done its job -
        // otherwise it'd sit fully red until some unrelated redraw.
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.18];
        fill.frame = CGRectMake(0, 0, 0, bounds.size.height);
        [CATransaction commit];

        self.pillHoldConfirmActiveButton = nil;
        if (completion) completion();
    }
}

#pragma mark Mods Library

// Compact one-field name prompt, reused by the main Import Mod(s) flow
// and each folder row's own Rename button. Deliberately terser than
// the old "New Mod Folder" alert (no descriptive message under the
// title) - on a small phone, title + message + text field + two
// buttons could push the alert tall enough that the keyboard covered
// the field itself before the person had even typed anything.
// completion only runs with a validated (non-empty, trimmed) name;
// Cancel or an empty submission just backs out silently.
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
// add/rename/delete. Entries are sorted bundles-first (entry.cab !=
// nil), then A-Z within each group, per request - +entriesInFolder:
// itself returns oldest-added-first, so this is purely a display-order
// sort, not a manifest rewrite.
- (void)gd_rebuildModsLibrary {
    if (!self.modsLibraryStack) return;

    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
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

        if (!expanded) continue;

        // Delete now lives inside the dropdown (per request) - first
        // thing shown once the folder is expanded, rather than on the
        // always-visible header row above.
        UIView *folderDeleteRow = gd_make_mods_folder_delete_row(folderName);
        UIButton *folderDeleteButton = objc_getAssociatedObject(folderDeleteRow, "gd_button_delete");
        NSString *folderNameForDelete = [folderName copy]; // own copy for the block below, independent of the loop variable
        gd_attach_hold_to_confirm(folderDeleteButton, self, ^{
            [weakSelf gd_deleteModFolderConfirmed:folderNameForDelete];
        });
        [self.modsLibraryStack addArrangedSubview:folderDeleteRow];

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

        // Bundles (parseable Unity bundle - entry.cab != nil) before
        // bank/other files, A-Z within each group.
        NSArray<ModAssetLibraryEntry *> *sortedEntries =
            [entries sortedArrayUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
                BOOL aIsBundle = (a.cab != nil);
                BOOL bIsBundle = (b.cab != nil);
                if (aIsBundle != bIsBundle) return aIsBundle ? NSOrderedAscending : NSOrderedDescending;
                return [a.fileName localizedStandardCompare:b.fileName];
            }];

        for (ModAssetLibraryEntry *entry in sortedEntries) {
            UIView *entryRow = gd_make_mods_entry_row(entry, self, @selector(gd_modsLibraryEntryInfoTapped:));
            [self.modsLibraryStack addArrangedSubview:entryRow];

            if ([self.modsLibraryExpandedInfoEntries containsObject:entry.path]) {
                // Delete now lives inside this info dropdown (per
                // request) instead of on the always-visible entry row
                // above - see gd_make_mods_entry_info_panel.
                UIView *infoPanel = gd_make_mods_entry_info_panel(entry);
                UIButton *entryDeleteButton = objc_getAssociatedObject(infoPanel, "gd_button_delete");
                ModAssetLibraryEntry *entryForDelete = entry;
                NSString *folderNameForEntry = [folderName copy];
                gd_attach_hold_to_confirm(entryDeleteButton, self, ^{
                    [weakSelf gd_deleteModEntryConfirmed:entryForDelete inFolder:folderNameForEntry];
                });
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
// this skips straight to the picker (tagged "modImport:<folder>",
// same as the main Import Mod(s) flow - see
// -gd_presentModImportPickerForFolder:) rather than prompting for a
// name again.
- (void)gd_modsLibraryFolderAddTapped:(UIButton *)sender {
    NSString *folderName = objc_getAssociatedObject(sender, "gd_modsFolderName");
    if (!folderName) return;
    [self gd_presentModImportPickerForFolder:folderName];
}

// Wired to a folder row's pencil button - prompts for a new name (same
// compact prompt as the main Import Mod(s) flow) and renames the
// folder's directory in place via
// +[ModAssetLibrary renameFolderNamed:to:error:].
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

// Wired to an entry row's "Info" pill (see gd_make_mods_entry_row) -
// toggles that one entry's dropdown (filepath/CAB/size, see
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

// Restores one tracked entry's swapped-in file back to stock before
// it's forgotten (by a per-entry delete OR as part of a whole-folder
// delete - see -gd_deleteModEntryConfirmed:inFolder:/
// -gd_deleteModFolderConfirmed: below). Bundles go through their own
// CAB via +[BundleTransplant restoreBackedUpBundlesForCAB:force:error:]
// (force:YES - a deliberate delete is a deliberate single-item action,
// same reasoning the old per-entry Reset button used); anything
// without a CAB is treated as a bank and restored by filename via
// +[BankTransplant restoreBackedUpBankNamed:error:]. Best-effort only:
// a tracked file that was never actually swapped in (no backup exists)
// just restores 0, which isn't a failure worth surfacing here - the
// delete itself should never be blocked by that.
- (void)gd_restoreModEntry:(ModAssetLibraryEntry *)entry {
    NSError *error = nil;
    if (entry.cab) {
        [BundleTransplant restoreBackedUpBundlesForCAB:entry.cab force:YES error:&error];
    } else {
        [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&error];
    }
    if (error) {
        ZLog(@"[Mods] couldn't restore %@ before removing it from the library: %@", entry.fileName, error.localizedDescription);
    }
}

// Fires once an entry row's X has been held for the full 1.5s (see
// gd_attach_hold_to_confirm) - restores that one file (see
// -gd_restoreModEntry:) and forgets it via
// +[ModAssetLibrary removeEntry:fromFolder:error:].
- (void)gd_deleteModEntryConfirmed:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    [self gd_restoreModEntry:entry];

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
// restores every entry still tracked in the folder (see
// -gd_restoreModEntry:), then deletes the folder itself (manifest and
// every file under it) via +[ModAssetLibrary deleteFolderNamed:error:].
- (void)gd_deleteModFolderConfirmed:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    for (ModAssetLibraryEntry *entry in entries) {
        [self gd_restoreModEntry:entry];
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

#pragma mark Syslog blacklist

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
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
