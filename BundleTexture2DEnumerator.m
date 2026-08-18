// BundleTexture2DEnumerator.m
//
// See BundleTexture2DEnumerator.h for scope/architecture notes.

#import "BundleTexture2DEnumerator.h"
#import "UnityBundleCAB.h"
#import "SerializedObjectTable.h"
#import "ZTweakLog.h"
#include <stdint.h>

NSString * const BundleTexture2DEnumeratorErrorDomain = @"BundleTexture2DEnumeratorErrorDomain";

// Unity's persistent class ID for Texture2D - see SerializedObjectTable.h's
// own note on typeID (a raw m_Types index) vs. classID (this value, only
// meaningful once typesResolved is YES).
static const int32_t kZSClassIDTexture2D = 28;

static uint32_t bte_read_u32_le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static NSError *bte_error(BundleTexture2DEnumeratorErrorCode code, NSString *reason, NSError * _Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (reason) info[NSLocalizedDescriptionKey] = reason;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:BundleTexture2DEnumeratorErrorDomain code:code userInfo:info];
}

@implementation ZSTexture2DEnumeratedObject
@end

@interface BundleTexture2DEnumerator ()
@property (nonatomic, strong) UnityBundleArchive *archive;
@property (nonatomic, strong) NSData *cabNodeData;
@property (nonatomic, strong) SerializedObjectTable *objectTable;
@property (nonatomic, assign) int32_t targetPlatform;
@property (nonatomic, assign) BOOL targetPlatformKnown;
@property (nonatomic, copy) NSArray<ZSTexture2DEnumeratedObject *> *texture2DObjects;
@end

@implementation BundleTexture2DEnumerator

+ (nullable instancetype)enumeratorForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSError *archiveError = nil;
    UnityBundleArchive *archive = [UnityBundleCAB decompressedArchiveAtPath:path error:&archiveError];
    if (!archive) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorArchiveFailed,
            [NSString stringWithFormat:@"couldn't decompress bundle at %@", path], archiveError);
        return nil;
    }
    if (archive.nodes.count == 0) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorNoPrimaryNode, @"archive reported zero nodes", nil);
        return nil;
    }

    // node[0] is always the archive's own primary SerializedFile (CAB)
    // node - see UnityBundleCAB.h's top comment.
    UnityBundleNode *cabNode = archive.nodes[0];
    if (cabNode.offset < 0 || cabNode.size < 0 ||
        (uint64_t)cabNode.offset + (uint64_t)cabNode.size > archive.data.length) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorNoPrimaryNode,
            [NSString stringWithFormat:@"primary node \"%@\" range [%lld, %lld) doesn't fit inside %lu-byte archive data",
                cabNode.path, cabNode.offset, cabNode.offset + cabNode.size, (unsigned long)archive.data.length], nil);
        return nil;
    }
    NSData *cabNodeData = [archive.data subdataWithRange:NSMakeRange((NSUInteger)cabNode.offset, (NSUInteger)cabNode.size)];

    NSError *tableError = nil;
    SerializedObjectTable *table = [SerializedObjectTable tableForSerializedFileNodeData:cabNodeData error:&tableError];
    if (!table) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorObjectTableFailed,
            [NSString stringWithFormat:@"couldn't parse object table in primary node \"%@\"", cabNode.path], tableError);
        return nil;
    }
    if (!table.typesResolved) {
        // No structural basis to tell Texture2D apart from anything
        // else in this file's object table - see the error code's own
        // doc and SerializedObjectTable.h's note on the byte-scan
        // fallback. Refuse rather than guess by raw typeID.
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorClassIDsUnresolved,
            [NSString stringWithFormat:@"class IDs unresolved for \"%@\" - object table was located via byte-scan fallback, not the Types-array walk", cabNode.path], nil);
        return nil;
    }

    int32_t targetPlatform = 0;
    BOOL targetPlatformKnown = table.targetPlatformFieldOffsetKnown;
    if (targetPlatformKnown) {
        NSUInteger off = (NSUInteger)table.targetPlatformFieldOffset;
        if (off + 4 <= cabNodeData.length) {
            targetPlatform = (int32_t)bte_read_u32_le((const uint8_t *)cabNodeData.bytes + off);
        } else {
            // Shouldn't happen - the table itself derived this offset
            // structurally from the same nodeData - but don't trust a
            // read past the buffer regardless.
            targetPlatformKnown = NO;
        }
    }

    NSMutableArray<ZSTexture2DEnumeratedObject *> *results = [NSMutableArray array];
    const uint8_t *cabBytes = (const uint8_t *)cabNodeData.bytes;
    NSUInteger cabLength = cabNodeData.length;

    for (SerializedObject *entry in table.objects) {
        if (!entry.classIDResolved || entry.classID != kZSClassIDTexture2D) continue;

        ZSTexture2DEnumeratedObject *obj = [ZSTexture2DEnumeratedObject new];
        obj.pathID = entry.pathID;
        obj.tableEntry = entry;
        obj.byteSize = entry.byteSize;

        int64_t absoluteStart64 = table.dataOffset + entry.byteStart;
        if (absoluteStart64 < 0 || (uint64_t)absoluteStart64 + (uint64_t)entry.byteSize > cabLength) {
            obj.parseError = bte_error(BundleTexture2DEnumeratorErrorObjectTableFailed,
                [NSString stringWithFormat:@"pathID %lld byte range [%lld, %lld) doesn't fit inside %lu-byte CAB node data",
                    entry.pathID, absoluteStart64, absoluteStart64 + entry.byteSize, (unsigned long)cabLength], nil);
            [results addObject:obj];
            continue;
        }
        NSUInteger absoluteStart = (NSUInteger)absoluteStart64;
        obj.cabAbsoluteOffset = absoluteStart;

        NSData *objectBytes = [NSData dataWithBytesNoCopy:(void *)(cabBytes + absoluteStart)
                                                     length:entry.byteSize
                                               freeWhenDone:NO];
        NSError *schemaError = nil;
        ZSTexture2DInfo *info = [Texture2DSchema parseObjectBytes:objectBytes error:&schemaError];
        obj.info = info;
        obj.parseError = info ? nil : schemaError;
        [results addObject:obj];
    }

    BundleTexture2DEnumerator *enumerator = [BundleTexture2DEnumerator new];
    enumerator.archive = archive;
    enumerator.cabNodeData = cabNodeData;
    enumerator.objectTable = table;
    enumerator.targetPlatform = targetPlatform;
    enumerator.targetPlatformKnown = targetPlatformKnown;
    enumerator.texture2DObjects = results;

    ZLog(@"[BundleTexture2DEnumerator] %@: %lu Texture2D objects (%lu parsed, %lu failed), targetPlatform=%@",
         cabNode.path, (unsigned long)results.count,
         (unsigned long)[results indexesOfObjectsPassingTest:^BOOL(ZSTexture2DEnumeratedObject *o, NSUInteger idx, BOOL *stop) { return o.info != nil; }].count,
         (unsigned long)[results indexesOfObjectsPassingTest:^BOOL(ZSTexture2DEnumeratedObject *o, NSUInteger idx, BOOL *stop) { return o.info == nil; }].count,
         targetPlatformKnown ? @(targetPlatform) : @"unknown");

    return enumerator;
}

- (nullable NSData *)sourcePixelBytesForObject:(ZSTexture2DEnumeratedObject *)object error:(NSError **)error {
    ZSTexture2DInfo *info = object.info;
    if (!info) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorObjectTableFailed,
            @"object has no parsed .info (parseError is set) - nothing to resolve", nil);
        return nil;
    }

    if (info.hasInlineImageData) {
        // Already inside this object's own bytes - no archive-wide
        // lookup needed. object.cabAbsoluteOffset + info.imageDataOffset
        // is the absolute position inside cabNodeData; slice from there.
        NSUInteger absoluteImageOffset = object.cabAbsoluteOffset + info.imageDataOffset;
        if (absoluteImageOffset + info.imageDataLength > self.cabNodeData.length) {
            if (error) *error = bte_error(BundleTexture2DEnumeratorErrorStreamRangeOutOfBounds,
                @"inline image data range doesn't fit inside the CAB node - object range was already bounds-checked at enumeration time, this should not happen", nil);
            return nil;
        }
        return [self.cabNodeData subdataWithRange:NSMakeRange(absoluteImageOffset, info.imageDataLength)];
    }

    // Streamed - resolve the companion .resS node. See this method's
    // header doc for the "trailing path component identifies the node,
    // streamOffset is relative to that node's own start" convention.
    NSString *resSName = info.streamPath.lastPathComponent;
    if (resSName.length == 0) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorNoResSNode,
            [NSString stringWithFormat:@"couldn't derive a node name from streamPath \"%@\"", info.streamPath], nil);
        return nil;
    }

    UnityBundleNode *resSNode = nil;
    for (UnityBundleNode *node in self.archive.nodes) {
        if ([node.path isEqualToString:resSName]) {
            resSNode = node;
            break;
        }
    }
    if (!resSNode) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorNoResSNode,
            [NSString stringWithFormat:@"no node named \"%@\" (from streamPath \"%@\") in this archive", resSName, info.streamPath], nil);
        return nil;
    }

    if (resSNode.offset < 0 || resSNode.size < 0) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorStreamRangeOutOfBounds,
            [NSString stringWithFormat:@"node \"%@\" has a negative offset/size", resSNode.path], nil);
        return nil;
    }
    uint64_t streamEnd = info.streamOffset + (uint64_t)info.streamSize;
    if (streamEnd < info.streamOffset || streamEnd > (uint64_t)resSNode.size) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorStreamRangeOutOfBounds,
            [NSString stringWithFormat:@"stream range [%llu, %llu) doesn't fit inside %lld-byte node \"%@\"",
                info.streamOffset, streamEnd, resSNode.size, resSNode.path], nil);
        return nil;
    }
    uint64_t absoluteStart = (uint64_t)resSNode.offset + info.streamOffset;
    if (absoluteStart + info.streamSize > self.archive.data.length) {
        if (error) *error = bte_error(BundleTexture2DEnumeratorErrorStreamRangeOutOfBounds,
            [NSString stringWithFormat:@"resolved stream range [%llu, %llu) doesn't fit inside %lu-byte archive data",
                absoluteStart, absoluteStart + info.streamSize, (unsigned long)self.archive.data.length], nil);
        return nil;
    }

    return [self.archive.data subdataWithRange:NSMakeRange((NSUInteger)absoluteStart, (NSUInteger)info.streamSize)];
}

@end
