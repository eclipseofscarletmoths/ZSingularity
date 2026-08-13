#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZSyslogController : NSObject

+ (instancetype)sharedController;

/// Starts the jailed-device log capture. The capture mirrors FLEXNewLogController:
/// stdout/stderr are temporarily redirected through an NSPipe and each chunk is
/// forwarded to the on-screen handler as plain text.
- (BOOL)start;

/// Stops collection, restores stdout/stderr, and clears the pipe.
- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Called on the main thread for each newly received text chunk/line.
@property (nonatomic, copy, nullable) void (^lineHandler)(NSString *line);

@end

NS_ASSUME_NONNULL_END
