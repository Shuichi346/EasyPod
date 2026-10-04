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
EPCaptureStatus ep_capture_status(EPCaptureWriter *writer);
int32_t ep_capture_flush(EPCaptureWriter *writer);
EPCaptureStatus ep_capture_finalize(EPCaptureWriter *writer);
int32_t ep_capture_destroy(EPCaptureWriter *writer);

#ifdef __cplusplus
}
#endif
