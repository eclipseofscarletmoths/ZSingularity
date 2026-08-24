// fps120.m
//
// dylib entry point/startup glue only. Waits for the runtime to be
// ready, then hands off to FPS120Controller (GDScripts.h/.m) and
// configures the Unity view's Metal layer.
//
// The 120fps logic itself - target-frame-rate control, the
// GlobalGameManager scene-state poll, and every other engine script -
// used to live here as a self-contained block with its own
// independent dlsym-based IL2CPP setup. It's all been moved to
// GDScripts.m, which reuses the same IL2CppBridge-backed caches as
// every rendering script in this tweak instead of duplicating that
// setup - see GDScripts.h for the full picture.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <string.h>
#import "GDScripts.h"
#import "GDFileIndex.h" // 2 - startup file index, see file_index_worker below
#import "ZTweakLog.h"

#pragma mark - Unity view discovery

static UIView *find_unity_view(id appController) {
    UIView *found = nil;
    Class cls = [appController class];

    while (cls && !found) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && strstr(type, "UnityView")) {
                id value = object_getIvar(appController, ivars[i]);
                if ([value isKindOfClass:[UIView class]]) {
                    found = (UIView *)value;
                    break;
                }
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return found;
}

static void configure_metal_layer(UIView *unityView) {
    if (!unityView) return;
    if (![unityView.layer isKindOfClass:[CAMetalLayer class]]) return;

    CAMetalLayer *metalLayer = (CAMetalLayer *)unityView.layer;
    metalLayer.framebufferOnly = YES;
}

#pragma mark - Startup

// 2 - indexes Library/UnityCache/Shared and the FMOD mobile builds
// folder once at launch (see GDFileIndex.h for the full why/shape). Run
// on its own thread, entirely independent of background_worker's own
// wait for the Unity view/IL2CPP below - indexing is pure filesystem
// work that needs neither, and every real consumer of the index (mod
// import, the doctor pipeline's install resolve) only ever runs off a
// person's own interaction with the Mods panel, which is always well
// after dylib load. Keeping this off background_worker's thread means a
// slow first-time (or changed-since-last-launch) re-index never adds to
// the Unity-view wait that gates FPS control coming up.
static void *file_index_worker(void *arg) {
    (void)arg;
    @autoreleasepool {
        [GDFileIndex ensureIndexUpToDate];
    }
    return NULL;
}

static void *background_worker(void *arg) {
    (void)arg;

    __block BOOL fpsReady = NO;
    __block BOOL metalConfigured = NO;

    // Wait for Unity's own view to exist before touching IL2CPP at all.
    // The view only appears after UnityInitApplicationGraphics() runs,
    // which itself only runs after UnityInitApplicationNoGraphics() has
    // already brought up il2cpp_init() - so "the Unity view exists" is a
    // much stronger "safe to call il2cpp_* now" signal than IL2CppBridge's
    // dlsym() check, which can succeed the instant UnityFramework is
    // mapped into memory, long before any of its init code has actually
    // run. Calling into il2cpp_domain_get_assemblies() during that window
    // doesn't fail cleanly - it segfaults, because the domain object it
    // reads is only partially constructed. This loop used to race that
    // window on every launch (attempting -[FPS120Controller start] in the
    // same breath as this view check, not gated behind it), which is what
    // caused the intermittent SIGSEGV-on-launch crashes.
    while (!metalConfigured) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            id appController = [[UIApplication sharedApplication] delegate];
            if (appController) {
                UIView *unityView = find_unity_view(appController);
                if (unityView) {
                    configure_metal_layer(unityView);
                    metalConfigured = YES;
                    ZLog(@"Unity view found, Metal layer configured");
                }
            }
        });
        if (!metalConfigured) usleep(200 * 1000);
    }

    // Safe to touch IL2CPP now - Unity's graphics init (and therefore
    // il2cpp_init()) has already completed by this point.
    while (!fpsReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            // -start begins the scene-state poll (if not already running)
            // and attempts an initial IL2CPP write of
            // Application.targetFrameRate; it returns YES once that write
            // actually resolves a method to call.
            fpsReady = [[FPS120Controller shared] start];
        });
        if (!fpsReady) usleep(200 * 1000);
    }
    ZLog(@"FPS120Controller started - scene-state poll and target frame rate write are live");

    return NULL;
}

__attribute__((constructor))
static void fps120_init(void) {
    ZLog(@"dylib loaded - starting background worker");

    pthread_t indexThread;
    pthread_create(&indexThread, NULL, file_index_worker, NULL);
    pthread_detach(indexThread);

    pthread_t t;
    pthread_create(&t, NULL, background_worker, NULL);
    pthread_detach(t);
}
