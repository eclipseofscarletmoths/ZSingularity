
#import <Foundation/Foundation.h>
#import <stdint.h>

@interface IL2CppBridge : NSObject

+ (BOOL)resolveSymbols;

+ (void *)classNamed:(const char *)className
          inNamespace:(const char *)namespaze
     assemblyContains:(const char *)assemblySubstring;

+ (const void *)methodOnClass:(void *)klass
                          name:(const char *)methodName
                      argCount:(int)argCount;

+ (void *)invokeMethod:(const void *)method
             onInstance:(void *)obj
                   args:(void **)args
          outException:(void **)outException;

+ (int32_t)fieldOffsetOnClass:(void *)klass name:(const char *)fieldName;

+ (void *)classOfInstance:(void *)obj;

+ (void *)reflectionTypeForClass:(void *)klass;

+ (NSString *)nsStringFromIl2CppString:(void *)il2cppString;

+ (const void *)paramTypeForMethod:(const void *)method index:(uint32_t)index;

+ (void *)classFromType:(const void *)type;

+ (void *)newObjectForClass:(void *)klass;

@end

