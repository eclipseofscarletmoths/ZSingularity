// FSB5HeaderRebuild.m — see FSB5HeaderRebuild.h.

#import "FSB5HeaderRebuild.h"
#import "FSB5SampleHeaderIO.h"
#import <string.h>
#import <stdlib.h>

int fsb5_rebuild_sample_header(const uint8_t stock_header[FSB5_STOCK_HEADER_BYTES],
                                uint32_t new_data_offset, uint32_t new_data_size,
                                const int16_t *pcm, size_t pcm_sample_count,
                                uint8_t out_header[FSB5_STOCK_HEADER_BYTES]) {
    (void)new_data_size; // not part of FSB5BaseHeaderFields per §1's notes - per-sample size is implicit from the next sample's offset (or dataSize for the last), same as FSB5VorbisExtract's read side

    FSB5BaseHeaderFields fields;
    if (fsb5_read_base_header(stock_header, &fields) != 0) return -1; // unimplemented plug point, see FSB5SampleHeaderIO.h

    fields.data_offset = new_data_offset;
    // frequency_hz / channels / num_samples / has_extradata: left as stock's own values, unchanged.

    memcpy(out_header, stock_header, FSB5_STOCK_HEADER_BYTES);
    if (fsb5_write_base_header(out_header, &fields) != 0) return -1;

    // Extension (bytes 8-15): constant `08 00 00 1A` (per §1) + a
    // per-sample float peak value in [0,1]. Recompute the peak from the
    // actual re-encoded content; leave the leading 4 constant bytes as
    // stock had them (copied via the memcpy above, untouched here).
    float peak = 0.0f;
    for (size_t i = 0; i < pcm_sample_count; i++) {
        float a = pcm[i] < 0 ? -(float)pcm[i] : (float)pcm[i];
        float norm = a / 32768.0f;
        if (norm > peak) peak = norm;
    }
    if (peak > 1.0f) peak = 1.0f;
    memcpy(out_header + 12, &peak, sizeof(float)); // assumes the float sits in the extension's trailing 4 bytes, matching "08 00 00 1A + float" order from §1 - unverified beyond what §1 already states

    return 0;
}
