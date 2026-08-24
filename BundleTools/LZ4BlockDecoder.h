
#import <Foundation/Foundation.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

int LZ4BlockDecompress(const uint8_t *src, size_t srcSize,
                        uint8_t *dst, size_t dstCapacity);

NS_ASSUME_NONNULL_END

