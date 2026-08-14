// VorbisSetupTable.h
//
// FSB5's Vorbis sample headers store only a crc32 of the Vorbis
// identification+setup (codebook) packet pair, not the packets
// themselves - per Overview.md §6, confirmed against python-fsb5
// (MIT-licensed, the reference FSB5-modding library): decoding requires
// looking that crc32 up against a table of FMOD's own preset
// setup-headers, which python-fsb5's maintainers had to dump directly
// out of FMOD's binaries because they aren't derivable from the FSB5
// file itself.
//
// That table is FMOD's own proprietary codec data, not something this
// tool can derive or ship a copy of sight-unseen. This header defines
// the lookup interface the rest of the pipeline needs and a loader for
// a bundled resource file - +loadFromResourceNamed: expects a table you
// build yourself offline (e.g. by exporting python-fsb5's known
// presets, which you'd need to already have installed/licensed for your
// own use, into the flat binary format documented below) and drop into
// the app bundle. Without that file populated, every sample whose
// crc32 isn't covered fails closed with
// BankTransplantErrorVorbisSetupUnknown rather than guessing.
//
// Bundled resource format (little-endian):
//   u32 entry_count
//   entry_count * {
//     u32 crc32
//     u32 setup_packet_len
//     u8  setup_packet[setup_packet_len]   // identification + setup packets, concatenated, Ogg-packet-framed
//   }

#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface VorbisSetupTable : NSObject

+ (nullable instancetype)loadFromResourceNamed:(NSString *)name error:(NSError **)error;

// NULL if crc32 isn't in the table. Pointer is owned by the table and
// valid for its lifetime.
- (nullable const uint8_t *)setupPacketForCRC32:(uint32_t)crc32 length:(size_t *)outLength;

@property (nonatomic, readonly) NSUInteger entryCount;

@end

NS_ASSUME_NONNULL_END
