// IL2CppBridge.h
//
// Small reusable wrapper around the handful of libil2cpp C API entry
// points needed to look up managed classes/methods/fields by name and
// call into them, without hand-rolling dlsym boilerplate per-feature.

#import <Foundation/Foundation.h>
#import <stdint.h>

@interface IL2CppBridge : NSObject

// Resolves the libil2cpp function pointers via dlsym if not already
// done. Safe to call repeatedly. Returns NO if the symbols aren't
// exported by this binary (in which case nothing else in this class
// will work, and callers should treat the whole feature as unavailable).
+ (BOOL)resolveSymbols;

// Finds a class by namespace + name, searching only images whose
// reported name contains assemblySubstring (e.g. "Assembly-CSharp",
// "CoreModule", "Universal.Runtime"). Results are NOT cached by this
// class - cache the returned pointer yourself, it's stable for the
// process lifetime once found.
+ (void *)classNamed:(const char *)className
          inNamespace:(const char *)namespaze
     assemblyContains:(const char *)assemblySubstring;

// Looks up a method by name + arg count on a class. Works for both
// static and instance methods - pass NULL as the instance in
// invokeMethod:onInstance:... below for statics.
+ (const void *)methodOnClass:(void *)klass
                          name:(const char *)methodName
                      argCount:(int)argCount;

// Invokes a method found via methodOnClass:name:argCount:.
// - obj: NULL for static methods, else the target instance.
// - args: array of pointers, one per parameter (il2cpp_runtime_invoke's
//   calling convention - each element points AT the value for value
//   types like Int32/Single; for reference-type params the slot holds
//   the object pointer itself, not a pointer to it). Pass NULL for
//   zero-arg calls.
// - outException: if non-NULL and an exception was thrown, this is set
//   and the return value should be treated as invalid.
+ (void *)invokeMethod:(const void *)method
             onInstance:(void *)obj
                   args:(void **)args
          outException:(void **)outException;

// Looks up a field's byte offset within its declaring class's instance
// layout by name. Always look this up dynamically rather than hardcode
// an offset from a specific dump - offsets shift across game updates,
// field names generally don't.
+ (int32_t)fieldOffsetOnClass:(void *)klass name:(const char *)fieldName;

// Returns the actual runtime class of a live object instance. Needed
// for generic instantiations (e.g. a VolumeParameter<float> field
// whose concrete backing class isn't known ahead of time) so field
// offsets can still be looked up by name instead of guessed.
+ (void *)classOfInstance:(void *)obj;

// Wraps a class as a System.Type object, for passing as an argument to
// methods that take System.Type (e.g. VolumeStack's non-generic
// GetComponent(Type) overload) - this sidesteps needing to instantiate
// an IL2CPP generic method by name, which the plain C API doesn't
// support directly.
+ (void *)reflectionTypeForClass:(void *)klass;

// Converts a live System.String* (as returned by invokeMethod:...) into
// an NSString. Returns nil for a NULL pointer (e.g. a method that
// returned null, or a failed call). Only needed by callers that invoke
// methods with a String return type - nothing in the graphics/render
// path uses this today.
+ (NSString *)nsStringFromIl2CppString:(void *)il2cppString;

// The three calls below back gd_install_scene_loaded_hook's delegate
// construction (GDScripts.m) and nothing else today. They're resolved
// optionally (like the String helpers above) - NOT part of the
// g_resolveOk gate - because they're a much newer, less universally
// present slice of the il2cpp embedding API than the class/method/field
// lookups every other script in this tweak depends on. Treat NULL from
// any of them as "this specific feature is unavailable on this build",
// not as the whole bridge being broken.

// Returns the Il2CppType* of a method's parameter at index (0-based).
// Used to discover the exact closed generic delegate type a method
// like SceneManager.add_sceneLoaded expects, instead of guessing at
// how to spell/construct a generic instantiation's name ourselves.
+ (const void *)paramTypeForMethod:(const void *)method index:(uint32_t)index;

// Resolves an Il2CppType* (as returned by paramTypeForMethod:index:)
// back to the Il2CppClass* it represents.
+ (void *)classFromType:(const void *)type;

// Allocates a zeroed, uninitialized instance of klass - the same first
// step Activator.CreateInstance performs before running a constructor.
// The returned object still needs its constructor invoked via
// invokeMethod:onInstance:args:outException: (pass ".ctor" as the
// method name) before it's safe to use as anything but a target for
// that constructor call.
+ (void *)newObjectForClass:(void *)klass;

@end
