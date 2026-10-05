#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EPCaptureWriter EPCaptureWriter;
typedef struct {
    int64_t sourceFrames;
    int64_t processedFrames;
    int64_t sourceQueuedFrames;
    int64_t processedQueuedFrames;
    int32_t sourceError;
    int32_t processedError;
    float level;
    float peak;
} EPCaptureStatus;

typedef struct {
    uint64_t sequence;
    int64_t sampleTime;
    int64_t previousSampleTime;
    uint64_t hostTime;
    uint64_t previousHostTime;
    double clockRate;
    double formatRate;
    uint32_t frames;
    bool valid;
} EPCaptureClock;

// Creation, flush, and destruction are non-realtime operations.
EPCaptureWriter *ep_capture_create(const char *sourcePath, const char *processedPath,
                                  double sampleRate, uint32_t channels, int32_t *error);
void ep_capture_enable_source(EPCaptureWriter *writer, bool enabled);
void ep_capture_enable_processed(EPCaptureWriter *writer, bool enabled);
void ep_capture_processed_window(EPCaptureWriter *writer, uint64_t skipFrames, uint64_t maximumFrames);
void ep_capture_processed_limit(EPCaptureWriter *writer, uint64_t maximumFrames);
void ep_capture_segment(EPCaptureWriter *writer, int64_t firstSampleTime, uint64_t latencyFrames);
// Only copies into preallocated lock-free buffers. Each branch has exactly one producer.
void ep_capture_push_source(EPCaptureWriter *writer, const AudioBufferList *buffers, uint32_t frames);
void ep_capture_push_processed(EPCaptureWriter *writer, const AudioBufferList *buffers, uint32_t frames);
void ep_capture_push_source_at(EPCaptureWriter *writer, const AudioBufferList *buffers,
                               uint32_t frames, int64_t sampleTime);
void ep_capture_push_processed_at(EPCaptureWriter *writer, const AudioBufferList *buffers,
                                  uint32_t frames, int64_t sampleTime);
// Normalize the declared hardware clock into recording frames and publish bounded atomic metadata.
void ep_capture_push_source_clocked(EPCaptureWriter *writer, const AudioBufferList *buffers,
                                    uint32_t frames, int64_t sampleTime, double clockRate,
                                    uint64_t hostTime, double formatRate);
void ep_capture_push_processed_clocked(EPCaptureWriter *writer, const AudioBufferList *buffers,
                                       uint32_t frames, int64_t sampleTime, double clockRate,
                                       uint64_t hostTime, double formatRate);
EPCaptureClock ep_capture_clock(EPCaptureWriter *writer, bool processed);
EPCaptureStatus ep_capture_status(EPCaptureWriter *writer);
int32_t ep_capture_flush(EPCaptureWriter *writer);
EPCaptureStatus ep_capture_finalize(EPCaptureWriter *writer);
int32_t ep_capture_destroy(EPCaptureWriter *writer);

typedef struct EPPlaybackHandoff EPPlaybackHandoff;
typedef struct {
    float level;
    bool completed;
} EPPlaybackStatus;

// Allocate before rendering and destroy after the tap and scheduled callbacks retire.
EPPlaybackHandoff *ep_playback_create(void);
void ep_playback_destroy(EPPlaybackHandoff *handoff);
void ep_playback_arm(EPPlaybackHandoff *handoff, uint64_t generation);
// These realtime operations only scan existing PCM and update lock-free atomics.
void ep_playback_meter(EPPlaybackHandoff *handoff, const AudioBufferList *buffers, uint32_t frames);
void ep_playback_complete(EPPlaybackHandoff *handoff, uint64_t generation);
EPPlaybackStatus ep_playback_status(EPPlaybackHandoff *handoff, uint64_t generation);

#ifdef __cplusplus
}
#endif
