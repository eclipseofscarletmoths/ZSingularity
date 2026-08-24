#import "ZSyslogController.h"
#import <unistd.h>
#import <fcntl.h>

@interface ZSyslogController ()
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, strong) NSPipe *pipe;
@property (nonatomic, assign) int stdoutCopy;
@property (nonatomic, assign) int stderrCopy;
@property (nonatomic, assign) BOOL restoredDescriptors;
@end

@implementation ZSyslogController

+ (instancetype)sharedController {
    static ZSyslogController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [ZSyslogController new];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stdoutCopy = -1;
        _stderrCopy = -1;
    }
    return self;
}

- (BOOL)start {
    if (self.running) return YES;

    int outCopy = dup(STDOUT_FILENO);
    int errCopy = dup(STDERR_FILENO);
    if (outCopy < 0 || errCopy < 0) {
        if (outCopy >= 0) close(outCopy);
        if (errCopy >= 0) close(errCopy);
        return NO;
    }

    NSPipe *pipe = [NSPipe pipe];
    if (!pipe) {
        close(outCopy);
        close(errCopy);
        return NO;
    }

    int writeFD = pipe.fileHandleForWriting.fileDescriptor;
    if (dup2(writeFD, STDOUT_FILENO) < 0 || dup2(writeFD, STDERR_FILENO) < 0) {

        dup2(outCopy, STDOUT_FILENO);
        dup2(errCopy, STDERR_FILENO);
        close(outCopy);
        close(errCopy);
        return NO;
    }

    self.stdoutCopy = outCopy;
    self.stderrCopy = errCopy;
    self.pipe = pipe;
    self.restoredDescriptors = NO;

    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;

        ZSyslogController *strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str.length > 0) {

            NSArray<NSString *> *parts = [str componentsSeparatedByCharactersInSet:
                                           [NSCharacterSet newlineCharacterSet]];
            for (NSString *part in parts) {
                if (part.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{
                    ZSyslogController *mainSelf = weakSelf;
                    if (mainSelf.lineHandler) {
                        mainSelf.lineHandler(part);
                    }
                });
            }
        }

        int fd = strongSelf.stdoutCopy >= 0 ? strongSelf.stdoutCopy : STDOUT_FILENO;

        ssize_t remaining = (ssize_t)data.length;
        const uint8_t *bytes = data.bytes;
        while (remaining > 0) {
            ssize_t written = write(fd, bytes, (size_t)remaining);
            if (written <= 0) break;
            bytes += written;
            remaining -= written;
        }
    };

    self.running = YES;
    return YES;
}

- (void)stop {
    if (!self.pipe && self.stdoutCopy < 0 && self.stderrCopy < 0) {
        self.running = NO;
        return;
    }

    NSPipe *pipe = self.pipe;
    if (pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil;
    }

    if (!self.restoredDescriptors) {
        if (self.stdoutCopy >= 0) dup2(self.stdoutCopy, STDOUT_FILENO);
        if (self.stderrCopy >= 0) dup2(self.stderrCopy, STDERR_FILENO);
        self.restoredDescriptors = YES;
    }

    if (self.stdoutCopy >= 0) {
        close(self.stdoutCopy);
        self.stdoutCopy = -1;
    }
    if (self.stderrCopy >= 0) {
        close(self.stderrCopy);
        self.stderrCopy = -1;
    }

    self.pipe = nil;
    self.running = NO;
}

- (void)dealloc {
    [self stop];
}

@end

