// FMODVorbisProbe.m
//
// See FMODVorbisProbe.h for the why. This file is two independent
// halves glued together at the bottom:
//
//   1. fvp_extract_fsb5_blob() - wrapper-chunk-walking to pull the raw
//      FSB5 bytes out of a .bank, plain C, ported from the same
//      approach as bt_find_wrapper_info/bt_walk_chunks in
//      BankTransplant.m (kept independent rather than shared, since
//      this only needs to LOCATE the blob, not touch sample headers or
//      the name table at all).
//   2. fvp_resolve_live_fmod_system() - IL2CppBridge calls to pull the
//      native FMOD_SYSTEM* out of FMODUnity.RuntimeManager.CoreSystem,
//      plus dlsym'd native FMOD C API calls to actually create the
//      sound from that system.

#import "FMODVorbisProbe.h"
#import "IL2CppBridge.h"
#import "ZTweakLog.h"
#import <stdint.h>
#import <string.h>
#import <dlfcn.h>

NSString * const FMODVorbisProbeErrorDomain = @"FMODVorbisProbeErrorDomain";

#pragma mark - Part 1: locate the FSB5 blob inside a .bank (see BankTransplant.m for the original wrapper-walk this is ported from)

typedef struct {
    uint8_t *data;
    size_t   size;
} FVPBuf;

static int fvp_read_file(const char *path, FVPBuf *out) {
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

static uint32_t fvp_rd_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// Only needs the FSB5 blob's start offset - unlike BankTransplant this
// never rewrites any length fields, so it doesn't need SNDH/SND field
// offsets, only where "FSB5" itself starts.
static int fvp_walk_chunks(const uint8_t *data, size_t off, size_t end, size_t *out_fsb5_offset) {
    while (off + 8 <= end) {
        const uint8_t *cid = data + off;
        uint32_t size = fvp_rd_u32(data + off + 4);
        size_t payload = off + 8;

        if (memcmp(cid, "LIST", 4) == 0 && size >= 4) {
            if (fvp_walk_chunks(data, payload + 4, payload + size, out_fsb5_offset) != 0) return -1;
        } else if (memcmp(cid, "SND ", 4) == 0) {
            *out_fsb5_offset = payload + 12; // 12-byte zero pad precedes "FSB5", same as BankTransplant
        }
        off = payload + size + (size & 1); // RIFF word-align padding
    }
    return 0;
}

// Returns 0 and fills *out_fsb5_start/*out_fsb5_len on success (the
// span covering the ENTIRE FSB5 blob to end-of-file, all samples
// included, completely unmodified). Non-zero on any parse failure.
static int fvp_find_fsb5_blob(const FVPBuf *bank, size_t *out_fsb5_start, size_t *out_fsb5_len) {
    if (bank->size < 12 || memcmp(bank->data, "RIFF", 4) != 0 || memcmp(bank->data + 8, "FEV ", 4) != 0)
        return -1;
    uint32_t riff_size = fvp_rd_u32(bank->data + 4);
    if (riff_size < 4 || 12 + (riff_size - 4) > bank->size) return -1;

    size_t fsb5_offset = 0;
    if (fvp_walk_chunks(bank->data, 12, 12 + (riff_size - 4), &fsb5_offset) != 0) return -1;
    if (!fsb5_offset || fsb5_offset + 4 > bank->size || memcmp(bank->data + fsb5_offset, "FSB5", 4) != 0) return -1;

    *out_fsb5_start = fsb5_offset;
    *out_fsb5_len = bank->size - fsb5_offset;
    return 0;
}

// FSB5Header layout (id/version/numSamples/sampleHeadersSize/nameTableSize/
// dataSize/mode, each a 4-byte LE field in that order) puts "mode" at
// byte offset 0x18 - confirmed against the two sample banks in the
// project notes (mode 15 = Vorbis, 16 = FADPCM at that same offset).
#define FVP_FSB5_MODE_OFFSET 0x18
#define FVP_FSB5_MODE_VORBIS 15

#pragma mark - Part 2: the live FMOD_SYSTEM* and native call

// FMOD_RESULT is a plain 32-bit enum in the C ABI (FMOD_RESULT_FORCEINT
// forces it signed 32-bit) - only the handful of values worth naming
// individually are mapped; anything else just prints its number. Full
// list is in FMOD's own fmod_common.h if this needs extending.
static NSString *fvp_fmod_result_name(int result) {
    switch (result) {
        case 0:  return @"FMOD_OK";
        case 18: return @"FMOD_ERR_FILE_BAD";
        case 22: return @"FMOD_ERR_FORMAT";
        case 26: return @"FMOD_ERR_HEADER_MISMATCH";
        case 28: return @"FMOD_ERR_INITIALIZATION";
        case 30: return @"FMOD_ERR_INTERNAL";
        case 32: return @"FMOD_ERR_INVALID_HANDLE";
        case 33: return @"FMOD_ERR_INVALID_PARAM";
        case 39: return @"FMOD_ERR_MEMORY";
        case 47: return @"FMOD_ERR_PLUGIN";
        case 48: return @"FMOD_ERR_PLUGIN_MISSING";
        case 62: return @"FMOD_ERR_UNIMPLEMENTED";
        case 63: return @"FMOD_ERR_UNINITIALIZED";
        case 64: return @"FMOD_ERR_UNSUPPORTED";
        case 65: return @"FMOD_ERR_VERSION";
        default: return [NSString stringWithFormat:@"FMOD_RESULT #%d", result];
    }
}

static NSString *fvp_fmod_soundtype_name(int type) {
    static const char *names[] = {
        "UNKNOWN","AIFF","ASF","AT3","DLS","FLAC","FSB","GCADPCM","IT","MIDI","MOD","MPEG",
        "OGGVORBIS","PLAYLIST","RAW","S3M","USER","WAV","XM","XMA","VAG","AUDIOQUEUE","XWMA",
        "BCWAV","AT9","VORBIS","MEDIA_FOUNDATION","MEDIACODEC","FADPCM"
    };
    if (type >= 0 && (size_t)type < sizeof(names) / sizeof(names[0])) return [NSString stringWithUTF8String:names[type]];
    return [NSString stringWithFormat:@"#%d", type];
}

static NSString *fvp_fmod_soundformat_name(int format) {
    static const char *names[] = {
        "NONE","PCM8","PCM16","PCM24","PCM32","PCMFLOAT","GCADPCM","IMAADPCM","VAG","HEVAG",
        "XMA","MPEG","CELT","AT9","XWMA","VORBIS","FADPCM"
    };
    if (format >= 0 && (size_t)format < sizeof(names) / sizeof(names[0])) return [NSString stringWithUTF8String:names[format]];
    return [NSString stringWithFormat:@"#%d", format];
}

typedef int (*FMOD_System_CreateSound_fn)(void *system, const char *name_or_data, unsigned int mode, void *exinfo, void **sound);
typedef int (*FMOD_Sound_GetFormat_fn)(void *sound, int *type, int *format, int *channels, int *bits);
typedef int (*FMOD_Sound_GetLength_fn)(void *sound, unsigned int *length, unsigned int lengthtype);
typedef int (*FMOD_Sound_Release_fn)(void *sound);

#define FVP_FMOD_DEFAULT       0x00000000u
#define FVP_FMOD_2D            0x00000008u
#define FVP_FMOD_CREATESAMPLE  0x00000100u  // decode eagerly, synchronously - so a decode failure surfaces in this same call
#define FVP_FMOD_TIMEUNIT_MS   0x00000001u

// Reads FMODUnity.RuntimeManager.CoreSystem's boxed FMOD.System return
// value and pulls the native pointer out of its "handle" field - the
// FMOD C# wrapper (fmod.cs, part of every FMODUnity integration) wraps
// every native handle type (System/Sound/Channel/...) as a struct with
// exactly one private IntPtr field named "handle". If field lookup by
// that name fails (a differently-named build of the wrapper), this
// logs both attempts and returns NULL rather than guessing an offset.
static void *fvp_resolve_live_fmod_system(void) {
    static const char *kAssemblySubstrings[] = { "FMODUnity", "FMOD", "" };
    void *runtimeManagerClass = NULL;
    for (size_t i = 0; i < sizeof(kAssemblySubstrings) / sizeof(kAssemblySubstrings[0]); i++) {
        runtimeManagerClass = [IL2CppBridge classNamed:"RuntimeManager" inNamespace:"FMODUnity" assemblyContains:kAssemblySubstrings[i]];
        if (runtimeManagerClass) break;
    }
    if (!runtimeManagerClass) {
        ZLog(@"[FMODVorbisProbe] couldn't find FMODUnity.RuntimeManager in any loaded assembly");
        return NULL;
    }

    const void *getCoreSystem = [IL2CppBridge methodOnClass:runtimeManagerClass name:"get_CoreSystem" argCount:0];
    if (!getCoreSystem) {
        ZLog(@"[FMODVorbisProbe] found RuntimeManager but not get_CoreSystem - check the IL2CPP dump for the actual property/method name on this build");
        return NULL;
    }

    void *exc = NULL;
    void *boxedSystem = [IL2CppBridge invokeMethod:getCoreSystem onInstance:NULL args:NULL outException:&exc];
    if (exc || !boxedSystem) {
        ZLog(@"[FMODVorbisProbe] RuntimeManager.CoreSystem getter threw or returned null");
        return NULL;
    }

    void *boxedClass = [IL2CppBridge classOfInstance:boxedSystem];
    int32_t handleOffset = [IL2CppBridge fieldOffsetOnClass:boxedClass name:"handle"];
    if (handleOffset < 0) handleOffset = [IL2CppBridge fieldOffsetOnClass:boxedClass name:"Handle"];
    if (handleOffset < 0) {
        ZLog(@"[FMODVorbisProbe] FMOD.System struct has neither a \"handle\" nor \"Handle\" field - wrapper layout differs on this build, check the IL2CPP dump");
        return NULL;
    }

    void *nativeSystem = *(void **)((uint8_t *)boxedSystem + handleOffset);
    ZLog(@"[FMODVorbisProbe] resolved live FMOD_SYSTEM* = %p (via boxed field offset %d)", nativeSystem, handleOffset);
    return nativeSystem;
}

#pragma mark - ObjC wrapper

static NSError *FVPError(FMODVorbisProbeErrorCode code, NSString *message) {
    return [NSError errorWithDomain:FMODVorbisProbeErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation FMODVorbisProbe

+ (BOOL)probeVorbisSupportWithModdedBankAtURL:(NSURL *)moddedURL
                            resultDescription:(NSString * _Nullable * _Nonnull)resultDescription
                                        error:(NSError * _Nullable * _Nullable)error {
    *resultDescription = nil;

    BOOL accessing = [moddedURL startAccessingSecurityScopedResource];
    FVPBuf mod = {0};
    int readRc = fvp_read_file(moddedURL.path.fileSystemRepresentation, &mod);
    if (accessing) [moddedURL stopAccessingSecurityScopedResource];

    if (readRc != 0) {
        if (error) *error = FVPError(FMODVorbisProbeErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read %@.", moddedURL.lastPathComponent]);
        return NO;
    }

    size_t fsb5Start = 0, fsb5Len = 0;
    if (fvp_find_fsb5_blob(&mod, &fsb5Start, &fsb5Len) != 0) {
        free(mod.data);
        if (error) *error = FVPError(FMODVorbisProbeErrorBadModdedWrapper,
            @"That file's FEV/RIFF wrapper didn't parse as expected (missing/unexpected SND or FSB5 chunk).");
        return NO;
    }

    if (fsb5Len < FVP_FSB5_MODE_OFFSET + 4 || fvp_rd_u32(mod.data + fsb5Start + FVP_FSB5_MODE_OFFSET) != FVP_FSB5_MODE_VORBIS) {
        free(mod.data);
        if (error) *error = FVPError(FMODVorbisProbeErrorNotVorbisCoded,
            @"That bank's FSB5 mode field isn't Vorbis (15) - pick the desktop-coded modded .bank, not a stock/mobile one.");
        return NO;
    }

    // Stage the extracted (unmodified) FSB5 blob to a temp file -
    // FMOD_System_CreateSound reads by path here rather than
    // FMOD_OPENMEMORY, deliberately: OPENMEMORY needs a correctly
    // populated FMOD_CREATESOUNDEXINFO (a large struct in FMOD's real,
    // compiled ABI) just to specify the buffer length, and getting
    // that struct's layout even slightly wrong across FMOD versions is
    // a real crash risk in a process we don't own. A plain file path
    // needs no ex-info struct at all.
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vorbisprobe.%@.fsb", [NSUUID UUID].UUIDString]];
    FILE *tf = fopen(tempPath.fileSystemRepresentation, "wb");
    BOOL wroteOk = tf && fwrite(mod.data + fsb5Start, 1, fsb5Len, tf) == fsb5Len;
    if (tf) fclose(tf);
    free(mod.data);

    if (!wroteOk) {
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        if (error) *error = FVPError(FMODVorbisProbeErrorTempWriteFailed, @"Couldn't stage the extracted FSB5 blob to a temp file.");
        return NO;
    }

    void *system = fvp_resolve_live_fmod_system();
    if (!system) {
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        if (error) *error = FVPError(FMODVorbisProbeErrorNoLiveFMODSystem,
            @"Couldn't resolve the game's live FMOD_SYSTEM* via IL2CPP - see syslog for which step failed.");
        return NO;
    }

    FMOD_System_CreateSound_fn createSound = (FMOD_System_CreateSound_fn)dlsym(RTLD_DEFAULT, "FMOD_System_CreateSound");
    FMOD_Sound_GetFormat_fn getFormat       = (FMOD_Sound_GetFormat_fn)dlsym(RTLD_DEFAULT, "FMOD_Sound_GetFormat");
    FMOD_Sound_GetLength_fn getLength       = (FMOD_Sound_GetLength_fn)dlsym(RTLD_DEFAULT, "FMOD_Sound_GetLength");
    FMOD_Sound_Release_fn releaseSound      = (FMOD_Sound_Release_fn)dlsym(RTLD_DEFAULT, "FMOD_Sound_Release");

    if (!createSound) {
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        if (error) *error = FVPError(FMODVorbisProbeErrorNoFMODSymbols,
            @"FMOD_System_CreateSound isn't resolvable via dlsym - the native FMOD library may not export plain C symbols on this build.");
        return NO;
    }

    void *sound = NULL;
    int result = createSound(system, tempPath.fileSystemRepresentation, FVP_FMOD_CREATESAMPLE | FVP_FMOD_2D, NULL, &sound);

    NSMutableString *desc = [NSMutableString stringWithFormat:@"%@ (code %d)", fvp_fmod_result_name(result), result];
    if (result == 0 && sound) {
        int type = -1, format = -1, channels = -1, bits = -1;
        unsigned int lengthMs = 0;
        if (getFormat) getFormat(sound, &type, &format, &channels, &bits);
        if (getLength) getLength(sound, &lengthMs, FVP_FMOD_TIMEUNIT_MS);
        [desc appendFormat:@" — decoded successfully. type=%@ format=%@ channels=%d bits=%d length=%ums",
            fvp_fmod_soundtype_name(type), fvp_fmod_soundformat_name(format), channels, bits, lengthMs];
    } else {
        [desc appendString:@" — Vorbis did not load on this device's FMOD runtime."];
    }
    if (sound && releaseSound) releaseSound(sound);

    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    ZLog(@"[FMODVorbisProbe] %@", desc);
    *resultDescription = desc;
    return YES;
}

@end
