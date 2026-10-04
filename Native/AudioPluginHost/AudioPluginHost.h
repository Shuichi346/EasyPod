#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A VST3 processor exposed as an audio-effect AU for AVAudioEngine.
@interface EPVST3AudioUnit : AUAudioUnit
+ (void)registerComponent;
+ (AudioComponentDescription)componentDescription;
- (BOOL)configureWithPath:(NSString *)path
                 classID:(NSString *)classID
              sampleRate:(double)sampleRate
                channels:(NSInteger)channels
                 offline:(BOOL)offline
                   error:(NSError **)error NS_SWIFT_NAME(configure(path:classID:sampleRate:channels:offline:));
- (nullable NSData *)savePluginStateWithError:(NSError **)error NS_SWIFT_NAME(savePluginState());
- (BOOL)restorePluginState:(NSData *)state error:(NSError **)error;
- (nullable NSView *)makeEditorView;
- (void)closeEditor;
/// A nonzero status means output must be treated as failed, even if dry audio survived.
@property(nonatomic, readonly) NSInteger processingFailure;
/// Latency or bus changes require a graph rebuild at a safe stopping point.
@property(nonatomic, readonly) BOOL requiresReconfiguration;
@property(nonatomic, readonly) BOOL hasInfiniteTail;
@end

/// Scanner implementation shared with the separate helper executable.
FOUNDATION_EXPORT NSArray<NSDictionary *> *EPScanVST3(NSString *path, NSError **error);

NS_ASSUME_NONNULL_END
