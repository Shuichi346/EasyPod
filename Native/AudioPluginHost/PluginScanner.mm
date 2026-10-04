#import "AudioPluginHost.h"
#include <cmath>
#include <cstdio>
#include <algorithm>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Plugin diagnostics use stdout in some factories; keep the JSON result on a dedicated file.
        if (argc < 3) { fprintf(stderr, "usage: EasyPodPluginScanner plugin.vst3 output.json [--smoke classID]\n"); return 64; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
        NSError *error = nil;
        id result = EPScanVST3(path, &error);
        if (!result) result = @{@"error": error.localizedDescription ?: @"VST3 scan failed"};
        if (argc == 5 && strcmp(argv[3], "--smoke") == 0 && !error) {
            EPVST3AudioUnit *unit = [[EPVST3AudioUnit alloc] initWithComponentDescription:EPVST3AudioUnit.componentDescription options:0 error:&error];
            NSString *classID = [NSString stringWithUTF8String:argv[4]];
            BOOL loaded = [unit configureWithPath:path classID:classID sampleRate:48000 channels:2 offline:YES error:&error];
            if (!loaded) loaded = [unit configureWithPath:path classID:classID sampleRate:48000 channels:2 offline:NO error:&error];
            NSData *state = loaded ? [unit savePluginStateWithError:&error] : nil;
            if (state) loaded = [unit restorePluginState:state error:&error];
            if (loaded) loaded = [unit allocateRenderResourcesAndReturnError:&error];
            if (loaded) {
                float channels[2][512]{};
                struct { UInt32 count; AudioBuffer buffers[2]; } list = {2, {{1, sizeof(channels[0]), channels[0]}, {1, sizeof(channels[1]), channels[1]}}};
                auto block = unit.internalRenderBlock;
                double peak = 0, delta = 0, bypassError = 0;
                int64_t latencyFrames = llround(unit.latency * 48000);
                for (int chunk = 0; chunk < 100; ++chunk) {
                    if (chunk == 50) unit.shouldBypassEffect = YES;
                    AudioTimeStamp timestamp{}; timestamp.mFlags = kAudioTimeStampSampleTimeValid; timestamp.mSampleTime = chunk * 512;
                    AudioUnitRenderActionFlags flags = 0;
                    OSStatus status = block(&flags, &timestamp, 512, 0, (AudioBufferList *)&list, nullptr,
                        ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *time, AUAudioFrameCount frames, NSInteger, AudioBufferList *input) {
                            for (UInt32 c = 0; c < input->mNumberBuffers; ++c) {
                                float *samples = (float *)input->mBuffers[c].mData;
                                for (UInt32 i = 0; i < frames; ++i) samples[i] = 0.2f * sinf((float)((time->mSampleTime + i) * 2 * M_PI * 440 / 48000));
                            }
                            return noErr;
                        });
                    if (status) { error = [NSError errorWithDomain:@"EasyPod.PluginSmoke" code:status userInfo:@{NSLocalizedDescriptionKey: @"Plugin render failed"}]; break; }
                    for (int c = 0; c < 2; ++c) for (int i = 0; i < 512; ++i) {
                        if (!std::isfinite(channels[c][i])) { error = [NSError errorWithDomain:@"EasyPod.PluginSmoke" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Plugin produced nonfinite audio"}]; break; }
                        peak = std::max(peak, fabs((double)channels[c][i]));
                        delta += fabs(channels[c][i] - 0.2 * sin((chunk * 512. + i) * 2 * M_PI * 440 / 48000));
                        if (chunk >= 50) {
                            int64_t source = chunk * 512 + i - latencyFrames;
                            float expected = source >= 0 ? 0.2f * sinf((float)(source * 2 * M_PI * 440 / 48000)) : 0;
                            bypassError = std::max(bypassError, fabs(channels[c][i] - (double)expected));
                        }
                    }
                    if (error) break;
                }
                [unit reset]; [unit deallocateRenderResources];
                if (!error && bypassError > 0.0001) error = [NSError errorWithDomain:@"EasyPod.PluginSmoke" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Bypass did not preserve latency alignment"}];
                if (!error) result = @{@"lifecycle": @"passed", @"renderedFrames": @51200, @"peak": @(peak), @"difference": @(delta), @"bypassMaximumError": @(bypassError), @"stateBytes": @(state.length), @"latency": @(unit.latency), @"tail": isfinite(unit.tailTime) ? @(unit.tailTime) : @"infinite"};
            }
            if (error) result = @{@"error": error.localizedDescription};
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        if (![json writeToFile:outputPath options:NSDataWritingAtomic error:nil]) return 74;
        return error ? 1 : 0;
    }
}
