// FSB5SampleHeaderIO.m
//
// FSB5's per-sample base header is a packed little-endian 64-bit word.
// Layout (LSB -> MSB), matching the public FSB5 parser used by python-fsb5:
//   bit 0      : has extra metadata chunks
//   bits 1..4  : frequency table index (1=8 kHz ... 9=48 kHz)
//   bit 5      : stereo flag (0=mono, 1=stereo)
//   bits 6..33 : data offset in 16-byte units
//   bits 34..63: decoded sample count
//
// FSB5 stores the sample offset in 16-byte units, not raw bytes. Keep the
// public struct byte-oriented so callers don't have to know about that
// storage detail; the conversion is performed here in one place.

#import "FSB5SampleHeaderIO.h"

static const uint32_t kFSB5FrequencyTable[] = {
    0,     // invalid / unused
    8000,
    11000,
    11025,
    16000,
    22050,
    24000,
    32000,
    44100,
    48000,
};

static uint64_t rd_u64_le(const uint8_t p[8]) {
    return ((uint64_t)p[0])
         | ((uint64_t)p[1] << 8)
         | ((uint64_t)p[2] << 16)
         | ((uint64_t)p[3] << 24)
         | ((uint64_t)p[4] << 32)
         | ((uint64_t)p[5] << 40)
         | ((uint64_t)p[6] << 48)
         | ((uint64_t)p[7] << 56);
}

static void wr_u64_le(uint8_t p[8], uint64_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
    p[4] = (uint8_t)(v >> 32);
    p[5] = (uint8_t)(v >> 40);
    p[6] = (uint8_t)(v >> 48);
    p[7] = (uint8_t)(v >> 56);
}

int fsb5_read_base_header(const uint8_t header8[8], FSB5BaseHeaderFields *out) {
    if (!header8 || !out) return -1;

    uint64_t raw = rd_u64_le(header8);
    uint32_t frequency_index = (uint32_t)((raw >> 1) & 0x0FULL);
    uint32_t offset_units    = (uint32_t)((raw >> 6) & 0x0FFFFFFFULL);
    uint32_t sample_count    = (uint32_t)((raw >> 34) & 0x3FFFFFFFULL);

    if (frequency_index == 0 || frequency_index >= (sizeof(kFSB5FrequencyTable) / sizeof(kFSB5FrequencyTable[0]))) {
        return -1;
    }

    uint64_t byte_offset = (uint64_t)offset_units * 16ULL;
    if (byte_offset > UINT32_MAX) return -1;

    out->data_offset = (uint32_t)byte_offset;
    out->frequency_hz = kFSB5FrequencyTable[frequency_index];
    out->channels = (uint8_t)(((raw >> 5) & 1ULL) + 1ULL);
    out->num_samples = sample_count;
    out->has_extradata = (int)(raw & 1ULL);

    if (out->channels < 1 || out->channels > 2) return -1;
    return 0;
}

int fsb5_write_base_header(uint8_t header8[8], const FSB5BaseHeaderFields *in) {
    if (!header8 || !in) return -1;

    uint32_t frequency_index = 0;
    for (uint32_t i = 1; i < (uint32_t)(sizeof(kFSB5FrequencyTable) / sizeof(kFSB5FrequencyTable[0])); i++) {
        if (kFSB5FrequencyTable[i] == in->frequency_hz) {
            frequency_index = i;
            break;
        }
    }
    if (frequency_index == 0) return -1;
    if (in->channels != 1 && in->channels != 2) return -1;
    if ((in->data_offset & 0x0F) != 0) return -1; // FSB5 stores offsets in 16-byte units.
    if (in->data_offset / 16U > 0x0FFFFFFFU) return -1;
    if (in->num_samples > 0x3FFFFFFFU) return -1;
    if (in->has_extradata != 0 && in->has_extradata != 1) return -1;

    // Reconstruct the complete packed word. All represented fields account
    // for all 64 bits, so there are no unknown bits to preserve.
    uint64_t raw = 0;
    raw |= (uint64_t)(in->has_extradata ? 1U : 0U);
    raw |= (uint64_t)frequency_index << 1;
    raw |= (uint64_t)(in->channels == 2 ? 1U : 0U) << 5;
    raw |= (uint64_t)(in->data_offset / 16U) << 6;
    raw |= (uint64_t)in->num_samples << 34;

    wr_u64_le(header8, raw);
    return 0;
}
