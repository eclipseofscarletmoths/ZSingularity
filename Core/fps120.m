
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <string.h>
#import "ZSScripts.h"
#import "ZSFileIndex.h"
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

static void *file_index_worker(void *arg) {
    (void)arg;
    @autoreleasepool {
        [ZSFileIndex ensureIndexUpToDate];
    }
    return NULL;
}

static void *background_worker(void *arg) {
    (void)arg;

    __block BOOL fpsReady = NO;
    __block BOOL metalConfigured = NO;

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

    while (!fpsReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{

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

