// FSB5VorbisExtract.m -- see FSB5VorbisExtract.h.

#import "FSB5VorbisExtract.h"
#import "FSB5SampleHeaderIO.h"
#import <string.h>

static uint32_t rd_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

// FSB5 extradata chunk type for Vorbis setup data, per public FSB5
// tooling (python-fsb5's FSB5_CHUNK_VORBISDATA). Each chunk is preceded
// by a u32 "next" word: bit0 = another chunk follows, bits1-24 = this
// chunk's payload size, bits25-31 = chunk type.
#define FSB5_CHUNK_VORBISDATA 11

// Walks the extradata chunk list starting at `p` (already past the
// 8-byte base header), looking for VORBISDATA. Returns bytes consumed
// (the full chunk-list length, so the caller can advance to the next
// sample's base header) or -1 on a malformed/truncated chunk.
static long walk_extradata_for_crc32(const uint8_t *p, size_t remaining, uint32_t *out_crc32, int *found_crc32) {
    size_t consumed = 0;
    *found_crc32 = 0;
    for (;;) {
        if (consumed + 4 > remaining) return -1;
        uint32_t word = rd_u32(p + consumed);
        int more       = word & 1;
        uint32_t size  = (word >> 1) & 0x00FFFFFF; // 24 bits
        uint32_t type  = (word >> 25) & 0x7F;       // 7 bits
        consumed += 4;
        if (consumed + size > remaining) return -1;

        if (type == FSB5_CHUNK_VORBISDATA && size >= 4) {
            *out_crc32 = rd_u32(p + consumed);
            *found_crc32 = 1;
        }
        consumed += size;

        if (!more) break;
    }
    return (long)consumed;
}

int fsb5_extract_vorbis_samples(const uint8_t *fsb5, size_t fsb5_len,
                                 FSB5VorbisSample *out_samples, int max_samples) {
    if (fsb5_len < 0x3C) return -1;
    if (memcmp(fsb5, "FSB5", 4) != 0) return -1;

    // Field order is signature(4)/version(4)/numSamples(4)/sampleHeadersSize(4)/
    // nameTableSize(4)/dataSize(4)/mode(4) - mode is at +24, not +4 (that's
    // version, always 1). Same offset bug as bt_read_stock_fadpcm_samples in
    // BankTransplant.m, confirmed against the real sample banks: +4 reads back
    // 1 for both Original/Modded, +24 reads back 16/15 as expected.
    int32_t mode              = (int32_t)rd_u32(fsb5 + 24);
    int32_t num_samples_total = (int32_t)rd_u32(fsb5 + 8);
    int32_t sample_headers_sz = (int32_t)rd_u32(fsb5 + 12);
    int32_t name_table_sz     = (int32_t)rd_u32(fsb5 + 16);
    int32_t data_sz           = (int32_t)rd_u32(fsb5 + 20);

    if (mode != 15) return -1; // not Vorbis - nothing for this extractor to do (BankTransplantErrorModdedNotVorbis at the caller)
    if (num_samples_total <= 0 || num_samples_total > max_samples) return -1;
    if (sample_headers_sz < 0 || name_table_sz < 0 || data_sz < 0) return -1;

    size_t headers_base = 0x3C;
    size_t name_table_base = headers_base + (size_t)sample_headers_sz;
    size_t data_base = name_table_base + (size_t)name_table_sz;
    if (data_base > fsb5_len) return -1;

    // Name table: same layout bt_fsb5_sample_names already relies on
    // (relative-offset table into a name-table region of null-terminated
    // strings) - duplicated narrowly here rather than sharing code across
    // the two files, since the two structs (char[64] names) differ.
    if (name_table_base + (size_t)num_samples_total * 4 > fsb5_len) return -1;

    size_t cursor = headers_base;
    for (int32_t i = 0; i < num_samples_total; i++) {
        if (cursor + 8 > name_table_base) return -1;

        FSB5BaseHeaderFields base;
        if (fsb5_read_base_header(fsb5 + cursor, &base) != 0) return -1;

        size_t after_base = cursor + 8;
        uint32_t crc32 = 0;
        int found_crc32 = 0;
        long extradata_len = 0;
        if (base.has_extradata) {
            extradata_len = walk_extradata_for_crc32(fsb5 + after_base, name_table_base - after_base, &crc32, &found_crc32);
            if (extradata_len < 0) return -1;
        }
        if (!found_crc32) return -1; // Vorbis sample with no VORBISDATA chunk - shouldn't happen, refuse rather than guess

        FSB5VorbisSample *s = &out_samples[i];
        memset(s, 0, sizeof(*s));
        s->num_samples = (int32_t)base.num_samples;
        s->sample_rate = (int32_t)base.frequency_hz;
        s->channels    = base.channels;
        s->setup_crc32 = crc32;
        s->data_offset = base.data_offset;

        // Name table lookup, same relative-offset scheme as bt_fsb5_sample_names.
        uint32_t rel = rd_u32(fsb5 + name_table_base + (size_t)i * 4);
        size_t ns = name_table_base + rel;
        if (ns > fsb5_len) return -1;
        size_t ne = ns;
        while (ne < fsb5_len && fsb5[ne] != 0) ne++;
        size_t nlen = ne - ns;
        if (nlen > 63) nlen = 63;
        memcpy(s->name, fsb5 + ns, nlen);
        s->name[nlen] = 0;

        cursor = after_base + (size_t)extradata_len;
    }

    // Data region: each sample's data runs from its own data_offset to
    // the next sample's data_offset (samples are expected in ascending
    // offset order, per Overview.md §1's "monotonically increasing data
    // offsets"), or to data_sz for the last sample. Filled in a second
    // pass since every sample's offset needs to be known first.
    for (int32_t i = 0; i < num_samples_total; i++) {
        FSB5VorbisSample *s = &out_samples[i];
        uint32_t start = s->data_offset;
        uint32_t end = (i + 1 < num_samples_total) ? out_samples[i + 1].data_offset : (uint32_t)data_sz;
        if (end < start || (size_t)data_base + end > fsb5_len) return -1;
        s->packet_stream = fsb5 + data_base + start;
        s->packet_stream_len = end - start;
    }

    return num_samples_total;
}
