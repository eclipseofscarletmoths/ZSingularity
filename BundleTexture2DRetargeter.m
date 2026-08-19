// BundleTexture2DRetargeter.m
//
// See BundleTexture2DRetargeter.h for the architecture. This file's
// own conventions worth calling out:
//
// - Every multi-byte field this writes into the CAB node buffer
//   (m_TextureFormat, m_CompleteImageSize, m_MipCount, the zeroed
//   image-data length, m_StreamData's offset/size/pathLen) is
//   LITTLE-endian, same as Texture2DSchema.m's own reads of the exact
//   same fields - see that file's top comment for why this is worth
//   stating explicitly (SerializedObjectTable.m's structural HEADER
//   fields are big-endian; everything inside the object DATA region,
//   which is everything this file touches, is little-endian).
// - m_TargetPlatform is patched via SerializedObjectTable's own
//   already-located, already-verified offset
//   (targetPlatformFieldOffset) - also little-endian, same reasoning.

#import "BundleTexture2DRetargeter.h"
#import "BundleTexture2DEnumerator.h"
#import "SerializedObjectTable.h"
#import "UnityBundleCAB.h"
#import "ZTweakLog.h"

NSString * const BundleTexture2DRetargeterErrorDomain = @"BundleTexture2DRetargeterErrorDomain";

#pragma mark - LE writers (mirrors Texture2DSchema.m's t2s_read_* naming, write direction)

static void btr_write_u32_le(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    [d appendBytes:b length:4];
}
static void btr_write_i32_le(NSMutableData *d, int32_t v) {
    btr_write_u32_le(d, (uint32_t)v);
}
static void btr_write_u64_le(NSMutableData *d, uint64_t v) {
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
    [d appendBytes:b length:8];
}
// In-place overwrite of a fixed-size field already present in `d` at
// `offset` - used for the three int32 fields patched at their EXISTING
// position (format/completeImageSize/mipCount), as opposed to the
// append-only writers above used for building a brand-new tail buffer.
static void btr_patch_i32_le(NSMutableData *d, NSUInteger offset, int32_t v) {
    uint8_t *p = (uint8_t *)d.mutableBytes + offset;
    uint32_t u = (uint32_t)v;
    p[0] = (uint8_t)u; p[1] = (uint8_t)(u >> 8); p[2] = (uint8_t)(u >> 16); p[3] = (uint8_t)(u >> 24);
}

static NSError *btr_error(BundleTexture2DRetargeterErrorCode code, NSString *reason, NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (reason) info[NSLocalizedDescriptionKey] = reason;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:BundleTexture2DRetargeterErrorDomain code:code userInfo:info];
}

#pragma mark - result classes

@implementation ZSTexture2DRetargetObjectResult
@end

@implementation ZSTexture2DRetargetSummary
@end

@implementation BundleTexture2DRetargeter

+ (nullable ZSTexture2DRetargetSummary *)retargetBundleAtPath:(NSString *)sourcePath
                                                  toPath:(NSString *)destinationPath
                                                   error:(NSError **)error {
    NSError *enumError = nil;
    BundleTexture2DEnumerator *enumerator = [BundleTexture2DEnumerator enumeratorForBundleAtPath:sourcePath error:&enumError];
    if (!enumerator) {
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorEnumerationFailed, @"bundle enumeration failed", enumError);
        return nil;
    }

    if (!enumerator.targetPlatformKnown) {
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorTargetPlatformUnknown,
                                       @"m_TargetPlatform offset not structurally known - refusing rather than guessing", nil);
        return nil;
    }

    // The CAB node this pipeline patches - a mutable copy so the
    // enumerator's own (borrowed, see BundleTexture2DEnumerator.h's own
    // MEMORY NOTE) archive.data slice is never mutated directly.
    // -[SerializedObjectTable patchObject:...] only ever touches bytes
    // via offsets, never object identity, so a copy with identical
    // layout for every byte up to the original length is a safe target
    // for it - see this file's header note.
    NSMutableData *mutableCAB = [enumerator.cabNodeData mutableCopy];
    if (!mutableCAB) {
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorEnumerationFailed, @"could not copy CAB node data", nil);
        return nil;
    }

    NSString *cabName = enumerator.archive.nodes.firstObject.path;
    NSString *resSNodeName = [NSString stringWithFormat:@"%@.zsingularity-rgba32.resS", cabName];
    NSString *newStreamPathValue = [NSString stringWithFormat:@"archive:/%@/%@", cabName, resSNodeName];
    NSData *newStreamPathUTF8 = [newStreamPathValue dataUsingEncoding:NSUTF8StringEncoding];

    // Disk-backed staging file for every converted texture's RGBA32
    // bytes - see this file's header note on why this is a brand-new
    // node rather than growing an existing one.
    NSString *stagingPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"zsingularity-retarget-%@.resS.tmp", [[NSUUID UUID] UUIDString]]];
    if (![NSFileManager.defaultManager createFileAtPath:stagingPath contents:nil attributes:nil]) {
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorStagingFileFailed, @"could not create staging file", nil);
        return nil;
    }
    NSFileHandle *stagingFH = [NSFileHandle fileHandleForWritingAtPath:stagingPath];
    if (!stagingFH) {
        [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorStagingFileFailed, @"could not open staging file for writing", nil);
        return nil;
    }

    __block int64_t stagingWriteOffset = 0;
    NSMutableArray<ZSTexture2DRetargetObjectResult *> *objectResults = [NSMutableArray array];
    __block NSInteger convertedCount = 0, unchangedCount = 0, failedCount = 0;
    // Total bytes appended to mutableCAB across every converted object's
    // relocated tail this loop - -[SerializedObjectTable patchObject:...]
    // only rewrites one entry's byteStart/byteSize, it has no visibility
    // into how much the buffer grew overall, so that bookkeeping has to
    // happen here and get applied once after the loop (see the
    // growFileSizeBy: call below and SerializedObjectTable.h's doc on it).
    __block uint64_t totalTailBytesAppended = 0;

    // Objects the enumerator itself couldn't parse - reported as
    // unchanged (nothing this class could have converted), not
    // failed - Layer B/the enumerator already logged the real reason.
    for (ZSTexture2DEnumeratedObject *obj in enumerator.texture2DObjects) {
        if (obj.info) continue;
        ZSTexture2DRetargetObjectResult *r = [ZSTexture2DRetargetObjectResult new];
        r.pathID = obj.pathID;
        r.enumeratorParseError = obj.parseError;
        [objectResults addObject:r];
        unchangedCount++;
        ZLogVerbose(@"[BundleTexture2DRetargeter]   pathID %lld: left unchanged - never reached conversion (enumerator parse failure): %@",
                    obj.pathID, obj.parseError.localizedDescription ?: @"(no detail)");
    }

    [Texture2DConverter convertObjectsInEnumerator:enumerator handler:^(ZSTexture2DConversionResult *result) {
        ZSTexture2DEnumeratedObject *obj = result.object;
        ZSTexture2DInfo *info = obj.info;

        ZSTexture2DRetargetObjectResult *r = [ZSTexture2DRetargetObjectResult new];
        r.pathID = obj.pathID;
        r.name = info.name;
        r.decision = result.decision;
        [objectResults addObject:r];

        if (result.decision == ZSTexture2DConversionNotNeeded) {
            unchangedCount++;
            return; // bytes untouched, table entry untouched - nothing to do
        }

        if (result.error || !result.rgba32Data) {
            r.error = result.error ?: btr_error(BundleTexture2DRetargeterErrorTableEntryPatchFailed, @"conversion required but no data produced", nil);
            failedCount++;
            ZLogVerbose(@"[BundleTexture2DRetargeter]   pathID %lld: FAILED before staging - %@ (%@)",
                        obj.pathID, r.error.localizedDescription ?: @"(no detail)",
                        r.error.userInfo[NSUnderlyingErrorKey] ?: @"no underlying error");
            return; // fail closed - object left exactly as it was, per Rework.txt's Layer C table
        }

        // Consumed immediately, inside this synchronous handler - never
        // retained past this scope, per Texture2DConverter.h's own
        // MEMORY POSTURE contract.
        NSData *rgba32 = result.rgba32Data;

        // Build this object's rewritten tail BEFORE touching either the
        // staging file or mutableCAB - see this method's fix note below.
        // Everything up to (not including) the image-data length field,
        // verbatim; then a fresh zero length (dropping any old inline
        // payload); then a brand-new StreamingInfo pointing at where
        // this object's bytes WILL land in the staging file once
        // actually written (thisStreamOffset == stagingWriteOffset as it
        // stands right now - nothing has been appended to the staging
        // file for this object yet). Field offsets before
        // imageDataLengthFieldOffset - including formatOffset/
        // completeImageSizeOffset/mipCountOffset - are patched in place
        // within this SAME leading slice before it's used, since they're
        // copied from the object's ORIGINAL bytes.
        int64_t thisStreamOffset = stagingWriteOffset;
        NSUInteger objBase = obj.cabAbsoluteOffset;
        NSMutableData *tail = [[enumerator.cabNodeData subdataWithRange:
                                 NSMakeRange(objBase, info.imageDataLengthFieldOffset)] mutableCopy];
        btr_patch_i32_le(tail, info.formatOffset, 4);
        btr_patch_i32_le(tail, info.completeImageSizeOffset, info.width * info.height * 4);
        btr_patch_i32_le(tail, info.mipCountOffset, 1);
        btr_write_u32_le(tail, 0); // image data length = 0 - pixels now live only in the new resS node
        btr_write_u64_le(tail, (uint64_t)thisStreamOffset); // m_StreamData.offset
        btr_write_u32_le(tail, (uint32_t)rgba32.length);     // m_StreamData.size
        btr_write_u32_le(tail, (uint32_t)newStreamPathUTF8.length); // m_StreamData.pathLen
        [tail appendData:newStreamPathUTF8];

        // NOTE: this used to also refuse when `tail.length >
        // info.objectLength` ("CAB NODE GROWTH IS SMALL"). That check
        // was never a correctness requirement - the rewritten tail is
        // ALWAYS relocated to freshly-appended space at the end of
        // mutableCAB below, never written back into the object's
        // original span, so there was nothing for that span to
        // overflow. It was only meant as a canary for "this object
        // barely shrank," but it fires unconditionally for every
        // already-STREAMED texture: a streamed object's original span
        // is already just its header + a short StreamingInfo path (no
        // inline pixels to remove), and the new resS path
        // (".zsingularity-rgba32.resS") is necessarily longer than
        // whatever short path it originally streamed from - so the
        // check rejected the majority of real conversions in a
        // streamed-heavy bundle, not just a rare edge case. See
        // Rework.txt/overview.md for the write-up. Removed.

        // From here on this object is committed: stage its RGBA32 bytes
        // and grow mutableCAB first, then only mark it converted (and
        // only leave the appended bytes in place) if patchObject: also
        // succeeds - roll both back on failure so a failure here can
        // never leave orphaned pixel data sitting in the staging file
        // or the CAB node with nothing pointing at it (the bug this
        // whole method used to have: the staging write happened before
        // any of these checks, so a rejected object's bytes rode along
        // into the final .resS anyway, unreferenced).
        @try {
            [stagingFH writeData:rgba32];
        } @catch (NSException *exc) {
            r.error = btr_error(BundleTexture2DRetargeterErrorStagingFileFailed, exc.reason ?: @"staging write failed", nil);
            failedCount++;
            ZLogVerbose(@"[BundleTexture2DRetargeter]   pathID %lld: FAILED staging write (%lu RGBA32 bytes @ offset %lld) - %@ %@",
                        obj.pathID, (unsigned long)rgba32.length, thisStreamOffset,
                        exc.name, exc.reason ?: @"(no reason)");
            return; // nothing written that stagingWriteOffset doesn't already account for - safe to just return
        }
        stagingWriteOffset += (int64_t)rgba32.length;

        int64_t newByteStartAbs = (int64_t)mutableCAB.length;
        [mutableCAB appendData:tail];

        int64_t newByteStartRelative = newByteStartAbs - enumerator.objectTable.dataOffset;
        NSError *patchErr = nil;
        BOOL patched = [enumerator.objectTable patchObject:obj.tableEntry
                                               newByteStart:newByteStartRelative
                                                newByteSize:(uint32_t)tail.length
                                                 inNodeData:mutableCAB
                                                      error:&patchErr];
        if (!patched) {
            // Roll back both appends so this failed object leaves no
            // trace in either the CAB node or the staging file.
            mutableCAB.length = (NSUInteger)newByteStartAbs;
            stagingWriteOffset = thisStreamOffset;
            @try {
                [stagingFH truncateFileAtOffset:(unsigned long long)thisStreamOffset];
                [stagingFH seekToEndOfFile];
            } @catch (NSException *exc) {
                // Staging file truncation failing is itself a hard
                // error - the file's on-disk length no longer matches
                // stagingWriteOffset's bookkeeping, and continuing
                // would risk exactly the orphaned-bytes bug this rewrite
                // exists to close. Surface it rather than pressing on.
                r.error = btr_error(BundleTexture2DRetargeterErrorStagingFileFailed,
                                     exc.reason ?: @"staging file rollback failed after table patch failure", nil);
                failedCount++;
                ZLogVerbose(@"[BundleTexture2DRetargeter]   pathID %lld: FAILED staging rollback after table patch failure - %@ %@ (original patch error: %@)",
                            obj.pathID, exc.name, exc.reason ?: @"(no reason)",
                            patchErr.localizedDescription ?: @"(no detail)");
                return;
            }
            r.error = btr_error(BundleTexture2DRetargeterErrorTableEntryPatchFailed, @"table entry patch failed", patchErr);
            failedCount++;
            ZLogVerbose(@"[BundleTexture2DRetargeter]   pathID %lld: FAILED table entry patch - tableOffset=%lu newByteStart=%lld(rel) %lld(abs) newByteSize=%lu mutableCAB.length=%lu dataOffset=%lld - %@",
                        obj.pathID, (unsigned long)obj.tableEntry.tableOffset, newByteStartRelative, newByteStartAbs,
                        (unsigned long)tail.length, (unsigned long)mutableCAB.length, enumerator.objectTable.dataOffset,
                        patchErr.localizedDescription ?: @"(no detail)");
            return;
        }

        totalTailBytesAppended += tail.length;
        r.patched = YES;
        convertedCount++;
    }];

    [stagingFH closeFile];

    if (failedCount > 0) {
        ZLog(@"[BundleTexture2DRetargeter] %ld/%lu Texture2D objects failed conversion and were left unchanged - see returned summary",
             (long)failedCount, (unsigned long)enumerator.texture2DObjects.count);
        // Roll call of exactly which pathIDs failed and why - the
        // per-object ZLogVerbose calls above this point already cover
        // each failure as it happens, but this collects them in one
        // place at the tail of the run so `failedCount > 0` on its own
        // (i.e. even in a non-Verbose Syslog capture) is enough to know
        // WHICH objects to go look at, not just how many.
        for (ZSTexture2DRetargetObjectResult *r in objectResults) {
            if (!r.error) continue;
            ZLog(@"[BundleTexture2DRetargeter]   FAILED pathID %lld (%@): %@",
                 r.pathID, r.name ?: @"?", r.error.localizedDescription ?: @"(no detail)");
        }
    }

    // m_TargetPlatform: 19 (StandaloneWindows64) -> 9 (iOS), in place,
    // via the structurally-located offset - see this class's own
    // BundleTexture2DRetargeterErrorTargetPlatformUnknown guard above.
    int32_t originalTargetPlatform = enumerator.targetPlatform;
    btr_patch_i32_le(mutableCAB, (NSUInteger)enumerator.objectTable.targetPlatformFieldOffset, 9);

    // Fix up the SerializedFile header's fileSize field to account for
    // every converted object's tail appended above - see
    // SerializedObjectTable.h's doc on growFileSizeBy: for why skipping
    // this breaks every later re-parse of this node (root-caused in
    // findings.md: the stale fileSize makes sot_decode_entry's bounds
    // check reject every relocated object's table entry, which truncates
    // the whole object-table walk at the first such entry instead of
    // just that one). Must happen before UnityBundleCAB packages
    // mutableCAB below.
    NSError *fixupErr = nil;
    ZLogVerbose(@"[BundleTexture2DRetargeter] fixing up fileSize header: %llu bytes appended across %ld converted object(s)",
                totalTailBytesAppended, (long)convertedCount);
    if (![enumerator.objectTable growFileSizeBy:totalTailBytesAppended inNodeData:mutableCAB error:&fixupErr]) {
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorHeaderFixupFailed, @"fileSize header fixup failed after appending converted object tails", fixupErr);
        [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
        return nil;
    }

    NSDictionary<NSString *, UnityBundleNode *> *origNodesByPath = ({
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (UnityBundleNode *n in enumerator.archive.nodes) m[n.path] = n;
        m;
    });

    NSMutableArray<UnityBundleNode *> *finalNodes = [NSMutableArray array];
    for (UnityBundleNode *orig in enumerator.archive.nodes) {
        UnityBundleNode *n = [UnityBundleNode new];
        n.path = orig.path;
        n.size = [orig.path isEqualToString:cabName] ? (int64_t)mutableCAB.length : orig.size;
        [finalNodes addObject:n]; // .offset filled in below, once every node's final size is known
    }
    UnityBundleNode *resSNode = [UnityBundleNode new];
    resSNode.path = resSNodeName;
    resSNode.size = stagingWriteOffset;
    [finalNodes addObject:resSNode];

    int64_t running = 0;
    for (UnityBundleNode *n in finalNodes) {
        n.offset = running;
        running += n.size;
    }

    NSError *writeErr = nil;
    BOOL ok = [UnityBundleCAB writeArchiveStreamingToPath:destinationPath
                                              unityVersion:enumerator.archive.unityVersion
                                             unityRevision:enumerator.archive.unityRevision
                                                     nodes:finalNodes
                                               cabNodePath:resSNodeName
                                               baseCABData:[NSData data]
                                            appendFilePath:stagingPath
                                              appendLength:stagingWriteOffset
                                           nodeDataAtIndex:^NSData * _Nullable(NSUInteger index) {
        UnityBundleNode *n = finalNodes[index];
        if ([n.path isEqualToString:cabName]) return mutableCAB;
        UnityBundleNode *orig = origNodesByPath[n.path];
        if (!orig) return nil; // shouldn't happen - every non-resS final node came from origNodesByPath
        return [enumerator.archive.data subdataWithRange:NSMakeRange((NSUInteger)orig.offset, (NSUInteger)orig.size)];
    }
                                                     error:&writeErr];

    [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];

    if (!ok) {
        if (error) *error = btr_error(BundleTexture2DRetargeterErrorFinalWriteFailed, @"final UnityFS write failed", writeErr);
        return nil;
    }

    ZSTexture2DRetargetSummary *summary = [ZSTexture2DRetargetSummary new];
    summary.objectResults = objectResults;
    summary.convertedCount = convertedCount;
    summary.unchangedCount = unchangedCount;
    summary.failedCount = failedCount;
    summary.originalTargetPlatform = originalTargetPlatform;
    summary.newTargetPlatform = 9;
    summary.resSNodeName = resSNodeName;
    summary.resSNodeByteLength = stagingWriteOffset;
    return summary;
}

@end
