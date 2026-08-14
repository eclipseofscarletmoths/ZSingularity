// FADPCMCodec.m — see FADPCMCodec.h for format notes and the coefficient
// table caveat. Plain C, no ObjC, kept as .m only to match this project's
// existing convention (BankTransplant.m does the same).

#import "FADPCMCodec.h"
#import <stdlib.h>
#import <string.h>

const FadpcmCoef fadpcm_coefs[FADPCM_NUM_COEFS] = {
    {0, 0},
    {60, 0},
    {122, 60},
    {115, 52},
    {98, 55},
    {0, 0},
    {0, 0},
    {0, 0},
};

static inline int16_t clamp16(int64_t v) {
    if (v > INT16_MAX) return INT16_MAX;
    if (v < INT16_MIN) return INT16_MIN;
    return (int16_t)v;
}

// nibble is stored as an unsigned 4-bit value; sign-extend per Overview.md.
static inline int sign_extend4(uint8_t nibble) {
    int v = nibble & 0xF;
    return (v & 0x8) ? (v - 16) : v;
}

static inline int16_t fadpcm_decode_sample(uint8_t nibble, int shift_factor,
                                            int16_t coef1, int16_t coef2,
                                            int16_t hist1, int16_t hist2) {
    int shift = 0x16 - shift_factor;
    int64_t scaled = (int64_t)sign_extend4(nibble) << shift;
    int64_t pred = (int64_t)hist2 * coef2 - (int64_t)hist1 * coef1;
    return clamp16((scaled - pred) >> 6);
}

#pragma mark - Decoder (reference, used for round-trip verification)

void fadpcm_decode(const uint8_t *frames, size_t frame_count, int16_t *out_pcm) {
    for (size_t f = 0; f < frame_count; f++) {
        const uint8_t *frame = frames + f * FADPCM_FRAME_BYTES;
        int16_t hist1 = (int16_t)(frame[8]  | (frame[9]  << 8));
        int16_t hist2 = (int16_t)(frame[10] | (frame[11] << 8));

        for (int g = 0; g < FADPCM_GROUPS_PER_FRAME; g++) {
            int coef_idx    = (frame[g / 2] >> ((g % 2) * 4)) & 0xF;
            int shift_factor = (frame[4 + g / 2] >> ((g % 2) * 4)) & 0xF;
            // FMOD/vgmstream folds coefficient indices 7+ back into the
            // seven defined entries (index 7 therefore repeats index 0).
            int16_t coef1 = fadpcm_coefs[coef_idx % 7].coef1;
            int16_t coef2 = fadpcm_coefs[coef_idx % 7].coef2;

            const uint8_t *group = frame + 12 + g * 16;
            int16_t *out = out_pcm + f * FADPCM_SAMPLES_PER_FRAME + g * FADPCM_SAMPLES_PER_GROUP;

            for (int i = 0; i < FADPCM_SAMPLES_PER_GROUP; i++) {
                uint8_t byte = group[i / 2];
                uint8_t nibble = (i % 2 == 0) ? (byte & 0xF) : (byte >> 4);
                int16_t sample = fadpcm_decode_sample(nibble, shift_factor, coef1, coef2, hist1, hist2);
                out[i] = sample;
                hist2 = hist1;
                hist1 = sample;
            }
        }
    }
}

#pragma mark - Encoder (analysis-by-synthesis: pick coef+shift per group by
#pragma mark   simulating the decoder and minimizing squared error, then
#pragma mark   commit using the ACTUAL decoded history so the encoder
#pragma mark   never drifts from what a real decoder will produce - this
#pragma mark   is required for any predictive/lossy codec; encoding
#pragma mark   against the un-quantized input would accumulate error.

// nibble range is 4 bits, signed: [-8, 7].
static inline int best_nibble_for_target(int64_t target_scaled_minus_pred, int shift) {
    int64_t n = target_scaled_minus_pred >> shift; // approx inverse of "scaled = nibble << shift"
    // round-to-nearest against the shifted-out bits rather than truncating
    int64_t rem = target_scaled_minus_pred - (n << shift);
    if (shift > 0) {
        int64_t half = (int64_t)1 << (shift - 1);
        if (rem >= half) n++;
        else if (rem < -half) n--;
    }
    if (n < -8) n = -8;
    if (n > 7) n = 7;
    return (int)n;
}

// Encodes one 32-sample group with a given coefficient pair, searching
// shift factors 0..15 for the lowest total squared error against `in`.
// Writes 16 bytes of packed nibbles to `out_nibbles` and returns the
// chosen shift_factor; updates *hist1/*hist2 to the real decoded
// trailing history (encoder and decoder must stay in lockstep).
static int encode_group_best_shift(const int16_t *in, int16_t coef1, int16_t coef2,
                                    int16_t *hist1, int16_t *hist2,
                                    uint8_t *out_nibbles, int64_t *out_error) {
    int best_shift = 0;
    int64_t best_err = INT64_MAX;
    uint8_t best_nibbles[16];
    int16_t best_h1 = *hist1, best_h2 = *hist2;

    for (int shift_factor = 0; shift_factor <= 15; shift_factor++) {
        int shift = 0x16 - shift_factor;
        int16_t h1 = *hist1, h2 = *hist2;
        uint8_t nibbles[16] = {0};
        int64_t err = 0;

        for (int i = 0; i < FADPCM_SAMPLES_PER_GROUP; i++) {
            int64_t pred = (int64_t)h2 * coef2 - (int64_t)h1 * coef1;
            // invert: sample*64 (roughly) == scaled - pred, i.e. scaled == sample*64 + pred
            int64_t target_scaled = ((int64_t)in[i] << 6) + pred;
            int nib = best_nibble_for_target(target_scaled, shift);
            int16_t decoded = fadpcm_decode_sample((uint8_t)(nib & 0xF), shift_factor, coef1, coef2, h1, h2);

            int64_t d = (int64_t)decoded - in[i];
            err += d * d;

            if (i % 2 == 0) nibbles[i / 2] = (uint8_t)(nib & 0xF);
            else             nibbles[i / 2] |= (uint8_t)((nib & 0xF) << 4);

            h2 = h1;
            h1 = decoded;
        }

        if (err < best_err) {
            best_err = err;
            best_shift = shift_factor;
            memcpy(best_nibbles, nibbles, 16);
            best_h1 = h1;
            best_h2 = h2;
        }
    }

    memcpy(out_nibbles, best_nibbles, 16);
    *hist1 = best_h1;
    *hist2 = best_h2;
    *out_error = best_err;
    return best_shift;
}

size_t fadpcm_encode(const int16_t *pcm, size_t sample_count, uint8_t *out_frames) {
    size_t frame_count = fadpcm_frame_count(sample_count);
    int16_t hist1 = 0, hist2 = 0;

    // Padded scratch buffer so every frame has a full 256 samples to
    // read from; padding is silence (0), matching what a decoder will
    // produce past the real sample_count if it ever reads past it.
    int16_t *padded = (int16_t *)calloc(frame_count * FADPCM_SAMPLES_PER_FRAME, sizeof(int16_t));
    memcpy(padded, pcm, sample_count * sizeof(int16_t));

    for (size_t f = 0; f < frame_count; f++) {
        uint8_t *frame = out_frames + f * FADPCM_FRAME_BYTES;
        uint8_t coef_nibbles[4] = {0};
        uint8_t shift_nibbles[4] = {0};

        int16_t frame_hist1 = hist1, frame_hist2 = hist2; // written into the frame header (state entering the frame)

        for (int g = 0; g < FADPCM_GROUPS_PER_FRAME; g++) {
            const int16_t *group_in = padded + f * FADPCM_SAMPLES_PER_FRAME + g * FADPCM_SAMPLES_PER_GROUP;

            int best_coef = 0, best_shift = 0;
            int64_t best_err = INT64_MAX;
            uint8_t best_group_nibbles[16];
            int16_t best_h1 = hist1, best_h2 = hist2;

            for (int c = 0; c < FADPCM_NUM_COEFS; c++) {
                int16_t h1 = hist1, h2 = hist2;
                uint8_t nibbles[16];
                int64_t err;
                int shift = encode_group_best_shift(group_in, fadpcm_coefs[c].coef1, fadpcm_coefs[c].coef2,
                                                      &h1, &h2, nibbles, &err);
                if (err < best_err) {
                    best_err = err;
                    best_coef = c;
                    best_shift = shift;
                    memcpy(best_group_nibbles, nibbles, 16);
                    best_h1 = h1;
                    best_h2 = h2;
                }
            }

            coef_nibbles[g / 2]  |= (uint8_t)(best_coef  << ((g % 2) * 4));
            shift_nibbles[g / 2] |= (uint8_t)(best_shift << ((g % 2) * 4));
            memcpy(frame + 12 + g * 16, best_group_nibbles, 16);

            hist1 = best_h1;
            hist2 = best_h2;
        }

        memcpy(frame + 0, coef_nibbles, 4);
        memcpy(frame + 4, shift_nibbles, 4);
        frame[8]  = (uint8_t)(frame_hist1 & 0xFF);
        frame[9]  = (uint8_t)((frame_hist1 >> 8) & 0xFF);
        frame[10] = (uint8_t)(frame_hist2 & 0xFF);
        frame[11] = (uint8_t)((frame_hist2 >> 8) & 0xFF);
    }

    free(padded);
    return frame_count;
}
