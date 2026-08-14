// FSB5SampleHeaderIO.m — see the header for why this is a stub.

#import "FSB5SampleHeaderIO.h"

int fsb5_read_base_header(const uint8_t header8[8], FSB5BaseHeaderFields *out) {
    (void)header8;
    (void)out;
    // TODO: port the bit-packing logic that already reads this
    // correctly per Overview.md §1 ("internally-consistent, monotonically
    // increasing data offsets and a constant 24 kHz/stereo across all 10
    // samples"). Not guessing at it here - see FSB5SampleHeaderIO.h.
    return -1;
}

int fsb5_write_base_header(uint8_t header8[8], const FSB5BaseHeaderFields *in) {
    (void)header8;
    (void)in;
    // TODO: same as above, inverse direction.
    return -1;
}
