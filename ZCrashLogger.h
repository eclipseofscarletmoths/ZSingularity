// ZCrashLogger.h
//
// Exists because system .ips crash reporting has turned out to be
// unreliable for this project's actual runtime shape - an injected
// dylib in a jailbroken process, which is exactly the kind of process
// ReportCrash/symptomsd is prone to either never observe or silently
// drop, device-dependent and not something this tweak can fix or
// detect in advance. Rather than depend on it, this installs the
// tweak's own BSD signal handlers so a fatal native fault gets written
// to a file in this app's own Documents sandbox BEFORE the process
// actually dies, independent of whatever the system does or doesn't
// do with it afterward.
//
// This catches native faults (SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGFPE)
// and process aborts (SIGABRT, which is also how a rethrown/uncaught
// NSException usually surfaces at the signal level after Foundation's
// own top-level handler runs). It does NOT catch every possible way a
// process can die - e.g. being jetsam-killed for memory pressure, or
// a watchdog kill for hanging the main thread, produce no signal at
// all and can't be caught this way. If a crash turns out NOT to be
// logged by this either, that in itself is a meaningful data point
// (points at jetsam/watchdog rather than a fault this tweak's code
// caused directly), not a failure of this file.
//
// IMPORTANT CAVEAT ON SAFETY: signal handlers run in a severely
// restricted context - the interrupted thread could have been in the
// middle of malloc's internal locks, Objective-C's runtime locks, etc,
// so calling anything that might allocate or lock (NSLog, most of
// Foundation, malloc itself) from inside the handler risks deadlocking
// instead of logging. This handler is written to avoid Foundation
// entirely and use only a pre-opened raw file descriptor + POSIX
// write()/backtrace_symbols_fd(). backtrace_symbols_fd() is what
// essentially every lightweight crash reporter (including Apple's own
// historical sample code) uses for exactly this purpose, but it is
// NOT formally POSIX-guaranteed async-signal-safe - flagging that
// honestly rather than overstating this as bulletproof. It's the
// standard pragmatic choice here, not a guaranteed-safe one.
//
// Addresses in the resulting backtrace are raw runtime addresses, not
// symbol names resolved against source - this tweak's own dylib is
// ASLR-slid at load, same as the game's own binary. +install logs both
// slides (this dylib's own, and the main executable's) once at startup,
// outside the signal handler, specifically so a raw address from a
// later crash can be converted back to a static/RVA-style offset
// afterward - the same offset space as the RVAs in the IL2CPP dump this
// project's whole hooking approach is already built around. Subtract
// the logged slide from a crashing frame's address to get back to that
// space.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZCrashLogger : NSObject

// Installs the signal handlers and the NSSetUncaughtExceptionHandler.
// Idempotent - safe to call more than once, only the first call does
// anything. Call this as the very first thing the dylib does (before
// even ZLog's "dylib loaded" line) - a crash during the early
// IL2CPP-not-ready-yet window fps120.m's own header comment already
// documents is exactly the kind of thing this needs to be armed for.
+ (void)install;

// Full path to the crash log file under this app's Documents
// directory. Exposed so a caller (e.g. a future "View Crash Log" row
// in GraphicsDebugOverlay's debug panel, or just manual retrieval via
// Filza/a file browser on the jailbroken device) can read it back
// in-app without needing the log off-device at all. The file is
// append-only across launches - each crash adds a new dated section
// rather than overwriting the last one.
+ (NSString *)crashLogPath;

@end

NS_ASSUME_NONNULL_END
