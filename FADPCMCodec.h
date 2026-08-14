// FADPCMCodec.h
//
// Encoder + decoder for the ADPCM variant FSB5 calls "FADPCM" (FSB5
// codec id 16). Frame layout and the decode formula below are taken
// directly from Overview.md §6, which sourced them from vgmstream's
// FADPCM reader (itself cross-checked against FMOD's own PC DLLs):
//
//   - 0x8C (140) byte frames, mono per channel (stereo = independent
//     per-channel frame streams, per Overview.md - NOT sample-interleaved).
//   - 12-byte frame header:
//       bytes 0-3: eight packed 4-bit coefficient-table indices, one
//                  per 8-sample group (8 groups/frame)
//       bytes 4-7: eight packed 4-bit shift factors, same grouping
//       bytes 8-9:  int16 hist1 (most recent decoded sample)
//       bytes 10-11: int16 hist2 (second most recent decoded sample)
//   - 8 groups x 16 bytes = 128 bytes of nibble data, 32 samples/group,
//     256 samples/frame.
//   - decode per nibble:
//       shift  = 0x16 - shift_factor
//       scaled = sign_extend4(nibble) << shift
//       pred   = hist2*coef2 - hist1*coef1
//       sample = clamp16((scaled - pred) >> 6)
//       hist2 = hist1; hist1 = sample
//
// KNOWN GAP - coefficient table: Overview.md confirms the table has 8
// entries, mostly {0,0}, with four nonzero entries {60,0}, {122,60},
// {115,52}, {98,55} - but does NOT confirm which index holds which
// value (that mapping wasn't in the source material this was built
// from). FADPCM_COEFS below is a placeholder ordering (zeros first,
// then the four nonzero entries in the order Overview.md listed them)
// - it is NOT verified bit-for-bit and must be checked against a known
// decoder (vgmstream's fadpcm.c table, or a hex dump of a real FADPCM
// frame's index nibbles vs. its own decoded output) before this is
// trusted for anything beyond round-trip self-tests. Get this wrong
// and encoded audio will decode to noise on-device while still round-
// tripping fine against this file's own decoder, so don't treat a
// passing self-test as proof the table is correct.

#import <stdint.h>
#import <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FADPCM_FRAME_BYTES     140
#define FADPCM_SAMPLES_PER_FRAME 256
#define FADPCM_GROUPS_PER_FRAME 8
#define FADPCM_SAMPLES_PER_GROUP 32
#define FADPCM_NUM_COEFS 8

typedef struct { int16_t coef1, coef2; } FadpcmCoef;

// See "KNOWN GAP" above - placeholder ordering, unverified.
extern const FadpcmCoef fadpcm_coefs[FADPCM_NUM_COEFS];

// Encodes mono PCM16 into consecutive FADPCM frames. sample_count may be
// any length; the final frame is zero-padded (silence) if it doesn't
// fill a whole 256-sample frame - the caller is responsible for tracking
// the true sample_count separately (as FSB5's sample header already does)
// so playback stops at the right point rather than playing the pad.
//
// out_frames must have room for fadpcm_frame_count(sample_count) *
// FADPCM_FRAME_BYTES bytes. Returns the number of frames written.
size_t fadpcm_encode(const int16_t *pcm, size_t sample_count, uint8_t *out_frames);

// Decodes FADPCM frames back to mono PCM16, writing exactly
// frame_count * FADPCM_SAMPLES_PER_FRAME samples to out_pcm. Used to
// verify fadpcm_encode via round-trip before trusting it against real
// game audio - does NOT confirm on-device correctness (see KNOWN GAP).
void fadpcm_decode(const uint8_t *frames, size_t frame_count, int16_t *out_pcm);

static inline size_t fadpcm_frame_count(size_t sample_count) {
    return (sample_count + FADPCM_SAMPLES_PER_FRAME - 1) / FADPCM_SAMPLES_PER_FRAME;
}

#ifdef __cplusplus
}
#endif
