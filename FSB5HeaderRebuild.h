// FSB5HeaderRebuild.h
//
// Stock's own FSB5 sample headers are already valid FADPCM headers for
// this exact audio (same sample names, same sample counts, same 24kHz
// stereo, per Overview.md §1) - so rather than construct a header from
// scratch, this clones stock's per-sample 16-byte header (8-byte packed
// base field + 8-byte extension, per §1) and patches only the two
// things that change when the sample data is replaced with a freshly
// FADPCM-encoded stream:
//   - the packed base field's data-offset (frame data moves once sizes
//     change) - via fsb5_write_base_header, FSB5SampleHeaderIO.h
//   - the extension's per-sample peak/normalization float (§1: constant
//     `08 00 00 1A` + a float in 0.94-1.0) - recomputed from the new
//     PCM's actual peak sample
//
// Frequency, channel count, and sample count are left untouched (they
// don't change: same audio content, just re-encoded).

#import <stdint.h>
#import <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FSB5_STOCK_HEADER_BYTES 16

// stock_header must be the exact 16 bytes read from the ORIGINAL
// (Mobile/FADPCM) bank for the sample with this name - the caller is
// responsible for matching by name, same as the existing sample-name-
// table matching bt_transplant_bank already did.
//
// new_data_offset/new_data_size describe where this sample's re-encoded
// FADPCM frames will land in the rebuilt FSB5 data region. pcm/
// pcm_sample_count are the decoded-then-FADPCM-re-encoded audio, used
// only to recompute the peak value.
//
// Writes the patched 16 bytes to out_header. Returns 0 on success, -1
// if fsb5_write_base_header isn't implemented yet (see
// FSB5SampleHeaderIO.h) or the stock header doesn't parse.
int fsb5_rebuild_sample_header(const uint8_t stock_header[FSB5_STOCK_HEADER_BYTES],
                                uint32_t new_data_offset, uint32_t new_data_size,
                                const int16_t *pcm, size_t pcm_sample_count,
                                uint8_t out_header[FSB5_STOCK_HEADER_BYTES]);

#ifdef __cplusplus
}
#endif
