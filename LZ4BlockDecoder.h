// LZ4BlockDecoder.h
//
// A from-scratch decoder for raw LZ4 blocks (the format LZ4_compress_default/
// LZ4_compress_HC produce - NOT the .lz4 frame format, which adds its own
// magic number/header/checksums on top). This is what UnityFS bundles
// actually contain: each compressed blob (blocks-info, and each data block)
// is a bare LZ4 block with a known uncompressed size sitting right next to
// it in the archive header, and nothing else.
//
// Why this exists instead of linking a system/vendored liblz4: there isn't
// one on-device (same situation BankTransplant.h describes for libvorbis -
// Apple's SDKs don't ship it), and unlike libvorbis, the raw-block decode
// side of LZ4 is small and stable enough (one byte-oriented format, unchanged
// since the format's inception) that vendoring+cross-compiling a whole
// second third-party library for it isn't worth it. This only implements
// decompression (what UnityBundleCAB.m needs to read an existing bundle's
// directory table) - no compressor, since nothing here re-compresses a
// bundle, only swaps whole files.
//
// Handles both LZ4 and LZ4HC compressed input identically - HC only changes
// how the compressor searches for matches, not the bitstream format, so the
// same decoder reads both (this matters because UnityFS's compression-type
// flag distinguishes them at the format level - see UnityBundleCAB.m - but
// they decode identically).

#import <Foundation/Foundation.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

// Decompresses a single raw LZ4 block. `src`/srcSize is the compressed
// input; `dst` must already be allocated to exactly `dstCapacity` bytes
// (the uncompressed size, which UnityFS's header always states up front -
// unlike the general-purpose LZ4_decompress_safe API this mirrors, there's
// no "figure out how big the output is" step here, by design of the format
// this is used for).
//
// Returns the number of bytes written to `dst` (always == dstCapacity on
// success, since UnityFS blocks are never partially used) on success, or
// -1 if the input is malformed/truncated or would overrun `dst`. Every
// bounds check that matters for safely parsing untrusted/corrupt input is
// in here - callers should not need their own.
int LZ4BlockDecompress(const uint8_t *src, size_t srcSize,
                        uint8_t *dst, size_t dstCapacity);

NS_ASSUME_NONNULL_END
