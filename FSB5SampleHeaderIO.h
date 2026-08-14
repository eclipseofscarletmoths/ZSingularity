// FSB5SampleHeaderIO.h
//
// FSB5's fixed 8-byte "base" per-sample header packs frequency,
// channel count, sample count, and data offset into a bitfield whose
// exact layout Overview.md §1 explicitly flags as unresolved bit-for-bit
// - despite the same section confirming that *some* existing analysis
// script elsewhere in the project already reads it correctly enough to
// get "internally-consistent, monotonically increasing data offsets and
// a constant 24 kHz/stereo across all 10 samples" out of the stock
// bank. That script isn't part of this repo/upload, so rather than
// guess at a bit layout here (wrong in a binary format doesn't fail
// loudly - it silently produces a corrupt bank that may not even fail
// to load, just play garbage or the wrong sample), this is left as an
// explicit plug point. Both FSB5VorbisExtract.m (read, for the modded/
// Vorbis file) and FSB5HeaderRebuild.m (read stock's header as a
// template, then write back a patched offset/size) call through this
// one interface, so there's a single place to drop the real bit-packing
// logic in once it's pulled over from wherever that prior analysis
// lives.
//
// fsb5_read_base_header/fsb5_write_base_header currently return -1
// (not implemented) so any caller that reaches them fails closed and
// loud (BankTransplantErrorWriteFailed) instead of writing a
// plausible-looking but wrong file.

#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t data_offset;  // meaning (byte offset? sample-count units? something else) unconfirmed - whatever unit the real codec uses
    uint32_t frequency_hz;
    uint8_t  channels;     // 1 or 2
    uint32_t num_samples;
    int      has_extradata;
} FSB5BaseHeaderFields;

// Returns 0 on success, -1 if not implemented / on parse failure.
int fsb5_read_base_header(const uint8_t header8[8], FSB5BaseHeaderFields *out);

// Writes fields into header8 (8 bytes), preserving whatever bits the
// unresolved layout requires that aren't represented in
// FSB5BaseHeaderFields. Returns 0 on success, -1 if not implemented.
int fsb5_write_base_header(uint8_t header8[8], const FSB5BaseHeaderFields *in);

#ifdef __cplusplus
}
#endif
