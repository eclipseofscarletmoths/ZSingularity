// FSB5SampleHeaderIO.h
//
// FSB5's fixed 8-byte per-sample base header is a packed little-endian
// 64-bit word:
//   bit 0      = has extra metadata chunks
//   bits 1..4  = frequency index
//   bit 5      = stereo flag
//   bits 6..33 = data offset in 16-byte units
//   bits 34..63= decoded sample count

#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t data_offset;  // byte offset within the FSB5 data region (must be 16-byte aligned)
    uint32_t frequency_hz;
    uint8_t  channels;     // 1 or 2
    uint32_t num_samples;
    int      has_extradata;
} FSB5BaseHeaderFields;

// Returns 0 on success, -1 on malformed/unsupported input.
int fsb5_read_base_header(const uint8_t header8[8], FSB5BaseHeaderFields *out);

// Writes the packed base header. Returns 0 on success, -1 for unrepresentable fields.
int fsb5_write_base_header(uint8_t header8[8], const FSB5BaseHeaderFields *in);

#ifdef __cplusplus
}
#endif
