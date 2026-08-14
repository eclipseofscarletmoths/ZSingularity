// BankTransplant.m
//
// See BankTransplant.h. The RIFF/FEV/SNDH/SND wrapper-chunk-walking
// utilities below (bt_walk_chunks/bt_find_wrapper_info) are carried over
// unchanged from the old splice version - they're just how both files'
// FSB5 blobs get located inside their wrapper, independent of what
// happens to the FSB5 payload itself. What's gone is bt_transplant_bank,
// which used to copy the modded FSB5 blob wholesale onto the stock
// wrapper. In its place, bt_reencode_bank below decodes every Vorbis
// sample, re-encodes to FADPCM (FADPCMCodec.h), and rebuilds each
// sample's header against stock's own (FSB5HeaderRebuild.h) instead.
//
// BUILD NOTE this file needs libvorbis (vorbis/codec.h) linked in to
// do anything - without it, bt_vorbis_decode_packets always fails with
// BankTransplantErrorVorbisDecodeFailed. It also needs
// FSB5SampleHeaderIO.m supplies the packed-header parser/writer used during
// extraction and rebuild. Both are called out here again
// because this is the file that will surface those failures at runtime.

#import "BankTransplant.h"
#import "ZTweakLog.h"
#import "FADPCMCodec.h"
#import "FSB5VorbisExtract.h"
#import "FSB5SampleHeaderIO.h"
#import "FSB5HeaderRebuild.h"
#import "VorbisSetupTable.h"
#import <stdint.h>
#import <string.h>
#import <stdlib.h>
#import <dispatch/dispatch.h> // dispatch_apply - parallelizes the per-sample decode+encode loop below

#if __has_include(<vorbis/codec.h>)
#import <vorbis/codec.h>
#define BT_HAVE_LIBVORBIS 1
#endif

NSString * const BankTransplantErrorDomain = @"BankTransplantErrorDomain";

#pragma mark - Wrapper chunk-walking (unchanged from the splice version)

typedef struct {
    uint8_t *data;
    size_t   size;
} BTBuf;

static int bt_read_file(const char *path, BTBuf *out) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return -1; }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) { fclose(f); return -1; }
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return -1; }
    fclose(f);
    out->data = buf;
    out->size = (size_t)sz;
    return 0;
}

static uint32_t bt_rd_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void bt_wr_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v);        p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);  p[3] = (uint8_t)(v >> 24);
}

typedef struct {
    size_t sndh_length_field_off;
    size_t snd_size_field_off;
    size_t fsb5_offset;
} BTWrapperInfo;

static int bt_walk_chunks(const uint8_t *data, size_t off, size_t end, BTWrapperInfo *info) {
    while (off + 8 <= end) {
        const uint8_t *cid = data + off;
        uint32_t size = bt_rd_u32(data + off + 4);
        size_t payload = off + 8;

        if (memcmp(cid, "LIST", 4) == 0 && size >= 4) {
            if (bt_walk_chunks(data, payload + 4, payload + size, info) != 0) return -1;
        } else if (memcmp(cid, "SNDH", 4) == 0 && size == 12) {
            info->sndh_length_field_off = payload + 8;
        } else if (memcmp(cid, "SND ", 4) == 0) {
            info->snd_size_field_off = off + 4;
            info->fsb5_offset = payload + 12;
        }
        off = payload + size + (size & 1);
    }
    return 0;
}

static int bt_find_wrapper_info(const BTBuf *bank, BTWrapperInfo *info) {
    memset(info, 0, sizeof(*info));
    if (bank->size < 12 || memcmp(bank->data, "RIFF", 4) != 0 || memcmp(bank->data + 8, "FEV ", 4) != 0)
        return -1;
    uint32_t riff_size = bt_rd_u32(bank->data + 4);
    if (riff_size < 4 || 12 + (riff_size - 4) > bank->size) return -1;
    if (bt_walk_chunks(bank->data, 12, 12 + (riff_size - 4), info) != 0) return -1;
    if (!info->sndh_length_field_off || !info->snd_size_field_off || !info->fsb5_offset) return -1;
    if (info->fsb5_offset + 4 > bank->size || memcmp(bank->data + info->fsb5_offset, "FSB5", 4) != 0) return -1;
    return 0;
}

#pragma mark - Stock (FADPCM) sample header table - fixed 16 bytes/sample, per §1

#define BT_MAX_SAMPLES FSB5_MAX_SAMPLES

typedef struct {
    char name[64];
    uint8_t header[FSB5_STOCK_HEADER_BYTES];
} BTStockSample;

// Stock's FSB5 is mode 16 (FADPCM), fixed 16-byte headers - much simpler
// to walk than the modded/Vorbis variable-size table in
// FSB5VorbisExtract.m, since there's no per-sample extradata to skip.
static int bt_read_stock_fadpcm_samples(const uint8_t *fsb5, size_t fsb5_len,
                                          BTStockSample *out, int max_samples, int *out_count) {
    if (fsb5_len < 0x3C) return -1;
    // Field order is signature(4)/version(4)/numSamples(4)/sampleHeadersSize(4)/
    // nameTableSize(4)/dataSize(4)/mode(4) - mode is at +24, not +4 (that's
    // version, always 1). Confirmed against the real Original/Modded sample
    // banks: +4 reads back 1 for both, +24 reads back 16/15 as expected.
    int32_t mode              = (int32_t)bt_rd_u32(fsb5 + 24);
    int32_t num_samples       = (int32_t)bt_rd_u32(fsb5 + 8);
    int32_t sample_headers_sz = (int32_t)bt_rd_u32(fsb5 + 12);
    if (mode != 16) return -1; // stock should already be FADPCM
    if (num_samples <= 0 || num_samples > max_samples) return -1;
    if ((size_t)sample_headers_sz != (size_t)num_samples * FSB5_STOCK_HEADER_BYTES) return -1; // fixed-size assumption from §1

    size_t base = 0x3C;
    size_t name_table_base = base + (size_t)sample_headers_sz;
    if (name_table_base + (size_t)num_samples * 4 > fsb5_len) return -1;

    for (int32_t i = 0; i < num_samples; i++) {
        memcpy(out[i].header, fsb5 + base + (size_t)i * FSB5_STOCK_HEADER_BYTES, FSB5_STOCK_HEADER_BYTES);

        uint32_t rel = bt_rd_u32(fsb5 + name_table_base + (size_t)i * 4);
        size_t s = name_table_base + rel;
        if (s > fsb5_len) return -1;
        size_t e = s;
        while (e < fsb5_len && fsb5[e] != 0) e++;
        size_t len = e - s;
        if (len > 63) len = 63;
        memcpy(out[i].name, fsb5 + s, len);
        out[i].name[len] = 0;
    }
    *out_count = num_samples;
    return 0;
}

#pragma mark - Vorbis decode (needs libvorbis + a populated VorbisSetupTable)

#ifdef BT_HAVE_LIBVORBIS
// Decodes one FSB5-framed Vorbis sample (length-prefixed packets, per
// FSB5VorbisExtract.h) to interleaved PCM16, given the identification+
// setup packets looked up by crc32. Returns malloc'd PCM (caller frees)
// and sample count via *out_count, or NULL on failure.
static int16_t *bt_vorbis_decode_packets(const uint8_t *packet_stream, size_t packet_stream_len,
                                          const uint8_t *setup_packets, size_t setup_packets_len,
                                          int channels, int sample_rate, size_t *out_sample_count) {
    // setup_packets is the raw Vorbis SETUP packet only (crc32-keyed,
    // straight out of VorbisSetupTable) - not an id+setup pair. FMOD's
    // presets only key the setup packet (the big codebook data); the
    // identification packet is small and fully derivable from data we
    // already have (channels/sample_rate), so it's synthesized below
    // rather than looked up. FSB5 doesn't carry a separate comment
    // packet either, so an empty one is synthesized too (libvorbis's
    // header chain requires exactly three: identification, comment, setup).
    vorbis_info vi; vorbis_info_init(&vi);
    vorbis_comment vc; vorbis_comment_init(&vc);
    vorbis_dsp_state vd;
    vorbis_block vb;

    ogg_packet header_id = {0}, header_comment = {0}, header_setup = {0};

    if (setup_packets_len == 0) goto fail_headers;
    header_setup.packet = (unsigned char *)setup_packets;
    header_setup.bytes = (long)setup_packets_len;

    // Standard 30-byte Vorbis identification header, synthesized from
    // channels/sample_rate rather than looked up - see this function's
    // header comment. blocksize_0=8/blocksize_1=11 (packed as 0xB8) is
    // FSB5's fixed default; worth cross-checking against python-fsb5's
    // generate_vorbis_headers() before trusting on real audio, same as
    // any other binary layout in this project - not guessed at lightly,
    // but not independently re-derived from first principles here either.
    uint8_t id_buf[30];
    id_buf[0] = 0x01;
    memcpy(id_buf + 1, "vorbis", 6);
    uint32_t ver = 0;
    memcpy(id_buf + 7, &ver, 4);                          // vorbis_version = 0
    id_buf[11] = (uint8_t)channels;
    uint32_t sr = (uint32_t)sample_rate;
    memcpy(id_buf + 12, &sr, 4);
    uint32_t zero = 0;
    memcpy(id_buf + 16, &zero, 4);                        // bitrate_maximum
    memcpy(id_buf + 20, &zero, 4);                        // bitrate_nominal
    memcpy(id_buf + 24, &zero, 4);                        // bitrate_minimum
    id_buf[28] = 0xB8;                                    // blocksize_0=8, blocksize_1=11
    id_buf[29] = 0x01;                                    // framing flag
    header_id.packet = id_buf;
    header_id.bytes = sizeof(id_buf);
    header_id.b_o_s = 1;

    static const unsigned char empty_comment[] = {
        3, 'v','o','r','b','i','s',   // packet type 3, "vorbis" magic
        0,0,0,0,                      // vendor_length = 0 (no vendor string follows)
        0,0,0,0,                      // user_comment_list_length = 0 (no comments follow)
        1,                            // framing bit
    };                                 // 16 bytes total - the previous 11-byte version
                                        // was missing user_comment_list_length and the
                                        // framing bit, which is almost certainly why
                                        // libvorbis was rejecting every sample: this
                                        // header gets fed to vorbis_synthesis_headerin
                                        // before the real setup packet ever does.
    header_comment.packet = (unsigned char *)empty_comment;
    header_comment.bytes = sizeof(empty_comment);

    if (vorbis_synthesis_headerin(&vi, &vc, &header_id) != 0) goto fail_headers;
    if (vorbis_synthesis_headerin(&vi, &vc, &header_comment) != 0) goto fail_headers;
    if (vorbis_synthesis_headerin(&vi, &vc, &header_setup) != 0) goto fail_headers;

    if (vorbis_synthesis_init(&vd, &vi) != 0) goto fail_headers;
    vorbis_block_init(&vd, &vb);

    size_t cap = 1 << 16, count = 0;
    int16_t *pcm = (int16_t *)malloc(cap * sizeof(int16_t));

    size_t p = 0;
    while (p + 2 <= packet_stream_len) {
        uint16_t plen = (uint16_t)(packet_stream[p] | (packet_stream[p+1] << 8));
        p += 2;
        if (p + plen > packet_stream_len) break;

        ogg_packet op = {0};
        op.packet = (unsigned char *)(packet_stream + p);
        op.bytes = plen;
        p += plen;

        if (vorbis_synthesis(&vb, &op) == 0) {
            vorbis_synthesis_blockin(&vd, &vb);
        }

        float **pcm_out;
        int samples;
        while ((samples = vorbis_synthesis_pcmout(&vd, &pcm_out)) > 0) {
            if (count + (size_t)samples * channels > cap) {
                cap = (count + (size_t)samples * channels) * 2;
                pcm = (int16_t *)realloc(pcm, cap * sizeof(int16_t));
            }
            for (int i = 0; i < samples; i++) {
                for (int c = 0; c < channels; c++) {
                    float v = pcm_out[c][i];
                    int32_t iv = (int32_t)(v * 32767.0f);
                    if (iv > 32767) iv = 32767;
                    if (iv < -32768) iv = -32768;
                    pcm[count++] = (int16_t)iv;
                }
            }
            vorbis_synthesis_read(&vd, samples);
        }
    }

    vorbis_block_clear(&vb);
    vorbis_dsp_clear(&vd);
    vorbis_comment_clear(&vc);
    vorbis_info_clear(&vi);

    *out_sample_count = count / (channels > 0 ? channels : 1);
    return pcm;

fail_headers:
    vorbis_comment_clear(&vc);
    vorbis_info_clear(&vi);
    *out_sample_count = 0;
    return NULL;
}
#endif

#pragma mark - Re-encode pipeline (replaces bt_transplant_bank)

// Decodes+encodes every modded sample in parallel via dispatch_apply.
// Pulled out of bt_reencode_bank into its own function because a block
// literal that captures a __strong variable (setupTable) opens an
// ARC-managed lifetime scope that a C `goto` cannot jump forward past -
// bt_reencode_bank has several early-exit `goto done;` statements before
// this point, and having the block inline there made all of them illegal
// ("jump enters lifetime of block which strongly captures a variable").
// Keeping the block in a separate function sidesteps that entirely: this
// function has no goto/label of its own, and the caller only needs one
// `goto done;` for the whole call, which doesn't cross anything.
//
// Writes into decoded_pcm/decoded_counts/encoded_fadpcm/encoded_bytes
// (each already calloc'd by the caller to modded_count entries) and
// returns 0 on success, or the first per-item BankTransplantErrorCode
// encountered on failure (which one "first" is is nondeterministic under
// concurrency, but any real failure here indicates every sample should be
// treated as failed anyway, so which index reported it doesn't matter).
static BankTransplantErrorCode bt_reencode_all_samples(FSB5VorbisSample *modded, int modded_count,
                                                         VorbisSetupTable *setupTable,
                                                         int16_t **decoded_pcm, size_t *decoded_counts,
                                                         uint8_t **encoded_fadpcm, size_t *encoded_bytes) {
    // Each sample's decode+encode is fully independent of every other
    // sample's (separate libvorbis state on the stack in
    // bt_vorbis_decode_packets, separate scratch buffers here) - the only
    // shared thing touched is setupTable, which is read-only after
    // +loadFromResourceNamed:error: returns, so concurrent
    // -setupPacketForCRC32:length: calls are safe. dispatch_apply blocks
    // the calling thread until every iteration completes.
    BankTransplantErrorCode *per_item_code = (BankTransplantErrorCode *)calloc((size_t)modded_count, sizeof(BankTransplantErrorCode));
    dispatch_apply((size_t)modded_count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i_) {
        int i = (int)i_;
        size_t setup_len = 0;
        const uint8_t *setup = [setupTable setupPacketForCRC32:modded[i].setup_crc32 length:&setup_len];
        if (!setup) { per_item_code[i] = BankTransplantErrorVorbisSetupUnknown; return; }

        size_t sample_count = 0;
        int16_t *pcm = bt_vorbis_decode_packets(modded[i].packet_stream, modded[i].packet_stream_len,
                                                  setup, setup_len, modded[i].channels, modded[i].sample_rate, &sample_count);
        if (!pcm) { per_item_code[i] = BankTransplantErrorVorbisDecodeFailed; return; }
        decoded_pcm[i] = pcm;
        decoded_counts[i] = sample_count;

        // FADPCM encode is mono-per-channel-stream (FADPCMCodec.h); for
        // stereo, de-interleave, encode each channel's frame stream
        // independently, then concatenate - per Overview.md §6's note
        // that FADPCM stereo is per-channel frames, not sample-interleaved.
        int ch = modded[i].channels > 0 ? modded[i].channels : 1;
        size_t frames_per_ch = fadpcm_frame_count(sample_count);
        size_t total_bytes = frames_per_ch * FADPCM_FRAME_BYTES * ch;
        uint8_t *enc = (uint8_t *)malloc(total_bytes);

        int16_t *mono = (int16_t *)malloc(sample_count * sizeof(int16_t));
        for (int c = 0; c < ch; c++) {
            for (size_t s = 0; s < sample_count; s++) mono[s] = pcm[s * ch + c];
            fadpcm_encode(mono, sample_count, enc + (size_t)c * frames_per_ch * FADPCM_FRAME_BYTES);
        }
        free(mono);

        encoded_fadpcm[i] = enc;
        encoded_bytes[i] = total_bytes;
    });

    BankTransplantErrorCode result = 0;
    for (int i = 0; i < modded_count; i++) {
        if (per_item_code[i] != 0) { result = per_item_code[i]; break; }
    }
    free(per_item_code);
    return result;
}

static int bt_reencode_bank(const char *original_path, const char *modded_path, const char *out_path,
                             VorbisSetupTable *setupTable,
                             BankTransplantErrorCode *outCode) {
    BTBuf orig = {0}, mod = {0};
    int rc = -1;
    int16_t **decoded_pcm = NULL;
    size_t *decoded_counts = NULL;
    uint8_t **encoded_fadpcm = NULL;
    size_t *encoded_bytes = NULL;
    uint8_t *out = NULL;

    if (bt_read_file(original_path, &orig) != 0) { *outCode = BankTransplantErrorCantReadOriginal; goto done; }
    if (bt_read_file(modded_path, &mod) != 0) { *outCode = BankTransplantErrorCantReadModded; goto done; }

    BTWrapperInfo orig_info, mod_info;
    if (bt_find_wrapper_info(&orig, &orig_info) != 0) { *outCode = BankTransplantErrorBadOriginalWrapper; goto done; }
    if (bt_find_wrapper_info(&mod, &mod_info) != 0) { *outCode = BankTransplantErrorBadModdedWrapper; goto done; }

    const uint8_t *fsb5_o = orig.data + orig_info.fsb5_offset;
    const uint8_t *fsb5_m = mod.data  + mod_info.fsb5_offset;
    size_t fsb5_o_len = orig.size - orig_info.fsb5_offset;
    size_t fsb5_m_len = mod.size  - mod_info.fsb5_offset;

    static BTStockSample stock[BT_MAX_SAMPLES];
    int stock_count = 0;
    if (bt_read_stock_fadpcm_samples(fsb5_o, fsb5_o_len, stock, BT_MAX_SAMPLES, &stock_count) != 0) {
        *outCode = BankTransplantErrorBadOriginalWrapper; goto done;
    }

    static FSB5VorbisSample modded[BT_MAX_SAMPLES];
    int modded_count = fsb5_extract_vorbis_samples(fsb5_m, fsb5_m_len, modded, BT_MAX_SAMPLES);
    if (modded_count < 0) { *outCode = BankTransplantErrorBadModdedWrapper; goto done; }
    if (modded_count == 0 || modded[0].setup_crc32 == 0) { /* extractor already refuses mode != 15 */ }

    if (stock_count != modded_count) { *outCode = BankTransplantErrorSampleSetMismatch; goto done; }
    for (int i = 0; i < stock_count; i++) {
        if (strcmp(stock[i].name, modded[i].name) != 0) { *outCode = BankTransplantErrorSampleSetMismatch; goto done; }
    }

#ifndef BT_HAVE_LIBVORBIS
    *outCode = BankTransplantErrorVorbisNotLinked; // <vorbis/codec.h> not found - this is a build-config problem, not a bad sample
    goto done;
#else
    decoded_pcm    = (int16_t **)calloc(modded_count, sizeof(int16_t *));
    decoded_counts = (size_t *)calloc(modded_count, sizeof(size_t));
    encoded_fadpcm = (uint8_t **)calloc(modded_count, sizeof(uint8_t *));
    encoded_bytes  = (size_t *)calloc(modded_count, sizeof(size_t));

    {
        BankTransplantErrorCode reencode_err = bt_reencode_all_samples(modded, modded_count, setupTable,
                                                                         decoded_pcm, decoded_counts,
                                                                         encoded_fadpcm, encoded_bytes);
        if (reencode_err != 0) { *outCode = reencode_err; goto done; }
    }

    // Rebuild headers + assemble new FSB5 data region, in stock's
    // sample order (already name-matched 1:1 against modded above).
    static uint8_t new_headers[BT_MAX_SAMPLES][FSB5_STOCK_HEADER_BYTES];
    // FSB5 sample offsets are stored in 16-byte units, so every sample
    // start must be 16-byte aligned. FADPCM frame sizes are 140 bytes and
    // therefore do not preserve alignment by themselves.
    size_t running_offset = 0;
    for (int i = 0; i < stock_count; i++) {
        running_offset = (running_offset + 15U) & ~((size_t)15U);
        if (fsb5_rebuild_sample_header(stock[i].header, (uint32_t)running_offset, (uint32_t)encoded_bytes[i],
                                        decoded_pcm[i], decoded_counts[i], new_headers[i]) != 0) {
            *outCode = BankTransplantErrorWriteFailed;
            goto done;
        }
        running_offset += encoded_bytes[i];
    }

    size_t wrapper_len = orig_info.fsb5_offset;
    size_t fsb5_header_len = 0x3C;
    size_t sample_headers_len = (size_t)stock_count * FSB5_STOCK_HEADER_BYTES;
    // Name table is byte-identical to stock's (same names, same order) -
    // copy it straight from the original FSB5 rather than rebuilding it.
    size_t name_table_off_o = fsb5_header_len + sample_headers_len;
    // stock's own sampleHeadersSize/nameTableSize let us find where its name table ends.
    int32_t orig_sample_headers_sz = (int32_t)bt_rd_u32(fsb5_o + 12);
    int32_t orig_name_table_sz     = (int32_t)bt_rd_u32(fsb5_o + 16);
    if ((size_t)orig_sample_headers_sz != sample_headers_len) { *outCode = BankTransplantErrorBadOriginalWrapper; goto done; }
    size_t name_table_len = (size_t)orig_name_table_sz;

    size_t new_fsb5_len = fsb5_header_len + sample_headers_len + name_table_len + running_offset;
    size_t new_size = wrapper_len + new_fsb5_len;
    out = (uint8_t *)malloc(new_size);

    memcpy(out, orig.data, wrapper_len); // wrapper bytes up to FSB5, unchanged
    uint8_t *fsb5_out = out + wrapper_len;
    memcpy(fsb5_out, fsb5_o, fsb5_header_len); // top-level FSB5 header, patched below
    for (int i = 0; i < stock_count; i++) {
        memcpy(fsb5_out + fsb5_header_len + (size_t)i * FSB5_STOCK_HEADER_BYTES, new_headers[i], FSB5_STOCK_HEADER_BYTES);
    }
    memcpy(fsb5_out + fsb5_header_len + sample_headers_len, fsb5_o + fsb5_header_len + sample_headers_len, name_table_len); // name table, verbatim
    size_t data_write_off = fsb5_header_len + sample_headers_len + name_table_len;
    size_t data_cursor = 0;
    for (int i = 0; i < stock_count; i++) {
        size_t aligned = (data_cursor + 15U) & ~((size_t)15U);
        if (aligned > data_cursor) {
            memset(fsb5_out + data_write_off + data_cursor, 0, aligned - data_cursor);
        }
        memcpy(fsb5_out + data_write_off + aligned, encoded_fadpcm[i], encoded_bytes[i]);
        data_cursor = aligned + encoded_bytes[i];
    }
    running_offset = data_cursor;
    bt_wr_u32(fsb5_out + 20, (uint32_t)running_offset); // FSB5 dataSize field

    bt_wr_u32(out + 4,                              (uint32_t)(wrapper_len - 8 + new_fsb5_len)); // RIFF size
    bt_wr_u32(out + orig_info.sndh_length_field_off, (uint32_t)new_fsb5_len);                     // SNDH length
    bt_wr_u32(out + orig_info.snd_size_field_off,    (uint32_t)(new_fsb5_len + 12));               // SND chunk size

    FILE *f = fopen(out_path, "wb");
    if (!f) { *outCode = BankTransplantErrorWriteFailed; goto done; }
    size_t written = fwrite(out, 1, new_size, f);
    fclose(f);
    if (written != new_size) { *outCode = BankTransplantErrorWriteFailed; goto done; }

    rc = 0;
#endif

done:
    if (decoded_pcm) { for (int i = 0; i < modded_count; i++) free(decoded_pcm[i]); free(decoded_pcm); }
    if (encoded_fadpcm) { for (int i = 0; i < modded_count; i++) free(encoded_fadpcm[i]); free(encoded_fadpcm); }
    free(decoded_counts);
    free(encoded_bytes);
    free(out);
    free(orig.data);
    free(mod.data);
    return rc;
}

#pragma mark - ObjC wrapper (unchanged in shape from the splice version - same public API)

static NSError *BTError(BankTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:BankTransplantErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * const kBTBackupSuffix = @".orig-bak";
static NSString * const kBTVorbisSetupResourceName = @"FSB5VorbisSetupTable.bin"; // see VorbisSetupTable.h

@implementation BankTransplant

+ (NSString *)mobileFMODBuildsDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"Assets/Sound/FMODBuilds/Mobile"];
}

+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL error:(NSError **)error {
    BOOL accessing = [moddedURL startAccessingSecurityScopedResource];

    NSString *fileName = moddedURL.lastPathComponent;
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *originalPath = mobileDir ? [mobileDir stringByAppendingPathComponent:fileName] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!originalPath || ![fm fileExistsAtPath:originalPath]) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorOriginalNotFound,
            [NSString stringWithFormat:@"No stock bank named \"%@\" found under Assets/Sound/FMODBuilds/Mobile.", fileName]);
        return NO;
    }

    NSError *setupErr = nil;
    VorbisSetupTable *setupTable = [VorbisSetupTable loadFromResourceNamed:kBTVorbisSetupResourceName error:&setupErr];
    if (!setupTable) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorVorbisSetupUnknown, setupErr.localizedDescription ?: @"Couldn't load the Vorbis setup-packet table.");
        return NO;
    }

    NSString *backupPath = [originalPath stringByAppendingString:kBTBackupSuffix];
    if (![fm fileExistsAtPath:backupPath]) {
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:originalPath toPath:backupPath error:&copyErr]) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            if (error) *error = BTError(BankTransplantErrorBackupFailed,
                [NSString stringWithFormat:@"Couldn't back up %@ before touching it: %@", fileName, copyErr.localizedDescription]);
            return NO;
        }
        ZLog(@"[BankTransplant] backed up %@ -> %@", fileName, backupPath.lastPathComponent);
    }

    NSString *tmpOutPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.reencode.%@", fileName, [NSUUID UUID].UUIDString]];

    BankTransplantErrorCode code = 0;
    int rc = bt_reencode_bank(originalPath.fileSystemRepresentation,
                               moddedURL.path.fileSystemRepresentation,
                               tmpOutPath.fileSystemRepresentation,
                               setupTable,
                               &code);

    if (accessing) [moddedURL stopAccessingSecurityScopedResource];

    if (rc != 0) {
        [fm removeItemAtPath:tmpOutPath error:nil];
        if (error) *error = BTError(code, [self messageForErrorCode:code fileName:fileName]);
        return NO;
    }

    NSError *replaceErr = nil;
    BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                      withItemAtURL:[NSURL fileURLWithPath:tmpOutPath]
                     backupItemName:nil
                            options:0
                   resultingItemURL:nil
                              error:&replaceErr];
    [fm removeItemAtPath:tmpOutPath error:nil];

    if (!ok) {
        if (error) *error = BTError(BankTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Re-encode succeeded but swapping %@ in place failed: %@", fileName, replaceErr.localizedDescription]);
        return NO;
    }

    ZLog(@"[BankTransplant] re-encoded modded Vorbis samples to FADPCM, swapped %@ in place", fileName);
    return YES;
}

+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error {
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:mobileDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: BTError(BankTransplantErrorOriginalNotFound, @"Couldn't list the Mobile FMOD build directory.");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *entry in entries) {
        if (![entry hasSuffix:kBTBackupSuffix]) continue;
        NSString *backupPath = [mobileDir stringByAppendingPathComponent:entry];
        NSString *originalPath = [backupPath substringToIndex:backupPath.length - kBTBackupSuffix.length];

        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:backupPath toPath:tmpPath error:&copyErr]) {
            ZLog(@"[BankTransplant] restore: couldn't stage %@: %@", entry, copyErr.localizedDescription);
            continue;
        }
        NSError *replaceErr = nil;
        BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                          withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                         backupItemName:nil
                                options:0
                       resultingItemURL:nil
                                  error:&replaceErr];
        [fm removeItemAtPath:tmpPath error:nil];
        if (ok) {
            restored++;
        } else {
            ZLog(@"[BankTransplant] restore: couldn't swap %@ back in: %@", originalPath.lastPathComponent, replaceErr.localizedDescription);
        }
    }
    return restored;
}

+ (NSString *)messageForErrorCode:(BankTransplantErrorCode)code fileName:(NSString *)fileName {
    switch (code) {
        case BankTransplantErrorCantReadModded:
            return [NSString stringWithFormat:@"Couldn't read the picked file %@.", fileName];
        case BankTransplantErrorOriginalNotFound:
            return [NSString stringWithFormat:@"No stock bank named \"%@\" found.", fileName];
        case BankTransplantErrorCantReadOriginal:
            return [NSString stringWithFormat:@"Couldn't read the stock bank %@.", fileName];
        case BankTransplantErrorBadOriginalWrapper:
            return @"The stock bank's FEV/RIFF wrapper or FADPCM sample table didn't parse as expected.";
        case BankTransplantErrorBadModdedWrapper:
            return @"The picked bank's FEV/RIFF wrapper or Vorbis sample table didn't parse as expected.";
        case BankTransplantErrorSampleSetMismatch:
            return @"Refused to re-encode: the two banks' FSB5 sample name tables don't match, so they're not the same bank/build.";
        case BankTransplantErrorModdedNotVorbis:
            return @"The picked bank's samples aren't Vorbis-coded - nothing to re-encode.";
        case BankTransplantErrorVorbisNotLinked:
            return @"This build has no Vorbis decoder linked in at all (<vorbis/codec.h> wasn't found at compile time) - check that build.yml's -I/-L flags for vendor/ogg and vendor/vorbis-src actually ran before this compile step, and that libogg.a/libvorbis.a built successfully.";
        case BankTransplantErrorVorbisSetupUnknown:
            return @"A sample's Vorbis setup data isn't in the bundled preset table, so it can't be decoded. See VorbisSetupTable.h.";
        case BankTransplantErrorVorbisDecodeFailed:
            return @"libvorbis is linked and ran, but rejected this sample's packet stream - a real decode failure (bad packet framing, wrong setup packet for this crc32, or similar), not a build/link problem.";
        case BankTransplantErrorBackupFailed:
            return @"Couldn't create a backup of the stock bank before touching it.";
        case BankTransplantErrorWriteFailed:
            return @"Re-encode or swap-in failed while writing the rebuilt FSB5 bank.";
    }
    return @"Unknown bank transplant failure.";
}

@end
