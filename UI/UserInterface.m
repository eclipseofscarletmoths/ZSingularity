
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import "ZSScripts.h"
#import "ZSyslogController.h"
#import "ZTweakLog.h"
#import "BankTransplant.h"
#import "ZTranscoderSettings.h"
#import "ZTranscoderService.h"
#import "PatchManifestNetwork.h"
#import "ZTranscoderInstaller.h"

#import "ModAssetLibrary.h"
#import "UnityBundleCAB.h"
#import "LunartiqueModArchive.h"
#import "UnityCacheLocator.h"
#import "ZSFileIndex.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "ZSEmbeddedFont.h"

#pragma mark - Window discovery

static UIWindow *zs_key_window(void) {
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

static UIColor *zs_accent_green_color(void) {
    return [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0];
}

static UIColor *zs_bar_fill_color(void) {
    UIColor *base = zs_accent_green_color();
    CGFloat h = 0, s = 0, b = 0, a = 0;
    [base getHue:&h saturation:&s brightness:&b alpha:&a];
    return [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.15) brightness:MIN(1.0, b * 1.12) alpha:a];
}

#pragma mark - Liquid Glass helpers

static BOOL zs_has_liquid_glass(void) {
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

static UIVisualEffect *zs_make_glass_effect_style(NSInteger style, BOOL interactive, UIColor *tintColor) {
    if (zs_has_liquid_glass()) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (!glassClass) return nil;

        SEL factory = NSSelectorFromString(@"effectWithStyle:");
        id effect = nil;
        if ([glassClass respondsToSelector:factory]) {

            effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, factory, style);
        }
        if (!effect) {

            effect = [[glassClass alloc] init];
        }

        SEL setInteractive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:setInteractive]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, interactive);
        }

        SEL setTint = NSSelectorFromString(@"setTintColor:");
        if ([effect respondsToSelector:setTint]) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, setTint, tintColor);
        }
        return effect;
    }

    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}

static UIVisualEffect *zs_make_glass_effect(BOOL interactive) {
    return zs_make_glass_effect_style(0 , interactive,
                                      [UIColor colorWithWhite:1.0 alpha:0.06]);
}

static void zs_dump_glass_effect_instance_info(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) {
        ZLog(@"[UserInterface] UIGlassEffect class not found");
        return;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(glassClass, &methodCount);
    ZLog(@"[UserInterface] UIGlassEffect instance methods (%u):", methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        ZLog(@"[UserInterface]   - %@", NSStringFromSelector(method_getName(methods[i])));
    }
    free(methods);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(glassClass, &propCount);
    ZLog(@"[UserInterface] UIGlassEffect properties (%u):", propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        ZLog(@"[UserInterface]   @property %s (%s)", property_getName(props[i]), property_getAttributes(props[i]));
    }
    free(props);
}

static UIVisualEffect *zs_make_glass_container_effect(CGFloat spacing) {
    if (!zs_has_liquid_glass()) return nil;
    Class containerClass = NSClassFromString(@"UIGlassContainerEffect");
    if (!containerClass) return nil;

    id effect = [[containerClass alloc] init];
    SEL setSpacing = NSSelectorFromString(@"setSpacing:");
    if ([effect respondsToSelector:setSpacing]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(effect, setSpacing, spacing);
    }
    return effect;
}

static void zs_configure_glass_corners(UIView *view, CGFloat radius, BOOL concentric) {
    if (!view || !zs_has_liquid_glass()) return;

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

static void zs_configure_glass_button_fixed_corner_radius(UIButton *button, CGFloat radius) {
    if (!button) return;

    SEL getConfiguration = NSSelectorFromString(@"configuration");
    if (![button respondsToSelector:getConfiguration]) return;
    id configuration = ((id (*)(id, SEL))objc_msgSend)(button, getConfiguration);
    if (!configuration) return;

    SEL setCornerStyle = NSSelectorFromString(@"setCornerStyle:");
    if ([configuration respondsToSelector:setCornerStyle]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(configuration, setCornerStyle, 1 );
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

static const CGFloat kZSAuthFieldCornerRadius = 3;

static void zs_style_button_as_native_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (@available(iOS 26.0, *)) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        if (configClass && [configClass respondsToSelector:glassSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, glassSel);
            if (configuration) {
                if (font) {
                    SEL setAttributedTitle = NSSelectorFromString(@"setAttributedTitle:");
                    if ([configuration respondsToSelector:setAttributedTitle]) {
                        NSAttributedString *attributedTitle =
                            [[NSAttributedString alloc] initWithString:title
                                                             attributes:@{NSFontAttributeName: font}];
                        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setAttributedTitle, attributedTitle);
                    }
                } else {
                    SEL setTitle = NSSelectorFromString(@"setTitle:");
                    if ([configuration respondsToSelector:setTitle]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setTitle, title);
                    }
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

    [button setTitle:title forState:UIControlStateNormal];
    if (tintColor) [button setTitleColor:tintColor forState:UIControlStateNormal];
    if (font) button.titleLabel.font = font;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;

    button.layer.cornerRadius = 200;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_button_as_native_glass(UIButton *button, NSString *title, UIColor *tintColor) {
    zs_style_button_as_native_glass_with_font(button, title, tintColor, nil);
}

static void zs_style_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
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

    [button setImage:image forState:UIControlStateNormal];
    if (tintColor) button.tintColor = tintColor;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    button.layer.cornerRadius = 9;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_auth_verify_button(UIButton *button, NSString *title) {
    zs_style_button_as_native_glass(button, title, zs_accent_green_color());
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    zs_configure_glass_button_fixed_corner_radius(button, kZSAuthFieldCornerRadius);
    if (!zs_has_liquid_glass()) {
        button.layer.cornerRadius = kZSAuthFieldCornerRadius;
        button.clipsToBounds = YES;
    }

    SEL setUpdateHandler = NSSelectorFromString(@"setConfigurationUpdateHandler:");
    if ([button respondsToSelector:setUpdateHandler]) {
        void (^reassertCorners)(__kindof UIButton *) = ^(__kindof UIButton *btn) {
            zs_configure_glass_button_fixed_corner_radius(btn, kZSAuthFieldCornerRadius);
        };
        ((void (*)(id, SEL, id))objc_msgSend)(button, setUpdateHandler, reassertCorners);
    }
}

static void zs_crossfade_auth_verify_button_title(UIButton *button, NSString *title) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        zs_style_auth_verify_button(button, title);
    }
                     completion:nil];
}

static void zs_style_auth_remove_button(UIButton *button, NSString *title) {
    zs_style_button_as_native_glass(button, title, [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    zs_configure_glass_button_fixed_corner_radius(button, kZSAuthFieldCornerRadius);
    if (!zs_has_liquid_glass()) {
        button.layer.cornerRadius = kZSAuthFieldCornerRadius;
        button.clipsToBounds = YES;
    }

    SEL setUpdateHandler = NSSelectorFromString(@"setConfigurationUpdateHandler:");
    if ([button respondsToSelector:setUpdateHandler]) {
        void (^reassertCorners)(__kindof UIButton *) = ^(__kindof UIButton *btn) {
            zs_configure_glass_button_fixed_corner_radius(btn, kZSAuthFieldCornerRadius);
        };
        ((void (*)(id, SEL, id))objc_msgSend)(button, setUpdateHandler, reassertCorners);
    }
}

static void zs_crossfade_auth_button_to_remove(UIButton *button) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        zs_style_auth_remove_button(button, @"Remove");
    }
                     completion:nil];
}

static void zs_crossfade_auth_button_to_verify(UIButton *button) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        zs_style_auth_verify_button(button, @"Verify");
    }
                     completion:nil];
}

static void zs_remove_pill_hold_to_confirm_gestures(UIButton *button) {
    for (UIGestureRecognizer *recognizer in [button.gestureRecognizers copy]) {
        if ([recognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
            [button removeGestureRecognizer:recognizer];
        }
    }
}

static void * const kZSHoldConfirmBlockKey = (void *)&kZSHoldConfirmBlockKey;

static void * const kZSHoldConfirmExpansionViewKey = (void *)&kZSHoldConfirmExpansionViewKey;
static void * const kZSHoldConfirmExpansionWidthKey = (void *)&kZSHoldConfirmExpansionWidthKey;
static void * const kZSHoldConfirmDeleteLabelKey = (void *)&kZSHoldConfirmDeleteLabelKey;
static void * const kZSHoldConfirmExpansionFillKey = (void *)&kZSHoldConfirmExpansionFillKey;
static void * const kZSHoldConfirmButtonFillKey = (void *)&kZSHoldConfirmButtonFillKey;

static void * const kZSHoldConfirmGlassViewKey = (void *)&kZSHoldConfirmGlassViewKey;
static void * const kZSHoldConfirmGlassHostKey = (void *)&kZSHoldConfirmGlassHostKey;

static const CGFloat kZSDeleteCapsuleExpandedWidth = 60;
static const NSTimeInterval kZSDeleteCapsuleSnapDuration = 0.28;
static const CGFloat kZSDeleteCapsuleSpringDamping = 0.6;
static const CGFloat kZSDeleteCapsuleSpringVelocity = 0.4;

static void zs_attach_delete_capsule(UIButton *button, UIView *parent, UIView *glassHost) {
    if (!parent) return;

    if (zs_has_liquid_glass() && glassHost) {

        UIVisualEffect *effect = zs_make_glass_effect_style(0 , YES,
                                                              [UIColor colorWithRed:1.0 green:0.12 blue:0.12 alpha:0.22]);
        UIVisualEffectView *capsuleGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
        capsuleGlass.userInteractionEnabled = NO;
        capsuleGlass.opaque = NO;
        capsuleGlass.clipsToBounds = YES;
        capsuleGlass.layer.cornerCurve = kCACornerCurveContinuous;
        capsuleGlass.alpha = 0;
        [glassHost addSubview:capsuleGlass];
        zs_configure_glass_corners(capsuleGlass, 9, NO);
        objc_setAssociatedObject(button, kZSHoldConfirmGlassViewKey, capsuleGlass, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(button, kZSHoldConfirmGlassHostKey, glassHost, OBJC_ASSOCIATION_RETAIN);
    }

    UIView *expansion = [[UIView alloc] init];
    expansion.translatesAutoresizingMaskIntoConstraints = NO;
    expansion.clipsToBounds = YES;
    expansion.userInteractionEnabled = NO;
    expansion.layer.cornerCurve = kCACornerCurveContinuous;
    [parent addSubview:expansion];

    [parent bringSubviewToFront:expansion];
    parent.clipsToBounds = NO;

    UILabel *deleteLabel = [[UILabel alloc] init];
    deleteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    deleteLabel.text = @"Delete";
    deleteLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    deleteLabel.textColor = [UIColor whiteColor];
    deleteLabel.alpha = 0;
    [expansion addSubview:deleteLabel];

    CALayer *expansionFill = [CALayer layer];
    expansionFill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
    expansionFill.anchorPoint = CGPointMake(0, 0);
    expansionFill.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    expansionFill.cornerCurve = kCACornerCurveContinuous;
    [expansion.layer insertSublayer:expansionFill atIndex:0];

    CALayer *buttonFill = [CALayer layer];
    buttonFill.backgroundColor = expansionFill.backgroundColor;
    buttonFill.anchorPoint = CGPointMake(0, 0);
    buttonFill.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    buttonFill.cornerCurve = kCACornerCurveContinuous;

    [button.layer insertSublayer:buttonFill atIndex:0];

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

    objc_setAssociatedObject(button, kZSHoldConfirmExpansionViewKey, expansion, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmExpansionWidthKey, widthConstraint, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmDeleteLabelKey, deleteLabel, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmExpansionFillKey, expansionFill, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmButtonFillKey, buttonFill, OBJC_ASSOCIATION_RETAIN);
}

static void zs_attach_hold_to_confirm(UIButton *button, id target, UIView *glassHost, void (^onConfirm)(void)) {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(zs_handleHoldToConfirmGesture:)];
    press.minimumPressDuration = 0;
    press.cancelsTouchesInView = NO;
    [button addGestureRecognizer:press];
    objc_setAssociatedObject(button, kZSHoldConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
    zs_attach_delete_capsule(button, button.superview, glassHost);
}

static void * const kZSPillHoldConfirmBlockKey = (void *)&kZSPillHoldConfirmBlockKey;
static void * const kZSPillHoldConfirmFillLayerKey = (void *)&kZSPillHoldConfirmFillLayerKey;

static void * const kZSPillHoldConfirmDurationKey = (void *)&kZSPillHoldConfirmDurationKey;

static void zs_attach_pill_hold_to_confirm(UIButton *button, id target, void (^onConfirm)(void)) {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(zs_handlePillHoldToConfirmGesture:)];
    press.minimumPressDuration = 0;
    press.cancelsTouchesInView = NO;
    [button addGestureRecognizer:press];
    objc_setAssociatedObject(button, kZSPillHoldConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
}

static void zs_attach_pill_hold_to_confirm_duration(UIButton *button, id target, NSTimeInterval duration, void (^onConfirm)(void)) {
    zs_attach_pill_hold_to_confirm(button, target, onConfirm);
    objc_setAssociatedObject(button, kZSPillHoldConfirmDurationKey, @(duration), OBJC_ASSOCIATION_RETAIN);
}

#pragma mark - Engine scripts

#pragma mark - Capsule slider (Control Center / Now Playing style)

static const CGFloat kCapsuleSliderHeight = 18;
static const CGFloat kCapsuleSliderThinHeight = 6;
static const CGFloat kCapsuleSliderFatHeight = 18;
static const CGFloat kDefaultSnapFraction = 0.035;

@interface ZSFillView : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign, getter=isTrailingSquared) BOOL trailingSquared;
@end

@implementation ZSFillView {
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

- (UIBezierPath *)zs_pathSquaredTrailing:(BOOL)squared {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return [UIBezierPath bezierPath];
    CGFloat r = MIN(self.cornerRadius, bounds.size.height / 2.0);
    UIRectCorner corners = squared ? (UIRectCornerTopLeft | UIRectCornerBottomLeft) : UIRectCornerAllCorners;
    return [UIBezierPath bezierPathWithRoundedRect:bounds byRoundingCorners:corners cornerRadii:CGSizeMake(r, r)];
}

- (void)zs_applyMask {
    UIBezierPath *path = [self zs_pathSquaredTrailing:self.trailingSquared];
    _maskLayer.frame = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _maskLayer.path = path.CGPath;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self zs_applyMask];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    if (_cornerRadius == cornerRadius) return;
    _cornerRadius = cornerRadius;
    [self zs_applyMask];
}

- (void)setTrailingSquared:(BOOL)squared {
    if (_trailingSquared == squared) return;
    _trailingSquared = squared;
    [self zs_applyMask];
}

@end

@interface ZSCapsuleSlider : UIControl
@property (nonatomic, assign) float minimumValue;
@property (nonatomic, assign) float maximumValue;
@property (nonatomic, assign) float value;
@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, assign) float defaultValue;
@property (nonatomic, assign) BOOL hasDefaultValue;
@property (nonatomic, assign) float step;

@property (nonatomic, copy) NSArray<NSNumber *> *indicatorValues;
@end

@interface ZSCapsuleSlider ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) ZSFillView *fill;
@property (nonatomic, strong) UIView *defaultTick;
@property (nonatomic, strong) NSMutableArray<UIView *> *indicatorTicks;
@property (nonatomic, strong) NSLayoutConstraint *fillWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *trackHeightConstraint;
@property (nonatomic, assign) BOOL touching;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;
@property (nonatomic, assign) BOOL glassEnabled;
@property (nonatomic, weak) UIView *glassHost;
@end

@implementation ZSCapsuleSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimumValue = 0;
        _maximumValue = 1;
        _value = 0;
        _fillColor = zs_bar_fill_color();
        _hasDefaultValue = NO;
        _step = 0;
        _indicatorTicks = [NSMutableArray new];

        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        self.track.backgroundColor = UIColor.clearColor;
        self.track.userInteractionEnabled = NO;
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
        self.track.clipsToBounds = YES;
        [self addSubview:self.track];

        self.fill = [[ZSFillView alloc] init];
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

        self.defaultTick = [[UIView alloc] init];
        self.defaultTick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.defaultTick.userInteractionEnabled = NO;
        self.defaultTick.hidden = YES;
        [self addSubview:self.defaultTick];

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

        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);
        self.trackGlass.layer.cornerRadius = h / 2.0;
        self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;

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
    self.value = self.value;
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

static const float kDefaultValueEpsilon = 0.0005f;

- (void)updateFillForCurrentValue {
    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat fraction = range > 0 ? (self.value - self.minimumValue) / range : 0;
    fraction = MAX(0, MIN(1, fraction));
    self.fillWidthConstraint.constant = self.bounds.size.width * fraction;

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

static const CGFloat kDefaultTickWidth = 1;
static const CGFloat kDefaultTickHeight = 4;
static const CGFloat kDefaultTickGap = 3;

- (void)updateDefaultTickPosition {
    if (self.bounds.size.width <= 0) return;

    self.defaultTick.hidden = !self.hasDefaultValue;
    if (self.defaultTick.hidden) return;

    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat fraction = range > 0 ? (self.defaultValue - self.minimumValue) / range : 0;
    fraction = MAX(0, MIN(1, fraction));
    CGFloat x = self.bounds.size.width * fraction - (kDefaultTickWidth / 2.0);
    x = MAX(0, MIN(self.bounds.size.width - kDefaultTickWidth, x));

    CGFloat trackTop = CGRectGetMinY(self.track.frame);
    CGFloat y = trackTop - kDefaultTickGap - kDefaultTickHeight;
    self.defaultTick.frame = CGRectMake(x, y, kDefaultTickWidth, kDefaultTickHeight);
    self.defaultTick.layer.cornerRadius = kDefaultTickWidth / 2.0;
}

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

static const CGFloat kFillAlpha = 1.0;

- (void)setGlassEnabled:(BOOL)glassEnabled {
    UIView *host = self.glassHost;

    if (!zs_has_liquid_glass() || !host) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
        return;
    }

    if (glassEnabled && _glassEnabled && self.trackGlass.superview == host) {
        UIView *overlay = host.superview;
        if (overlay.window) {
            self.trackGlass.frame = [self.track convertRect:self.track.bounds toView:host];
        }
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        if (!self.trackGlass) {
            UIVisualEffect *effect = zs_make_glass_effect(YES);
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

        CGFloat h = self.trackHeightConstraint.constant;
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);

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

@interface ZSModeSlider : UIControl
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) NSInteger defaultIndex;
@property (nonatomic, strong) UIColor *fillColor;
- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated;
@end

@interface ZSModeSlider ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, strong) UIView *defaultIndicator;
@property (nonatomic, strong) NSMutableArray<UILabel *> *segmentLabels;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;
@property (nonatomic, assign) BOOL glassEnabled;
@property (nonatomic, weak) UIView *glassHost;
@end

@implementation ZSModeSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _selectedIndex = 0;
        _defaultIndex = -1;
        _fillColor = zs_bar_fill_color();
        _segmentLabels = [NSMutableArray new];

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

- (void)setGlassEnabled:(BOOL)glassEnabled {
    UIView *host = self.glassHost;

    if (!zs_has_liquid_glass() || !host) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
        return;
    }

    if (glassEnabled && _glassEnabled && self.trackGlass.superview == host) {
        UIView *overlay = host.superview;
        if (overlay.window) {
            self.trackGlass.frame = [self.track convertRect:self.track.bounds toView:host];
        }
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        if (!self.trackGlass) {
            UIVisualEffect *effect = zs_make_glass_effect(YES);
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

        CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);

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

        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);
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

    BOOL hasDefault = self.defaultIndex >= 0 && self.defaultIndex < count;
    self.defaultIndicator.hidden = !hasDefault;
    if (hasDefault) {
        CGFloat length = kDefaultTickHeight * 1.75;
        CGFloat thickness = kDefaultTickWidth;
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

@interface ZSRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) ZSCapsuleSlider *slider;
@property (nonatomic, strong) ZSModeSlider *modeSlider;
@property (nonatomic, strong) UISwitch *toggle;
@end

@implementation ZSRow
@end

@interface ZSMarqueeLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *textColor;

@property (nonatomic, copy) NSString *marqueeKey;
@end

@implementation ZSMarqueeLabel {
    UILabel *_label;
    NSLayoutConstraint *_labelLeadingConstraint;
    BOOL _scrolling;
}

static NSMutableDictionary<NSString *, NSNumber *> *gGDMarqueeCycleStartTimes;
static dispatch_once_t gGDMarqueeRegistryToken;
static CFTimeInterval zs_marquee_cycle_start(NSString *key) {
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
        _label.lineBreakMode = NSLineBreakByClipping;
        [self addSubview:_label];

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
    [_label.layer removeAnimationForKey:@"zsMarqueeScroll"];
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
        [self zs_startScrollingWithOverflow:overflow];
    } else if (overflow <= 4 && _scrolling) {

        _scrolling = NO;
        [_label.layer removeAnimationForKey:@"zsMarqueeScroll"];
        _label.layer.transform = CATransform3DIdentity;
    }
}

- (void)zs_startScrollingWithOverflow:(CGFloat)overflow {
    NSTimeInterval moveDuration = MAX(2.5, overflow / 16.0);
    NSTimeInterval holdDuration = 0.9;
    NSTimeInterval cycle = 2 * (moveDuration + holdDuration);

    NSTimeInterval t1 = holdDuration / cycle;
    NSTimeInterval t2 = (holdDuration + moveDuration) / cycle;
    NSTimeInterval t3 = (2 * holdDuration + moveDuration) / cycle;

    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    anim.keyTimes = @[@0, @(t1), @(t2), @(t3), @1];
    anim.values = @[@0, @0, @(-overflow), @(-overflow), @0];
    CAMediaTimingFunction *linear = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    CAMediaTimingFunction *easeInOut = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    anim.timingFunctions = @[linear, easeInOut, linear, easeInOut];
    anim.duration = cycle;
    anim.repeatCount = HUGE_VALF;
    anim.beginTime = zs_marquee_cycle_start(self.marqueeKey);
    anim.removedOnCompletion = NO;
    [_label.layer addAnimation:anim forKey:@"zsMarqueeScroll"];
}

@end

static const CGFloat kRowHeight = 26;
static const CGFloat kTitleColumnWidth = 92;
static const CGFloat kValueColumnWidth = 34;

static float zs_slider_step_for_range(float minV, float maxV) {
    if (minV >= -1.0f && maxV <= 1.0f) return 0.05f;
    if (maxV > 20.0f) return 5.0f;
    return 0.0f;
}

static ZSRow *zs_make_slider_row(NSString *title, float minV, float maxV, float val, NSString *(^format)(float)) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    float step = zs_slider_step_for_range(minV, maxV);
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
    row.valueLabel.textColor = zs_accent_green_color();
    row.valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    row.valueLabel.textAlignment = NSTextAlignmentRight;
    [row addSubview:row.valueLabel];

    row.slider = [[ZSCapsuleSlider alloc] init];
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

    objc_setAssociatedObject(row.slider, "zs_format", format, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(row.slider, "zs_valueLabel", row.valueLabel, OBJC_ASSOCIATION_RETAIN);

    return row;
}

static ZSRow *zs_make_mode_slider_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.modeSlider = [[ZSModeSlider alloc] init];
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

static ZSRow *zs_make_switch_row(NSString *title, BOOL val) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
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

static ZSRow *zs_make_button_pair_row(NSString *leftTitle, UIColor *leftTint,
                                       NSString *rightTitle, UIColor *rightTint) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *leftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    leftButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass(leftButton, leftTitle, leftTint);
    leftButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [row addSubview:leftButton];
    objc_setAssociatedObject(row, "zs_button_left", leftButton, OBJC_ASSOCIATION_RETAIN);

    UIButton *rightButton = [UIButton buttonWithType:UIButtonTypeSystem];
    rightButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass(rightButton, rightTitle, rightTint);
    rightButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [row addSubview:rightButton];
    objc_setAssociatedObject(row, "zs_button_right", rightButton, OBJC_ASSOCIATION_RETAIN);

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

static ZSRow *zs_make_single_button_row(NSString *title, UIColor *tint) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass(button, title, tint);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [row addSubview:button];
    objc_setAssociatedObject(row, "zs_button", button, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
        [button.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],
    ]];

    return row;
}

static UIVisualEffectView *zs_wrap_field_in_native_glass(UITextField *field, CGFloat cornerRadius) {
    field.borderStyle = UITextBorderStyleNone;
    UIView *leftPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    field.leftView = leftPadding;
    field.leftViewMode = UITextFieldViewModeAlways;

    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, cornerRadius, NO);

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

static NSArray<NSString *> *zs_reencode_format_options(void) {
    return @[@"ASTC_RGBA_4x4", @"ASTC_RGBA_6x6", @"ASTC_RGBA_8x8", @"RGBA32", @"ETC2"];
}

static NSString * const kZSDefaultReencodeFormat = @"RGBA32";

static const CGFloat kZSReencodeFieldWidth = 116;
static const CGFloat kZSReencodeFieldHeight = 28;

static const CGFloat kZSReencodeHorizontalPadding = 10;

static const CGFloat kZSReencodeChevronReserve = 20;

static NSString *zs_reencode_format_display_name(NSString *format) {
    if ([format isEqualToString:@"ASTC_RGBA_4x4"]) return @"ASTC 4x4";
    if ([format isEqualToString:@"ASTC_RGBA_6x6"]) return @"ASTC 6x6";
    if ([format isEqualToString:@"ASTC_RGBA_8x8"]) return @"ASTC 8x8";
    if ([format isEqualToString:@"RGBA32"]) return @"RGBA32";
    if ([format isEqualToString:@"ETC2"]) return @"ETC2";
    return format ?: @"RGBA32";
}

static UIImage *zs_make_dropdown_chevron_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:symbolConfig];
    chevronImage = [chevronImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    return chevronImage;
}

static UIImageView *zs_reencode_chevron_view(UIButton *button) {
    static const void *kChevronKey = &kChevronKey;
    UIImageView *chevron = objc_getAssociatedObject(button, kChevronKey);
    if (!chevron) {
        chevron = [[UIImageView alloc] initWithImage:zs_make_dropdown_chevron_image()];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.contentMode = UIViewContentModeCenter;

        chevron.userInteractionEnabled = NO;
        [button addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[

            [chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor
                                                    constant:-kZSReencodeHorizontalPadding],
            [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        ]];
        objc_setAssociatedObject(button, kChevronKey, chevron, OBJC_ASSOCIATION_RETAIN);
    }
    return chevron;
}

static void zs_style_reencode_format_button(UIButton *button, NSString *format) {

    zs_style_button_as_native_glass(button, zs_reencode_format_display_name(format), UIColor.whiteColor);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;

    SEL getConfiguration = NSSelectorFromString(@"configuration");
    if ([button respondsToSelector:getConfiguration]) {
        id configuration = ((id (*)(id, SEL))objc_msgSend)(button, getConfiguration);
        if (configuration) {

            SEL setContentInsets = NSSelectorFromString(@"setContentInsets:");
            if ([configuration respondsToSelector:setContentInsets]) {
                NSDirectionalEdgeInsets insets = NSDirectionalEdgeInsetsMake(
                    6, kZSReencodeHorizontalPadding,
                    6, kZSReencodeHorizontalPadding + kZSReencodeChevronReserve);
                ((void (*)(id, SEL, NSDirectionalEdgeInsets))objc_msgSend)(configuration, setContentInsets, insets);
            }
            SEL setConfig = NSSelectorFromString(@"setConfiguration:");
            if ([button respondsToSelector:setConfig]) {
                ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
            }
        }
    }

    zs_configure_glass_button_fixed_corner_radius(button, kZSAuthFieldCornerRadius);
    if (!zs_has_liquid_glass()) {
        button.layer.cornerRadius = kZSAuthFieldCornerRadius;
        button.clipsToBounds = YES;
    }

    [button bringSubviewToFront:zs_reencode_chevron_view(button)];
}

static UIButton *zs_make_reencode_dropdown_option_button(NSString *format, BOOL selected, NSInteger tag, id target, SEL action) {
    UIButton *option = [UIButton buttonWithType:UIButtonTypeSystem];
    option.tag = tag;
    option.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    option.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    option.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    [option setTitle:zs_reencode_format_display_name(format) forState:UIControlStateNormal];
    [option setTitleColor:(selected ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.6])
                  forState:UIControlStateNormal];
    option.backgroundColor = UIColor.clearColor;

    [option addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return option;
}

static ZSRow *zs_make_reencode_format_row(NSString *selectedFormat, id target, SEL tapAction) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
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

    [button addTarget:target action:tapAction forControlEvents:UIControlEventTouchDown];
    [row addSubview:button];
    objc_setAssociatedObject(row, "zs_button", button, OBJC_ASSOCIATION_RETAIN);

    zs_style_reencode_format_button(button, selectedFormat);

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.leadingAnchor constant:-6],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.widthAnchor constraintEqualToConstant:kZSReencodeFieldWidth],
        [button.heightAnchor constraintEqualToConstant:kZSReencodeFieldHeight],
        [button.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:3],
    ]];

    return row;
}

static ZSRow *zs_make_button_and_glass_field_row(NSString *buttonTitle, UIColor *buttonTint, NSString *placeholder) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass(button, buttonTitle, buttonTint);
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    [row addSubview:button];
    objc_setAssociatedObject(row, "zs_button", button, OBJC_ASSOCIATION_RETAIN);

    UITextField *field = [[UITextField alloc] init];
    field.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    field.textColor = UIColor.whiteColor;
    field.tintColor = zs_accent_green_color();
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    objc_setAssociatedObject(row, "zs_textfield", field, OBJC_ASSOCIATION_RETAIN);

    UIVisualEffectView *fieldGlass = zs_wrap_field_in_native_glass(field, 6);
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

        [button.widthAnchor constraintEqualToAnchor:fieldContainer.widthAnchor multiplier:0.5],
    ]];

    return row;
}

static BOOL zs_parse_github_repo_link(NSString *raw, NSString **outOwner, NSString **outName) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return NO;

    if ([s hasPrefix:@"git@github.com:"]) {
        s = [s substringFromIndex:@"git@github.com:".length];
    } else {

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

static NSString *zs_format_github_repo_link(NSString *owner, NSString *name) {
    if (owner.length == 0 || name.length == 0) return @"";
    return [NSString stringWithFormat:@"%@/%@", owner, name];
}

static NSString *zs_sanitize_personal_access_token(NSString *raw) {
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

static ZSRow *zs_make_labeled_glass_field_row(NSString *placeholder, BOOL secure, UIButton *trailingButton) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UITextField *field = [[UITextField alloc] init];
    field.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    field.textColor = UIColor.whiteColor;
    field.tintColor = zs_accent_green_color();
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    field.secureTextEntry = secure;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    objc_setAssociatedObject(row, "zs_textfield", field, OBJC_ASSOCIATION_RETAIN);

    UIVisualEffectView *fieldGlass = zs_wrap_field_in_native_glass(field, 6);
    UIView *fieldContainer = fieldGlass ?: field;
    fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fieldContainer];

    objc_setAssociatedObject(row, "zs_fieldContainer", fieldContainer, OBJC_ASSOCIATION_RETAIN);

    NSMutableArray<NSLayoutConstraint *> *fieldConstraints = [NSMutableArray arrayWithArray:@[
        [fieldContainer.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [fieldContainer.topAnchor constraintEqualToAnchor:row.topAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:28],
        [row.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],
    ]];

    if (trailingButton) {
        trailingButton.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:trailingButton];

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

    [NSLayoutConstraint activateConstraints:[fieldConstraints copy]];

    return row;
}

static UIView *zs_make_blacklist_entry_row(NSString *term, id target, SEL removeAction) {
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

    UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:6 weight:UIImageSymbolWeightSemibold];
    UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
    zs_style_icon_button_as_native_glass(removeButton, xImage, [UIColor colorWithWhite:1 alpha:0.55]);
    [removeButton addTarget:target action:removeAction forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(removeButton, "zs_blacklistTerm", term, OBJC_ASSOCIATION_RETAIN);
    [row addSubview:removeButton];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:4],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:removeButton.leadingAnchor constant:-6],

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

static const CGFloat kZSModsOptionsButtonWidth = 30;
static const CGFloat kZSModsOptionsButtonHeight = 18;

static NSString * const kZSProcessedBundlesFolderName = @"Processed Bundles";
static NSString * const kZSProcessedBundlesFolderSubtext = @"download bundles stored in the proxy\u2019s release tab";

static NSString * const kZSStoredBundlesFolderName = @"Stored Bundles";
static NSString * const kZSStoredBundlesFolderSubtext = @"Your stored bundles are here, you can restore them any time.";

static UIView *zs_make_mods_folder_row(NSString *folderName, NSString *remark, BOOL expanded, id target, SEL tapAction, SEL optionsAction) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "zs_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);

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

    BOOL hasRemark = (remark.length > 0);
    ZSMarqueeLabel *remarkLabel = nil;
    if (hasRemark) {
        remarkLabel = [[ZSMarqueeLabel alloc] init];
        remarkLabel.text = remark;
        remarkLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
        remarkLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];

        remarkLabel.marqueeKey = [folderName stringByAppendingString:@"|remark"];
        [row addSubview:remarkLabel];
    }

    UIButton *optionsButton = nil;
    if (optionsAction) {
        optionsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        optionsButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *dotsSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
        UIImage *dotsImage = [UIImage systemImageNamed:@"ellipsis" withConfiguration:dotsSymbolConfig];
        zs_style_icon_button_as_native_glass(optionsButton, dotsImage, [UIColor colorWithWhite:1 alpha:0.6]);
        objc_setAssociatedObject(optionsButton, "zs_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
        [optionsButton addTarget:target action:optionsAction forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:optionsButton];
        objc_setAssociatedObject(row, "zs_button_options", optionsButton, OBJC_ASSOCIATION_RETAIN);
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:tapAction];
    [row addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [chevron.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:2],
        [chevron.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:14],

        [folderIcon.leadingAnchor constraintEqualToAnchor:chevron.trailingAnchor constant:4],
        [folderIcon.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [folderIcon.widthAnchor constraintEqualToConstant:18],

        [label.leadingAnchor constraintEqualToAnchor:folderIcon.trailingAnchor constant:6],
    ]];

    UIView *labelTrailingNeighbor = optionsButton ?: row;
    [NSLayoutConstraint activateConstraints:@[
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
    ]];
    if (optionsButton) {
        [NSLayoutConstraint activateConstraints:@[
            [optionsButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [optionsButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [optionsButton.widthAnchor constraintEqualToConstant:kZSModsOptionsButtonWidth],
            [optionsButton.heightAnchor constraintEqualToConstant:kZSModsOptionsButtonHeight],
        ]];
    }

    if (hasRemark) {
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:6],

            [remarkLabel.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
            [remarkLabel.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:2],

            [remarkLabel.trailingAnchor constraintEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
            [row.bottomAnchor constraintEqualToAnchor:remarkLabel.bottomAnchor constant:6],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-5],
            [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:5],
        ]];
    }
    return row;
}

static const CGFloat kZSModsDoctorCapsuleHeight = 18;
static const CGFloat kZSModsDoctorCapsuleMinWidth = 54;

static const CGFloat kZSModsDoctorCapsuleFontSize = 9 * 0.6;

#pragma mark - Mods Library file options menu (3.4)

static const CGFloat kZSModsOptionsDropdownWidth = 190;
static const CGFloat kZSModsOptionsRowHeight = kZSReencodeFieldHeight;

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_file_options(void) {
    return @[
        @{@"title": @"Cache bundle", @"symbol": @"archivebox",   @"destructive": @NO},
        @{@"title": @"Add remark",   @"symbol": @"quote.bubble", @"destructive": @NO},
        @{@"title": @"Delete",       @"symbol": @"trash",        @"destructive": @YES},
    ];
}

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_stored_bundle_file_options(void) {
    return @[
        @{@"title": @"Restore", @"symbol": @"arrow.uturn.backward", @"destructive": @NO},
        @{@"title": @"Delete",  @"symbol": @"trash",                @"destructive": @YES},
    ];
}

static UIButton *zs_make_mods_options_row_button(NSDictionary<NSString *, id> *option, NSInteger tag, id target, SEL action) {
    BOOL destructive = [option[@"destructive"] boolValue];
    UIColor *tint = destructive ? [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]
                                : [UIColor colorWithWhite:1 alpha:0.85];

    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    row.tag = tag;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    row.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 24);
    row.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    [row setTitle:option[@"title"] forState:UIControlStateNormal];
    [row setTitleColor:tint forState:UIControlStateNormal];
    row.backgroundColor = UIColor.clearColor;
    [row addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    UIImage *symbolImage = [UIImage systemImageNamed:option[@"symbol"] withConfiguration:symConfig];
    symbolImage = [symbolImage imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImageView *symbolView = [[UIImageView alloc] initWithImage:symbolImage];
    symbolView.translatesAutoresizingMaskIntoConstraints = NO;
    symbolView.contentMode = UIViewContentModeCenter;
    symbolView.userInteractionEnabled = NO;
    [row addSubview:symbolView];
    [NSLayoutConstraint activateConstraints:@[
        [symbolView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [symbolView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [symbolView.widthAnchor constraintEqualToConstant:16],
    ]];

    return row;
}

#pragma mark - Mods Library folder options menu (3.4.5)

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_folder_options(void) {
    return @[
        @{@"title": @"Add mod",      @"symbol": @"plus",         @"destructive": @NO},
        @{@"title": @"Rename",       @"symbol": @"pencil",       @"destructive": @NO},
        @{@"title": @"Cache folder", @"symbol": @"archivebox",   @"destructive": @NO},
        @{@"title": @"Add remark",   @"symbol": @"quote.bubble", @"destructive": @NO},
        @{@"title": @"Delete",       @"symbol": @"trash",        @"destructive": @YES},
    ];
}

static UIView *zs_make_mods_entry_row(ModAssetLibraryEntry *entry, id target, SEL tapAction,
                                       SEL dispatchAction, SEL downloadAction, SEL retryAction, SEL optionsAction, BOOL showActions,
                                       BOOL downloadInFlight, BOOL isStoredBundlesFolder) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);

    BOOL isDoctorEligible = entry.isAssetBundle && !isStoredBundlesFolder;
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

    UIButton *optionsButton = nil;
    if (showActions) {
        optionsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        optionsButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *dotsSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
        UIImage *dotsImage = [UIImage systemImageNamed:@"ellipsis" withConfiguration:dotsSymbolConfig];
        zs_style_icon_button_as_native_glass(optionsButton, dotsImage, [UIColor colorWithWhite:1 alpha:0.6]);
        objc_setAssociatedObject(optionsButton, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
        [optionsButton addTarget:target action:optionsAction forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:optionsButton];
        objc_setAssociatedObject(row, "zs_button_options", optionsButton, OBJC_ASSOCIATION_RETAIN);
    }

    UIView *doctorView = nil;
    UIButton *doctorButton = nil;
    if (isDoctorEligible) {
        switch (entry.doctorStatus) {
            case ModAssetLibraryDoctorStatusNotDispatched: {

                if (downloadInFlight) {
                    UILabel *progressLabel = [[UILabel alloc] init];
                    progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
                    progressLabel.text = @"installing…";
                    progressLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
                    progressLabel.textColor = zs_accent_green_color();
                    progressLabel.textAlignment = NSTextAlignmentRight;
                    objc_setAssociatedObject(row, "zs_label_doctorProgress", progressLabel, OBJC_ASSOCIATION_RETAIN);
                    doctorView = progressLabel;
                    break;
                }
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                zs_style_button_as_native_glass_with_font(doctorButton, @"dispatch", zs_accent_green_color(),
                    [UIFont systemFontOfSize:kZSModsDoctorCapsuleFontSize weight:UIFontWeightSemibold]);
                [doctorButton addTarget:target action:dispatchAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "zs_button_dispatch", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
            case ModAssetLibraryDoctorStatusUploading: {

                break;
            }
            case ModAssetLibraryDoctorStatusProcessing: {

                break;
            }
            case ModAssetLibraryDoctorStatusReadyToDownload: {

                if (downloadInFlight) {
                    break;
                }
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                zs_style_button_as_native_glass_with_font(doctorButton, @"download", zs_accent_green_color(),
                    [UIFont systemFontOfSize:kZSModsDoctorCapsuleFontSize weight:UIFontWeightSemibold]);
                [doctorButton addTarget:target action:downloadAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "zs_button_download", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
            case ModAssetLibraryDoctorStatusInstalled: {

                break;
            }
            case ModAssetLibraryDoctorStatusFailed: {
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                UIColor *failTint = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
                zs_style_button_as_native_glass_with_font(doctorButton, @"retry", failTint,
                    [UIFont systemFontOfSize:kZSModsDoctorCapsuleFontSize weight:UIFontWeightSemibold]);
                [doctorButton addTarget:target action:retryAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "zs_button_retry", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
        }
        if (doctorView) {
            objc_setAssociatedObject(doctorView, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
            [row addSubview:doctorView];
            objc_setAssociatedObject(row, "zs_view_doctor", doctorView, OBJC_ASSOCIATION_RETAIN);
        }
    }

    UIView *labelTrailingNeighbor = doctorView ?: (optionsButton ?: row);
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:22],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:5],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:3],
    ]];

    if (optionsButton) {
        [NSLayoutConstraint activateConstraints:@[
            [optionsButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [optionsButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [optionsButton.widthAnchor constraintEqualToConstant:kZSModsOptionsButtonWidth],
            [optionsButton.heightAnchor constraintEqualToConstant:kZSModsOptionsButtonHeight],
        ]];
        if (doctorView) {
            [NSLayoutConstraint activateConstraints:@[
                [doctorView.trailingAnchor constraintEqualToAnchor:optionsButton.leadingAnchor constant:-3],
            ]];
        }
    } else if (doctorView) {

        [NSLayoutConstraint activateConstraints:@[
            [doctorView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        ]];
    }

    if (doctorView) {
        [NSLayoutConstraint activateConstraints:@[
            [doctorView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [doctorView.widthAnchor constraintGreaterThanOrEqualToConstant:kZSModsDoctorCapsuleMinWidth],
        ]];
        if (doctorButton) {
            [doctorView.heightAnchor constraintEqualToConstant:kZSModsDoctorCapsuleHeight].active = YES;
        }
    }

    return row;
}

static NSString *zs_truncated_cab_identifier_for_display(NSString *cabIdentifier) {
    static const NSUInteger kMaxDisplayedCABLength = 16;
    if (cabIdentifier.length <= kMaxDisplayedCABLength) return cabIdentifier;
    return [[cabIdentifier substringToIndex:kMaxDisplayedCABLength] stringByAppendingString:@"\u2026"];
}

static UIView *zs_make_marquee_info_row(NSString *labelText, NSString *value, NSString *marqueeKey, UIFont *font, UIColor *color) {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentFill;
    row.spacing = 4;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *staticLabel = [[UILabel alloc] init];
    staticLabel.text = labelText;
    staticLabel.font = font;
    staticLabel.textColor = color;
    [staticLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [staticLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    ZSMarqueeLabel *valueLabel = [[ZSMarqueeLabel alloc] init];
    valueLabel.text = value;
    valueLabel.font = font;
    valueLabel.textColor = color;

    valueLabel.marqueeKey = marqueeKey;
    [valueLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    [row addArrangedSubview:staticLabel];
    [row addArrangedSubview:valueLabel];
    return row;
}

static UIView *zs_make_mods_entry_info_panel(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(container, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    UIStackView *panel = [[UIStackView alloc] init];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 2;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layoutMarginsRelativeArrangement = YES;
    panel.layoutMargins = UIEdgeInsetsMake(2, 38, 2, 4);
    [container addSubview:panel];

    UIFont *subtextFont = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    UIColor *subtextColor = [UIColor colorWithWhite:1 alpha:0.4];

    if (entry.remark.length > 0) {
        ZSMarqueeLabel *remarkLabel = [[ZSMarqueeLabel alloc] init];
        remarkLabel.text = entry.remark;
        remarkLabel.font = subtextFont;
        remarkLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        remarkLabel.marqueeKey = [entry.path stringByAppendingString:@"|remark"];
        [panel addArrangedSubview:remarkLabel];
    }

    if (!isStoredBundlesFolder) {

        NSString *displayedPath = entry.livePathDescription ?: entry.resolvedInstallTargetPath ?: entry.path;
        UIView *pathRow = zs_make_marquee_info_row(@"Filepath:", displayedPath,
                                                    [entry.path stringByAppendingString:@"|path"],
                                                    subtextFont, subtextColor);
        [panel addArrangedSubview:pathRow];
    }

    if (entry.isAssetBundle) {
        if (entry.cabIdentifier.length > 0) {

            UIView *identifierRow = zs_make_marquee_info_row(@"Identifier:", zs_truncated_cab_identifier_for_display(entry.cabIdentifier),
                                                               [entry.path stringByAppendingString:@"|cab"],
                                                               subtextFont, subtextColor);
            [panel addArrangedSubview:identifierRow];
        }

        if (entry.targetPlatform) {
            int32_t platform = entry.targetPlatform.intValue;
            UILabel *platformLabel = [[UILabel alloc] init];
            platformLabel.text = [NSString stringWithFormat:@"Target Platform: %@(%d)", [UnityBundleCAB nameForTargetPlatform:platform], platform];
            platformLabel.font = subtextFont;
            platformLabel.textColor = subtextColor;
            [panel addArrangedSubview:platformLabel];
        }

        NSString *statusText;
        if (isStoredBundlesFolder) {
            statusText = @"Stored";
        } else
        switch (entry.doctorStatus) {
            case ModAssetLibraryDoctorStatusUploading: {
                unsigned long long bytesSent = (unsigned long long)MAX((int64_t)0, entry.doctorUploadProgress);
                statusText = [NSString stringWithFormat:@"%llu Bytes Uploaded", bytesSent];
                break;
            }
            case ModAssetLibraryDoctorStatusProcessing: {
                NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, entry.doctorProcessProgress)) * 100.0);
                statusText = [NSString stringWithFormat:@"%ld%% Processed", (long)percent];
                break;
            }
            case ModAssetLibraryDoctorStatusReadyToDownload:
                if (downloadInFlight) {

                    unsigned long long bytesWritten = (unsigned long long)MAX((int64_t)0, entry.doctorDownloadProgress);
                    statusText = [NSString stringWithFormat:@"%llu Bytes Downloaded", bytesWritten];
                } else {
                    statusText = @"Not installed";
                }
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
    [panel addArrangedSubview:sizeLabel];

    UILabel *dateLabel = [[UILabel alloc] init];
    dateLabel.text = [NSString stringWithFormat:@"Date Added: %@", entry.dateAdded.length ? entry.dateAdded : @"unknown"];
    dateLabel.font = subtextFont;
    dateLabel.textColor = subtextColor;
    [panel addArrangedSubview:dateLabel];

    if (entry.doctorStatus == ModAssetLibraryDoctorStatusFailed && entry.doctorLastError.length) {
        ZSMarqueeLabel *errorLabel = [[ZSMarqueeLabel alloc] init];
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

#pragma mark - Mods Library "Processed Bundles" rows (6)

static UIView *zs_make_processed_bundle_row(ZTranscoderProcessedRelease *release, id target, SEL tapAction) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "zs_processedRelease", release, OBJC_ASSOCIATION_RETAIN);

    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"shippingbox.fill" withConfiguration:iconConfig]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    icon.contentMode = UIViewContentModeCenter;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = release.displayName;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:tapAction];
    [row addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:22],
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

static UIView *zs_make_processed_bundle_info_panel(ZTranscoderProcessedRelease *release, BOOL installInFlight, id target, SEL installAction) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(container, "zs_processedRelease", release, OBJC_ASSOCIATION_RETAIN);

    UIStackView *panel = [[UIStackView alloc] init];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 2;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layoutMarginsRelativeArrangement = YES;
    panel.layoutMargins = UIEdgeInsetsMake(2, 38, 2, 4);
    [container addSubview:panel];

    UIFont *subtextFont = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    UIColor *subtextColor = [UIColor colorWithWhite:1 alpha:0.4];

    UILabel *sizeLabel = [[UILabel alloc] init];
    sizeLabel.text = [NSString stringWithFormat:@"Size: %@", [NSByteCountFormatter stringFromByteCount:(long long)release.byteSize countStyle:NSByteCountFormatterCountStyleFile]];
    sizeLabel.font = subtextFont;
    sizeLabel.textColor = subtextColor;
    [panel addArrangedSubview:sizeLabel];

    UILabel *dateLabel = [[UILabel alloc] init];
    dateLabel.text = [NSString stringWithFormat:@"Upload date: %@", release.uploadedAt.length ? release.uploadedAt : @"unknown"];
    dateLabel.font = subtextFont;
    dateLabel.textColor = subtextColor;
    [panel addArrangedSubview:dateLabel];

    if (release.checksum.length > 0) {
        UIView *checksumRow = zs_make_marquee_info_row(@"Checksum:", release.checksum,
                                                         [release.tagName stringByAppendingString:@"|checksum"],
                                                         subtextFont, subtextColor);
        [panel addArrangedSubview:checksumRow];
    }

    UIView *installRow = [[UIView alloc] init];
    installRow.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    installButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass_with_font(installButton, installInFlight ? @"installing\u2026" : @"install",
        zs_accent_green_color(), [UIFont systemFontOfSize:kZSModsDoctorCapsuleFontSize weight:UIFontWeightSemibold]);
    installButton.enabled = !installInFlight;
    objc_setAssociatedObject(installButton, "zs_processedRelease", release, OBJC_ASSOCIATION_RETAIN);
    [installButton addTarget:target action:installAction forControlEvents:UIControlEventTouchUpInside];
    [installRow addSubview:installButton];
    [NSLayoutConstraint activateConstraints:@[
        [installButton.leadingAnchor constraintEqualToAnchor:installRow.leadingAnchor],
        [installButton.topAnchor constraintEqualToAnchor:installRow.topAnchor constant:2],
        [installButton.bottomAnchor constraintEqualToAnchor:installRow.bottomAnchor],
        [installButton.widthAnchor constraintGreaterThanOrEqualToConstant:kZSModsDoctorCapsuleMinWidth],
        [installButton.heightAnchor constraintEqualToConstant:kZSModsDoctorCapsuleHeight],
    ]];
    [panel addArrangedSubview:installRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

static UILabel *zs_make_section_header(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [text uppercaseString];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    return label;
}

#pragma mark - Panel title block

static void zs_register_embedded_fonts(void) {
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
            ZLog(@"[UserInterface] Failed to parse embedded Excelsior Sans data");
            return;
        }

        CFErrorRef error = NULL;
        BOOL registered = CTFontManagerRegisterGraphicsFont(cgFont, &error);
        CGFontRelease(cgFont);

        if (!registered) {

            NSError *nsError = (__bridge NSError *)error;
            ZLog(@"[UserInterface] Excelsior Sans registration result: %@", nsError.localizedDescription ?: @"(already registered)");
        }
        if (error) CFRelease(error);
    });
}

static UIFont *zs_excelsior_sans_font(CGFloat size, UIFontWeight weight) {
    zs_register_embedded_fonts();

    UIFont *regular = [UIFont fontWithName:@"EXCELSIORSANS" size:size];
    if (!regular) {
        ZLog(@"[UserInterface] Excelsior Sans did not resolve after registration - falling back to system font");
        return [UIFont systemFontOfSize:size weight:weight];
    }
    if (weight < UIFontWeightSemibold) return regular;

    UIFontDescriptor *boldDescriptor =
        [regular.fontDescriptor fontDescriptorWithSymbolicTraits:regular.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold];
    return boldDescriptor ? [UIFont fontWithDescriptor:boldDescriptor size:size] : regular;
}

#ifndef ZS_BUILD_NUMBER
#define ZS_BUILD_NUMBER 0
#endif

static NSString *zs_version_string(void) {
    if (ZS_BUILD_NUMBER == 0) {
        return @"v0.0.1 (local build)";
    }
    return [NSString stringWithFormat:@"v0.0.1 build %d", ZS_BUILD_NUMBER];
}

static const CGFloat kZSSubtitleFontSize = 10;

static UIView *zs_make_title_block(void) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.textAlignment = NSTextAlignmentNatural;

    NSString *fullTitle = @"ZSingularity";
    NSString *emphasized = @"ZS";

    UIFont *bigFont = zs_excelsior_sans_font(45, UIFontWeightBold);
    UIFont *restFont = zs_excelsior_sans_font(33.75, UIFontWeightBold);
    UIColor *titleColor = zs_accent_green_color();

    NSMutableAttributedString *titleString =
        [[NSMutableAttributedString alloc] initWithString:fullTitle
                                                 attributes:@{
            NSFontAttributeName: restFont,
            NSForegroundColorAttributeName: titleColor,
        }];
    [titleString addAttribute:NSFontAttributeName
                         value:bigFont
                         range:NSMakeRange(0, emphasized.length)];

    NSString *versionTag = [@" " stringByAppendingString:zs_version_string()];
    UIFont *versionFont = zs_excelsior_sans_font(kZSSubtitleFontSize, UIFontWeightMedium);
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
    subtitleLabel.font = [UIFont systemFontOfSize:kZSSubtitleFontSize weight:UIFontWeightMedium];
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

@interface UserInterface : NSObject <UIGestureRecognizerDelegate, UIScrollViewDelegate, UITextFieldDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIVisualEffectView *glassContainer;
@property (nonatomic, strong) UIVisualEffectView *panelGlass;
@property (nonatomic, strong) UIVisualEffectView *handleGlass;
@property (nonatomic, strong) UIVisualEffectView *sliderGlassContainer;
@property (nonatomic, strong) UIView *sliderGlassContent;
@property (nonatomic, strong) UIView *contentOverlay;
@property (nonatomic, strong) UIView *glassContainerContent;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, strong) UILabel *chevron;
@property (nonatomic, strong) UIView *scrollViewport;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) CGFloat panelWidth;
@property (nonatomic, strong) NSTimer *postFXReapplyTimer;
@property (nonatomic, strong) NSTimer *saveDebounceTimer;
@property (nonatomic, strong) UIVisualEffectView *syslogHandleGlass;
@property (nonatomic, strong) UIView *syslogHandle;
@property (nonatomic, strong) UILabel *syslogHandleLabel;
@property (nonatomic, strong) UIScrollView *syslogOverlay;
@property (nonatomic, strong) UILabel *syslogTextLabel;
@property (nonatomic, assign) BOOL syslogTabEnabled;
@property (nonatomic, assign) BOOL syslogVisible;
@property (nonatomic, strong) NSMutableArray<NSString *> *syslogLines;
@property (nonatomic, strong) UITextField *syslogBlacklistField;
@property (nonatomic, strong) UILabel *syslogBlacklistStatusLabel;
@property (nonatomic, strong) UIStackView *syslogBlacklistEntriesStack;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *syslogBlacklist;
@property (nonatomic, assign) CGFloat syslogHandleHeight;

@property (nonatomic, strong) UITextField *authRepoLinkField;
@property (nonatomic, strong) UITextField *authTokenField;

@property (nonatomic, strong) UIView *authRepoLinkFieldContainer;
@property (nonatomic, strong) UIView *authTokenFieldContainer;
@property (nonatomic, strong) UIButton *authVerifyButton;

@property (nonatomic, strong) UILabel *authStatusLabel;

@property (nonatomic, assign) BOOL authInRemoveMode;

@property (nonatomic, assign) BOOL authCredentialsStale;

@property (nonatomic, strong) UIButton *reencodeFormatButton;
@property (nonatomic, strong) UIView *reencodeDropdownOverlay;
@property (nonatomic, strong) UIControl *reencodeDropdownScrim;
@property (nonatomic, assign) BOOL reencodeDropdownOpen;

@property (nonatomic, weak) UIButton *modsOptionsDropdownButton;
@property (nonatomic, strong) UIView *modsOptionsDropdownOverlay;
@property (nonatomic, strong) UIControl *modsOptionsDropdownScrim;
@property (nonatomic, assign) BOOL modsOptionsDropdownOpen;
@property (nonatomic, strong) ModAssetLibraryEntry *modsOptionsDropdownEntry;
@property (nonatomic, copy) NSString *modsOptionsDropdownFolderName;

@property (nonatomic, weak) UIDocumentPickerViewController *loadModsPicker;
@property (nonatomic, copy) NSString *loadModsTargetFolder;

@property (nonatomic, strong) NSMutableArray<NSString *> *loadModsSummaryLines;

@property (nonatomic, strong) UIStackView *modsLibraryStack;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedFolders;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedInfoEntries;

@property (nonatomic, weak) UIDocumentPickerViewController *libraryImportPicker;
@property (nonatomic, copy) NSString *libraryImportTargetFolder;

@property (nonatomic, strong) NSArray<ZTranscoderProcessedRelease *> *processedBundlesReleases;
@property (nonatomic, assign) BOOL processedBundlesLoading;
@property (nonatomic, copy) NSString *processedBundlesErrorMessage;

@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedProcessedBundles;

@property (nonatomic, strong) NSMutableSet<NSString *> *processedBundleInstallInFlight;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTimer *> *doctorPollTimers;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorUploadProgressLastBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorProcessProgressLastPercent;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorDownloadProgressLastBytes;

@property (nonatomic, strong) NSMutableSet<NSString *> *doctorDownloadInFlightPaths;

@property (nonatomic, weak) UIDocumentPickerViewController *doctorInstallTargetPicker;
@property (nonatomic, copy) NSURL *doctorInstallPendingDoctoredURL;
@property (nonatomic, copy) NSString *doctorInstallPendingEntryPath;
@property (nonatomic, copy) NSString *doctorInstallPendingFolderName;

@property (nonatomic, assign) BOOL doctorStateRecoveredThisLaunch;

@property (nonatomic, weak) UIButton *holdConfirmActiveButton;
@property (nonatomic, assign) NSTimeInterval holdConfirmStartTime;
@property (nonatomic, assign) BOOL holdConfirmTriggered;
@property (nonatomic, strong) CADisplayLink *holdConfirmDisplayLink;

@property (nonatomic, assign) CGRect zs_lastKeyboardFrame;

@property (nonatomic, strong) UIView *zsFloatingFieldBackdrop;
@property (nonatomic, strong) UIView *zsFloatingFieldContainer;
@property (nonatomic, strong) UITextField *zsFloatingField;
@property (nonatomic, weak) NSLayoutConstraint *zsFloatingFieldBottomConstraint;
@property (nonatomic, copy) void (^zsFloatingFieldCompletion)(NSString * _Nullable trimmedText);

@property (nonatomic, weak) UIButton *pillHoldConfirmActiveButton;
@property (nonatomic, assign) NSTimeInterval pillHoldConfirmStartTime;
@property (nonatomic, assign) BOOL pillHoldConfirmTriggered;
@property (nonatomic, strong) CADisplayLink *pillHoldConfirmDisplayLink;

@property (nonatomic, strong) UIButton *syslogButton;
@property (nonatomic, assign) BOOL syslogVerboseEnabled;
@property (nonatomic, strong) CALayer *syslogButtonFillLayer;
@property (nonatomic, strong) CADisplayLink *syslogHoldDisplayLink;
@property (nonatomic, assign) NSTimeInterval syslogHoldStartTime;
@property (nonatomic, assign) BOOL syslogHoldTriggered;

@property (nonatomic, strong) ZSCapsuleSlider *normalFpsSlider;
@property (nonatomic, strong) UILabel *normalFpsValueLabel;
@property (nonatomic, strong) ZSCapsuleSlider *combatFpsSlider;
@property (nonatomic, strong) UILabel *combatFpsValueLabel;

+ (instancetype)shared;
- (void)installIfNeeded;
@end

static const NSTimeInterval kPostFXReapplyInterval = 1.0;
static const NSTimeInterval kSaveDebounceInterval = 0.4;

@implementation UserInterface

+ (instancetype)shared {
    static UserInterface *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [UserInterface new]; });
    return instance;
}

- (void)installIfNeeded {
    if (self.panel) return;
    UIWindow *window = zs_key_window();
    if (!window) return;

    [self buildPanel:window];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(deviceOrientationChanged)
                                                  name:UIDeviceOrientationDidChangeNotification
                                                object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(zs_keyboardWillChangeFrame:)
                                                  name:UIKeyboardWillChangeFrameNotification
                                                object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(zs_pollAllActiveDoctorEntriesImmediately)
                                                  name:UIApplicationWillEnterForegroundNotification
                                                object:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = zs_key_window();
        if (w && weakSelf.panel) [weakSelf layoutPanelForWindow:w];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = zs_key_window();
        if (w && weakSelf.panel) [weakSelf layoutPanelForWindow:w];
    });
}

- (void)toggleTapped {
    self.panelOpen = !self.panelOpen;
    [self positionPanel];
    [UIView animateWithDuration:0.25 animations:^{
        self.chevron.transform = self.panelOpen ? CGAffineTransformMakeRotation(M_PI) : CGAffineTransformIdentity;
    }];

    if (self.panelOpen) [self zs_pollAllActiveDoctorEntriesImmediately];
}

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

    if ([touch.view isKindOfClass:[ZSCapsuleSlider class]]) return NO;
    if ([touch.view isKindOfClass:[ZSModeSlider class]]) return NO;
    if ([touch.view isKindOfClass:[UISwitch class]]) return NO;
    if ([touch.view isKindOfClass:[UIButton class]]) return NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

#pragma mark Panel

static const CGFloat kPanelWidth = 320;
static const CGFloat kPanelPadding = 16;

static const CGFloat kRowSpacing = 4;
static const CGFloat kSectionSpacing = 20;

static void zs_add_section_header(UIStackView *stack, NSString *title) {
    UIView *previous = stack.arrangedSubviews.lastObject;
    UILabel *header = zs_make_section_header(title);
    [stack addArrangedSubview:header];
    if (previous) {
        [stack setCustomSpacing:kSectionSpacing afterView:previous];
    }
}

static const CGFloat kHandleWidth = 27;
static const CGFloat kHandleHeight = 72;
static const CGFloat kPanelCornerRadiusMinimum = 20;
static const CGFloat kHandleCornerRadius = 10;
static const CGFloat kGlassMergeSpacing = 16;
static const CGFloat kSyslogHandleHeight = 34;
static const CGFloat kSyslogHandleGap = 6;
static const CGFloat kContentFadeHeight = 22;

- (void)buildPanel:(UIWindow *)window {
    self.panelWidth = kPanelWidth;

    UIVisualEffectView *chrome = nil;

    if (zs_has_liquid_glass()) {
        chrome = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_container_effect(kGlassMergeSpacing)];
    } else {

        chrome = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(NO)];
    }

    self.glassContainer = chrome;
    self.glassContainerContent = chrome.contentView;
    self.glassContainer.userInteractionEnabled = YES;
    [window addSubview:self.glassContainer];

    if (zs_has_liquid_glass()) {

        self.panelGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(NO)];
        self.panelGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.panelGlass, kPanelCornerRadiusMinimum, YES);
        [self.glassContainerContent addSubview:self.panelGlass];

        self.handleGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        self.handleGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.handleGlass, kHandleCornerRadius, NO);
        [self.glassContainerContent addSubview:self.handleGlass];

        self.panel = self.panelGlass.contentView;
        self.handle = self.handleGlass.contentView;
    } else {

        self.panel = [[UIView alloc] init];
        self.handle = [[UIView alloc] init];
        self.panel.backgroundColor = UIColor.clearColor;
        self.handle.backgroundColor = UIColor.clearColor;
        [self.glassContainerContent addSubview:self.panel];
        [self.glassContainerContent addSubview:self.handle];
    }

    if (zs_has_liquid_glass()) {
        self.sliderGlassContainer =
            [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_container_effect(0.0)];
        self.sliderGlassContainer.userInteractionEnabled = NO;
        self.sliderGlassContainer.opaque = NO;
        self.sliderGlassContent = self.sliderGlassContainer.contentView;
        self.sliderGlassContent.backgroundColor = UIColor.clearColor;
        [window addSubview:self.sliderGlassContainer];
    }

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

    self.syslogLines = [NSMutableArray array];
    self.syslogBlacklist = [NSMutableOrderedSet orderedSet];

    if (zs_has_liquid_glass()) {
        self.syslogHandleGlass =
            [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        self.syslogHandleGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.syslogHandleGlass, 8, NO);
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

    self.syslogHandleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kSyslogHandleHeight, kHandleWidth)];
    self.syslogHandleLabel.text = @"SYSLOG";
    self.syslogHandleLabel.textAlignment = NSTextAlignmentCenter;
    self.syslogHandleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.syslogHandleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    self.syslogHandleLabel.transform = CGAffineTransformMakeRotation(-((CGFloat)M_PI_2));
    self.syslogHandleLabel.center = CGPointMake(kHandleWidth * 0.5, kSyslogHandleHeight * 0.5);
    [self.syslogHandle addSubview:self.syslogHandleLabel];

    [self zs_updateSyslogHandleLabelLayout];

    UITapGestureRecognizer *syslogTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(syslogTabTapped)];
    [self.syslogHandle addGestureRecognizer:syslogTap];

    self.syslogOverlay = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.syslogOverlay.backgroundColor = UIColor.clearColor;
    self.syslogOverlay.opaque = NO;
    self.syslogOverlay.userInteractionEnabled = YES;
    self.syslogOverlay.showsVerticalScrollIndicator = YES;
    self.syslogOverlay.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.syslogOverlay.alwaysBounceVertical = YES;

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
    self.scrollView.delegate = self;

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

    NSDictionary *saved = zs_load_settings_dictionary();
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

    NSArray *savedBlacklist = [saved[@"syslogBlacklist"] isKindOfClass:[NSArray class]] ? saved[@"syslogBlacklist"] : nil;
    for (id term in savedBlacklist) {
        if ([term isKindOfClass:[NSString class]]) [self.syslogBlacklist addObject:term];
    }
    g_syslogBlacklist = self.syslogBlacklist.array;

    NSDictionary *savedUrp = [saved[@"urpEffects"] isKindOfClass:[NSDictionary class]] ? saved[@"urpEffects"] : nil;
    for (int i = 0; i < kURPPostEffectCount; i++) {
        const ZSVolumeEffectDef *def = &kURPPostEffects[i];
        NSString *name = [NSString stringWithUTF8String:def->name];
        g_urpActive[name] = @YES;
        if (def->floatField) {
            NSNumber *savedVal = [savedUrp[name] isKindOfClass:[NSNumber class]] ? savedUrp[name] : nil;
            g_urpValue[name] = @(savedVal ? savedVal.floatValue : def->defaultV);
        }
    }

    NSString *(^fpsFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%d", (int)roundf(v)]; };
    NSString *(^twoDecimalFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.2f", v]; };
    NSString *(^wholeNumberFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f", v]; };
    NSString *(^texFormat)(float) = ^NSString *(float position) {

        int32_t engineValue = 4 - (int32_t)roundf(position);
        return [NSString stringWithFormat:@"%d", (int)engineValue];
    };

    UIView *titleBlock = zs_make_title_block();
    [self.stack addArrangedSubview:titleBlock];
    [self.stack setCustomSpacing:kSectionSpacing afterView:titleBlock];

    zs_add_section_header(self.stack, @"Display");

    ZSRow *normalRow = zs_make_slider_row(@"Menu FPS", 10, 120, g_menuFPS, fpsFormat);
    self.normalFpsSlider = normalRow.slider;
    self.normalFpsValueLabel = normalRow.valueLabel;
    normalRow.slider.defaultValue = kDefaultMenuFPS;
    normalRow.slider.hasDefaultValue = YES;
    [normalRow.slider addTarget:self action:@selector(normalFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:normalRow];

    ZSRow *combatRow = zs_make_slider_row(@"Combat FPS", 10, 120, g_combatFPS, fpsFormat);
    self.combatFpsSlider = combatRow.slider;
    self.combatFpsValueLabel = combatRow.valueLabel;
    combatRow.slider.defaultValue = kDefaultCombatFPS;
    combatRow.slider.hasDefaultValue = YES;
    [combatRow.slider addTarget:self action:@selector(combatFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:combatRow];

    zs_add_section_header(self.stack, @"Rendering");

    float texInitialPosition = 4.0f - (float)g_textureMip;
    float texDefaultPosition = 4.0f - (float)kDefaultTextureMipEngine;
    ZSRow *texRow = zs_make_slider_row(@"Texture MIP", 0, 4, texInitialPosition, texFormat);
    texRow.slider.defaultValue = texDefaultPosition;
    texRow.slider.hasDefaultValue = YES;
    [texRow.slider addTarget:self action:@selector(texChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:texRow];

    ZSRow *scaleRow = zs_make_slider_row(@"Render Scale", 25, 100, g_renderScale * 100.0f, ^NSString *(float v) {
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

    ZSRow *msaaRow = zs_make_mode_slider_row(@"MSAA", @[@"1x", @"2x", @"4x", @"8x"], g_msaaIndex, kDefaultMSAAIndex);
    [msaaRow.modeSlider addTarget:self action:@selector(msaaChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:msaaRow];

    zs_add_section_header(self.stack, @"Anti-Aliasing");

    ZSRow *aaModeRow = zs_make_mode_slider_row(@"AA Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], g_aaModeIndex, kDefaultAAModeIndex);
    [aaModeRow.modeSlider addTarget:self action:@selector(cameraAAModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaModeRow];

    ZSRow *aaQualityRow = zs_make_mode_slider_row(@"AA Quality", @[@"Low", @"Med", @"High"], g_aaQualityIndex, kDefaultAAQualityIndex);
    [aaQualityRow.modeSlider addTarget:self action:@selector(cameraAAQualityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaQualityRow];

    ZSRow *ditherRow = zs_make_switch_row(@"Dithering", g_ditheringOn);
    objc_setAssociatedObject(ditherRow.toggle, "zs_defaultBool", @(kDefaultDithering), OBJC_ASSOCIATION_RETAIN);
    [ditherRow.toggle addTarget:self action:@selector(cameraDitheringChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:ditherRow];

    zs_add_section_header(self.stack, @"Post FX");

    ZSRow *hdrRow = zs_make_switch_row(@"Bloom", g_hdrOn);
    objc_setAssociatedObject(hdrRow.toggle, "zs_defaultBool", @(kDefaultHDR), OBJC_ASSOCIATION_RETAIN);
    [hdrRow.toggle addTarget:self action:@selector(hdrChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:hdrRow];

    ZSRow *blurIntensityRow = zs_make_slider_row(@"Motion Blur", 0, 1, g_blurIntensity, twoDecimalFormat);
    blurIntensityRow.slider.defaultValue = kDefaultMotionBlur;
    blurIntensityRow.slider.hasDefaultValue = YES;
    [blurIntensityRow.slider addTarget:self action:@selector(blurIntensityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:blurIntensityRow];

    ZSRow *tonemapRow = zs_make_mode_slider_row(@"Tonemap", @[@"None", @"Neutral", @"ACES"], g_tonemapMode, kDefaultTonemapIndex);
    [tonemapRow.modeSlider addTarget:self action:@selector(tonemapModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:tonemapRow];

    for (int i = 0; i < kURPPostEffectCount; i++) {
        const ZSVolumeEffectDef *def = &kURPPostEffects[i];
        NSString *name = [NSString stringWithUTF8String:def->name];
        if (!def->floatField) continue;
        float currentVal = g_urpValue[name] ? g_urpValue[name].floatValue : def->defaultV;

        NSString *(^rowFormat)(float) = (def->maxV >= 20.0f) ? wholeNumberFormat : twoDecimalFormat;
        ZSRow *sliderRow = zs_make_slider_row(name, def->minV, def->maxV, currentVal, rowFormat);
        sliderRow.slider.defaultValue = def->defaultV;
        sliderRow.slider.hasDefaultValue = YES;
        objc_setAssociatedObject(sliderRow.slider, "zs_urp_name", name, OBJC_ASSOCIATION_RETAIN);
        [sliderRow.slider addTarget:self action:@selector(urpEffectValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.stack addArrangedSubview:sliderRow];
    }

    zs_add_section_header(self.stack, @"Debug");

    ZSRow *syslogRow = zs_make_button_and_glass_field_row(@"Syslog",
                                                            [UIColor colorWithWhite:1 alpha:0.88],
                                                            @"Blacklist keywords");
    UIButton *syslogButton = objc_getAssociatedObject(syslogRow, "zs_button");
    self.syslogButton = syslogButton;

    zs_configure_glass_button_fixed_corner_radius(syslogButton, kZSAuthFieldCornerRadius);
    if (!zs_has_liquid_glass()) {
        syslogButton.layer.cornerRadius = kZSAuthFieldCornerRadius;
        syslogButton.clipsToBounds = YES;
    }
    SEL syslogSetUpdateHandler = NSSelectorFromString(@"setConfigurationUpdateHandler:");
    if ([syslogButton respondsToSelector:syslogSetUpdateHandler]) {
        void (^syslogReassertCorners)(__kindof UIButton *) = ^(__kindof UIButton *btn) {
            zs_configure_glass_button_fixed_corner_radius(btn, kZSAuthFieldCornerRadius);
        };
        ((void (*)(id, SEL, id))objc_msgSend)(syslogButton, syslogSetUpdateHandler, syslogReassertCorners);
    }
    [syslogButton addTarget:self action:@selector(toggleSyslogTapped) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *syslogHold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleSyslogButtonLongPress:)];
    syslogHold.minimumPressDuration = 0;
    syslogHold.cancelsTouchesInView = NO;
    [syslogButton addGestureRecognizer:syslogHold];

    self.syslogBlacklistField = objc_getAssociatedObject(syslogRow, "zs_textfield");
    self.syslogBlacklistField.delegate = self;
    [self.stack addArrangedSubview:syslogRow];
    [self.stack setCustomSpacing:8 afterView:syslogRow];

    UILabel *blacklistHeader = [[UILabel alloc] init];
    blacklistHeader.translatesAutoresizingMaskIntoConstraints = NO;
    blacklistHeader.text = @"Blacklisted keywords";
    blacklistHeader.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    blacklistHeader.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    [self.stack addArrangedSubview:blacklistHeader];

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

    [self zs_rebuildSyslogBlacklistEntries];

    zs_add_section_header(self.stack, @"Mods");
    ZSRow *modsRow = zs_make_button_pair_row(
        @"Load Mods", [UIColor colorWithRed:0.55 green:0.42 blue:1.0 alpha:1.0],
        @"Restore Originals", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    UIButton *loadModsButton = objc_getAssociatedObject(modsRow, "zs_button_left");
    [loadModsButton addTarget:self action:@selector(loadModsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *restoreOriginalsButton = objc_getAssociatedObject(modsRow, "zs_button_right");

    zs_attach_pill_hold_to_confirm(restoreOriginalsButton, self, ^{
        [weakSelf restoreOriginalsTapped];
    });
    [self.stack addArrangedSubview:modsRow];

    self.modsLibraryExpandedFolders = [NSMutableSet set];
    self.modsLibraryExpandedInfoEntries = [NSMutableSet set];
    self.modsLibraryExpandedProcessedBundles = [NSMutableSet set];
    self.processedBundleInstallInFlight = [NSMutableSet set];
    self.modsLibraryStack = [[UIStackView alloc] init];
    self.modsLibraryStack.axis = UILayoutConstraintAxisVertical;
    self.modsLibraryStack.spacing = 2;
    self.modsLibraryStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.modsLibraryStack];
    [self zs_rebuildModsLibrary];

    zs_add_section_header(self.stack, @"Auth");

    ZSRow *repoLinkRow = zs_make_labeled_glass_field_row(@"owner/repo", NO, nil);
    self.authRepoLinkField = objc_getAssociatedObject(repoLinkRow, "zs_textfield");
    self.authRepoLinkField.keyboardType = UIKeyboardTypeURL;
    self.authRepoLinkField.delegate = self;
    self.authRepoLinkFieldContainer = objc_getAssociatedObject(repoLinkRow, "zs_fieldContainer");
    [self.stack addArrangedSubview:repoLinkRow];
    [self.stack setCustomSpacing:8 afterView:repoLinkRow];

    self.authVerifyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.authVerifyButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_auth_verify_button(self.authVerifyButton, @"Verify");
    [self.authVerifyButton addTarget:self action:@selector(zs_authVerifyTapped:) forControlEvents:UIControlEventTouchUpInside];

    ZSRow *authTokenRow = zs_make_labeled_glass_field_row(@"ghp_xxxxxxxxxxxxxxxxxxxx", YES, self.authVerifyButton);
    self.authTokenField = objc_getAssociatedObject(authTokenRow, "zs_textfield");
    self.authTokenField.delegate = self;
    self.authTokenFieldContainer = objc_getAssociatedObject(authTokenRow, "zs_fieldContainer");
    [self.stack addArrangedSubview:authTokenRow];
    [self.stack setCustomSpacing:4 afterView:authTokenRow];

    self.authStatusLabel = [[UILabel alloc] init];
    self.authStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.authStatusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    self.authStatusLabel.numberOfLines = 0;
    self.authStatusLabel.hidden = YES;
    [self.stack addArrangedSubview:self.authStatusLabel];

    [self zs_loadAuthFields];

    [self zs_authRunBootVerification];

    zs_add_section_header(self.stack, @"Config");

    NSString *currentReencodeFormat = [ZTranscoderSettings loadConfig].outputFormat;
    if (currentReencodeFormat.length == 0) currentReencodeFormat = kZSDefaultReencodeFormat;
    ZSRow *reencodeFormatRow = zs_make_reencode_format_row(currentReencodeFormat, self,
                                                            @selector(zs_reencodeFormatButtonTapped:));
    self.reencodeFormatButton = objc_getAssociatedObject(reencodeFormatRow, "zs_button");
    [self.stack addArrangedSubview:reencodeFormatRow];

    ZSRow *fmodZeroingRow = zs_make_switch_row(@"Disable FModManifest zeroing", !PatchManifestNetwork.isZeroingEnabled);
    [fmodZeroingRow.toggle addTarget:self action:@selector(fmodZeroingDisableChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:fmodZeroingRow];

    ZSRow *lz4hcRow = zs_make_switch_row(@"Disable LZ4HC compression on dispatch", !ZTranscoderService.isUploadCompressionEnabled);
    [lz4hcRow.toggle addTarget:self action:@selector(lz4hcCompressionDisableChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:lz4hcRow];

    ZSRow *manualIndexRow = zs_make_single_button_row(@"Manually Index Files", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    UIButton *manualIndexButton = objc_getAssociatedObject(manualIndexRow, "zs_button");
    [manualIndexButton addTarget:self action:@selector(manuallyIndexFilesTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:manualIndexRow];

    ZSRow *configRow = zs_make_button_pair_row(
        @"Reset Settings", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0],
        @"Reapply Settings", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    UIButton *resetButton = objc_getAssociatedObject(configRow, "zs_button_left");
    [resetButton addTarget:self action:@selector(resetSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reapplyButton = objc_getAssociatedObject(configRow, "zs_button_right");
    [reapplyButton addTarget:self action:@selector(reapplySettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:configRow];

    ZSRow *hardResetRow = zs_make_single_button_row(@"Hard Assets Reset", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    UIButton *hardResetButton = objc_getAssociatedObject(hardResetRow, "zs_button");
    zs_attach_pill_hold_to_confirm_duration(hardResetButton, self, 3.0, ^{
        [weakSelf hardAssetsResetTapped];
    });
    [self.stack addArrangedSubview:hardResetRow];

    ZSRow *deleteProxyReleasesRow = zs_make_single_button_row(@"Delete Stored Bundles in Proxy", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    UIButton *deleteProxyReleasesButton = objc_getAssociatedObject(deleteProxyReleasesRow, "zs_button");
    zs_attach_pill_hold_to_confirm(deleteProxyReleasesButton, self, ^{
        [weakSelf deleteStoredBundlesInProxyTapped:deleteProxyReleasesButton];
    });
    [self.stack addArrangedSubview:deleteProxyReleasesRow];

    [self layoutPanelForWindow:window];

    zs_reapply_all_settings();
}

#pragma mark Settings persistence

- (void)zs_scheduleSave {
    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kSaveDebounceInterval
                                                                target:self
                                                              selector:@selector(zs_writeSettingsNow)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)zs_writeSettingsNow {
    self.saveDebounceTimer = nil;
    zs_write_settings_dictionary(zs_current_settings_dictionary());
}

#pragma mark Reset

- (void)resetSettingsTapped {
    for (UIView *arranged in self.stack.arrangedSubviews) {
        if (![arranged isKindOfClass:[ZSRow class]]) continue;
        ZSRow *row = (ZSRow *)arranged;
        if (row.slider && row.slider.hasDefaultValue) {
            row.slider.value = row.slider.defaultValue;
            zs_update_value_label(row.slider);
            [row.slider sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.modeSlider) {
            NSInteger def = row.modeSlider.defaultIndex >= 0 ? row.modeSlider.defaultIndex : 0;
            [row.modeSlider setSelectedIndex:def animated:YES];
            [row.modeSlider sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.toggle) {
            NSNumber *def = objc_getAssociatedObject(row.toggle, "zs_defaultBool");
            if (def) {
                row.toggle.on = def.boolValue;
                [row.toggle sendActionsForControlEvents:UIControlEventValueChanged];
            }
        }
    }

    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = nil;
    zs_write_settings_dictionary(zs_current_settings_dictionary());

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)reapplySettingsTapped {
    zs_reapply_all_settings();

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

#pragma mark Config (Manually Index Files)

- (void)manuallyIndexFilesTapped {
    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *indexing = [UIAlertController alertControllerWithTitle:@"Indexing\u2026"
                                                                        message:@"Reading bundle identifiers and matching them against the game's cache."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [indexing.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:indexing.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:indexing.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:indexing animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [ZSFileIndex forceReindex];

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            void (^afterDismiss)(void) = ^{
                [strongSelf zs_presentModsAlertWithTitle:@"Manually Index Files"
                                                  message:@"File index rebuilt."];
            };
            if (indexing.presentingViewController) {
                [indexing dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

#pragma mark Config (Hard Assets Reset)

- (void)hardAssetsResetTapped {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSArray<NSString *> *trackedPaths = zs_tracked_asset_paths();
    NSInteger assetsDeleted = 0;
    for (NSString *path in trackedPaths) {
        if (![fm fileExistsAtPath:path]) continue;
        NSError *removeErr = nil;
        if ([fm removeItemAtPath:path error:&removeErr]) {
            assetsDeleted++;
        } else {
            ZLog(@"[UserInterface] hard reset: couldn't delete live asset %@: %@", path, removeErr.localizedDescription);
        }
    }
    zs_clear_tracked_asset_paths();

    NSString *bankBackupDir = [BankTransplant bankBackupDirectory];
    if (bankBackupDir) [fm removeItemAtPath:bankBackupDir error:nil];
    NSString *bundleBackupDir = [ZTranscoderInstaller bundleBackupDirectory];
    if (bundleBackupDir) [fm removeItemAtPath:bundleBackupDir error:nil];

    NSError *libraryError = nil;
    BOOL libraryCleared = [ModAssetLibrary deleteAllFoldersWithError:&libraryError];

    [self zs_rebuildModsLibrary];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (!libraryCleared) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = libraryError.localizedDescription ?: @"Unknown error.";
        [self zs_presentModsAlertWithTitle:@"Hard Reset Failed" message:reason];
        return;
    }

    if (assetsDeleted == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self zs_presentModsAlertWithTitle:@"Nothing to Reset"
                                    message:@"No tracked bank or bundle assets were found. Every backup and the Mod Asset Library have been cleared regardless."];
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSString *message = [NSString stringWithFormat:
        @"Deleted %ld tracked asset%@ from the game's own files, cleared every backup, and emptied the Mod Asset Library. Restart the game for it to take effect.",
        (long)assetsDeleted, assetsDeleted == 1 ? @"" : @"s"];
    [self zs_presentModsAlertWithTitle:@"Hard Assets Reset" message:message];
}

- (void)deleteStoredBundlesInProxyTapped:(UIButton *)button {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    NSString *originalTitle = [button titleForState:UIControlStateNormal];
    button.enabled = NO;
    [button setTitle:@"Deleting\u2026" forState:UIControlStateNormal];

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService deleteAllReleasesForConfig:config completion:^(NSInteger deletedCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        button.enabled = YES;
        [button setTitle:originalTitle forState:UIControlStateNormal];

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        if (error) {
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            [strongSelf zs_presentModsAlertWithTitle:@"Delete Failed"
                                              message:error.localizedDescription ?: @"Couldn't reach the configured repository."];
            return;
        }

        if (deletedCount == 0) {
            [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
            [strongSelf zs_presentModsAlertWithTitle:@"Nothing to Delete"
                                              message:@"No releases were found in the configured repository."];
            return;
        }

        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        [strongSelf zs_presentModsAlertWithTitle:@"Proxy Cleared"
                                          message:[NSString stringWithFormat:@"Deleted %ld release%@ from the configured repository.",
                                                    (long)deletedCount, deletedCount == 1 ? @"" : @"s"]];
    }];
}

#pragma mark Mods (Load Mods - single entry point, routes by file kind)

- (void)loadModsTapped {
    __weak typeof(self) weakSelf = self;
    [self zs_promptForModFolderNameWithTitle:@"New Mod Folder"
                                  actionTitle:@"Create"
                                   completion:^(NSString *trimmedName) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *error = nil;
        BOOL created = [ModAssetLibrary createFolderNamed:trimmedName error:&error];
        if (!created) {
            [strongSelf zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:error.localizedDescription ?: @"Unknown error."];
            return;
        }
        [strongSelf zs_rebuildModsLibrary];
        [strongSelf zs_presentLoadModsPickerIntoFolder:trimmedName];
    }];
}

- (void)zs_presentLoadModsPickerIntoFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = zs_key_window().rootViewController;
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
        if (folderName) [self zs_handleLoadModsPickedURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.libraryImportPicker) {
        NSString *folderName = self.libraryImportTargetFolder;
        self.libraryImportTargetFolder = nil;
        if (folderName) [self zs_handlePickedLibraryImportURLs:urls intoFolder:folderName];
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
            [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:urls.firstObject entryPath:entryPath inFolder:folderName];
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
            [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
                [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                     code:ZTranscoderInstallerErrorNoInstallTarget
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cancelled - no stock bundle was picked to install into."}]];
        }
    }
}

- (void)zs_handleLoadModsPickedZipURLs:(NSArray<NSURL *> *)zipURLs intoFolder:(NSString *)folderName summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    for (NSURL *zipURL in zipURLs) {
        BOOL accessing = [zipURL startAccessingSecurityScopedResource];
        NSError *formatErr = nil;
        BOOL isLunartique = [LunartiqueModArchive isLunartiqueFormatZipAtURL:zipURL error:&formatErr];
        if (!isLunartique) {
            if (accessing) [zipURL stopAccessingSecurityScopedResource];
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - doesn't match the Lunartique mod format's file tree", zipURL.lastPathComponent]];
            continue;
        }

        NSError *importErr = nil;
        NSArray<NSString *> *rejectedEntryLines = nil;
        BOOL imported = [ModAssetLibrary importLunartiqueZipURL:zipURL intoFolder:folderName rejectedEntryLines:&rejectedEntryLines error:&importErr];
        if (accessing) [zipURL stopAccessingSecurityScopedResource];

        if (rejectedEntryLines.count > 0) {
            [summaryLines addObjectsFromArray:rejectedEntryLines];
        }

        if (imported) {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: Lunartique mod imported - tap Dispatch when ready to send it for processing", zipURL.lastPathComponent]];
        } else if (rejectedEntryLines.count == 0) {

            [summaryLines addObject:[NSString stringWithFormat:@"%@: Lunartique format matched, but import failed - %@", zipURL.lastPathComponent, importErr.localizedDescription ?: @"unknown error"]];
        }
    }
}

- (void)zs_handleLoadModsPickedURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    if (urls.count == 0) return;

    NSMutableArray<NSURL *> *validURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *bankURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *zipURLs = [NSMutableArray array];
    NSMutableArray<NSString *> *summaryLines = [NSMutableArray array];

    for (NSURL *url in urls) {
        if ([url.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
            [zipURLs addObject:url];
        } else if ([url.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
            [bankURLs addObject:url];
            [validURLs addObject:url];
        } else if ([self zs_isRecognizedBundleURL:url]) {

            [validURLs addObject:url];
            [summaryLines addObject:[NSString stringWithFormat:@"%@: added to Mods Library - tap Dispatch when ready to send it for processing", url.lastPathComponent]];
        } else {

            [summaryLines addObject:[NSString stringWithFormat:@"%@: not a recognized bank or bundle", url.lastPathComponent]];
        }
    }

    self.loadModsSummaryLines = summaryLines;

    if (validURLs.count == 0 && zipURLs.count == 0) {
        [self zs_processLoadModsBankURLs:bankURLs];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *indexing = [UIAlertController alertControllerWithTitle:@"Indexing\u2026"
                                                                        message:@"Reading bundle identifiers and matching them against the game's cache."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [indexing.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:indexing.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:indexing.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:indexing animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (validURLs.count > 0) {
            NSError *importError = nil;
            NSArray<NSString *> *rejectedFileLines = nil;
            BOOL imported = [ModAssetLibrary importFileURLs:validURLs intoFolder:folderName rejectedFileLines:&rejectedFileLines error:&importError];
            if (!imported && rejectedFileLines.count == 0) {
                ZLog(@"[Mods] couldn't add picked files to Mod Asset Library folder \"%@\": %@", folderName, importError);
            }

            for (NSString *rejectedLine in rejectedFileLines) {
                NSString *rejectedFileName = [[rejectedLine componentsSeparatedByString:@": rejected"] firstObject];
                NSUInteger existingIdx = [summaryLines indexOfObjectPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
                    return [line hasPrefix:[rejectedFileName stringByAppendingString:@": "]];
                }];
                if (existingIdx != NSNotFound) {
                    summaryLines[existingIdx] = rejectedLine;
                } else {
                    [summaryLines addObject:rejectedLine];
                }
            }
        }
        if (zipURLs.count > 0) {
            [self zs_handleLoadModsPickedZipURLs:zipURLs intoFolder:folderName summaryLines:summaryLines];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loadModsSummaryLines = summaryLines;
            void (^afterDismiss)(void) = ^{
                [strongSelf zs_rebuildModsLibrary];
                [strongSelf zs_processLoadModsBankURLs:bankURLs];
            };
            if (indexing.presentingViewController) {
                [indexing dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (BOOL)zs_isRecognizedBundleURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return isBundle;
}

- (void)zs_processLoadModsBankURLs:(NSArray<NSURL *> *)bankURLs {
    if (bankURLs.count == 0) {
        [self zs_presentLoadModsFinalSummary];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
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
                [strongSelf zs_presentLoadModsFinalSummary];
            };
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (void)restoreOriginalsTapped {
    [self zs_performRestoreOriginalsForce:NO];
}

- (void)zs_forceRestoreOriginalsTapped {
    [self zs_performRestoreOriginalsForce:YES];
}

- (void)zs_performRestoreOriginalsForce:(BOOL)force {
    NSError *bankError = nil;
    NSInteger banksRestored = [BankTransplant restoreAllBackedUpBanksForce:force error:&bankError];

    NSError *bundleError = nil;
    NSInteger bundlesRestored = [ZTranscoderInstaller restoreAllBackedUpBundlesForce:force error:&bundleError];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (banksRestored < 0 || bundlesRestored < 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = bankError.localizedDescription ?: bundleError.localizedDescription ?: @"Unknown error.";
        [self zs_presentModsAlertWithTitle:@"Restore Failed" message:reason];
        return;
    }

    if (banksRestored == 0 && bundlesRestored == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        if (force) {

            [self zs_presentModsAlertWithTitle:@"Nothing to Restore" message:@"No backed-up banks or bundles found."];
        } else {
            [self zs_presentRestoreNothingToRestoreAlertWithForceOption];
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
    [self zs_presentModsAlertWithTitle:@"Restore Originals" message:message];
}

- (void)zs_presentRestoreNothingToRestoreAlertWithForceOption {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] Nothing to Restore: every backed-up bank/bundle already matches its backup.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nothing to Restore"
                                                                     message:@"Every backed-up bank/bundle already matches its backup byte-for-byte. Force Restore rewrites them anyway, just in case."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Force Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_forceRestoreOriginalsTapped];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Mods (doctor pipeline)

static const int64_t kZSDoctorProgressByteThreshold = 32 * 1024;

static NSString *zs_mods_folder_name_for_entry(ModAssetLibraryEntry *entry) {
    NSString *root = [ModAssetLibrary modLibraryRootDirectory];
    NSString *path = entry.path;
    if (root.length > 0 && [path hasPrefix:root]) {
        NSString *relative = [path substringFromIndex:root.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        NSString *first = relative.pathComponents.firstObject;
        if (first.length > 0) return first;
    }

    return path.stringByDeletingLastPathComponent.lastPathComponent;
}

static ModAssetLibraryEntry *zs_mods_entry_placeholder_for_path(NSString *path) {
    ModAssetLibraryEntry *placeholder = [ModAssetLibraryEntry new];
    placeholder.path = path;
    return placeholder;
}

static const NSTimeInterval kDoctorPollInterval = 6.0;

- (void)zs_modsLibraryEntryDispatchTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Dispatch tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    [self zs_doctorStartOrInstallForEntry:entry folderName:folderName previousScratchBranch:entry.doctorScratchBranch];
}

- (void)zs_doctorStartOrInstallForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName previousScratchBranch:(nullable NSString *)previousScratchBranch {
    if (entry.targetPlatform && entry.targetPlatform.intValue == 9) {
        if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
        if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) return;
        [self.doctorDownloadInFlightPaths addObject:entry.path];
        [self zs_rebuildModsLibrary];
        [self zs_doctorInstallUsingKnownTargetForDoctoredURL:[NSURL fileURLWithPath:entry.path]
                                                entryPath:entry.path
                                                 inFolder:folderName];
        return;
    }

    [self zs_doctorBeginDispatchForEntry:entry folderName:folderName previousScratchBranch:previousScratchBranch];
}

- (void)zs_doctorBeginDispatchForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName previousScratchBranch:(nullable NSString *)previousScratchBranch {

    if (self.authCredentialsStale) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    NSString *entryPath = entry.path;
    [self.doctorUploadProgressLastBytes removeObjectForKey:entryPath];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusUploading;
        entryToMutate.doctorUploadProgress = 0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorLastError = nil;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't flip %@ to Uploading: %@", entry.fileName, stateError);
        return;
    }
    [self zs_rebuildModsLibrary];

    NSURL *bundleURL = [NSURL fileURLWithPath:entryPath];
    __weak typeof(self) weakSelf = self;
    [ZTranscoderService dispatchBundleAtURL:bundleURL
                                        config:config
                         previousScratchBranch:previousScratchBranch
                                uploadProgress:^(int64_t bytesSent) {
        [weakSelf zs_doctorHandleUploadProgress:bytesSent forEntryPath:entryPath inFolder:folderName];
    }
                                    completion:^(ZTranscoderHandle * _Nullable handle, NSError * _Nullable error) {
        [weakSelf zs_doctorDispatchCompletedForEntryPath:entryPath inFolder:folderName handle:handle error:error];
    }];
}

- (void)zs_modsLibraryEntryRetryTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) return;

    [self zs_stopDoctorPollTimerForEntryPath:entry.path];
    [self.doctorUploadProgressLastBytes removeObjectForKey:entry.path];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entry.path];

    NSString *previousScratchBranch = entry.doctorScratchBranch;

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusNotDispatched;
        entryToMutate.doctorUploadProgress = 0;
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

    [self zs_doctorStartOrInstallForEntry:updated folderName:folderName previousScratchBranch:previousScratchBranch];
}

- (void)zs_doctorHandleUploadProgress:(int64_t)bytesSent forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorUploadProgressLastBytes) self.doctorUploadProgressLastBytes = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorUploadProgressLastBytes[entryPath];
    if (last && llabs(bytesSent - last.longLongValue) < kZSDoctorProgressByteThreshold) return;
    self.doctorUploadProgressLastBytes[entryPath] = @(bytesSent);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorUploadProgress = bytesSent;
    }
                                                                           error:&error];
    if (!updated) return;
    [self zs_rebuildModsLibrary];
}

- (void)zs_doctorDispatchCompletedForEntryPath:(NSString *)entryPath
                                        inFolder:(NSString *)folderName
                                          handle:(ZTranscoderHandle *)handle
                                           error:(NSError *)error {
    [self.doctorUploadProgressLastBytes removeObjectForKey:entryPath];

    if (!handle) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
        return;
    }

    if (handle.alreadyComplete) {
        NSError *stateError = nil;
        ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                            inFolder:folderName
                                                                          applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
            entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusReadyToDownload;

            entryToMutate.doctorProcessProgress = 1.0;
            entryToMutate.doctorScratchBranch = handle.scratchBranch;
            entryToMutate.doctorRunID = nil;
            entryToMutate.doctorRunURL = nil;
        }
                                                                               error:&stateError];
        if (!updated) {
            ZLog(@"[Mods Library] cache-hit dispatch finished for %@ but its manifest entry is gone (deleted mid-upload?).", entryPath.lastPathComponent);
            return;
        }
        [self zs_rebuildModsLibrary];
        return;
    }

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusProcessing;

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
    [self zs_rebuildModsLibrary];
    [self zs_armDoctorPollTimerForEntryPath:entryPath inFolder:folderName];
}

- (void)zs_doctorFailEntryAtPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self zs_stopDoctorPollTimerForEntryPath:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
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
    [self zs_rebuildModsLibrary];
}

#pragma mark Mods (doctor pipeline) - 6s poll loop

- (void)zs_armDoctorPollTimerForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorPollTimers) self.doctorPollTimers = [NSMutableDictionary dictionary];
    [self.doctorPollTimers[entryPath] invalidate];

    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kDoctorPollInterval
                                              repeats:YES
                                                block:^(NSTimer *timer) {
        [weakSelf zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.doctorPollTimers[entryPath] = timer;

    [self zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
}

- (void)zs_stopDoctorPollTimerForEntryPath:(NSString *)entryPath {
    NSTimer *timer = self.doctorPollTimers[entryPath];
    [timer invalidate];
    [self.doctorPollTimers removeObjectForKey:entryPath];
}

- (void)zs_pollAllActiveDoctorEntriesImmediately {
    for (NSString *entryPath in self.doctorPollTimers.allKeys) {
        NSString *folderName = zs_mods_folder_name_for_entry(zs_mods_entry_placeholder_for_path(entryPath));
        [self zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
    }
}

- (void)zs_pollDoctorRunForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *readError = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&readError];
    ModAssetLibraryEntry *current = nil;
    for (ModAssetLibraryEntry *candidate in entries) {
        if ([candidate.path isEqualToString:entryPath]) { current = candidate; break; }
    }
    if (!current || current.doctorStatus != ModAssetLibraryDoctorStatusProcessing) {

        [self zs_stopDoctorPollTimerForEntryPath:entryPath];
        return;
    }

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                 code:ZTranscoderServiceErrorInvalidConfig
                             userInfo:@{NSLocalizedDescriptionKey: @"GitHub auth was cleared while this bundle was still processing."}]];
        return;
    }

    ZTranscoderHandle *handle = [ZTranscoderHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": current.doctorScratchBranch ?: @"",
        @"runID": current.doctorRunID ?: @"",
        @"runURL": current.doctorRunURL ?: @"",
    }];
    if (!handle) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                 code:ZTranscoderServiceErrorRunNotFound
                             userInfo:@{NSLocalizedDescriptionKey: @"Lost track of this submission's scratch branch."}]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (current.doctorRunID.length == 0) {

        [ZTranscoderService resolveRunForHandle:handle config:config completion:^(BOOL found, NSError * _Nullable error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
                return;
            }
            if (!found) return;
            [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                inFolder:folderName
                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorRunID = handle.runID;
                entryToMutate.doctorRunURL = handle.runURL;
            }
                                                   error:nil];
            [strongSelf zs_rebuildModsLibrary];
        }];
        return;
    }

    [ZTranscoderService fetchRunStatusForHandle:handle config:config completion:^(ZTranscoderRunStatus status, double percentComplete, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (status == ZTranscoderRunStatusFailed) {
            [strongSelf zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
            return;
        }
        if (status == ZTranscoderRunStatusSucceeded) {
            [strongSelf zs_stopDoctorPollTimerForEntryPath:entryPath];
            [strongSelf.doctorProcessProgressLastPercent removeObjectForKey:entryPath];
            NSError *stateError = nil;
            ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                                inFolder:folderName
                                                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusReadyToDownload;
                entryToMutate.doctorProcessProgress = 1.0;
            }
                                                                                   error:&stateError];
            if (updated) [strongSelf zs_rebuildModsLibrary];
            return;
        }

        [strongSelf zs_doctorHandleProcessProgress:percentComplete forEntryPath:entryPath inFolder:folderName];
    }];
}

- (void)zs_doctorHandleProcessProgress:(double)fractionComplete forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, fractionComplete)) * 100.0);
    if (!self.doctorProcessProgressLastPercent) self.doctorProcessProgressLastPercent = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorProcessProgressLastPercent[entryPath];
    if (last && last.integerValue == percent) return;
    self.doctorProcessProgressLastPercent[entryPath] = @(percent);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorProcessProgress = fractionComplete;
    }
                                                                           error:&error];
    if (!updated) return;
    [self zs_rebuildModsLibrary];
}

- (void)zs_recoverStaleDoctorStateForThisLaunch {
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
                    [self zs_armDoctorPollTimerForEntryPath:entry.path inFolder:folderName];
                }
            }
        }
    }
}

- (void)zs_presentLoadModsFinalSummary {
    NSArray<NSString *> *lines = self.loadModsSummaryLines ?: @[];
    self.loadModsSummaryLines = nil;

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    if (lines.count == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self zs_presentModsAlertWithTitle:@"No Files Loaded" message:@"No files were submitted."];
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
    [self zs_presentModsAlertWithTitle:@"Load Mods" message:message];
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIViewController *presenter = zs_key_window().rootViewController;
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

- (void)zs_updateSyslogHandleLabelLayout {
    if (!self.syslogHandleLabel) return;
    CGSize textSize = [self.syslogHandleLabel.text sizeWithAttributes:@{NSFontAttributeName: self.syslogHandleLabel.font}];
    CGFloat height = MAX(kSyslogHandleHeight, ceil(textSize.width) + 14.0);
    self.syslogHandleHeight = height;

    self.syslogHandleLabel.transform = CGAffineTransformIdentity;
    self.syslogHandleLabel.frame = CGRectMake(0, 0, height, kHandleWidth);
    self.syslogHandleLabel.transform = CGAffineTransformMakeRotation(-((CGFloat)M_PI_2));
    self.syslogHandleLabel.center = CGPointMake(kHandleWidth * 0.5, height * 0.5);
}

#pragma mark Mods Library

- (void)zs_promptForModFolderNameWithTitle:(NSString *)title
                                actionTitle:(NSString *)actionTitle
                                 completion:(void (^)(NSString *trimmedName))completion {
    UIViewController *presenter = zs_key_window().rootViewController;
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

- (void)zs_rebuildModsLibrary {
    if (!self.modsLibraryStack) return;

    BOOL wasDropdownOpen = self.modsOptionsDropdownOpen;
    BOOL dropdownWasFolderMode = wasDropdownOpen && (self.modsOptionsDropdownEntry == nil);
    NSString *dropdownTargetFolderName = wasDropdownOpen ? self.modsOptionsDropdownFolderName : nil;
    NSString *dropdownTargetEntryPath = (wasDropdownOpen && !dropdownWasFolderMode) ? self.modsOptionsDropdownEntry.path : nil;

    [self zs_recoverStaleDoctorStateForThisLaunch];

    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {

        UIButton *deleteButton = objc_getAssociatedObject(view, "zs_button_delete");
        if (deleteButton) {
            UIView *capsuleGlass = objc_getAssociatedObject(deleteButton, kZSHoldConfirmGlassViewKey);
            [capsuleGlass removeFromSuperview];
        }
        [self.modsLibraryStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSMutableArray<NSString *> *folders = [[ModAssetLibrary folderNames] mutableCopy];
    [folders removeObject:kZSStoredBundlesFolderName];
    if (folders.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No mod folders yet.";
        empty.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        empty.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        [self.modsLibraryStack addArrangedSubview:empty];

    }

    for (NSString *folderName in folders) {
        BOOL expanded = [self.modsLibraryExpandedFolders containsObject:folderName];

        NSString *folderRemark = [ModAssetLibrary remarkForFolder:folderName];
        UIView *folderRow = zs_make_mods_folder_row(folderName, folderRemark, expanded, self,
            @selector(zs_modsLibraryFolderRowTapped:),
            @selector(zs_modsLibraryFolderOptionsTapped:));
        [self.modsLibraryStack addArrangedSubview:folderRow];

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

            UIView *entryRow = zs_make_mods_entry_row(entry, self,
                @selector(zs_modsLibraryEntryInfoTapped:),
                @selector(zs_modsLibraryEntryDispatchTapped:),
                @selector(zs_modsLibraryEntryDownloadTapped:),
                @selector(zs_modsLibraryEntryRetryTapped:),
                @selector(zs_modsLibraryEntryOptionsTapped:),
                entryExpanded,
                [self.doctorDownloadInFlightPaths containsObject:entry.path],
                NO);
            [self.modsLibraryStack addArrangedSubview:entryRow];

            if (entryExpanded) {
                UIView *infoPanel = zs_make_mods_entry_info_panel(entry,
                    [self.doctorDownloadInFlightPaths containsObject:entry.path], NO);
                [self.modsLibraryStack addArrangedSubview:infoPanel];
            }
        }
    }

    NSError *storedError = nil;
    NSArray<ModAssetLibraryEntry *> *storedEntries =
        [[ModAssetLibrary folderNames] containsObject:kZSStoredBundlesFolderName]
            ? [ModAssetLibrary entriesInFolder:kZSStoredBundlesFolderName error:&storedError]
            : nil;

    if (storedEntries.count > 0) {
        BOOL storedExpanded = [self.modsLibraryExpandedFolders containsObject:kZSStoredBundlesFolderName];
        UIView *storedFolderRow = zs_make_mods_folder_row(kZSStoredBundlesFolderName,
            kZSStoredBundlesFolderSubtext, storedExpanded, self,
            @selector(zs_modsLibraryFolderRowTapped:), NULL);
        [self.modsLibraryStack addArrangedSubview:storedFolderRow];

        if (storedExpanded) {

            NSArray<ModAssetLibraryEntry *> *sortedStoredEntries =
                [storedEntries sortedArrayUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
                    return [a.fileName localizedStandardCompare:b.fileName];
                }];

            for (ModAssetLibraryEntry *entry in sortedStoredEntries) {
                BOOL entryExpanded = [self.modsLibraryExpandedInfoEntries containsObject:entry.path];

                UIView *entryRow = zs_make_mods_entry_row(entry, self,
                    @selector(zs_modsLibraryEntryInfoTapped:),
                    @selector(zs_modsLibraryEntryDispatchTapped:),
                    @selector(zs_modsLibraryEntryDownloadTapped:),
                    @selector(zs_modsLibraryEntryRetryTapped:),
                    @selector(zs_modsLibraryEntryOptionsTapped:),
                    entryExpanded,
                    NO,
                    YES);
                [self.modsLibraryStack addArrangedSubview:entryRow];

                if (entryExpanded) {
                    UIView *infoPanel = zs_make_mods_entry_info_panel(entry, NO, YES);
                    [self.modsLibraryStack addArrangedSubview:infoPanel];
                }
            }
        }
    }

    if (wasDropdownOpen) {
        UIButton *newButton = nil;
        ModAssetLibraryEntry *newEntry = nil;
        for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
            if (dropdownWasFolderMode) {
                NSString *rowFolderName = objc_getAssociatedObject(view, "zs_modsFolderName");
                if (rowFolderName && [rowFolderName isEqualToString:dropdownTargetFolderName]) {
                    newButton = objc_getAssociatedObject(view, "zs_button_options");
                    break;
                }
            } else {
                ModAssetLibraryEntry *rowEntry = objc_getAssociatedObject(view, "zs_modsEntry");
                if (rowEntry && [rowEntry.path isEqualToString:dropdownTargetEntryPath]) {
                    newButton = objc_getAssociatedObject(view, "zs_button_options");
                    newEntry = rowEntry;
                    break;
                }
            }
        }

        if (newButton) {

            newButton.hidden = YES;
            self.modsOptionsDropdownButton = newButton;
            if (newEntry) self.modsOptionsDropdownEntry = newEntry;

            CGRect newButtonFrame = [newButton convertRect:newButton.bounds toView:self.contentOverlay];
            CGRect currentFrame = self.modsOptionsDropdownOverlay.frame;
            CGFloat dx = CGRectGetMaxX(newButtonFrame) - CGRectGetMaxX(currentFrame);
            CGFloat dy = CGRectGetMinY(newButtonFrame) - CGRectGetMinY(currentFrame);
            if (dx != 0 || dy != 0) {
                self.modsOptionsDropdownOverlay.frame = CGRectOffset(currentFrame, dx, dy);
            }
        } else {

            [self zs_closeModsOptionsDropdownAnimated:NO];
        }
    }

    BOOL processedExpanded = [self.modsLibraryExpandedFolders containsObject:kZSProcessedBundlesFolderName];
    UIView *processedFolderRow = zs_make_mods_folder_row(kZSProcessedBundlesFolderName,
        kZSProcessedBundlesFolderSubtext, processedExpanded, self,
        @selector(zs_modsLibraryFolderRowTapped:), NULL);
    [self.modsLibraryStack addArrangedSubview:processedFolderRow];

    if (!processedExpanded) return;

    if (self.processedBundlesLoading) {
        UILabel *loading = [[UILabel alloc] init];
        loading.text = @"  Loading\u2026";
        loading.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        loading.textColor = [UIColor colorWithWhite:1 alpha:0.4];
        [self.modsLibraryStack addArrangedSubview:loading];
        return;
    }

    if (self.processedBundlesErrorMessage.length > 0) {
        UILabel *errorLabel = [[UILabel alloc] init];
        errorLabel.text = [NSString stringWithFormat:@"  %@", self.processedBundlesErrorMessage];
        errorLabel.numberOfLines = 0;
        errorLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        errorLabel.textColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:0.85];
        [self.modsLibraryStack addArrangedSubview:errorLabel];
        return;
    }

    if (self.processedBundlesReleases.count == 0) {
        UILabel *emptyFolder = [[UILabel alloc] init];
        emptyFolder.text = @"  No processed bundles yet.";
        emptyFolder.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        emptyFolder.textColor = [UIColor colorWithWhite:1 alpha:0.4];
        [self.modsLibraryStack addArrangedSubview:emptyFolder];
        return;
    }

    for (ZTranscoderProcessedRelease *release in self.processedBundlesReleases) {
        BOOL releaseExpanded = [self.modsLibraryExpandedProcessedBundles containsObject:release.tagName];
        UIView *releaseRow = zs_make_processed_bundle_row(release, self, @selector(zs_processedBundleRowTapped:));
        [self.modsLibraryStack addArrangedSubview:releaseRow];

        if (releaseExpanded) {
            BOOL installInFlight = [self.processedBundleInstallInFlight containsObject:release.tagName];
            UIView *releaseInfoPanel = zs_make_processed_bundle_info_panel(release, installInFlight, self,
                @selector(zs_processedBundleInstallTapped:));
            [self.modsLibraryStack addArrangedSubview:releaseInfoPanel];
        }
    }
}

- (void)zs_modsLibraryFolderRowTapped:(UITapGestureRecognizer *)gesture {
    NSString *folderName = objc_getAssociatedObject(gesture.view, "zs_modsFolderName");
    if (!folderName) return;
    BOOL wasExpanded = [self.modsLibraryExpandedFolders containsObject:folderName];
    if (wasExpanded) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
    } else {
        [self.modsLibraryExpandedFolders addObject:folderName];
    }
    [self zs_rebuildModsLibrary];

    if (!wasExpanded && [folderName isEqualToString:kZSProcessedBundlesFolderName]) {
        [self zs_fetchProcessedBundles];
    }
}

- (void)zs_fetchProcessedBundles {
    self.processedBundlesLoading = YES;
    self.processedBundlesErrorMessage = nil;
    [self zs_rebuildModsLibrary];

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        self.processedBundlesLoading = NO;
        self.processedBundlesErrorMessage = @"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first.";
        [self zs_rebuildModsLibrary];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService listProcessedReleasesForConfig:config
        completion:^(NSArray<ZTranscoderProcessedRelease *> * _Nullable releases, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.processedBundlesLoading = NO;
        if (!releases) {
            strongSelf.processedBundlesErrorMessage = error.localizedDescription ?: @"Couldn't load processed bundles.";
            strongSelf.processedBundlesReleases = nil;
        } else {
            strongSelf.processedBundlesErrorMessage = nil;
            strongSelf.processedBundlesReleases = releases;
        }

        [strongSelf zs_rebuildModsLibrary];
    }];
}

- (void)zs_processedBundleRowTapped:(UITapGestureRecognizer *)gesture {
    ZTranscoderProcessedRelease *release = objc_getAssociatedObject(gesture.view, "zs_processedRelease");
    if (!release) return;
    if ([self.modsLibraryExpandedProcessedBundles containsObject:release.tagName]) {
        [self.modsLibraryExpandedProcessedBundles removeObject:release.tagName];
    } else {
        [self.modsLibraryExpandedProcessedBundles addObject:release.tagName];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_processedBundleInstallTapped:(UIButton *)sender {
    ZTranscoderProcessedRelease *release = objc_getAssociatedObject(sender, "zs_processedRelease");
    if (!release) return;

    if (!self.processedBundleInstallInFlight) self.processedBundleInstallInFlight = [NSMutableSet set];
    if ([self.processedBundleInstallInFlight containsObject:release.tagName]) return;

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    __weak typeof(self) weakSelf = self;
    [self zs_pickModsLibraryFolderForInstallWithCompletion:^(NSString *folderName) {
        [weakSelf zs_installProcessedBundleRelease:release intoFolder:folderName config:config];
    }];
}

- (void)zs_pickModsLibraryFolderForInstallWithCompletion:(void (^)(NSString *chosenFolder))completion {
    NSMutableArray<NSString *> *pickable = [[ModAssetLibrary folderNames] mutableCopy];
    [pickable removeObject:kZSStoredBundlesFolderName];

    void (^createAndContinue)(void) = ^{
        [self zs_promptForModFolderNameWithTitle:@"New Folder"
                                      actionTitle:@"Create & Install"
                                       completion:^(NSString *trimmedName) {
            NSError *createErr = nil;
            if (![ModAssetLibrary createFolderNamed:trimmedName error:&createErr]) {
                [self zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:createErr.localizedDescription ?: @"Unknown error."];
                return;
            }
            completion(trimmedName);
        }];
    };

    if (pickable.count == 0) {
        createAndContinue();
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Install Into Which Folder?"
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *candidate in pickable) {
        [sheet addAction:[UIAlertAction actionWithTitle:candidate style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            completion(candidate);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"New Folder\u2026" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        createAndContinue();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)zs_installProcessedBundleRelease:(ZTranscoderProcessedRelease *)release intoFolder:(NSString *)folderName config:(ZTranscoderConfig *)config {
    if ([self.processedBundleInstallInFlight containsObject:release.tagName]) return;
    [self.processedBundleInstallInFlight addObject:release.tagName];
    [self zs_rebuildModsLibrary];

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService downloadProcessedRelease:release config:config
        progress:nil
        completion:^(NSURL * _Nullable bundleURL, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!bundleURL) {
            [strongSelf.processedBundleInstallInFlight removeObject:release.tagName];
            UINotificationFeedbackGenerator *errHaptic = [UINotificationFeedbackGenerator new];
            [errHaptic notificationOccurred:UINotificationFeedbackTypeError];
            [strongSelf zs_presentModsAlertWithTitle:@"Download Failed"
                                              message:error.localizedDescription ?: @"Unknown error."];
            [strongSelf zs_rebuildModsLibrary];
            return;
        }
        [strongSelf zs_importAndInstallDownloadedProcessedBundleAtURL:bundleURL release:release intoFolder:folderName];
    }];
}

- (void)zs_importAndInstallDownloadedProcessedBundleAtURL:(NSURL *)bundleURL release:(ZTranscoderProcessedRelease *)release intoFolder:(NSString *)folderName {
    NSError *beforeErr = nil;
    NSSet<NSString *> *pathsBefore = [NSSet setWithArray:
        [[ModAssetLibrary entriesInFolder:folderName error:&beforeErr] valueForKey:@"path"] ?: @[]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *importError = nil;
        NSArray<NSString *> *rejectedFileLines = nil;
        BOOL imported = [ModAssetLibrary importFileURLs:@[bundleURL] intoFolder:folderName rejectedFileLines:&rejectedFileLines error:&importError];

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!imported) {
                [strongSelf.processedBundleInstallInFlight removeObject:release.tagName];
                UINotificationFeedbackGenerator *errHaptic = [UINotificationFeedbackGenerator new];
                [errHaptic notificationOccurred:UINotificationFeedbackTypeError];

                NSString *failureMessage = rejectedFileLines.firstObject ?: (importError.localizedDescription ?: @"Unknown error.");
                [strongSelf zs_presentModsAlertWithTitle:@"Import Failed"
                                                  message:failureMessage];
                [strongSelf zs_rebuildModsLibrary];
                return;
            }

            NSError *afterErr = nil;
            NSArray<ModAssetLibraryEntry *> *afterEntries = [ModAssetLibrary entriesInFolder:folderName error:&afterErr] ?: @[];
            ModAssetLibraryEntry *newEntry = nil;
            for (ModAssetLibraryEntry *candidate in afterEntries) {
                if (![pathsBefore containsObject:candidate.path]) { newEntry = candidate; break; }
            }
            if (!newEntry) {
                ZLog(@"[Mods Library] imported processed release %@ into \"%@\" but couldn't find its new entry afterward.", release.tagName, folderName);
                [strongSelf.processedBundleInstallInFlight removeObject:release.tagName];
                [strongSelf zs_rebuildModsLibrary];
                return;
            }

            [strongSelf.processedBundleInstallInFlight removeObject:release.tagName];
            [strongSelf zs_rebuildModsLibrary];
            [strongSelf zs_doctorInstallUsingKnownTargetForDoctoredURL:bundleURL entryPath:newEntry.path inFolder:folderName];
        });
    });
}

- (void)zs_modsLibraryEntryInfoTapped:(UITapGestureRecognizer *)gesture {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(gesture.view, "zs_modsEntry");
    if (!entry) return;
    if ([self.modsLibraryExpandedInfoEntries containsObject:entry.path]) {
        [self.modsLibraryExpandedInfoEntries removeObject:entry.path];
    } else {
        [self.modsLibraryExpandedInfoEntries addObject:entry.path];
    }
    [self zs_rebuildModsLibrary];
}

#pragma mark Mods Library file options dropdown (3.4)

- (void)zs_modsLibraryEntryOptionsTapped:(UIButton *)sender {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;

    if (self.modsOptionsDropdownOpen && self.modsOptionsDropdownButton == sender) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }
    if (self.modsOptionsDropdownOpen) {
        [self zs_closeModsOptionsDropdownAnimated:NO];
    }

    [self zs_openModsOptionsDropdownForButton:sender entry:entry folderName:zs_mods_folder_name_for_entry(entry)];
}

- (void)zs_modsLibraryFolderOptionsTapped:(UIButton *)sender {
    NSString *folderName = objc_getAssociatedObject(sender, "zs_modsFolderName");
    if (!folderName) return;

    if (self.modsOptionsDropdownOpen && self.modsOptionsDropdownButton == sender) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }
    if (self.modsOptionsDropdownOpen) {
        [self zs_closeModsOptionsDropdownAnimated:NO];
    }

    [self zs_openModsOptionsDropdownForButton:sender entry:nil folderName:folderName];
}

- (void)zs_openModsOptionsDropdownForButton:(UIButton *)button entry:(nullable ModAssetLibraryEntry *)entry folderName:(NSString *)folderName {
    if (!button || !self.contentOverlay || self.modsOptionsDropdownOpen || !folderName) return;

    BOOL isStoredBundlesRow = entry && [folderName isEqualToString:kZSStoredBundlesFolderName];
    NSArray<NSDictionary<NSString *, id> *> *options = entry
        ? (isStoredBundlesRow ? zs_mods_stored_bundle_file_options() : zs_mods_file_options())
        : zs_mods_folder_options();
    if (options.count == 0) return;

    CGRect buttonFrame = [button convertRect:button.bounds toView:self.contentOverlay];

    CGRect collapsedFrame = CGRectMake(CGRectGetMaxX(buttonFrame) - kZSModsOptionsDropdownWidth,
                                        CGRectGetMinY(buttonFrame),
                                        kZSModsOptionsDropdownWidth,
                                        CGRectGetHeight(buttonFrame));

    UIControl *scrim = [[UIControl alloc] initWithFrame:self.contentOverlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_modsOptionsDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentOverlay addSubview:scrim];
    self.modsOptionsDropdownScrim = scrim;

    UIView *overlay;
    UIVisualEffectView *glassOverlay = nil;
    if (zs_has_liquid_glass()) {
        glassOverlay = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        glassOverlay.frame = collapsedFrame;
        glassOverlay.clipsToBounds = YES;
        zs_configure_glass_corners(glassOverlay, kZSAuthFieldCornerRadius, NO);
        glassOverlay.layer.borderWidth = 1;
        glassOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        overlay = glassOverlay;
    } else {
        overlay = [[UIView alloc] initWithFrame:collapsedFrame];
        overlay.clipsToBounds = YES;
        overlay.layer.cornerRadius = kZSAuthFieldCornerRadius;
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
        overlay.layer.borderWidth = 1;
        overlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        overlay.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    [self.contentOverlay addSubview:overlay];
    self.modsOptionsDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        UIButton *rowButton = zs_make_mods_options_row_button(options[i], i, self,
                                                                @selector(zs_modsOptionsDropdownRowTapped:));
        rowButton.frame = CGRectMake(0, i * kZSModsOptionsRowHeight,
                                      kZSModsOptionsDropdownWidth, kZSModsOptionsRowHeight);
        rowButton.alpha = 0;
        [rowHost addSubview:rowButton];

        if (i > 0) {
            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * kZSModsOptionsRowHeight - hairline,
                                                                        kZSModsOptionsDropdownWidth, hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    button.hidden = YES;
    self.modsOptionsDropdownButton = button;
    self.modsOptionsDropdownEntry = entry;
    self.modsOptionsDropdownFolderName = folderName;
    self.modsOptionsDropdownOpen = YES;

    CGFloat expandedHeight = kZSModsOptionsRowHeight * options.count;
    CGRect expandedFrame = CGRectMake(CGRectGetMinX(collapsedFrame), CGRectGetMinY(collapsedFrame),
                                       kZSModsOptionsDropdownWidth, expandedHeight);
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.frame = expandedFrame;
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeModsOptionsDropdownAnimated:(BOOL)animated {
    if (!self.modsOptionsDropdownOpen) return;

    UIView *overlay = self.modsOptionsDropdownOverlay;
    UIControl *scrim = self.modsOptionsDropdownScrim;
    UIButton *button = self.modsOptionsDropdownButton;
    self.modsOptionsDropdownOverlay = nil;
    self.modsOptionsDropdownScrim = nil;
    self.modsOptionsDropdownButton = nil;
    self.modsOptionsDropdownEntry = nil;
    self.modsOptionsDropdownFolderName = nil;
    self.modsOptionsDropdownOpen = NO;

    if (!button || !button.superview) {
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        return;
    }

    CGRect collapsedFrame = [button convertRect:button.bounds toView:self.contentOverlay];
    CGRect collapsedDropdownFrame = CGRectMake(CGRectGetMaxX(collapsedFrame) - kZSModsOptionsDropdownWidth,
                                                CGRectGetMinY(collapsedFrame),
                                                kZSModsOptionsDropdownWidth,
                                                CGRectGetHeight(collapsedFrame));

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        button.hidden = NO;
    };

    if (!animated) {
        finish();
        return;
    }

    UIView *rowHost = [overlay isKindOfClass:[UIVisualEffectView class]]
        ? ((UIVisualEffectView *)overlay).contentView
        : overlay;
    for (UIView *subview in rowHost.subviews) {
        subview.alpha = 0;
    }

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.frame = collapsedDropdownFrame;
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_modsOptionsDropdownRowTapped:(UIButton *)sender {
    ModAssetLibraryEntry *entry = self.modsOptionsDropdownEntry;
    NSString *folderName = self.modsOptionsDropdownFolderName;
    BOOL isFolderMode = (entry == nil);
    BOOL isStoredBundlesRow = !isFolderMode && [folderName isEqualToString:kZSStoredBundlesFolderName];
    NSArray<NSDictionary<NSString *, id> *> *options = isFolderMode ? zs_mods_folder_options()
        : (isStoredBundlesRow ? zs_mods_stored_bundle_file_options() : zs_mods_file_options());
    if (sender.tag < 0 || sender.tag >= (NSInteger)options.count) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }

    [self zs_closeModsOptionsDropdownAnimated:YES];
    if (!folderName) return;
    if (!isFolderMode && !entry) return;

    NSString *title = options[sender.tag][@"title"];

    if (isFolderMode) {
        if ([title isEqualToString:@"Add mod"]) {
            [self zs_presentModImportPickerForFolder:folderName];
        } else if ([title isEqualToString:@"Rename"]) {
            [self zs_promptForModFolderRenameForFolder:folderName];
        } else if ([title isEqualToString:@"Cache folder"]) {
            [self zs_cacheModFolder:folderName];
        } else if ([title isEqualToString:@"Add remark"]) {
            [self zs_promptForModFolderRemarkForFolder:folderName];
        } else if ([title isEqualToString:@"Delete"]) {
            [self zs_confirmDeleteModFolder:folderName];
        }
        return;
    }

    if ([title isEqualToString:@"Cache bundle"]) {
        [self zs_cacheBundleEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Restore"]) {
        [self zs_restoreStoredBundleEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Add remark"]) {
        [self zs_promptForModRemarkForEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Delete"]) {
        [self zs_confirmDeleteModEntry:entry inFolder:folderName];
    }
}

- (void)zs_modsOptionsDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeModsOptionsDropdownAnimated:YES];
}

static NSURL *zs_mods_live_stock_url_for_entry(ModAssetLibraryEntry *entry) {
    if (entry.livePathDescription.length == 0) return nil;
    NSString *absolute = [NSHomeDirectory() stringByAppendingPathComponent:entry.livePathDescription];
    return [NSURL fileURLWithPath:absolute];
}

- (BOOL)zs_cacheBundleEntryCore:(ModAssetLibraryEntry *)entry
                        inFolder:(NSString *)folderName
                    partlyFailed:(BOOL *)outPartlyFailed
                           error:(NSError **)outError {
    if (outPartlyFailed) *outPartlyFailed = NO;
    BOOL isLiveInstalledBundle = entry.isAssetBundle && entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled;

    NSURL *stockURL = isLiveInstalledBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;
    if (isLiveInstalledBundle && !stockURL) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsCache" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This entry's live location isn't known."}];
        return NO;
    }

    NSString *tempPath = nil;
    NSURL *replacementBytesURL = nil;
    if (stockURL) {

        tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSError *snapshotErr = nil;
        BOOL scoped = [stockURL startAccessingSecurityScopedResource];
        BOOL snapshotted = [NSFileManager.defaultManager copyItemAtURL:stockURL toURL:[NSURL fileURLWithPath:tempPath] error:&snapshotErr];
        if (scoped) [stockURL stopAccessingSecurityScopedResource];
        if (!snapshotted) {
            if (outError) *outError = snapshotErr ?: [NSError errorWithDomain:@"ZSModsCache" code:2
                                                                       userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the live bundle."}];
            return NO;
        }

        NSError *cacheErr = nil;
        if (![ZTranscoderInstaller cacheOriginalBackForStockBundleURL:stockURL error:&cacheErr]) {
            [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
            if (outError) *outError = cacheErr ?: [NSError errorWithDomain:@"ZSModsCache" code:3
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown error."}];
            return NO;
        }
        replacementBytesURL = [NSURL fileURLWithPath:tempPath];
    }

    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:kZSStoredBundlesFolderName error:&createErr]
        && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        if (tempPath) [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
        if (outError) *outError = createErr ?: [NSError errorWithDomain:@"ZSModsCache" code:4
                                                                  userInfo:@{NSLocalizedDescriptionKey: @"Couldn't prepare Stored Bundles."}];
        return NO;
    }

    entry.cachedFromFolder = folderName;
    NSError *moveErr = nil;
    ModAssetLibraryEntry *moved = [ModAssetLibrary moveEntry:entry
                                                    fromFolder:folderName
                                                      toFolder:kZSStoredBundlesFolderName
                                           replacementBytesURL:replacementBytesURL
                                                         error:&moveErr];
    if (tempPath) [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
    if (!moved) {

        ZLog(@"[Mods Library] couldn't move %@ into Stored Bundles: %@", entry.fileName, moveErr.localizedDescription);
        if (outPartlyFailed) *outPartlyFailed = (replacementBytesURL != nil);
        if (outError) *outError = moveErr ?: [NSError errorWithDomain:@"ZSModsCache" code:5
                                                                userInfo:@{NSLocalizedDescriptionKey: @"The entry couldn't be moved into Stored Bundles."}];
        return NO;
    }

    return YES;
}

- (void)zs_cacheBundleEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    BOOL partlyFailed = NO;
    NSError *error = nil;
    BOOL ok = [self zs_cacheBundleEntryCore:entry inFolder:folderName partlyFailed:&partlyFailed error:&error];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:partlyFailed ? @"Store Partly Failed" : @"Store Failed"
                                    message:partlyFailed
                                        ? @"The live bundle was restored, but the entry couldn't be moved into Stored Bundles. See syslog."
                                        : (error.localizedDescription ?: @"Unknown error.")];
        [self zs_rebuildModsLibrary];
        return;
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self zs_rebuildModsLibrary];
}

- (void)zs_cacheModFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    if (entries.count == 0) {
        [self zs_presentModsAlertWithTitle:@"Nothing to Cache" message:@"This folder has no mods in it."];
        return;
    }

    NSInteger failureCount = 0;
    BOOL anyPartlyFailed = NO;
    for (ModAssetLibraryEntry *entry in entries) {
        BOOL partlyFailed = NO;
        NSError *error = nil;
        BOOL ok = [self zs_cacheBundleEntryCore:entry inFolder:folderName partlyFailed:&partlyFailed error:&error];
        if (!ok) {
            failureCount++;
            if (partlyFailed) anyPartlyFailed = YES;
            ZLog(@"[Mods Library] Cache folder %@: couldn't cache %@: %@", folderName, entry.fileName, error.localizedDescription);
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:failureCount == 0 ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (failureCount > 0) {
        NSString *message = [NSString stringWithFormat:@"%ld of %ld mod%@ couldn't be moved into Stored Bundles.%@ See syslog.",
                              (long)failureCount, (long)entries.count, entries.count == 1 ? @"" : @"s",
                              anyPartlyFailed ? @" Some live bundles were already restored before the move failed." : @""];
        [self zs_presentModsAlertWithTitle:@"Cache Folder Partly Failed" message:message];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_restoreStoredBundleEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSURL *stockURL = entry.isAssetBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;

    NSArray<NSString *> *realFolders = [[ModAssetLibrary folderNames] mutableCopy];
    NSString *targetFolder = entry.cachedFromFolder;
    BOOL targetStillExists = targetFolder.length > 0 && [realFolders containsObject:targetFolder];
    if (targetStillExists) {
        [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:targetFolder];
        return;
    }

    NSMutableArray<NSString *> *pickable = [realFolders mutableCopy];
    [pickable removeObject:kZSStoredBundlesFolderName];

    if (pickable.count == 0) {
        [self zs_promptForModFolderNameWithTitle:@"Choose a Folder"
                                      actionTitle:@"Create & Restore"
                                       completion:^(NSString *trimmedName) {
            NSError *createErr = nil;
            if (![ModAssetLibrary createFolderNamed:trimmedName error:&createErr]) {
                [self zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:createErr.localizedDescription ?: @"Unknown error."];
                return;
            }
            [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:trimmedName];
        }];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Restore Into Which Folder?"
                                                                      message:[NSString stringWithFormat:@"\"%@\" no longer exists.", targetFolder ?: @"its original folder"]
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *candidate in pickable) {
        [sheet addAction:[UIAlertAction actionWithTitle:candidate style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:candidate];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)zs_finishRestoringStoredBundleEntry:(ModAssetLibraryEntry *)entry stockURL:(nullable NSURL *)stockURL intoFolder:(NSString *)destFolder {
    if (stockURL) {
        NSError *installErr = nil;
        if (![ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                              toStockBundleURL:stockURL
                                                          error:&installErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:installErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    entry.cachedFromFolder = nil;
    NSError *moveErr = nil;
    ModAssetLibraryEntry *moved = [ModAssetLibrary moveEntry:entry
                                                    fromFolder:kZSStoredBundlesFolderName
                                                      toFolder:destFolder
                                           replacementBytesURL:nil
                                                         error:&moveErr];
    if (!moved) {
        ZLog(@"[Mods Library] restored %@'s live file but couldn't move its library entry back into \"%@\": %@", entry.fileName, destFolder, moveErr.localizedDescription);
        [self zs_presentModsAlertWithTitle:@"Restore Partly Failed"
                                    message:@"The live bundle was restored, but the entry couldn't be moved out of Stored Bundles. See syslog."];
        [self zs_rebuildModsLibrary];
        return;
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self zs_rebuildModsLibrary];
}

- (void)zs_presentFloatingTextFieldWithInitialText:(NSString *)initialText
                                        placeholder:(NSString *)placeholder
                                             secure:(BOOL)secure
                                         completion:(void (^)(NSString * _Nullable trimmedText))completion {
    UIWindow *window = zs_key_window();
    if (!window) return;
    if (self.zsFloatingField) {
        [self zs_commitFloatingFieldSaving:YES];
    }

    self.zsFloatingFieldCompletion = completion;

    UIView *backdrop = [[UIView alloc] init];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = UIColor.clearColor;
    backdrop.userInteractionEnabled = YES;
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_floatingFieldBackdropTapped)]];
    [window addSubview:backdrop];
    self.zsFloatingFieldBackdrop = backdrop;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:window.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:window.bottomAnchor],
    ]];

    UITextField *field = [[UITextField alloc] init];
    field.text = initialText;
    field.placeholder = placeholder;
    field.secureTextEntry = secure;
    field.textColor = UIColor.whiteColor;
    field.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    field.returnKeyType = UIReturnKeyDone;
    field.autocapitalizationType = secure ? UITextAutocapitalizationTypeNone : UITextAutocapitalizationTypeSentences;
    field.autocorrectionType = secure ? UITextAutocorrectionTypeNo : UITextAutocorrectionTypeDefault;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    self.zsFloatingField = field;

    UIVisualEffectView *glass = zs_wrap_field_in_native_glass(field, 6);
    UIView *container = glass ?: field;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:container];
    [window bringSubviewToFront:container];
    self.zsFloatingFieldContainer = container;

    container.alpha = 0;
    NSLayoutConstraint *bottom = [container.bottomAnchor constraintEqualToAnchor:window.bottomAnchor constant:-8];
    self.zsFloatingFieldBottomConstraint = bottom;
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:16],
        [container.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-16],
        bottom,
        [container.heightAnchor constraintEqualToConstant:44],
    ]];

    CGFloat bottomInset = window.safeAreaInsets.bottom + 291;
    if (!CGRectIsEmpty(self.zs_lastKeyboardFrame)) {
        CGFloat inset = CGRectGetHeight(window.bounds) - CGRectGetMinY(self.zs_lastKeyboardFrame);
        if (inset >= 8) bottomInset = inset;
    }
    bottom.constant = -(bottomInset + 8);
    [window layoutIfNeeded];

    [UIView animateWithDuration:0.15 animations:^{
        container.alpha = 1;
    }];

    [field becomeFirstResponder];
}

- (void)zs_commitFloatingFieldSaving:(BOOL)saving {
    void (^completion)(NSString * _Nullable) = self.zsFloatingFieldCompletion;
    NSString *trimmed = [(self.zsFloatingField.text ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    UIView *backdrop = self.zsFloatingFieldBackdrop;
    UIView *container = self.zsFloatingFieldContainer;
    self.zsFloatingFieldBackdrop = nil;
    self.zsFloatingFieldContainer = nil;
    self.zsFloatingField = nil;
    self.zsFloatingFieldBottomConstraint = nil;
    self.zsFloatingFieldCompletion = nil;

    [UIView animateWithDuration:0.15 animations:^{
        backdrop.alpha = 0;
        container.alpha = 0;
    } completion:^(BOOL finished) {
        [backdrop removeFromSuperview];
        [container removeFromSuperview];
    }];

    if (saving && completion) {
        completion(trimmed.length > 0 ? trimmed : nil);
    }
}

- (void)zs_commitFloatingField {
    [self zs_commitFloatingFieldSaving:YES];
}

- (void)zs_floatingFieldBackdropTapped {
    [self.zsFloatingField resignFirstResponder];
}

- (void)zs_promptForModRemarkForEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    if (!entry) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:entry.remark
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_saveModRemark:trimmedText forEntry:entry inFolder:folderName];
    }];
}

- (void)zs_saveModRemark:(nullable NSString *)remark forEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.remark = remark;
    }
                                                                           error:&error];
    if (!updated) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Save Remark" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_confirmDeleteModEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete File?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D will be removed from the Mod Asset Library and the original will be restored in the game's files.", entry.fileName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_deleteModEntryConfirmed:entry inFolder:folderName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_promptForModFolderRenameForFolder:(NSString *)folderName {
    __weak typeof(self) weakSelf = self;
    [self zs_promptForModFolderNameWithTitle:@"Rename Folder"
                                  actionTitle:@"Rename"
                                   completion:^(NSString *trimmedName) {
        [weakSelf zs_renameModFolder:folderName to:trimmedName];
    }];
}

- (void)zs_renameModFolder:(NSString *)folderName to:(NSString *)newName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary renameFolderNamed:folderName to:newName error:&error];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Rename Folder" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }

    if ([self.modsLibraryExpandedFolders containsObject:folderName]) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
        [self.modsLibraryExpandedFolders addObject:newName];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_promptForModFolderRemarkForFolder:(NSString *)folderName {
    if (!folderName) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:[ModAssetLibrary remarkForFolder:folderName]
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_saveModFolderRemark:trimmedText forFolder:folderName];
    }];
}

- (void)zs_saveModFolderRemark:(nullable NSString *)remark forFolder:(NSString *)folderName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary setRemark:remark forFolder:folderName error:&error];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Save Remark" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_confirmDeleteModFolder:(NSString *)folderName {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Folder?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D and every mod inside it will be removed. Each mod's original will be restored in the game's files first.", folderName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_deleteModFolderConfirmed:folderName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_modsLibraryEntryDownloadTapped:(UIButton *)sender {

    if (self.authCredentialsStale) {
        UINotificationFeedbackGenerator *errorHaptic = [UINotificationFeedbackGenerator new];
        [errorHaptic notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Download tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
    if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) return;

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    ZTranscoderHandle *handle = [ZTranscoderHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": entry.doctorScratchBranch ?: @"",
        @"runID": entry.doctorRunID ?: @"",
        @"runURL": entry.doctorRunURL ?: @"",
    }];
    if (!handle) {
        [self zs_presentModsAlertWithTitle:@"Can't Download"
                                    message:@"Lost track of this submission's scratch branch - try Retry to send it again."];
        return;
    }

    NSString *entryPath = entry.path;
    [self.doctorDownloadInFlightPaths addObject:entryPath];
    [self.doctorDownloadProgressLastBytes removeObjectForKey:entryPath];
    NSError *resetError = nil;
    [ModAssetLibrary updateDoctorStateForEntry:entry inFolder:folderName applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorDownloadProgress = 0;
    } error:&resetError];
    [self zs_rebuildModsLibrary];

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService fetchDoctoredBundleForHandle:handle config:config
        progress:^(int64_t bytesWritten) {
            [weakSelf zs_doctorHandleDownloadProgress:bytesWritten forEntryPath:entryPath inFolder:folderName];
        }
        completion:^(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!doctoredBundleURL) {
            [strongSelf zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:error];
            return;
        }
        [strongSelf zs_doctorInstallUsingKnownTargetForDoctoredURL:doctoredBundleURL entryPath:entryPath inFolder:folderName];
    }];
}

- (void)zs_doctorHandleDownloadProgress:(int64_t)bytesWritten forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorDownloadProgressLastBytes) self.doctorDownloadProgressLastBytes = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorDownloadProgressLastBytes[entryPath];
    if (last && llabs(bytesWritten - last.longLongValue) < kZSDoctorProgressByteThreshold) return;
    self.doctorDownloadProgressLastBytes[entryPath] = @(bytesWritten);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorDownloadProgress = bytesWritten;
    }
                                                                           error:&error];
    if (!updated) return;
    [self zs_rebuildModsLibrary];
}

- (void)zs_doctorDownloadFailedForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self.doctorDownloadInFlightPaths removeObject:entryPath];
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeError];
    [self zs_presentModsAlertWithTitle:@"Download Failed"
                                message:error.localizedDescription ?: @"Unknown error."];
    [self zs_rebuildModsLibrary];
}

- (void)zs_doctorInstallUsingKnownTargetForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    ModAssetLibraryEntry *entry = nil;
    for (ModAssetLibraryEntry *candidate in entries) {
        if ([candidate.path isEqualToString:entryPath]) { entry = candidate; break; }
    }

    NSString *relativeTarget = entry.resolvedInstallTargetPath;
    if (relativeTarget.length > 0) {
        NSString *absolute = [NSHomeDirectory() stringByAppendingPathComponent:relativeTarget];
        [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:absolute] entryPath:entryPath inFolder:folderName];
        return;
    }

    if (entry.zipCacheHash1.length > 0 && entry.zipCacheHash2.length > 0) {
        NSError *synthErr = nil;
        NSString *synthDir = [UnityCacheLocator synthesizeCacheDirectoryForHash1:entry.zipCacheHash1 hash2:entry.zipCacheHash2 error:&synthErr];
        if (synthDir) {
            NSString *synthDataPath = [synthDir stringByAppendingPathComponent:@"__data"];

            NSString *storedInfoPath = [entryPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"__info"];
            if ([NSFileManager.defaultManager fileExistsAtPath:storedInfoPath]) {
                [NSFileManager.defaultManager copyItemAtPath:storedInfoPath toPath:[synthDir stringByAppendingPathComponent:@"__info"] error:nil];
            }
            ZLog(@"[Mods Library] no import-time cache match for %@ - using SYNTHESIZED (unverified) target %@ from its Lunartique zip hash pair.",
                 entryPath.lastPathComponent, synthDataPath);
            [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:synthDataPath] entryPath:entryPath inFolder:folderName];
            return;
        }
        ZLog(@"[Mods Library] Lunartique cache-directory synthesis failed for %@: %@ - falling back to the manual picker.",
             entryPath.lastPathComponent, synthErr.localizedDescription);
    }

    ZLog(@"[Mods Library] no import-time cache match on file for %@ - falling back to the manual picker.", entryPath.lastPathComponent);
    [self zs_presentDoctorInstallTargetPickerForDoctoredURL:doctoredURL entryPath:entryPath inFolder:folderName];
}

- (void)zs_presentDoctorInstallTargetPickerForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (self.doctorInstallTargetPicker) {

        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                 code:ZTranscoderInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Another download is already waiting on a file pick - finish that one, then try this download again."}]];
        return;
    }

    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {

        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {

        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the doctor install target picker from");
        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                 code:ZTranscoderInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Couldn't present the file picker."}]];
        return;
    }

    self.doctorInstallTargetPicker = picker;
    self.doctorInstallPendingDoctoredURL = doctoredURL;
    self.doctorInstallPendingEntryPath = entryPath;
    self.doctorInstallPendingFolderName = folderName;

    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_doctorInstallDoctoredURL:(NSURL *)doctoredURL toStockBundleURL:(NSURL *)stockBundleURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {

    NSError *readErr = nil;
    NSData *doctoredData = [NSData dataWithContentsOfURL:doctoredURL options:0 error:&readErr];
    if (!doctoredData) {
        [self.doctorDownloadInFlightPaths removeObject:entryPath];
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Install Failed"
                                    message:readErr.localizedDescription ?: @"Couldn't read the doctored bundle."];
        [self zs_rebuildModsLibrary];
        return;
    }
    NSError *libraryWriteErr = nil;
    if (![doctoredData writeToFile:entryPath options:NSDataWritingAtomic error:&libraryWriteErr]) {
        [self.doctorDownloadInFlightPaths removeObject:entryPath];
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Install Failed"
                                    message:libraryWriteErr.localizedDescription ?: @"Couldn't update the mod library's own copy."];
        [self zs_rebuildModsLibrary];
        return;
    }

    NSError *installError = nil;
    BOOL installed = [ZTranscoderInstaller installDoctoredBundleAtURL:doctoredURL toStockBundleURL:stockBundleURL error:&installError];
    [self.doctorDownloadInFlightPaths removeObject:entryPath];

    if (!installed) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Install Failed"
                                    message:installError.localizedDescription ?: @"Unknown error."];
        [self zs_rebuildModsLibrary];
        return;
    }

    int32_t freshPlatform = 0;
    NSError *platformErr = nil;
    BOOL gotPlatform = [UnityBundleCAB targetPlatform:&freshPlatform forBundleAtPath:doctoredURL.path error:&platformErr];
    NSNumber *freshPlatformNumber = gotPlatform ? @(freshPlatform) : nil;
    if (!gotPlatform) {

        ZLog(@"[Mods Library] couldn't re-read target platform from the doctored bundle for %@, leaving the row's existing value: %@", entryPath.lastPathComponent, platformErr.localizedDescription);
    }
    NSDictionary<NSFileAttributeKey, id> *doctoredAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:doctoredURL.path error:nil];
    unsigned long long freshByteSize = doctoredAttrs.fileSize;

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *nowISO = [iso stringFromDate:[NSDate date]];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusInstalled;
        if (freshPlatformNumber) entryToMutate.targetPlatform = freshPlatformNumber;
        if (freshByteSize > 0) entryToMutate.byteSize = freshByteSize;
        entryToMutate.dateAdded = nowISO;

        entryToMutate.livePathDescription = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:stockBundleURL];

    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] installed %@ but couldn't record it as Installed on the manifest (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self zs_rebuildModsLibrary];
}

- (void)zs_restoreModEntryBestEffort:(ModAssetLibraryEntry *)entry {
    NSError *bankError = nil;
    [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&bankError];
    if (bankError) {
        ZLog(@"[Mods Library] couldn't restore %@ before removing it from the library: %@", entry.fileName, bankError.localizedDescription);
    }

    if (entry.isAssetBundle) {
        NSURL *stockURL = zs_mods_live_stock_url_for_entry(entry);
        if (stockURL) {
            NSError *bundleError = nil;
            BOOL restored = [ZTranscoderInstaller cacheOriginalBackForStockBundleURL:stockURL error:&bundleError];
            if (!restored) {
                ZLog(@"[Mods Library] couldn't restore %@'s live bundle at %@ before removing it from the library: %@", entry.fileName, stockURL.path, bundleError.localizedDescription);
            }
        }
    }
}

- (void)zs_handleHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (![button isKindOfClass:[UIButton class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.holdConfirmActiveButton = button;
            self.holdConfirmStartTime = CACurrentMediaTime();
            self.holdConfirmTriggered = NO;

            UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kZSHoldConfirmExpansionWidthKey);
            UILabel *deleteLabel = objc_getAssociatedObject(button, kZSHoldConfirmDeleteLabelKey);
            UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kZSHoldConfirmGlassViewKey);
            UIView *glassHost = objc_getAssociatedObject(button, kZSHoldConfirmGlassHostKey);

            widthConstraint.constant = kZSDeleteCapsuleExpandedWidth;
            [UIView animateWithDuration:kZSDeleteCapsuleSnapDuration
                                   delay:0
                  usingSpringWithDamping:kZSDeleteCapsuleSpringDamping
                   initialSpringVelocity:kZSDeleteCapsuleSpringVelocity
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
            self.holdConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_holdConfirmTick:)];
            [self.holdConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = nil;

            if (!self.holdConfirmTriggered) {

                [self zs_collapseHoldConfirmButton:button];

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

- (void)zs_holdConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kZSHoldConfirmDuration = 1.5;

    UIButton *button = self.holdConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    NSTimeInterval elapsed = CACurrentMediaTime() - self.holdConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kZSHoldConfirmDuration);

    UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kZSHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kZSHoldConfirmButtonFillKey);

    CGFloat expansionWidth = expansion.bounds.size.width;
    CGFloat buttonWidth = button.bounds.size.width;
    CGFloat filledWidth = (expansionWidth + buttonWidth) * pct;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    expansionFill.frame = CGRectMake(0, 0, MIN(filledWidth, expansionWidth), expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, MAX(0, filledWidth - expansionWidth), buttonWidth);
    [CATransaction commit];

    if (pct >= 1.0 && !self.holdConfirmTriggered) {
        self.holdConfirmTriggered = YES;
        [link invalidate];
        self.holdConfirmDisplayLink = nil;

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        void (^onConfirm)(void) = objc_getAssociatedObject(button, kZSHoldConfirmBlockKey);
        if (onConfirm) onConfirm();
    }
}

- (void)zs_collapseHoldConfirmButton:(UIButton *)button {
    UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kZSHoldConfirmExpansionWidthKey);
    UILabel *deleteLabel = objc_getAssociatedObject(button, kZSHoldConfirmDeleteLabelKey);
    UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kZSHoldConfirmGlassViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kZSHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kZSHoldConfirmButtonFillKey);

    widthConstraint.constant = 0;
    [UIView animateWithDuration:kZSDeleteCapsuleSnapDuration
                           delay:0
          usingSpringWithDamping:kZSDeleteCapsuleSpringDamping
           initialSpringVelocity:kZSDeleteCapsuleSpringVelocity
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

- (void)zs_handlePillHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (![button isKindOfClass:[UIButton class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.pillHoldConfirmActiveButton = button;
            self.pillHoldConfirmStartTime = CACurrentMediaTime();
            self.pillHoldConfirmTriggered = NO;

            CALayer *fill = objc_getAssociatedObject(button, kZSPillHoldConfirmFillLayerKey);
            if (!fill) {
                fill = [CALayer layer];
                fill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
                fill.anchorPoint = CGPointMake(0, 0);
                fill.cornerRadius = button.bounds.size.height / 2.0;
                fill.cornerCurve = kCACornerCurveContinuous;
                [button.layer insertSublayer:fill atIndex:0];
                objc_setAssociatedObject(button, kZSPillHoldConfirmFillLayerKey, fill, OBJC_ASSOCIATION_RETAIN);
            }

            [self.pillHoldConfirmDisplayLink invalidate];
            self.pillHoldConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_pillHoldConfirmTick:)];
            [self.pillHoldConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.pillHoldConfirmDisplayLink invalidate];
            self.pillHoldConfirmDisplayLink = nil;

            if (!self.pillHoldConfirmTriggered) {
                [self zs_resetPillHoldConfirmFillForButton:button];

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

- (void)zs_resetPillHoldConfirmFillForButton:(UIButton *)button {
    CALayer *fill = objc_getAssociatedObject(button, kZSPillHoldConfirmFillLayerKey);
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    fill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
    fill.cornerRadius = button.bounds.size.height / 2.0;
    [CATransaction commit];
}

- (void)zs_pillHoldConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kZSPillHoldConfirmDuration = 1.5;

    UIButton *button = self.pillHoldConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    NSNumber *durationOverride = objc_getAssociatedObject(button, kZSPillHoldConfirmDurationKey);
    NSTimeInterval duration = durationOverride ? durationOverride.doubleValue : kZSPillHoldConfirmDuration;

    NSTimeInterval elapsed = CACurrentMediaTime() - self.pillHoldConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / duration);

    CALayer *fill = objc_getAssociatedObject(button, kZSPillHoldConfirmFillLayerKey);
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

        void (^onConfirm)(void) = objc_getAssociatedObject(button, kZSPillHoldConfirmBlockKey);
        if (onConfirm) onConfirm();

        [self zs_resetPillHoldConfirmFillForButton:button];
    }
}

- (void)zs_deleteModEntryConfirmed:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    [self zs_restoreModEntryBestEffort:entry];

    NSError *error = nil;
    BOOL ok = [ModAssetLibrary removeEntry:entry fromFolder:folderName error:&error];
    [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Remove File" message:error.localizedDescription ?: @"Unknown error."];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_deleteModFolderConfirmed:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    for (ModAssetLibraryEntry *entry in entries) {
        [self zs_restoreModEntryBestEffort:entry];
    }

    NSError *deleteErr = nil;
    BOOL ok = [ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr];

    [self.modsLibraryExpandedFolders removeObject:folderName];
    for (ModAssetLibraryEntry *entry in entries) [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Delete Folder" message:deleteErr.localizedDescription ?: @"Unknown error."];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_presentModImportPickerForFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the file picker from");
        return;
    }
    self.libraryImportPicker = picker;
    self.libraryImportTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_handlePickedLibraryImportURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    [self zs_handleLoadModsPickedURLs:urls intoFolder:folderName];
}

#pragma mark Syslog

- (void)toggleSyslogTapped {

    if (self.syslogHoldTriggered) {
        self.syslogHoldTriggered = NO;
        return;
    }

    if (self.syslogVerboseEnabled) {
        [self zs_resetSyslogVerboseMode];
        return;
    }

    self.syslogTabEnabled = !self.syslogTabEnabled;
    self.syslogHandle.hidden = !self.syslogTabEnabled;
    self.syslogHandleGlass.hidden = !self.syslogTabEnabled;

    if (!self.syslogTabEnabled) {
        [self stopSyslog];
    }

    UIWindow *window = zs_key_window();
    if (window) {
        [self layoutPanelForWindow:window];
    }

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)handleSyslogButtonLongPress:(UILongPressGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.syslogHoldStartTime = CACurrentMediaTime();
            self.syslogHoldTriggered = NO;

            if (!self.syslogButtonFillLayer) {
                CALayer *fill = [CALayer layer];

                fill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
                fill.anchorPoint = CGPointMake(0, 0);

                fill.cornerRadius = kZSAuthFieldCornerRadius;
                fill.cornerCurve = kCACornerCurveContinuous;

                [self.syslogButton.layer insertSublayer:fill atIndex:0];
                self.syslogButtonFillLayer = fill;
            }

            [self.syslogHoldDisplayLink invalidate];
            self.syslogHoldDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_syslogHoldTick:)];
            [self.syslogHoldDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.syslogHoldDisplayLink invalidate];
            self.syslogHoldDisplayLink = nil;

            if (!self.syslogHoldTriggered) {

                [CATransaction begin];
                [CATransaction setAnimationDuration:0.18];
                self.syslogButtonFillLayer.frame = CGRectMake(0, 0, 0, self.syslogButton.bounds.size.height);
                self.syslogButtonFillLayer.cornerRadius = kZSAuthFieldCornerRadius;
                [CATransaction commit];
            }
            break;
        }
        default:
            break;
    }
}

- (void)zs_syslogHoldTick:(CADisplayLink *)link {

    static const NSTimeInterval kSyslogHoldDuration = 1.0;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.syslogHoldStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kSyslogHoldDuration);

    CGRect bounds = self.syslogButton.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.syslogButtonFillLayer.frame = CGRectMake(0, 0, bounds.size.width * pct, bounds.size.height);
    self.syslogButtonFillLayer.cornerRadius = kZSAuthFieldCornerRadius;
    [CATransaction commit];

    if (pct >= 1.0 && !self.syslogHoldTriggered) {
        self.syslogHoldTriggered = YES;
        [link invalidate];
        self.syslogHoldDisplayLink = nil;
        [self zs_enterSyslogVerboseMode];
    }
}

- (void)zs_enterSyslogVerboseMode {
    self.syslogVerboseEnabled = YES;

    zs_style_button_as_native_glass(self.syslogButton, @"Verbose", [UIColor colorWithWhite:1 alpha:0.95]);
    zs_configure_glass_button_fixed_corner_radius(self.syslogButton, kZSAuthFieldCornerRadius);

    self.syslogTabEnabled = YES;
    self.syslogHandle.hidden = NO;
    self.syslogHandleGlass.hidden = NO;

    self.syslogHandleLabel.text = @"VERBOSE";
    [self zs_updateSyslogHandleLabelLayout];

    UIWindow *window = zs_key_window();
    if (window) {
        [self layoutPanelForWindow:window];
    }
    [self zs_renderSyslogBuffer];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];

    ZLog(@"Verbose syslog mode enabled - filtering to tweak-only log lines");
}

- (void)zs_resetSyslogVerboseMode {
    self.syslogVerboseEnabled = NO;
    zs_style_button_as_native_glass(self.syslogButton, @"Syslog", [UIColor colorWithWhite:1 alpha:0.88]);
    zs_configure_glass_button_fixed_corner_radius(self.syslogButton, kZSAuthFieldCornerRadius);

    self.syslogHandleLabel.text = @"SYSLOG";
    [self zs_updateSyslogHandleLabelLayout];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.syslogButtonFillLayer.frame = CGRectMake(0, 0, 0, self.syslogButton.bounds.size.height);
    self.syslogButtonFillLayer.cornerRadius = kZSAuthFieldCornerRadius;
    [CATransaction commit];

    UIWindow *window = zs_key_window();
    if (window) {
        [self layoutPanelForWindow:window];
    }
    [self zs_renderSyslogBuffer];

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
        UIWindow *window = zs_key_window();
        if (window) {
            [window bringSubviewToFront:self.syslogOverlay];
        }

        [self zs_renderSyslogBuffer];

        if (!started) {
            [self appendSyslogLine:@"[syslog] Unable to start stdout/stderr capture"];
        }
    } else {
        [self pauseSyslogCapture];
    }
}

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

- (BOOL)zs_syslogLineIsBlacklisted:(NSString *)line {
    if (self.syslogBlacklist.count == 0) return NO;
    NSString *lower = line.lowercaseString;
    for (NSString *term in self.syslogBlacklist) {
        if (term.length > 0 && [lower containsString:term]) return YES;
    }
    return NO;
}

- (void)appendSyslogLine:(NSString *)line {
    if (!line.length) return;
    if ([self zs_syslogLineIsBlacklisted:line]) return;

    [self.syslogLines addObject:line];
    static const NSUInteger kMaxSyslogLines = 80;
    if (self.syslogLines.count > kMaxSyslogLines) {
        NSUInteger removeCount = self.syslogLines.count - kMaxSyslogLines;
        [self.syslogLines removeObjectsInRange:NSMakeRange(0, removeCount)];
    }

    [self zs_renderSyslogBuffer];
}

- (NSArray<NSString *> *)zs_syslogDisplayLines {
    if (!self.syslogVerboseEnabled) return self.syslogLines;

    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *line in self.syslogLines) {
        if ([line containsString:kZLogTag]) [filtered addObject:line];
    }
    return filtered;
}

- (void)zs_renderSyslogBuffer {
    NSArray<NSString *> *displayLines = [self zs_syslogDisplayLines];
    NSString *joined = displayLines.count > 0
        ? [displayLines componentsJoinedByString:@"\n"]
        : (self.syslogVisible
           ? (self.syslogVerboseEnabled ? @"[syslog] Listening for tweak output\u2026" : @"[syslog] Listening for output\u2026")
           : @"");

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
    [self layoutSyslogOverlayForWindow:zs_key_window()];
}

- (void)layoutSyslogOverlayForWindow:(UIWindow *)window {
    if (!window || !self.syslogOverlay || !self.syslogTextLabel) return;

    CGFloat leftInset = window.safeAreaInsets.left + 16.0;

    CGFloat width = MIN(window.bounds.size.width * 0.72, 700.0);

    CGFloat interactWidth = width / 3.0;
    CGFloat top = window.safeAreaInsets.top + 6.0;
    CGFloat height = MIN(window.bounds.size.height * 0.48, 420.0);

    self.syslogOverlay.frame = CGRectMake(leftInset, top, interactWidth, height);

    CGSize fitSize = [self.syslogTextLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGFloat textHeight = MAX(height, ceil(fitSize.height) + 8.0);
    self.syslogTextLabel.frame = CGRectMake(0, 0, width, textHeight);
    self.syslogOverlay.contentSize = CGSizeMake(interactWidth, textHeight);

    if (textHeight > height && !self.syslogOverlay.isDragging && !self.syslogOverlay.isDecelerating) {
        self.syslogOverlay.contentOffset = CGPointMake(0, textHeight - height);
    }
}

#pragma mark Auth

- (void)zs_loadAuthFields {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    self.authRepoLinkField.text = zs_format_github_repo_link(config.repoOwner, config.repoName);
    self.authTokenField.text = config.authToken ?: @"";
}

- (void)zs_persistAuthFields {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];

    NSString *linkRaw = [self.authRepoLinkField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (linkRaw.length == 0) {
        config.repoOwner = nil;
        config.repoName = nil;
    } else {
        NSString *owner = nil, *name = nil;
        if (zs_parse_github_repo_link(linkRaw, &owner, &name)) {
            config.repoOwner = owner;
            config.repoName = name;

            self.authRepoLinkField.text = zs_format_github_repo_link(owner, name);
        } else {

            ZLog(@"[UserInterface] Auth: couldn't parse GitHub repo link \"%@\" - keeping previously saved repo, if any", linkRaw);
        }
    }

    NSString *tokenSanitized = zs_sanitize_personal_access_token(self.authTokenField.text ?: @"");
    config.authToken = tokenSanitized.length > 0 ? tokenSanitized : nil;
    self.authTokenField.text = tokenSanitized;

    NSError *error = nil;
    if (![ZTranscoderSettings saveConfig:config error:&error]) {
        ZLog(@"[UserInterface] Auth: failed to save ZTranscoder config: %@", error);
    }
}

- (void)zs_setAuthStatusLabelText:(NSString *)text color:(UIColor *)color {
    self.authStatusLabel.text = text ?: @"";
    self.authStatusLabel.textColor = color;
    self.authStatusLabel.hidden = (text.length == 0);
}

- (void)zs_setAuthFieldsLocked:(BOOL)locked {
    self.authRepoLinkField.enabled = !locked;
    self.authTokenField.enabled = !locked;

    UIColor *textColor = locked ? [UIColor colorWithWhite:1 alpha:0.35] : UIColor.whiteColor;
    self.authRepoLinkField.textColor = textColor;
    self.authTokenField.textColor = textColor;

    NSArray<UIView *> *fieldContainers = @[self.authRepoLinkFieldContainer, self.authTokenFieldContainer];
    for (UIView *container in fieldContainers) {
        if (!container) continue;
        container.alpha = locked ? 0.5 : 1.0;
        if (zs_has_liquid_glass() && [container isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)container).effect = zs_make_glass_effect(!locked);
        }
    }
}

- (void)zs_authEnterVerifiedState {
    self.authCredentialsStale = NO;
    self.authInRemoveMode = YES;
    [self zs_setAuthFieldsLocked:YES];

    zs_remove_pill_hold_to_confirm_gestures(self.authVerifyButton);
    __weak typeof(self) weakSelf = self;
    zs_attach_pill_hold_to_confirm_duration(self.authVerifyButton, self, 1.0, ^{
        [weakSelf zs_authRemoveCredentialsConfirmed];
    });
    self.authVerifyButton.enabled = YES;
    zs_crossfade_auth_button_to_remove(self.authVerifyButton);

    [self zs_setAuthStatusLabelText:@"Credentials confirmed." color:zs_accent_green_color()];
}

- (void)zs_authEnterStaleState {
    self.authCredentialsStale = YES;
    self.authInRemoveMode = YES;
    [self zs_setAuthFieldsLocked:YES];

    zs_remove_pill_hold_to_confirm_gestures(self.authVerifyButton);
    __weak typeof(self) weakSelf = self;
    zs_attach_pill_hold_to_confirm_duration(self.authVerifyButton, self, 1.0, ^{
        [weakSelf zs_authRemoveCredentialsConfirmed];
    });
    self.authVerifyButton.enabled = YES;
    zs_crossfade_auth_button_to_remove(self.authVerifyButton);

    [self zs_setAuthStatusLabelText:@"Your credentials are no longer valid."
                               color:[UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]];
}

- (void)zs_authRemoveCredentialsConfirmed {
    NSError *error = nil;
    if (![ZTranscoderSettings clearAllWithError:&error]) {
        ZLog(@"[UserInterface] Auth: failed to wipe stored credentials: %@", error);
    }

    self.authInRemoveMode = NO;
    self.authCredentialsStale = NO;
    zs_remove_pill_hold_to_confirm_gestures(self.authVerifyButton);

    self.authRepoLinkField.text = @"";
    self.authTokenField.text = @"";
    [self zs_setAuthFieldsLocked:NO];

    self.authVerifyButton.enabled = YES;
    zs_crossfade_auth_button_to_verify(self.authVerifyButton);

    [self zs_setAuthStatusLabelText:nil color:nil];
}

- (void)zs_authRunBootVerification {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService verifyCredentialsForConfig:config completion:^(BOOL valid, NSError *verifyError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (valid) {
            [strongSelf zs_authEnterVerifiedState];
        } else {
            [strongSelf zs_authEnterStaleState];
        }
    }];
}

#pragma mark Re-Encoding format

- (void)zs_reencodeFormatSelected:(NSString *)format {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    config.outputFormat = format;

    NSError *error = nil;
    if (![ZTranscoderSettings saveConfig:config error:&error]) {
        ZLog(@"[UserInterface] Config: failed to save Re-Encoding format: %@", error);
        return;
    }

    if (self.reencodeFormatButton) {
        zs_style_reencode_format_button(self.reencodeFormatButton, format);
    }

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_reencodeFormatButtonTapped:(UIButton *)sender {
    if (self.reencodeDropdownOpen) {
        [self zs_closeReencodeDropdownAnimated:YES];
    } else {
        [self zs_openReencodeDropdown];
    }
}

- (void)zs_openReencodeDropdown {
    if (!self.reencodeFormatButton || !self.contentOverlay || self.reencodeDropdownOpen) return;

    NSArray<NSString *> *options = zs_reencode_format_options();
    if (options.count == 0) return;

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    NSString *currentFormat = config.outputFormat.length > 0 ? config.outputFormat : kZSDefaultReencodeFormat;

    CGRect collapsedFrame = [self.reencodeFormatButton convertRect:self.reencodeFormatButton.bounds
                                                              toView:self.contentOverlay];

    UIControl *scrim = [[UIControl alloc] initWithFrame:self.contentOverlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_reencodeDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentOverlay addSubview:scrim];
    self.reencodeDropdownScrim = scrim;

    UIView *overlay;
    UIVisualEffectView *glassOverlay = nil;
    if (zs_has_liquid_glass()) {
        glassOverlay = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        glassOverlay.frame = collapsedFrame;
        glassOverlay.clipsToBounds = YES;
        zs_configure_glass_corners(glassOverlay, kZSAuthFieldCornerRadius, NO);
        glassOverlay.layer.borderWidth = 1;
        glassOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        overlay = glassOverlay;
    } else {
        overlay = [[UIView alloc] initWithFrame:collapsedFrame];
        overlay.clipsToBounds = YES;
        overlay.layer.cornerRadius = kZSAuthFieldCornerRadius;
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
        overlay.layer.borderWidth = 1;
        overlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;

        overlay.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    [self.contentOverlay addSubview:overlay];
    self.reencodeDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        NSString *format = options[i];
        BOOL selected = [format isEqualToString:currentFormat];
        UIButton *optionButton = zs_make_reencode_dropdown_option_button(format, selected, i, self,
                                                                          @selector(zs_reencodeDropdownOptionTapped:));
        optionButton.frame = CGRectMake(0, i * kZSReencodeFieldHeight,
                                         CGRectGetWidth(collapsedFrame), kZSReencodeFieldHeight);

        optionButton.alpha = 0;
        [rowHost addSubview:optionButton];

        if (i > 0) {

            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * kZSReencodeFieldHeight - hairline,
                                                                        CGRectGetWidth(collapsedFrame), hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    self.reencodeFormatButton.hidden = YES;
    self.reencodeDropdownOpen = YES;

    CGFloat expandedHeight = kZSReencodeFieldHeight * options.count;
    CGRect expandedFrame = CGRectMake(CGRectGetMinX(collapsedFrame), CGRectGetMinY(collapsedFrame),
                                       CGRectGetWidth(collapsedFrame), expandedHeight);
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.frame = expandedFrame;
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeReencodeDropdownAnimated:(BOOL)animated {
    if (!self.reencodeDropdownOpen) return;

    UIView *overlay = self.reencodeDropdownOverlay;
    UIControl *scrim = self.reencodeDropdownScrim;
    self.reencodeDropdownOverlay = nil;
    self.reencodeDropdownScrim = nil;
    self.reencodeDropdownOpen = NO;

    CGRect collapsedFrame = [self.reencodeFormatButton convertRect:self.reencodeFormatButton.bounds
                                                              toView:self.contentOverlay];

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        self.reencodeFormatButton.hidden = NO;
    };

    if (!animated) {
        finish();
        return;
    }

    UIView *rowHost = [overlay isKindOfClass:[UIVisualEffectView class]]
        ? ((UIVisualEffectView *)overlay).contentView
        : overlay;
    for (UIView *subview in rowHost.subviews) {
        subview.alpha = 0;
    }

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.frame = collapsedFrame;
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_reencodeDropdownOptionTapped:(UIButton *)sender {
    NSArray<NSString *> *options = zs_reencode_format_options();
    if (sender.tag < 0 || sender.tag >= (NSInteger)options.count) return;

    NSString *format = options[sender.tag];
    [self zs_reencodeFormatSelected:format];
    [self zs_closeReencodeDropdownAnimated:YES];
}

- (void)zs_reencodeDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeReencodeDropdownAnimated:YES];
}

- (void)zs_authVerifyTapped:(UIButton *)sender {
    if (self.authInRemoveMode) return;

    [self zs_persistAuthFields];

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token above first."];
        return;
    }

    sender.enabled = NO;
    zs_crossfade_auth_verify_button_title(sender, @"Verifying\u2026");

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService verifyCredentialsForConfig:config completion:^(BOOL valid, NSError *verifyError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (valid) {
            [strongSelf zs_authEnterVerifiedState];
        } else {
            sender.enabled = YES;
            zs_crossfade_auth_verify_button_title(sender, @"Verify");
            [strongSelf zs_presentModsAlertWithTitle:@"Verification Failed"
                                              message:verifyError.localizedDescription ?: @"Couldn't verify the repository link and token."];
        }
    }];
}

- (void)zs_keyboardWillChangeFrame:(NSNotification *)note {
    UIWindow *window = zs_key_window();
    if (!window) return;

    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endFrameInWindow = [window convertRect:endFrame fromView:nil];
    self.zs_lastKeyboardFrame = endFrameInWindow;

    BOOL keyboardVisible = CGRectGetMinY(endFrameInWindow) < CGRectGetMaxY(window.bounds);
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    if (duration <= 0) duration = 0.25;

    if (self.zsFloatingField && keyboardVisible) {
        CGFloat bottomInset = CGRectGetHeight(window.bounds) - CGRectGetMinY(endFrameInWindow);
        self.zsFloatingFieldBottomConstraint.constant = -(bottomInset + 8);
        [UIView animateWithDuration:duration animations:^{
            [window layoutIfNeeded];
        }];
    } else if (self.zsFloatingField && !keyboardVisible) {
        [self.zsFloatingField resignFirstResponder];
    }
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField == self.authRepoLinkField || textField == self.authTokenField) {
        __weak typeof(self) weakSelf = self;
        __weak UITextField *weakField = textField;
        [self zs_presentFloatingTextFieldWithInitialText:textField.text
                                              placeholder:textField.placeholder
                                                   secure:textField.secureTextEntry
                                               completion:^(NSString * _Nullable trimmedText) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            __strong UITextField *strongField = weakField;
            if (!strongSelf || !strongField) return;
            strongField.text = trimmedText ?: @"";
            [strongSelf zs_persistAuthFields];
        }];
        return NO;
    }
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == self.zsFloatingField) {

        [self zs_commitFloatingField];
        return;
    }
}

#pragma mark Syslog blacklist

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.zsFloatingField) {

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
        [self.syslogBlacklist addObject:term];
    }

    textField.text = @"";
    if (added) {
        g_syslogBlacklist = self.syslogBlacklist.array;
        [self zs_rebuildSyslogBlacklistEntries];
        [self zs_scheduleSave];
        [self reapplySyslogBlacklistFilter];
    }
    [textField resignFirstResponder];
    return YES;
}

- (void)zs_rebuildSyslogBlacklistEntries {
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
            zs_make_blacklist_entry_row(term, self, @selector(zs_removeBlacklistEntryTapped:))];
    }
}

- (void)zs_removeBlacklistEntryTapped:(UIButton *)sender {
    NSString *term = objc_getAssociatedObject(sender, "zs_blacklistTerm");
    if (!term) return;

    [self.syslogBlacklist removeObject:term];
    g_syslogBlacklist = self.syslogBlacklist.array;
    [self zs_rebuildSyslogBlacklistEntries];
    [self zs_scheduleSave];
}

- (void)reapplySyslogBlacklistFilter {
    if (self.syslogLines.count == 0) return;
    NSIndexSet *toRemove = [self.syslogLines indexesOfObjectsPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
        return [self zs_syslogLineIsBlacklisted:line];
    }];
    if (toRemove.count == 0) return;
    [self.syslogLines removeObjectsAtIndexes:toRemove];
    [self zs_renderSyslogBuffer];
}

#pragma mark Pull tab

- (void)layoutPanelForWindow:(UIWindow *)window {
    if (!self.glassContainer || !self.panel || !self.handle) return;

    CGFloat width = self.panelWidth > 0 ? self.panelWidth : kPanelWidth;
    CGFloat height = window.bounds.size.height;
    CGFloat chromeWidth = width + kHandleWidth;

    self.glassContainer.frame = CGRectMake(window.bounds.size.width - kHandleWidth,
                                            0,
                                            chromeWidth,
                                            height);

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

    if (self.panelGlass) {
        zs_configure_glass_corners(self.panelGlass, kPanelCornerRadiusMinimum, YES);
    }
    if (self.handleGlass) {
        zs_configure_glass_corners(self.handleGlass, kHandleCornerRadius, NO);
    }

    self.panel.frame = self.panelGlass ? self.panelGlass.bounds : self.panel.bounds;
    self.handle.frame = self.handleGlass ? self.handleGlass.bounds : self.handle.bounds;

    if (self.syslogHandle) {

        CGFloat mainHandleY = CGRectGetMinY(handleElement.frame);
        CGFloat syslogY = MAX(window.safeAreaInsets.top + 2.0,
                              mainHandleY - kSyslogHandleGap - self.syslogHandleHeight);
        CGRect syslogFrame = CGRectMake(0,
                                         syslogY,
                                         kHandleWidth,
                                         self.syslogHandleHeight);
        if (self.syslogHandleGlass) {
            self.syslogHandleGlass.frame = syslogFrame;
            zs_configure_glass_corners(self.syslogHandleGlass, 8, NO);
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

        self.sliderGlassContainer.frame = [self.glassContainer convertRect:self.glassContainer.bounds
                                                                    toView:window];
        [window bringSubviewToFront:self.sliderGlassContainer];

        if (self.contentOverlay) [window bringSubviewToFront:self.contentOverlay];
    }

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
    [self zs_updateSliderGlassVisibility];
}

#pragma mark Scroll-linked slider glass

static const CGFloat kZSSliderGlassCullMargin = 80;

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self zs_updateSliderGlassVisibility];

    if (self.reencodeDropdownOpen) {
        [self zs_closeReencodeDropdownAnimated:NO];
    }
}

- (void)zs_updateSliderGlassVisibility {
    if (!zs_has_liquid_glass() || !self.stack || !self.scrollViewport) return;

    CGRect visibleRect = CGRectInset(self.scrollViewport.bounds, -kZSSliderGlassCullMargin, -kZSSliderGlassCullMargin);

    for (UIView *arranged in self.stack.arrangedSubviews) {
        if (![arranged isKindOfClass:[ZSRow class]]) continue;
        ZSRow *row = (ZSRow *)arranged;
        if (!row.slider && !row.modeSlider) continue;

        CGRect rowFrameInViewport = [row convertRect:row.bounds toView:self.scrollViewport];
        BOOL onScreen = CGRectIntersectsRect(rowFrameInViewport, visibleRect);

        if (row.slider) {
            row.slider.glassHost = self.sliderGlassContent;
            [row.slider setGlassEnabled:onScreen];
        } else {
            row.modeSlider.glassHost = self.sliderGlassContent;
            [row.modeSlider setGlassEnabled:onScreen];
        }
    }
}

#pragma mark Content edge mask

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
    UIWindow *window = zs_key_window();
    if (!window || !self.panel) return;
    [self layoutPanelForWindow:window];
}

- (void)positionPanel {
    [self positionPanelAnimated:YES];
}

- (void)positionPanelAnimated:(BOOL)animated {
    UIWindow *window = zs_key_window();
    if (!window || !self.glassContainer) return;

    CGFloat chromeWidth = self.panelWidth + kHandleWidth;
    CGFloat targetX = self.panelOpen
        ? (window.bounds.size.width - chromeWidth)
        : (window.bounds.size.width - kHandleWidth);

    void (^changes)(void) = ^{

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

    [self zs_updateSliderGlassVisibility];
}

#pragma mark Post FX continuous reapply

- (void)startPostFXReapply {
    if (self.postFXReapplyTimer) return;
    self.postFXReapplyTimer = [NSTimer timerWithTimeInterval:kPostFXReapplyInterval
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        zs_reapply_post_fx();
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.postFXReapplyTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPostFXReapply {
    [self.postFXReapplyTimer invalidate];
    self.postFXReapplyTimer = nil;
}

#pragma mark Slider/switch/mode-slider actions

static void zs_update_value_label(ZSCapsuleSlider *slider) {
    UILabel *label = objc_getAssociatedObject(slider, "zs_valueLabel");
    NSString *(^format)(float) = objc_getAssociatedObject(slider, "zs_format");
    if (label && format) label.text = format(slider.value);
}

- (void)normalFpsChanged:(ZSCapsuleSlider *)slider {
    NSInteger fps = (NSInteger)roundf(slider.value);
    g_menuFPS = fps;
    self.normalFpsValueLabel.text = [NSString stringWithFormat:@"%d", (int)fps];
    [[FPS120Controller shared] setManualMenuFPS:fps];
    [self zs_scheduleSave];
}

- (void)combatFpsChanged:(ZSCapsuleSlider *)slider {
    NSInteger fps = (NSInteger)roundf(slider.value);
    g_combatFPS = fps;
    self.combatFpsValueLabel.text = [NSString stringWithFormat:@"%d", (int)fps];
    [[FPS120Controller shared] setManualCombatFPS:fps];
    [self zs_scheduleSave];
}

- (void)texChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);

    int32_t engineValue = 4 - (int32_t)roundf(slider.value);
    g_textureMip = engineValue;
    zs_set_texture_mip_limit(engineValue);
    [self zs_scheduleSave];
}

- (void)scaleChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    float scale = slider.value / 100.0f;
    g_renderScale = scale;
    zs_set_render_scale(scale);
    [self zs_scheduleSave];
}

- (void)msaaChanged:(ZSModeSlider *)slider {
    int32_t idx = (int32_t)slider.selectedIndex;
    g_msaaIndex = idx;
    int32_t v = zs_step_value(kMSAASteps, 4, (float)idx);
    zs_urp_set_int("set_msaaSampleCount", v);
    [self zs_scheduleSave];
}

- (void)hdrChanged:(UISwitch *)toggle {
    g_hdrOn = toggle.on;
    zs_urp_set_bool("set_supportsHDR", toggle.on);
    [self zs_scheduleSave];
}

- (void)fmodZeroingDisableChanged:(UISwitch *)toggle {
    [PatchManifestNetwork setZeroingEnabled:!toggle.on];
}

- (void)lz4hcCompressionDisableChanged:(UISwitch *)toggle {
    [ZTranscoderService setUploadCompressionEnabled:!toggle.on];
}

- (void)blurIntensityChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    g_blurIntensity = slider.value;
    zs_apply_motion_blur();
    [self zs_scheduleSave];
}

- (void)tonemapModeChanged:(ZSModeSlider *)slider {
    g_tonemapMode = (int32_t)slider.selectedIndex;
    zs_apply_tonemapping();
    [self zs_scheduleSave];
}

- (void)urpEffectValueChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    NSString *name = objc_getAssociatedObject(slider, "zs_urp_name");
    if (!name) return;
    g_urpValue[name] = @(slider.value);
    zs_apply_urp_post_effect(name);
    [self zs_scheduleSave];
}

- (void)cameraAAModeChanged:(ZSModeSlider *)slider {
    g_aaModeIndex = (int32_t)slider.selectedIndex;
    int32_t v = zs_step_value(kAAModeSteps, 4, (float)slider.selectedIndex);
    zs_camera_data_set_int("set_antialiasing", v);
    [self zs_scheduleSave];
}

- (void)cameraAAQualityChanged:(ZSModeSlider *)slider {
    g_aaQualityIndex = (int32_t)slider.selectedIndex;
    int32_t v = zs_step_value(kAAQualitySteps, 3, (float)slider.selectedIndex);
    zs_camera_data_set_int("set_antialiasingQuality", v);
    [self zs_scheduleSave];
}

- (void)cameraDitheringChanged:(UISwitch *)toggle {
    g_ditheringOn = toggle.on;
    zs_camera_data_set_bool("set_dithering", toggle.on);
    [self zs_scheduleSave];
}

@end

#pragma mark - Startup

__attribute__((constructor))
static void graphics_debug_overlay_init(void) {
    __block NSTimer *installTimer;
    installTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [[UserInterface shared] installIfNeeded];
        if ([UserInterface shared].panel) {
            zs_dump_glass_effect_instance_info();
            [timer invalidate];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:installTimer forMode:NSRunLoopCommonModes];
}

