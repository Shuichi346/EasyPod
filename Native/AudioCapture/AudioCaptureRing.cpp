#include "AudioCaptureRing.h"
#include <CoreAudio/CoreAudio.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
constexpr uint64_t capacity = 262144;
constexpr uint32_t blockSize = 4096;
constexpr int32_t overflowError = -71001;
constexpr int32_t timestampError = -71002;
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<int64_t>::is_always_lock_free);
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<int32_t>::is_always_lock_free);

struct TapClock {
    std::atomic<uint64_t> version{0}, host{0}, previousHost{0};
    std::atomic<int64_t> sample{INT64_MIN}, previousSample{INT64_MIN};
    std::atomic<double> rate{0}, format{0};
    std::atomic<uint32_t> frames{0};
    std::atomic<bool> valid{false};

    int64_t observe(uint32_t count, int64_t time, double clockRate, uint64_t hostTime,
                    double formatRate, double recordingRate) noexcept {
        double normalized = static_cast<double>(time) * (recordingRate / clockRate);
        bool usable = count > 0 && time != INT64_MIN && hostTime != 0 &&
                      std::isfinite(clockRate) && clockRate > 0 && formatRate == recordingRate &&
                      std::isfinite(normalized) && std::abs(normalized) < static_cast<double>(INT64_MAX / 2);
        int64_t position = usable ? std::llround(normalized) : INT64_MIN;
        version.fetch_add(1, std::memory_order_acq_rel);
        previousSample.store(sample.load(std::memory_order_relaxed), std::memory_order_relaxed);
        previousHost.store(host.load(std::memory_order_relaxed), std::memory_order_relaxed);
        sample.store(position, std::memory_order_relaxed);
        host.store(hostTime, std::memory_order_relaxed);
        rate.store(clockRate, std::memory_order_relaxed);
        format.store(formatRate, std::memory_order_relaxed);
        frames.store(count, std::memory_order_relaxed);
        valid.store(usable, std::memory_order_relaxed);
        version.fetch_add(1, std::memory_order_release);
        return position;
    }

    EPCaptureClock snapshot() const noexcept {
        // A contended observation is retried on the control thread's next poll, never spun on audio.
        for (int attempt = 0; attempt < 3; ++attempt) {
            uint64_t before = version.load(std::memory_order_acquire);
            if (before & 1) continue;
            EPCaptureClock result{before / 2, sample.load(std::memory_order_relaxed),
                previousSample.load(std::memory_order_relaxed), host.load(std::memory_order_relaxed),
                previousHost.load(std::memory_order_relaxed), rate.load(std::memory_order_relaxed),
                format.load(std::memory_order_relaxed), frames.load(std::memory_order_relaxed),
                valid.load(std::memory_order_relaxed)};
            std::atomic_thread_fence(std::memory_order_acquire);
            if (before == version.load(std::memory_order_acquire)) return result;
        }
        EPCaptureClock unavailable{};
        uint64_t current = version.load(std::memory_order_acquire);
        unavailable.sequence = current / 2 + (current & 1);
        return unavailable;
    }
};

struct Track {
    std::vector<float> samples;
    std::vector<float> scratch;
    std::atomic<uint64_t> produced{0}, consumed{0}, written{0};
    std::atomic<uint64_t> skip{0}, maximum{UINT64_MAX};
    std::atomic<int64_t> minimumSampleTime{INT64_MIN};
    std::atomic<int32_t> error{0};
    std::atomic<uint32_t> activePushes{0};
    std::atomic<bool> enabled{false};
    ExtAudioFileRef file = nullptr;
    int descriptor = -1;
    uint32_t channels;

    explicit Track(uint32_t channelCount) : samples(capacity * channelCount),
        scratch(blockSize * channelCount), channels(channelCount) {}

    OSStatus open(const char *path, double sampleRate) {
        if (!path || !*path) return noErr;
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr,
            reinterpret_cast<const UInt8 *>(path), std::strlen(path), false);
        AudioStreamBasicDescription disk{};
        disk.mSampleRate = sampleRate;
        disk.mFormatID = kAudioFormatLinearPCM;
        disk.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        disk.mBytesPerPacket = disk.mBytesPerFrame = channels * sizeof(float);
        disk.mFramesPerPacket = 1;
        disk.mChannelsPerFrame = channels;
        disk.mBitsPerChannel = 32;
        OSStatus status = ExtAudioFileCreateWithURL(url, kAudioFileCAFType, &disk, nullptr,
                                                   kAudioFileFlags_EraseFile, &file);
        CFRelease(url);
        if (status) return status;
        AudioStreamBasicDescription client = disk;
        client.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
        client.mBytesPerPacket = client.mBytesPerFrame = sizeof(float);
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         sizeof(client), &client);
        AudioFileID audioFile = nullptr;
        UInt32 size = sizeof(audioFile);
        if (!status) status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile,
                                                    &size, &audioFile);
        UInt32 deferSizes = 0;
        if (!status) status = AudioFileSetProperty(audioFile, kAudioFilePropertyDeferSizeUpdates,
                                                   sizeof(deferSizes), &deferSizes);
        descriptor = ::open(path, O_RDONLY);
        return status;
    }

    void push(const AudioBufferList *buffers, uint32_t count, int64_t sampleTime, std::atomic<float> *rms,
              std::atomic<float> *peak) noexcept {
        activePushes.fetch_add(1, std::memory_order_acquire);
        if (!enabled.load(std::memory_order_acquire) || error.load(std::memory_order_relaxed)) {
            activePushes.fetch_sub(1, std::memory_order_release);
            return;
        }
        uint64_t ignored = 0;
        int64_t firstSample = minimumSampleTime.load(std::memory_order_acquire);
        if (firstSample != INT64_MIN) {
            if (sampleTime == INT64_MIN) {
                error.store(timestampError, std::memory_order_release);
                enabled.store(false, std::memory_order_release);
                activePushes.fetch_sub(1, std::memory_order_release);
                return;
            }
            if (sampleTime < firstSample) {
                ignored = std::min<uint64_t>(count, static_cast<uint64_t>(firstSample) - static_cast<uint64_t>(sampleTime));
            }
        }
        uint64_t delayed = std::min<uint64_t>(skip.load(std::memory_order_relaxed), count - ignored);
        skip.fetch_sub(delayed, std::memory_order_relaxed);
        ignored += delayed;
        uint64_t position = produced.load(std::memory_order_relaxed);
        uint64_t limit = maximum.load(std::memory_order_acquire);
        count = static_cast<uint32_t>(std::min<uint64_t>(count - ignored,
                                                       limit > position ? limit - position : 0));
        if (count > capacity - (position - consumed.load(std::memory_order_acquire))) {
            error.store(overflowError, std::memory_order_release);
            enabled.store(false, std::memory_order_release);
            activePushes.fetch_sub(1, std::memory_order_release);
            return;
        }
        double squares = 0;
        float maximumPeak = 0;
        bool planar = buffers->mNumberBuffers > 1 || buffers->mBuffers[0].mNumberChannels == 1;
        for (uint32_t channel = 0; channel < channels; ++channel) {
            uint32_t inputChannel = planar ? std::min(channel, buffers->mNumberBuffers - 1) : channel;
            const float *input = static_cast<const float *>(buffers->mBuffers[planar ? inputChannel : 0].mData);
            if (!input) continue;
            uint32_t stride = planar ? 1 : buffers->mBuffers[0].mNumberChannels;
            input += ignored * stride + (planar ? 0 : inputChannel);
            for (uint32_t frame = 0; frame < count; ++frame) {
                float value = input[frame * stride];
                samples[channel * capacity + ((position + frame) & (capacity - 1))] = value;
                squares += static_cast<double>(value) * value;
                maximumPeak = std::max(maximumPeak, std::abs(value));
            }
        }
        if (count && rms && peak) {
            rms->store(static_cast<float>(std::sqrt(squares / (count * channels))), std::memory_order_relaxed);
            peak->store(maximumPeak, std::memory_order_relaxed);
        }
        produced.store(position + count, std::memory_order_release);
        activePushes.fetch_sub(1, std::memory_order_release);
    }

    bool drain() {
        uint64_t position = consumed.load(std::memory_order_relaxed);
        uint32_t count = static_cast<uint32_t>(std::min<uint64_t>(blockSize,
                                           produced.load(std::memory_order_acquire) - position));
        if (!count) return false;
        struct TwoBuffers { UInt32 count; AudioBuffer buffers[2]; } storage{};
        storage.count = channels;
        for (uint32_t channel = 0; channel < channels; ++channel) {
            float *target = scratch.data() + channel * blockSize;
            uint64_t offset = position & (capacity - 1);
            uint32_t first = static_cast<uint32_t>(std::min<uint64_t>(count, capacity - offset));
            std::memcpy(target, samples.data() + channel * capacity + offset, first * sizeof(float));
            std::memcpy(target + first, samples.data() + channel * capacity, (count - first) * sizeof(float));
            storage.buffers[channel] = {1, count * static_cast<UInt32>(sizeof(float)), target};
        }
        // An overflow still permits the already accepted audio to reach the file.
        if (file && (error.load() == 0 || error.load() == overflowError)) {
            OSStatus status = ExtAudioFileWrite(file, count, reinterpret_cast<AudioBufferList *>(&storage));
            if (status) {
                error.store(status);
                enabled.store(false);
            } else written.fetch_add(count, std::memory_order_release);
        }
        consumed.store(position + count, std::memory_order_release);
        return true;
    }

    int32_t sync() {
        if (descriptor >= 0 && fsync(descriptor) != 0) return errno;
        return error.load();
    }

    int32_t close() {
        int32_t result = error.load();
        if (file) {
            OSStatus status = ExtAudioFileDispose(file);
            file = nullptr;
            if (!result) result = status;
        }
        if (descriptor >= 0) {
            if (fsync(descriptor) && !result) result = errno;
            ::close(descriptor);
            descriptor = -1;
        }
        return result;
    }
    ~Track() { close(); }
};
}

struct EPCaptureWriter {
    Track source, processed;
    TapClock sourceClock, processedClock;
    const double sampleRate;
    std::atomic<float> level{0}, peak{0};
    std::atomic<bool> stopping{false};
    std::atomic<uint64_t> flushRequest{0}, flushFinished{0};
    std::thread worker;
    EPCaptureWriter(uint32_t channels, double rate) : source(channels), processed(channels), sampleRate(rate) {}
    void run() {
        auto lastSync = std::chrono::steady_clock::now();
        while (true) {
            bool work = source.drain();
            work = processed.drain() || work;
            bool drained = source.produced.load() == source.consumed.load()
                        && processed.produced.load() == processed.consumed.load();
            uint64_t request = flushRequest.load(std::memory_order_acquire);
            auto now = std::chrono::steady_clock::now();
            if ((drained && request != flushFinished.load()) || now - lastSync >= std::chrono::seconds(1)) {
                int32_t status = source.sync();
                if (status && !source.error.load()) source.error.store(status);
                status = processed.sync();
                if (status && !processed.error.load()) processed.error.store(status);
                lastSync = now;
                if (drained) flushFinished.store(request, std::memory_order_release);
            }
            if (stopping.load(std::memory_order_acquire) && drained) break;
            if (!work) std::this_thread::sleep_for(std::chrono::milliseconds(4));
        }
    }
};

EPCaptureWriter *ep_capture_create(const char *sourcePath, const char *processedPath,
                                  double sampleRate, uint32_t channels, int32_t *error) {
    if (channels < 1 || channels > 2 || sampleRate < 8000 || sampleRate > 96000) {
        if (error) *error = -50;
        return nullptr;
    }
    try {
        auto writer = std::make_unique<EPCaptureWriter>(channels, sampleRate);
        OSStatus status = writer->source.open(sourcePath, sampleRate);
        if (!status) status = writer->processed.open(processedPath, sampleRate);
        if (status) { if (error) *error = status; return nullptr; }
        writer->worker = std::thread([raw = writer.get()] { raw->run(); });
        if (error) *error = 0;
        return writer.release();
    } catch (...) { if (error) *error = -108; return nullptr; }
}

void ep_capture_enable_source(EPCaptureWriter *writer, bool enabled) {
    writer->source.enabled.store(enabled, std::memory_order_release);
    if (!enabled) while (writer->source.activePushes.load(std::memory_order_acquire)) std::this_thread::yield();
}
void ep_capture_enable_processed(EPCaptureWriter *writer, bool enabled) {
    writer->processed.enabled.store(enabled, std::memory_order_release);
    if (!enabled) while (writer->processed.activePushes.load(std::memory_order_acquire)) std::this_thread::yield();
}
void ep_capture_processed_window(EPCaptureWriter *writer, uint64_t skipFrames, uint64_t maximumFrames) {
    writer->processed.skip.store(skipFrames, std::memory_order_release);
    writer->processed.maximum.store(maximumFrames, std::memory_order_release);
}
void ep_capture_processed_limit(EPCaptureWriter *writer, uint64_t maximumFrames) {
    writer->processed.maximum.store(maximumFrames, std::memory_order_release);
}
void ep_capture_segment(EPCaptureWriter *writer, int64_t firstSampleTime, uint64_t latencyFrames) {
    // Both producers are disabled while this future boundary is prepared.
    if (latencyFrames > INT64_MAX || firstSampleTime > INT64_MAX - static_cast<int64_t>(latencyFrames)) {
        writer->source.error.store(-50, std::memory_order_release);
        writer->processed.error.store(-50, std::memory_order_release);
        return;
    }
    writer->source.minimumSampleTime.store(firstSampleTime, std::memory_order_release);
    writer->processed.minimumSampleTime.store(firstSampleTime + static_cast<int64_t>(latencyFrames), std::memory_order_release);
    writer->processed.skip.store(0, std::memory_order_release);
    writer->processed.maximum.store(UINT64_MAX, std::memory_order_release);
}
void ep_capture_push_source(EPCaptureWriter *writer, const AudioBufferList *buffers, uint32_t frames) {
    writer->source.push(buffers, frames, INT64_MIN, &writer->level, &writer->peak);
}
void ep_capture_push_processed(EPCaptureWriter *writer, const AudioBufferList *buffers, uint32_t frames) {
    writer->processed.push(buffers, frames, INT64_MIN, nullptr, nullptr);
}
void ep_capture_push_source_at(EPCaptureWriter *writer, const AudioBufferList *buffers, uint32_t frames, int64_t sampleTime) {
    writer->source.push(buffers, frames, sampleTime, &writer->level, &writer->peak);
}
void ep_capture_push_processed_at(EPCaptureWriter *writer, const AudioBufferList *buffers, uint32_t frames, int64_t sampleTime) {
    writer->processed.push(buffers, frames, sampleTime, nullptr, nullptr);
}
void ep_capture_push_source_clocked(EPCaptureWriter *writer, const AudioBufferList *buffers,
                                    uint32_t frames, int64_t sampleTime, double clockRate,
                                    uint64_t hostTime, double formatRate) {
    writer->source.activePushes.fetch_add(1, std::memory_order_acquire);
    int64_t position = writer->sourceClock.observe(frames, sampleTime, clockRate, hostTime, formatRate, writer->sampleRate);
    writer->source.push(buffers, frames, position, &writer->level, &writer->peak);
    writer->source.activePushes.fetch_sub(1, std::memory_order_release);
}
void ep_capture_push_processed_clocked(EPCaptureWriter *writer, const AudioBufferList *buffers,
                                       uint32_t frames, int64_t sampleTime, double clockRate,
                                       uint64_t hostTime, double formatRate) {
    writer->processed.activePushes.fetch_add(1, std::memory_order_acquire);
    int64_t position = writer->processedClock.observe(frames, sampleTime, clockRate, hostTime, formatRate, writer->sampleRate);
    writer->processed.push(buffers, frames, position, nullptr, nullptr);
    writer->processed.activePushes.fetch_sub(1, std::memory_order_release);
}
EPCaptureClock ep_capture_clock(EPCaptureWriter *writer, bool processed) {
    return processed ? writer->processedClock.snapshot() : writer->sourceClock.snapshot();
}
EPCaptureStatus ep_capture_status(EPCaptureWriter *writer) {
    return {static_cast<int64_t>(writer->source.written.load()),
            static_cast<int64_t>(writer->processed.written.load()),
            static_cast<int64_t>(writer->source.produced.load()),
            static_cast<int64_t>(writer->processed.produced.load()),
            writer->source.error.load(), writer->processed.error.load(),
            writer->level.load(), writer->peak.load()};
}
int32_t ep_capture_flush(EPCaptureWriter *writer) {
    uint64_t request = writer->flushRequest.fetch_add(1, std::memory_order_release) + 1;
    while (writer->flushFinished.load(std::memory_order_acquire) < request)
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    return writer->source.error.load();
}
EPCaptureStatus ep_capture_finalize(EPCaptureWriter *writer) {
    if (!writer) return {};
    ep_capture_enable_source(writer, false);
    ep_capture_enable_processed(writer, false);
    writer->stopping.store(true, std::memory_order_release);
    if (writer->worker.joinable()) writer->worker.join();
    EPCaptureStatus status = ep_capture_status(writer);
    status.sourceError = writer->source.close();
    status.processedError = writer->processed.close();
    delete writer;
    return status;
}
int32_t ep_capture_destroy(EPCaptureWriter *writer) {
    return ep_capture_finalize(writer).sourceError;
}

struct EPPlaybackHandoff {
    std::atomic<float> level{0};
    // The low bit is completion; the remaining bits identify the scheduled segment.
    std::atomic<uint64_t> state{0};
};

EPPlaybackHandoff *ep_playback_create(void) {
    try { return new EPPlaybackHandoff; }
    catch (...) { return nullptr; }
}

void ep_playback_destroy(EPPlaybackHandoff *handoff) { delete handoff; }

void ep_playback_arm(EPPlaybackHandoff *handoff, uint64_t generation) {
    handoff->state.store(generation << 1, std::memory_order_release);
    handoff->level.store(0, std::memory_order_relaxed);
}

void ep_playback_meter(EPPlaybackHandoff *handoff, const AudioBufferList *buffers, uint32_t frames) {
    double squares = 0;
    uint64_t samples = 0;
    if (buffers) {
        for (uint32_t index = 0; index < buffers->mNumberBuffers; ++index) {
            const AudioBuffer &buffer = buffers->mBuffers[index];
            const float *input = static_cast<const float *>(buffer.mData);
            if (!input || !buffer.mNumberChannels) continue;
            uint64_t count = std::min<uint64_t>(static_cast<uint64_t>(frames) * buffer.mNumberChannels,
                                               buffer.mDataByteSize / sizeof(float));
            for (uint64_t sample = 0; sample < count; ++sample) {
                double value = input[sample];
                if (std::isfinite(value)) squares += value * value;
            }
            samples += count;
        }
    }
    handoff->level.store(samples ? static_cast<float>(std::sqrt(squares / samples)) : 0,
                         std::memory_order_relaxed);
}

void ep_playback_complete(EPPlaybackHandoff *handoff, uint64_t generation) {
    uint64_t expected = generation << 1;
    // One CAS prevents a retired callback from completing a newly sought segment.
    handoff->state.compare_exchange_strong(expected, expected | 1, std::memory_order_release,
                                           std::memory_order_relaxed);
}

EPPlaybackStatus ep_playback_status(EPPlaybackHandoff *handoff, uint64_t generation) {
    return {handoff->level.load(std::memory_order_relaxed),
            handoff->state.load(std::memory_order_acquire) == ((generation << 1) | 1)};
}

namespace {
constexpr uint32_t maximumPcmChannels = 32;
constexpr uint32_t maximumPcmCapacity = 1048576;
constexpr int32_t inputDeviceError = -71003;

struct PcmChannel {
    float *data;
    uint32_t stride;
};

// Resolve the buffer topology before copying any data. No channel can index past
// its buffer even when channels are grouped into multiple interleaved buffers.
bool pcmChannels(const AudioBufferList *buffers, uint32_t frames, uint32_t channels,
                 std::array<PcmChannel, maximumPcmChannels> &mapping) noexcept {
    if (!buffers || !buffers->mNumberBuffers || buffers->mNumberBuffers > channels) return false;
    uint32_t channel = 0;
    for (uint32_t index = 0; index < buffers->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = buffers->mBuffers[index];
        uint32_t count = buffer.mNumberChannels;
        if (!count || count > channels - channel || !buffer.mData ||
            static_cast<uint64_t>(frames) * count * sizeof(float) > buffer.mDataByteSize) return false;
        float *base = static_cast<float *>(buffer.mData);
        for (uint32_t local = 0; local < count; ++local) mapping[channel++] = {base + local, count};
    }
    return channel == channels;
}

uint32_t pcmCapacity(uint32_t requested) noexcept {
    if (!requested || requested > maximumPcmCapacity) return 0;
    uint32_t result = 1;
    while (result < requested) result <<= 1;
    return result;
}
}

struct EPPcmBridge {
    const uint32_t channels, capacityFrames;
    std::vector<float> samples;
    std::atomic<uint64_t> produced{0}, consumed{0};
    std::atomic<int32_t> error{0};

    EPPcmBridge(uint32_t count, uint32_t frames) : channels(count), capacityFrames(frames),
        samples(static_cast<size_t>(count) * frames) {}

    void fail(int32_t status) noexcept {
        int32_t expected = 0;
        error.compare_exchange_strong(expected, status, std::memory_order_release, std::memory_order_relaxed);
    }

    void clear() noexcept {
        produced.store(0, std::memory_order_relaxed);
        consumed.store(0, std::memory_order_relaxed);
        error.store(0, std::memory_order_release);
    }

    uint32_t available() const noexcept {
        // Called by the sole consumer, whose own position cannot change here.
        uint64_t position = consumed.load(std::memory_order_relaxed);
        return static_cast<uint32_t>(produced.load(std::memory_order_acquire) - position);
    }

    bool push(const AudioBufferList *buffers, uint32_t frames) noexcept {
        if (error.load(std::memory_order_acquire)) return false;
        if (!frames) return true;
        uint64_t position = produced.load(std::memory_order_relaxed);
        uint64_t queued = position - consumed.load(std::memory_order_acquire);
        if (frames > capacityFrames - queued) { fail(overflowError); return false; }
        std::array<PcmChannel, maximumPcmChannels> mapping{};
        if (!pcmChannels(buffers, frames, channels, mapping)) { fail(-50); return false; }
        for (uint32_t channel = 0; channel < channels; ++channel) {
            const PcmChannel &input = mapping[channel];
            float *target = samples.data() + static_cast<size_t>(channel) * capacityFrames;
            for (uint32_t frame = 0; frame < frames; ++frame)
                target[(position + frame) & (capacityFrames - 1)] = input.data[static_cast<size_t>(frame) * input.stride];
        }
        produced.store(position + frames, std::memory_order_release);
        return true;
    }

    uint32_t read(AudioBufferList *buffers, uint32_t maximumFrames, bool silence) noexcept {
        if (!maximumFrames) return 0;
        if (maximumFrames > maximumPcmCapacity) { fail(-50); return 0; }
        uint64_t position = consumed.load(std::memory_order_relaxed);
        uint32_t count = static_cast<uint32_t>(std::min<uint64_t>(maximumFrames,
            produced.load(std::memory_order_acquire) - position));
        uint32_t outputFrames = silence ? maximumFrames : count;
        if (!outputFrames) return 0;
        std::array<PcmChannel, maximumPcmChannels> mapping{};
        if (!pcmChannels(buffers, outputFrames, channels, mapping)) { fail(-50); return 0; }
        for (uint32_t channel = 0; channel < channels; ++channel) {
            const PcmChannel &output = mapping[channel];
            const float *source = samples.data() + static_cast<size_t>(channel) * capacityFrames;
            for (uint32_t frame = 0; frame < count; ++frame)
                output.data[static_cast<size_t>(frame) * output.stride] = source[(position + frame) & (capacityFrames - 1)];
            for (uint32_t frame = count; frame < outputFrames; ++frame)
                output.data[static_cast<size_t>(frame) * output.stride] = 0;
        }
        for (uint32_t index = 0; index < buffers->mNumberBuffers; ++index)
            buffers->mBuffers[index].mDataByteSize = outputFrames * buffers->mBuffers[index].mNumberChannels * sizeof(float);
        consumed.store(position + count, std::memory_order_release);
        return count;
    }
};

EPPcmBridge *ep_pcm_create(uint32_t channels, uint32_t capacityFrames) {
    uint32_t size = pcmCapacity(capacityFrames);
    if (!channels || channels > maximumPcmChannels || !size) return nullptr;
    try { return new EPPcmBridge(channels, size); }
    catch (...) { return nullptr; }
}
void ep_pcm_destroy(EPPcmBridge *bridge) { delete bridge; }
bool ep_pcm_push(EPPcmBridge *bridge, const AudioBufferList *buffers, uint32_t frames) {
    return bridge && bridge->push(buffers, frames);
}
uint32_t ep_pcm_available(EPPcmBridge *bridge) { return bridge ? bridge->available() : 0; }
int32_t ep_pcm_error(EPPcmBridge *bridge) { return bridge ? bridge->error.load(std::memory_order_acquire) : -50; }
uint32_t ep_pcm_read(EPPcmBridge *bridge, AudioBufferList *buffers, uint32_t maximumFrames) {
    return bridge ? bridge->read(buffers, maximumFrames, false) : 0;
}
void ep_pcm_clear(EPPcmBridge *bridge) { if (bridge) bridge->clear(); }
OSStatus ep_pcm_render(EPPcmBridge *bridge, AudioBufferList *buffers, uint32_t frames) {
    if (!bridge) return -50;
    bridge->read(buffers, frames, true);
    return bridge->error.load(std::memory_order_acquire);
}
OSStatus ep_pcm_render_strict(EPPcmBridge *bridge, AudioBufferList *buffers, uint32_t frames) {
    if (!bridge) return -50;
    int32_t status = bridge->error.load(std::memory_order_acquire);
    if (status) return status;
    if (frames > bridge->available()) {
        bridge->fail(-71006);
        return bridge->error.load(std::memory_order_acquire);
    }
    bridge->read(buffers, frames, false);
    return bridge->error.load(std::memory_order_acquire);
}

struct EPInputCapture {
    AudioUnit unit = nullptr;
    AudioDeviceID device = kAudioObjectUnknown;
    double sampleRate = 0;
    uint32_t channels = 0, maximumFrames = 0;
    bool running = false;
    std::unique_ptr<EPPcmBridge> queue;
    std::vector<float> scratch;
    struct BufferStorage { UInt32 count; AudioBuffer buffers[maximumPcmChannels]; } storage{};
    double expectedSampleTime = 0;
    uint64_t previousHostTime = 0;
    bool observedClock = false;
    std::chrono::steady_clock::time_point nextDeviceCheck{};

    AudioBufferList *buffers() noexcept { return reinterpret_cast<AudioBufferList *>(&storage); }

    OSStatus releaseUnit() noexcept {
        if (!unit) return noErr;
        // Dispose is the final callback barrier, including when Stop fails.
        if (running) AudioOutputUnitStop(unit);
        OSStatus status = AudioComponentInstanceDispose(unit);
        if (!status) { unit = nullptr; running = false; }
        return status;
    }

    ~EPInputCapture() { releaseUnit(); }

    static OSStatus input(void *context, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *time, UInt32, UInt32 frames, AudioBufferList *) noexcept {
        auto *capture = static_cast<EPInputCapture *>(context);
        if (capture->queue->error.load(std::memory_order_acquire)) return noErr;
        if (!frames) return noErr;
        if (frames > capture->maximumFrames) { capture->queue->fail(overflowError); return noErr; }
        if (!time || !(time->mFlags & kAudioTimeStampSampleTimeValid) ||
            !std::isfinite(time->mSampleTime)) { capture->queue->fail(timestampError); return noErr; }
        bool validHost = time->mFlags & kAudioTimeStampHostTimeValid;
        if (capture->observedClock && (std::abs(time->mSampleTime - capture->expectedSampleTime) > 1.0 ||
            (validHost && capture->previousHostTime && time->mHostTime <= capture->previousHostTime))) {
            capture->queue->fail(timestampError);
            return noErr;
        }
        capture->expectedSampleTime = time->mSampleTime + frames;
        capture->previousHostTime = validHost ? time->mHostTime : 0;
        capture->observedClock = true;
        for (uint32_t channel = 0; channel < capture->channels; ++channel) {
            capture->storage.buffers[channel].mData = capture->scratch.data() + static_cast<size_t>(channel) * capture->maximumFrames;
            capture->storage.buffers[channel].mDataByteSize = frames * sizeof(float);
        }
        OSStatus status = AudioUnitRender(capture->unit, flags, time, 1, frames, capture->buffers());
        if (status) capture->queue->fail(status);
        else capture->queue->push(capture->buffers(), frames);
        // Error reporting belongs to the control owner, never a driver callback.
        return noErr;
    }
};

EPInputCapture *ep_input_create(uint32_t deviceID, int32_t *error) {
    if (error) *error = noErr;
    try {
        auto capture = std::make_unique<EPInputCapture>();
        capture->device = deviceID;
        auto failed = [&](OSStatus status) -> EPInputCapture * {
            if (error) *error = status;
            // Failed disposal retains callback-owned state rather than releasing it.
            if (capture->releaseUnit()) capture.release();
            return nullptr;
        };
        if (deviceID == kAudioObjectUnknown) return failed(-50);
        AudioObjectPropertyAddress aliveAddress{kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 alive = 0, size = sizeof(alive);
        OSStatus status = AudioObjectGetPropertyData(deviceID, &aliveAddress, 0, nullptr, &size, &alive);
        if (status || !alive) return failed(status ? status : inputDeviceError);
        AudioComponentDescription description{kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                             kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &description);
        if (!component) return failed(kAudioUnitErr_InvalidProperty);
        status = AudioComponentInstanceNew(component, &capture->unit);
        if (status) return failed(status);
        UInt32 enabled = 1, disabled = 0;
        status = AudioUnitSetProperty(capture->unit, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
        if (!status) status = AudioUnitSetProperty(capture->unit, kAudioOutputUnitProperty_EnableIO,
                                                  kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
        if (!status) status = AudioUnitSetProperty(capture->unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
        if (status) return failed(status);
        AudioStreamBasicDescription hardware{};
        size = sizeof(hardware);
        status = AudioUnitGetProperty(capture->unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 1, &hardware, &size);
        if (status) return failed(status);
        if (!std::isfinite(hardware.mSampleRate) || hardware.mSampleRate <= 0 || hardware.mSampleRate > 768000 ||
            !hardware.mChannelsPerFrame || hardware.mChannelsPerFrame > maximumPcmChannels) return failed(-50);
        capture->sampleRate = hardware.mSampleRate;
        capture->channels = hardware.mChannelsPerFrame;
        AudioStreamBasicDescription client{};
        client.mSampleRate = capture->sampleRate;
        client.mFormatID = kAudioFormatLinearPCM;
        client.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        client.mBytesPerPacket = client.mBytesPerFrame = sizeof(float);
        client.mFramesPerPacket = 1;
        client.mChannelsPerFrame = capture->channels;
        client.mBitsPerChannel = 32;
        status = AudioUnitSetProperty(capture->unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &client, sizeof(client));
        if (!status) status = AudioUnitSetProperty(capture->unit, kAudioUnitProperty_ShouldAllocateBuffer,
                                                  kAudioUnitScope_Output, 1, &disabled, sizeof(disabled));
        AURenderCallbackStruct callback{EPInputCapture::input, capture.get()};
        if (!status) status = AudioUnitSetProperty(capture->unit, kAudioOutputUnitProperty_SetInputCallback,
                                                  kAudioUnitScope_Global, 0, &callback, sizeof(callback));
        if (!status) status = AudioUnitInitialize(capture->unit);
        if (status) return failed(status);
        size = sizeof(capture->maximumFrames);
        status = AudioUnitGetProperty(capture->unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &capture->maximumFrames, &size);
        if (status) return failed(status);
        if (!capture->maximumFrames || capture->maximumFrames > 65536) return failed(-50);
        uint32_t queueFrames = pcmCapacity(std::max<uint32_t>(capture->maximumFrames * 4,
            static_cast<uint32_t>(std::min(2.0 * capture->sampleRate, static_cast<double>(maximumPcmCapacity)))));
        capture->queue = std::make_unique<EPPcmBridge>(capture->channels, queueFrames);
        capture->scratch.resize(static_cast<size_t>(capture->channels) * capture->maximumFrames);
        capture->storage.count = capture->channels;
        for (uint32_t channel = 0; channel < capture->channels; ++channel)
            capture->storage.buffers[channel].mNumberChannels = 1;
        return capture.release();
    } catch (...) { if (error) *error = -108; return nullptr; }
}

double ep_input_sample_rate(EPInputCapture *capture) { return capture ? capture->sampleRate : 0; }
uint32_t ep_input_channels(EPInputCapture *capture) { return capture ? capture->channels : 0; }
uint32_t ep_input_maximum_frames(EPInputCapture *capture) { return capture ? capture->maximumFrames : 0; }
int32_t ep_input_start(EPInputCapture *capture) {
    if (!capture || capture->running) return -50;
    capture->queue->clear();
    capture->observedClock = false;
    capture->expectedSampleTime = 0;
    capture->previousHostTime = 0;
    capture->nextDeviceCheck = {};
    OSStatus status = AudioOutputUnitStart(capture->unit);
    if (!status) capture->running = true;
    else capture->queue->fail(status);
    return status;
}
int32_t ep_input_stop(EPInputCapture *capture) {
    if (!capture) return -50;
    if (!capture->running) return noErr;
    OSStatus status = AudioOutputUnitStop(capture->unit);
    if (!status) capture->running = false;
    else capture->queue->fail(status);
    return status;
}
int32_t ep_input_destroy(EPInputCapture *capture) {
    if (!capture) return noErr;
    // Never release callback state if the driver refuses to dispose its unit.
    OSStatus status = capture->releaseUnit();
    if (!status) delete capture;
    else capture->queue->fail(status);
    return status;
}
uint32_t ep_input_available(EPInputCapture *capture) { return capture ? capture->queue->available() : 0; }
uint32_t ep_input_read(EPInputCapture *capture, AudioBufferList *buffers, uint32_t maximumFrames) {
    return capture ? capture->queue->read(buffers, maximumFrames, false) : 0;
}
int32_t ep_input_error(EPInputCapture *capture) {
    if (!capture) return -50;
    int32_t status = capture->queue->error.load(std::memory_order_acquire);
    if (status || !capture->running) return status;
    auto now = std::chrono::steady_clock::now();
    if (now < capture->nextDeviceCheck) return capture->queue->error.load(std::memory_order_acquire);
    capture->nextDeviceCheck = now + std::chrono::milliseconds(100);
    // Device disappearance and rate changes invalidate the fixed-rate queue. This
    // control-thread check avoids any hardware property calls in the input proc.
    UInt32 alive = 0, size = sizeof(alive);
    AudioObjectPropertyAddress address{kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    status = AudioObjectGetPropertyData(capture->device, &address, 0, nullptr, &size, &alive);
    if (!status && !alive) status = inputDeviceError;
    if (!status) {
        Float64 rate = 0;
        address.mSelector = kAudioDevicePropertyNominalSampleRate;
        size = sizeof(rate);
        status = AudioObjectGetPropertyData(capture->device, &address, 0, nullptr, &size, &rate);
        if (!status && (!std::isfinite(rate) || std::abs(rate - capture->sampleRate) > 0.5)) status = inputDeviceError;
    }
    if (!status) {
        UInt32 running = 0;
        size = sizeof(running);
        status = AudioUnitGetProperty(capture->unit, kAudioOutputUnitProperty_IsRunning,
                                      kAudioUnitScope_Global, 0, &running, &size);
        if (!status && !running) status = inputDeviceError;
    }
    if (status) capture->queue->fail(status);
    return capture->queue->error.load(std::memory_order_acquire);
}
