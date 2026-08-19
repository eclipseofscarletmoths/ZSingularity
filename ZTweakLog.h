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

// Extra-detail tier, added specifically to debug the Texture2D retarget
// pipeline's per-object behavior (why a given object parsed/didn't,
// which conversion decision it got, whether its patch verified, etc.) -
// see findings.md. Same kZLogTag, so it still shows up in the debug
// panel's Verbose overlay filter same as ZLog, but gated separately so
// a full per-object trace across every object in a bundle (a couple
// hundred lines, easily) doesn't drown out the terse one-line-per-stage
// summaries every normal run already produces via plain ZLog. Flip to
// NO once the pipeline's behavior on a given bundle/corpus is
// understood - this is diagnostic-session logging, not steady-state
// output every call site should assume is on.
static BOOL kZSVerbosePipelineLogging = YES;

#define ZLogVerbose(fmt, ...) do { if (kZSVerbosePipelineLogging) NSLog(@"%@[verbose] " fmt, kZLogTag, ##__VA_ARGS__); } while (0)

#endif /* ZTweakLog_h */
