// ZCrashLogger.m — see ZCrashLogger.h for the why and the safety caveats.

#import "ZCrashLogger.h"
#import "ZTweakLog.h"
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

// Kept open for the process lifetime once +install runs, specifically
// so the signal handler never has to call open() itself - one less
// thing that could go wrong (or allocate/lock) while already inside a
// fault.
static int g_crashLogFD = -1;
static NSString *g_crashLogPath = nil;

// Signals this handles. SIGKILL/SIGSTOP deliberately excluded - they
// can't be caught by any process, POSIX forbids installing a handler
// for them at all.
static const int kHandledSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
static const int kHandledSignalCount = sizeof(kHandledSignals) / sizeof(kHandledSignals[0]);

// A dedicated signal stack - if the fault IS a stack overflow, the
// handler needs somewhere else to run other than the already-blown
// stack. 64KB is comfortably more than backtrace()/write() need.
static uint8_t g_altStack[64 * 1024];

#pragma mark - Async-signal-safe helpers
//
// Everything below this point may run inside a signal handler and is
// restricted to what that context allows: no malloc, no Objective-C
// messaging, no Foundation. Plain POSIX only.

static void safe_write_str(const char *s) {
    if (g_crashLogFD < 0 || !s) return;
    write(g_crashLogFD, s, strlen(s));
}

// Minimal hex formatter - avoids snprintf's undocumented-in-signal-
// context-safety status for the one thing this actually needs to
// print numerically (addresses).
static void safe_write_hex(uintptr_t value) {
    char buf[2 + sizeof(uintptr_t) * 2 + 1];
    char *p = buf + sizeof(buf) - 1;
    *p = '\0';
    if (value == 0) {
        *--p = '0';
    } else {
        while (value != 0) {
            uint8_t nibble = value & 0xF;
            *--p = (nibble < 10) ? ('0' + nibble) : ('a' + (nibble - 10));
            value >>= 4;
        }
    }
    *--p = 'x';
    *--p = '0';
    safe_write_str(p);
}

static const char *name_for_signal(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        default:      return "UNKNOWN";
    }
}

static void crash_signal_handler(int sig, siginfo_t *info, void *uctx) {
    (void)uctx;

    safe_write_str("\n=== ZCrashLogger: fatal signal ===\n");
    safe_write_str("signal: ");
    safe_write_str(name_for_signal(sig));
    safe_write_str("\n");

    if (info) {
        safe_write_str("si_addr (faulting address, SIGSEGV/SIGBUS only - meaningless for other signals): ");
        safe_write_hex((uintptr_t)info->si_addr);
        safe_write_str("\n");
    }

    safe_write_str("backtrace:\n");
    // backtrace() itself just walks frame pointers - no allocation.
    // backtrace_symbols_fd() resolves symbols via dladdr and writes
    // directly to the fd without building an array of C strings (that's
    // specifically why the _fd variant exists over plain
    // backtrace_symbols(), which does allocate). See the header's
    // caveat - widely used for this exact purpose, not formally
    // guaranteed async-signal-safe.
    void *frames[64];
    int frameCount = backtrace(frames, 64);
    if (frameCount > 0) {
        backtrace_symbols_fd(frames, frameCount, g_crashLogFD);
    } else {
        safe_write_str("(backtrace() returned no frames)\n");
    }

    safe_write_str("=== end ===\n");

    // fsync before anything else happens - the process may not survive
    // much longer and buffered-but-unflushed data written via write()
    // to a regular file isn't guaranteed durable yet.
    fsync(g_crashLogFD);

    // Chain to the default handler instead of swallowing the signal -
    // this restores default disposition and re-raises, so the OS still
    // sees a normal fatal crash (any system-level reporting that DOES
    // work on a given device still gets a chance to fire; the process
    // still actually terminates rather than being left in an undefined
    // half-alive state with a corrupted stack/fault unresolved).
    signal(sig, SIG_DFL);
    raise(sig);
}

#pragma mark - Uncaught NSException handler
//
// Separate mechanism from the signal handler above and NOT restricted
// to async-signal-safe calls - by the time NSSetUncaughtExceptionHandler's
// callback runs, this is ordinary (if doomed) Objective-C/Foundation
// execution, just about to unwind into an abort(). Full NSLog/file-write
// API use is fine here.

static void uncaught_exception_handler(NSException *exception) {
    NSMutableString *log = [NSMutableString stringWithFormat:
        @"\n=== ZCrashLogger: uncaught NSException ===\nname: %@\nreason: %@\ncallStackSymbols:\n%@\n=== end ===\n",
        exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    const char *utf8 = log.UTF8String;
    if (g_crashLogFD >= 0 && utf8) {
        write(g_crashLogFD, utf8, strlen(utf8));
        fsync(g_crashLogFD);
    }
    ZLog(@"%@", log);
    // Deliberately not re-throwing/re-raising here - an uncaught
    // NSException reaching this callback is already unwinding toward
    // SIGABRT on its own (that's how NSSetUncaughtExceptionHandler's
    // contract works), which crash_signal_handler above will also catch
    // and log its own backtrace for. No need to force it.
}

@implementation ZCrashLogger

+ (NSString *)crashLogPath {
    if (!g_crashLogPath) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        g_crashLogPath = [docs stringByAppendingPathComponent:@"zsingularity_crash.log"];
    }
    return g_crashLogPath;
}

+ (void)install {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    NSString *path = [self crashLogPath];
    g_crashLogFD = open(path.UTF8String, O_CREAT | O_APPEND | O_WRONLY, 0644);
    if (g_crashLogFD < 0) {
        ZLog(@"[ZCrashLogger] couldn't open %@ for writing - crash logging is disabled this run", path);
        return;
    }

    // Log both ASLR slides up front, outside any signal context, so a
    // raw address from a later backtrace can be converted back to a
    // static offset (same space as this project's IL2CPP dump RVAs) by
    // subtracting the appropriate one of these two. Image 0 is
    // conventionally the main executable; this tweak's own image is
    // found by matching _dyld_get_image_name against dladdr on a
    // symbol known to live in this file.
    uint32_t imageCount = _dyld_image_count();
    uintptr_t mainSlide = (imageCount > 0) ? (uintptr_t)_dyld_get_image_vmaddr_slide(0) : 0;

    Dl_info selfInfo;
    uintptr_t tweakSlide = 0;
    NSString *tweakPath = @"(unknown)";
    if (dladdr((const void *)&crash_signal_handler, &selfInfo) && selfInfo.dli_fname) {
        tweakPath = @(selfInfo.dli_fname);
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strcmp(name, selfInfo.dli_fname) == 0) {
                tweakSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
                break;
            }
        }
    }

    NSString *header = [NSString stringWithFormat:
        @"\n=== ZCrashLogger installed ===\nmain executable slide: 0x%lx\ntweak dylib (%@) slide: 0x%lx\n",
        (unsigned long)mainSlide, tweakPath, (unsigned long)tweakSlide];
    const char *headerUtf8 = header.UTF8String;
    if (headerUtf8) write(g_crashLogFD, headerUtf8, strlen(headerUtf8));
    fsync(g_crashLogFD);

    // Alternate stack, so a stack-overflow fault still has somewhere
    // valid to run the handler.
    stack_t ss;
    ss.ss_sp = g_altStack;
    ss.ss_size = sizeof(g_altStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = crash_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;

    for (int i = 0; i < kHandledSignalCount; i++) {
        sigaction(kHandledSignals[i], &action, NULL);
    }

    NSSetUncaughtExceptionHandler(&uncaught_exception_handler);

    ZLog(@"[ZCrashLogger] installed - crash log path: %@", path);
}

@end
