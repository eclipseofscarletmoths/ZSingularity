// BankTransplant.m
//
// See BankTransplant.h. The chunk-walking/splice core below is a direct
// port of bank_transplant.c (kept as plain C, static to this file) -
// only the file IO at the edges changed, to work with paths/URLs inside
// the app sandbox and to report failures as NSError instead of a bare
// int. The wrapper-parsing and splice logic itself is untouched: it
// still locates SNDH/SND by walking generic RIFF chunks rather than
// hardcoded offsets, and still refuses to splice two banks whose FSB5
// sample name tables don't match exactly (see bt_fsb5_sample_names).

#import "BankTransplant.h"
#import "ZTweakLog.h"
#import <stdint.h>
#import <string.h>

NSString * const BankTransplantErrorDomain = @"BankTransplantErrorDomain";

#pragma mark - Ported C core (see bank_transplant.c for the original, commented version)

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
    size_t sndh_length_field_off; // offset of the 4-byte "fsb5 length" field inside SNDH
    size_t snd_size_field_off;    // offset of the "SND " chunk's own RIFF size field
    size_t fsb5_offset;           // absolute offset of the FSB5 blob (== SND payload + 12)
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
            info->fsb5_offset = payload + 12; // 12-byte zero pad precedes "FSB5"
        }
        off = payload + size + (size & 1); // RIFF word-align padding
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

#define BT_MAX_SAMPLES 256

static int bt_fsb5_sample_names(const uint8_t *fsb5, size_t fsb5_len, char names[][64], int max_names, int *out_count) {
    if (fsb5_len < 0x3C) return -1;
    int32_t numSamples        = (int32_t)bt_rd_u32(fsb5 + 8);
    int32_t sampleHeadersSize = (int32_t)bt_rd_u32(fsb5 + 12);
    size_t base = 0x3C;
    if (sampleHeadersSize < 0 || base + (size_t)sampleHeadersSize > fsb5_len) return -1;
    size_t nt_start = base + (size_t)sampleHeadersSize;
    if (numSamples <= 0 || numSamples > max_names) return -1;
    if (nt_start + (size_t)numSamples * 4 > fsb5_len) return -1;
    *out_count = numSamples;
    for (int i = 0; i < numSamples; i++) {
        uint32_t rel = bt_rd_u32(fsb5 + nt_start + i * 4);
        size_t s = nt_start + rel;
        if (s > fsb5_len) return -1;
        size_t e = s;
        while (e < fsb5_len && fsb5[e] != 0) e++;
        size_t len = e - s;
        if (len > 63) len = 63;
        memcpy(names[i], fsb5 + s, len);
        names[i][len] = 0;
    }
    return 0;
}

// Splices modded_path's FSB5 payload onto original_path's wrapper and
// writes the result to out_path. Returns 0 on success; on failure returns
// a negative BankTransplantErrorCode-compatible reason via *outCode
// (caller maps it straight into an NSError).
static int bt_transplant_bank(const char *original_path, const char *modded_path, const char *out_path,
                               BankTransplantErrorCode *outCode) {
    BTBuf orig = {0}, mod = {0};
    int rc = -1;

    if (bt_read_file(original_path, &orig) != 0) { *outCode = BankTransplantErrorCantReadOriginal; goto done; }
    if (bt_read_file(modded_path, &mod) != 0) { *outCode = BankTransplantErrorCantReadModded; goto done; }

    BTWrapperInfo orig_info, mod_info;
    if (bt_find_wrapper_info(&orig, &orig_info) != 0) { *outCode = BankTransplantErrorBadOriginalWrapper; goto done; }
    if (bt_find_wrapper_info(&mod, &mod_info) != 0) { *outCode = BankTransplantErrorBadModdedWrapper; goto done; }

    static char names_o[BT_MAX_SAMPLES][64];
    static char names_m[BT_MAX_SAMPLES][64];
    int count_o = 0, count_m = 0;
    const uint8_t *fsb5_o = orig.data + orig_info.fsb5_offset;
    const uint8_t *fsb5_m = mod.data  + mod_info.fsb5_offset;
    size_t fsb5_o_len = orig.size - orig_info.fsb5_offset;
    size_t fsb5_m_len = mod.size  - mod_info.fsb5_offset;

    if (bt_fsb5_sample_names(fsb5_o, fsb5_o_len, names_o, BT_MAX_SAMPLES, &count_o) != 0) { *outCode = BankTransplantErrorBadOriginalWrapper; goto done; }
    if (bt_fsb5_sample_names(fsb5_m, fsb5_m_len, names_m, BT_MAX_SAMPLES, &count_m) != 0) { *outCode = BankTransplantErrorBadModdedWrapper; goto done; }
    if (count_o != count_m) { *outCode = BankTransplantErrorSampleSetMismatch; goto done; }
    for (int i = 0; i < count_o; i++) {
        if (strcmp(names_o[i], names_m[i]) != 0) { *outCode = BankTransplantErrorSampleSetMismatch; goto done; }
    }

    size_t wrapper_len = orig_info.fsb5_offset;
    size_t new_size = wrapper_len + fsb5_m_len;
    uint8_t *out = (uint8_t *)malloc(new_size);
    if (!out) { *outCode = BankTransplantErrorWriteFailed; goto done; }
    memcpy(out, orig.data, wrapper_len);
    memcpy(out + wrapper_len, fsb5_m, fsb5_m_len);

    bt_wr_u32(out + 4,                              (uint32_t)(wrapper_len - 8 + fsb5_m_len)); // RIFF size
    bt_wr_u32(out + orig_info.sndh_length_field_off, (uint32_t)fsb5_m_len);                     // SNDH length
    bt_wr_u32(out + orig_info.snd_size_field_off,    (uint32_t)(fsb5_m_len + 12));               // SND chunk size

    FILE *f = fopen(out_path, "wb");
    if (!f) { free(out); *outCode = BankTransplantErrorWriteFailed; goto done; }
    size_t written = fwrite(out, 1, new_size, f);
    fclose(f);
    free(out);
    if (written != new_size) { *outCode = BankTransplantErrorWriteFailed; goto done; }

    rc = 0;
done:
    free(orig.data);
    free(mod.data);
    return rc;
}

#pragma mark - ObjC wrapper

static NSError *BTError(BankTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:BankTransplantErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * const kBTBackupSuffix = @".orig-bak";

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

    // One-time backup of the untouched stock file, never overwritten once
    // it exists - so repeated re-swaps of the same bank (e.g. after
    // re-picking an updated mod) can never lose the original.
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
        [NSString stringWithFormat:@"%@.transplant.%@", fileName, [NSUUID UUID].UUIDString]];

    BankTransplantErrorCode code = 0;
    int rc = bt_transplant_bank(originalPath.fileSystemRepresentation,
                                 moddedURL.path.fileSystemRepresentation,
                                 tmpOutPath.fileSystemRepresentation,
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
    [fm removeItemAtPath:tmpOutPath error:nil]; // no-op if replaceItemAtURL already consumed it

    if (!ok) {
        if (error) *error = BTError(BankTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Splice succeeded but swapping %@ in place failed: %@", fileName, replaceErr.localizedDescription]);
        return NO;
    }

    ZLog(@"[BankTransplant] spliced modded FSB5 payload from %@ onto stock wrapper, swapped in place", fileName);
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
            return @"The stock bank's FEV/RIFF wrapper didn't parse as expected (missing/unexpected SNDH+SND or FSB5 chunk).";
        case BankTransplantErrorBadModdedWrapper:
            return @"The picked bank's FEV/RIFF wrapper didn't parse as expected (missing/unexpected SNDH+SND or FSB5 chunk).";
        case BankTransplantErrorSampleSetMismatch:
            return @"Refused to splice: the two banks' FSB5 sample name tables don't match, so they're not the same bank/build.";
        case BankTransplantErrorBackupFailed:
            return @"Couldn't create a backup of the stock bank before touching it.";
        case BankTransplantErrorWriteFailed:
            return @"Splice or swap-in failed while writing to disk.";
    }
    return @"Unknown bank transplant failure.";
}

@end
