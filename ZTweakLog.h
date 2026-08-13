// ZTweakLog.h
//
// One-line drop-in replacement for NSLog that every file in the tweak
// can use for "the tweak did X" logging. It exists for exactly one
// reason: ZSyslogController's stdout/stderr capture (see
// ZSyslogController.h) already sees EVERYTHING written to stdout/stderr
// in the injected process - that's the game/engine's own output as much
// as it is ours. There is no signal at the pipe level that tells those
// apart.
//
// kZLogTag is that signal. Every call site that wants a line to show up
// under the debug panel's "Verbose" filter (tweak-only output) should
// go through ZLog(...) instead of a bare NSLog(...) - the tag is what
// -[GraphicsDebugOverlay gd_renderSyslogBuffer] matches against once
// Verbose mode is engaged. Everything else (plain NSLog, the engine's
// own console spam, etc.) still shows up in normal (non-Verbose) Syslog
// mode, same as today - it's just excluded once Verbose narrows the
// view down to the tweak's own lines.
//
// This is deliberately NOT a call-everywhere-automatically mechanism -
// see the implementation notes left in GraphicsDebugOverlay.m/GDScripts.m/
// IL2CppBridge.m/fps120.m for why an automatic (e.g. swizzling-based)
// approach was ruled out. It's a single macro precisely so adding a new
// call site is a one-line change, not a new logging helper per file.

#ifndef ZTweakLog_h
#define ZTweakLog_h

#import <Foundation/Foundation.h>

static NSString * const kZLogTag = @"[ZSingularity]";

#define ZLog(fmt, ...) NSLog(@"%@ " fmt, kZLogTag, ##__VA_ARGS__)

#endif /* ZTweakLog_h */
