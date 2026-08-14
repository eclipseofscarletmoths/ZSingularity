// FSB5VorbisExtract.h
//
// Parses an FSB5 blob whose samples are mode 15 (Vorbis) to recover,
// per sample: numSamples, sample rate, channel count, the setup-packet
// crc32 (§6), and the raw data region (a stream of FMOD's
// length-prefixed Vorbis packets - 2-byte LE size + packet bytes,
// repeated). This layout is the same one used across open FSB5 tooling
// (python-fsb5, vgmstream's fsb5.c) - NOT independently re-verified in
// this session against the real sample banks named in Overview.md,
// since those .bank files weren't part of this upload. Treat this as
// "should be right per public prior art" rather than "confirmed against
// ground truth", and sanity-check bt_fsb5_extract_vorbis_samples's
// output (packet count, total size vs. dataSize) against a real modded
// bank before trusting it further.
//
// This only reads. It never needs to write a Vorbis header back out -
// re-encoding always targets FADPCM (FADPCMCodec.h) and a rebuilt
// header (FSB5HeaderRebuild.h), never another Vorbis file.

#import <stdint.h>
#import <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char     name[64];
    int32_t  num_samples;
    int32_t  sample_rate;
    int32_t  channels;       // 1 or 2
    uint32_t setup_crc32;
    uint32_t data_offset;     // byte offset of this sample's data within the FSB5 data region, per FSB5SampleHeaderIO's (currently unimplemented) base-header decode
    const uint8_t *packet_stream; // points into the caller's FSB5 buffer - not owned
    size_t   packet_stream_len;
} FSB5VorbisSample;

#define FSB5_MAX_SAMPLES 256

// fsb5 must point at the start of a valid FSB5 blob (mode field == 15).
// Fills out up to max_samples entries in out_samples; returns the
// number filled, or -1 on a parse error (malformed/truncated header,
// unexpected mode, or a chunk that runs past the buffer).
int fsb5_extract_vorbis_samples(const uint8_t *fsb5, size_t fsb5_len,
                                 FSB5VorbisSample *out_samples, int max_samples);

#ifdef __cplusplus
}
#endif
