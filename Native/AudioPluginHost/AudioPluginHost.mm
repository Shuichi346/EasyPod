#import "AudioPluginHost.h"
#import <AudioToolbox/AUAudioUnitImplementation.h>
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/processdata.h"
#include "public.sdk/source/vst/utility/stringconvert.h"
#include "public.sdk/source/common/memorystream.h"
#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "pluginterfaces/gui/iplugview.h"
#include <atomic>
#include <array>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {
NSError *hostError(NSString *message, NSInteger code = 1) {
    return [NSError errorWithDomain:@"EasyPod.PluginHost" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *text(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size()
                                 encoding:NSUTF8StringEncoding] ?: @"";
}

IPtr<HostApplication> &application() {
    static IPtr<HostApplication> context = owned(new HostApplication);
    static std::once_flag flag;
    std::call_once(flag, [&] {
        PluginContextFactory::instance().setPluginContext(context);
        PlugProvider::setErrorStream(nullptr);
    });
    return context;
}

// Storage is fixed before activation; plugins cannot allocate parameter queues on the render path.
class FixedQueue final : public U::ImplementsNonDestroyable<U::Directly<IParamValueQueue>> {
public:
    ParamID id = 0;
    int32 count = 0;
    std::array<int32, 32> offsets{};
    std::array<ParamValue, 32> values{};
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return count; }
    tresult PLUGIN_API getPoint(int32 i, int32 &offset, ParamValue &value) override {
        if (i < 0 || i >= count) return kInvalidArgument;
        offset = offsets[i]; value = values[i]; return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 offset, ParamValue value, int32 &index) override {
        // Coalescing a full queue preserves the latest edit without growing storage.
        index = count < 32 ? count++ : 31;
        offsets[index] = offset; values[index] = value; return kResultOk;
    }
};

class FixedChanges final : public U::ImplementsNonDestroyable<U::Directly<IParameterChanges>> {
public:
    std::vector<std::unique_ptr<FixedQueue>> queues;
    std::vector<FixedQueue *> active;
    int32 used = 0;
    void prepare(const std::vector<ParamID> &ids) {
        for (auto id : ids) { auto queue = std::make_unique<FixedQueue>(); queue->id = id; queues.push_back(std::move(queue)); }
        active.resize(ids.size());
    }
    void clear() { for (int i = 0; i < used; ++i) active[i]->count = 0; used = 0; }
    int32 PLUGIN_API getParameterCount() override { return used; }
    IParamValueQueue *PLUGIN_API getParameterData(int32 index) override {
        return index >= 0 && index < used ? active[index] : nullptr;
    }
    IParamValueQueue *PLUGIN_API addParameterData(const ParamID &id, int32 &index) override {
        for (int i = 0; i < used; ++i) if (active[i]->id == id) { index = i; return active[i]; }
        for (auto &queue : queues) if (queue->id == id) {
            index = used; active[used++] = queue.get(); return queue.get();
        }
        return nullptr;
    }
};

struct Parameter {
    ParameterInfo info{};
    std::atomic<double> value{0};
    std::atomic<bool> pending{false};
    std::atomic<bool> controllerPending{false};
};

class Host final : public U::ImplementsNonDestroyable<U::Directly<IComponentHandler, IPlugFrame>> {
public:
    VST3::Hosting::Module::Ptr module;
    std::unique_ptr<PlugProvider> provider;
    IPtr<IComponent> component;
    IPtr<IEditController> controller;
    IPtr<IAudioProcessor> processor;
    IPtr<IPlugView> view;
    __weak NSView *editor = nil;
    std::vector<std::unique_ptr<Parameter>> parameters;
    FixedChanges inputChanges, outputChanges;
    HostProcessData data;
    ProcessContext context{};
    std::atomic<int> failure{0};
    std::atomic<int32> restartFlags{0};
    std::atomic<bool> bypassed{false};
    std::atomic<bool> stateAccess{false};
    std::atomic<int> rendering{0};
    std::atomic<uint32_t> latencyReported{0};
    bool active = false, processing = false, offline = false;
    int channels = 2, pluginChannels = 2;
    uint32_t maxFrames = 4096;
    double sampleRate = 48000;
    int64_t position = 0;
    std::vector<float> dryDelay, dryOutput;
    uint32_t dryDelayPosition = 0;
    struct { UInt32 count; AudioBuffer buffers[2]; } inputList{};

    ~Host() {
        closeEditor();
        deactivate();
        if (controller) controller->setComponentHandler(nullptr);
        processor.reset(); controller.reset(); component.reset(); provider.reset(); module.reset();
    }

    Parameter *parameter(ParamID id) {
        for (auto &p : parameters) if (p->info.id == id) return p.get();
        return nullptr;
    }

    void edit(ParamID id, double value, bool updateController) {
        if (auto p = parameter(id)) {
            value = std::clamp(value, 0., 1.);
            p->value.store(value, std::memory_order_relaxed);
            p->pending.store(true, std::memory_order_release);
            if (updateController && controller) controller->setParamNormalized(id, value);
        }
    }

    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override { edit(id, value, false); return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32 flags) override {
        restartFlags.fetch_or(flags, std::memory_order_release); return kResultOk;
    }
    tresult PLUGIN_API resizeView(IPlugView *plugView, ViewRect *rect) override {
        if (!rect || !editor || ![NSThread isMainThread]) return kInvalidArgument;
        [editor setFrameSize:NSMakeSize(rect->getWidth(), rect->getHeight())];
        if (editor.window) [editor.window setContentSize:editor.frame.size];
        return plugView->onSize(rect);
    }

    bool load(NSString *path, NSString *classID, double rate, int channelCount, bool isOffline, NSError **error) {
        sampleRate = rate; channels = channelCount; offline = isOffline;
        std::string message;
        module = VST3::Hosting::Module::create(path.UTF8String, message);
        if (!module) { if (error) *error = hostError(text(message)); return false; }
        auto factory = module->getFactory(); factory.setHostContext(application());
        for (const auto &info : factory.classInfos()) {
            if (info.category() != kVstAudioEffectClass || info.ID().toString() != classID.UTF8String) continue;
            provider = std::make_unique<PlugProvider>(factory, info, true); break;
        }
        if (!provider || !provider->initialize()) {
            if (error) *error = hostError(@"VST3 の初期化に失敗しました。認証と互換性を確認してください。"); return false;
        }
        component = provider->getComponentPtr(); controller = provider->getControllerPtr();
        processor = U::cast<IAudioProcessor>(component);
        if (!processor || processor->canProcessSampleSize(kSample32) != kResultOk) {
            if (error) *error = hostError(@"この VST3 は float32 音声処理に対応していません。"); return false;
        }
        if (component->getBusCount(kAudio, kInput) < 1 || component->getBusCount(kAudio, kOutput) < 1) {
            if (error) *error = hostError(@"音声入力と出力を持つエフェクトだけを利用できます。"); return false;
        }
        std::vector<SpeakerArrangement> inputs(component->getBusCount(kAudio, kInput));
        std::vector<SpeakerArrangement> outputs(component->getBusCount(kAudio, kOutput));
        for (int i = 0; i < inputs.size(); ++i) processor->getBusArrangement(kInput, i, inputs[i]);
        for (int i = 0; i < outputs.size(); ++i) processor->getBusArrangement(kOutput, i, outputs[i]);
        bool arranged = false;
        for (int requested : {channelCount, 2}) {
            inputs[0] = outputs[0] = requested == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo;
            auto accepted = processor->setBusArrangements(inputs.data(), (int32)inputs.size(), outputs.data(), (int32)outputs.size());
            SpeakerArrangement currentIn = 0, currentOut = 0;
            processor->getBusArrangement(kInput, 0, currentIn); processor->getBusArrangement(kOutput, 0, currentOut);
            if (accepted == kResultOk || (currentIn == inputs[0] && currentOut == outputs[0])) {
                arranged = true; pluginChannels = requested; break;
            }
        }
        BusInfo in{}, out{};
        component->getBusInfo(kAudio, kInput, 0, in); component->getBusInfo(kAudio, kOutput, 0, out);
        if (!arranged || in.channelCount != pluginChannels || out.channelCount != pluginChannels) {
            if (error) *error = hostError(@"モノラル／ステレオのバス構成に対応していません。"); return false;
        }
        for (auto direction : {kInput, kOutput}) {
            for (int i = 0; i < component->getBusCount(kAudio, direction); ++i)
                component->activateBus(kAudio, direction, i, i == 0);
            for (int i = 0; i < component->getBusCount(kEvent, direction); ++i)
                component->activateBus(kEvent, direction, i, false);
        }
        std::vector<ParamID> ids;
        if (controller) {
            if (controller->getParameterCount() > 4096) {
                if (error) *error = hostError(@"パラメータ数がホストの上限を超えています。"); return false;
            }
            for (int i = 0; i < controller->getParameterCount(); ++i) {
                auto p = std::make_unique<Parameter>();
                if (controller->getParameterInfo(i, p->info) != kResultOk) continue;
                p->value.store(controller->getParamNormalized(p->info.id)); ids.push_back(p->info.id);
                parameters.push_back(std::move(p));
            }
            controller->setComponentHandler(this);
            MemoryStream stream;
            if (component->getState(&stream) == kResultOk) {
                stream.seek(0, IBStream::kIBSeekSet, nullptr); controller->setComponentState(&stream);
            }
        }
        inputChanges.prepare(ids); outputChanges.prepare(ids);
        return true;
    }

    bool activate(uint32_t frames, NSError **error) {
        deactivate(); maxFrames = frames;
        ProcessSetup setup{offline ? kOffline : kRealtime, kSample32, (int32)frames, sampleRate};
        if (processor->setupProcessing(setup) != kResultOk) {
            if (error) *error = hostError(offline ? @"この VST3 はオフライン処理を開始できません。リアルタイム書き出しが必要です。" : @"VST3 の音声処理設定に失敗しました。", 2);
            return false;
        }
        if (!data.prepare(*component, frames, kSample32)) {
            if (error) *error = hostError(@"VST3 の音声バッファを確保できませんでした。"); return false;
        }
        data.processMode = offline ? kOffline : kRealtime;
        data.inputParameterChanges = &inputChanges; data.outputParameterChanges = &outputChanges;
        context.sampleRate = sampleRate; data.processContext = &context;
        inputList.count = channels;
        for (int i = 0; i < channels; ++i) inputList.buffers[i] = {1, frames * (UInt32)sizeof(float), data.inputs[0].channelBuffers32[i]};
        if (component->setActive(true) != kResultOk) { if (error) *error = hostError(@"VST3 を有効にできませんでした。"); return false; }
        active = true;
        if (processor->setProcessing(true) != kResultOk) { deactivate(); if (error) *error = hostError(@"VST3 の処理を開始できませんでした。"); return false; }
        processing = true;
        // Some installed processors establish latency during activation, before their first render.
        uint32_t delay = processor->getLatencySamples();
        if (delay > sampleRate * 30) {
            deactivate(); if (error) *error = hostError(@"プラグインの遅延が 30 秒を超えているため利用できません。"); return false;
        }
        latencyReported.store(delay);
        dryDelay.assign((size_t)channels * std::max(1u, delay), 0);
        dryOutput.assign((size_t)channels * frames, 0);
        dryDelayPosition = 0;
        position = 0; failure.store(0); restartFlags.store(0); return true;
    }

    void deactivate() {
        if (processor && processing) processor->setProcessing(false);
        processing = false;
        if (component && active) component->setActive(false);
        active = false; data.unprepare();
    }

    // State access suspends SDK processing without ever blocking the audio thread.
    bool beginStateAccess(NSError **error) {
        stateAccess.store(true, std::memory_order_seq_cst);
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
        while (rendering.load(std::memory_order_seq_cst) != 0) {
            if (std::chrono::steady_clock::now() >= deadline) {
                stateAccess.store(false); if (error) *error = hostError(@"プラグイン状態の読み込みがタイムアウトしました。"); return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }

    NSData *save(NSError **error) {
        if (!beginStateAccess(error)) return nil;
        MemoryStream comp, ctrl;
        auto result = component->getState(&comp);
        if (controller) controller->getState(&ctrl);
        stateAccess.store(false, std::memory_order_release);
        if (result != kResultOk) { if (error) *error = hostError(@"VST3 の状態を保存できませんでした。"); return nil; }
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (auto &p : parameters) values[[NSString stringWithFormat:@"%u", p->info.id]] = @(p->value.load());
        return [NSPropertyListSerialization dataWithPropertyList:@{
            @"component": [NSData dataWithBytes:comp.getData() length:comp.getSize()],
            @"controller": [NSData dataWithBytes:ctrl.getData() length:ctrl.getSize()], @"values": values
        } format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    }

    bool restore(NSData *state, NSError **error) {
        NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:state options:0 format:nil error:error];
        if (![plist isKindOfClass:NSDictionary.class] || ![plist[@"component"] isKindOfClass:NSData.class]) {
            if (error) *error = hostError(@"VST3 の保存状態が壊れています。"); return false;
        }
        if (!beginStateAccess(error)) return false;
        NSData *comp = plist[@"component"], *ctrl = plist[@"controller"];
        MemoryStream componentStream((void *)comp.bytes, comp.length);
        auto result = component->setState(&componentStream);
        if (controller && result == kResultOk) {
            componentStream.seek(0, IBStream::kIBSeekSet, nullptr); controller->setComponentState(&componentStream);
            if ([ctrl isKindOfClass:NSData.class] && ctrl.length) {
                MemoryStream controllerStream((void *)ctrl.bytes, ctrl.length); controller->setState(&controllerStream);
            }
            NSDictionary *values = plist[@"values"];
            for (auto &p : parameters) {
                NSNumber *saved = [values isKindOfClass:NSDictionary.class] ? values[[NSString stringWithFormat:@"%u", p->info.id]] : nil;
                double value = [saved isKindOfClass:NSNumber.class] ? saved.doubleValue : controller->getParamNormalized(p->info.id);
                p->value.store(value); p->pending.store(true);
                controller->setParamNormalized(p->info.id, value);
            }
        }
        stateAccess.store(false, std::memory_order_release);
        if (result != kResultOk && error) *error = hostError(@"VST3 の保存状態を復元できませんでした。");
        return result == kResultOk;
    }

    OSStatus render(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                    uint32_t frames, AudioBufferList *output, const AURenderEvent *events,
                    AURenderPullInputBlock pull) {
        if (!processing || frames > maxFrames || !pull) return kAudioUnitErr_Uninitialized;
        inputList.count = channels;
        for (int i = 0; i < channels; ++i) {
            inputList.buffers[i].mDataByteSize = frames * sizeof(float);
            inputList.buffers[i].mData = data.inputs[0].channelBuffers32[i];
        }
        OSStatus status = pull(flags, timestamp, frames, 0, (AudioBufferList *)&inputList);
        if (status) { failure.store(status); return status; }
        for (int i = 0; i < pluginChannels; ++i) {
            const float *source = (float *)inputList.buffers[std::min(i, channels - 1)].mData;
            if (!source) return kAudioUnitErr_NoConnection;
            float *target = data.inputs[0].channelBuffers32[i];
            if (target != source) memcpy(target, source, frames * sizeof(float));
        }
        uint32_t delay = latencyReported.load(std::memory_order_relaxed);
        for (uint32_t i = 0; i < frames; ++i) {
            for (int c = 0; c < channels; ++c) {
                float input = data.inputs[0].channelBuffers32[c][i];
                if (delay) {
                    size_t index = (size_t)c * delay + dryDelayPosition;
                    dryOutput[(size_t)c * maxFrames + i] = dryDelay[index];
                    dryDelay[index] = input;
                } else dryOutput[(size_t)c * maxFrames + i] = input;
            }
            if (delay && ++dryDelayPosition == delay) dryDelayPosition = 0;
        }
        rendering.fetch_add(1, std::memory_order_seq_cst);
        bool suspended = stateAccess.load(std::memory_order_seq_cst);
        if (!suspended) {
            inputChanges.clear(); outputChanges.clear();
            for (auto &p : parameters) if (p->pending.exchange(false, std::memory_order_acquire)) {
                int32 index, point; auto q = inputChanges.addParameterData(p->info.id, index);
                if (q) q->addPoint(0, p->value.load(std::memory_order_relaxed), point);
            }
            for (auto event = events; event; event = event->head.next) {
                if (event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp) {
                    int32 index, point; auto q = inputChanges.addParameterData((ParamID)event->parameter.parameterAddress, index);
                    if (q) q->addPoint(0, event->parameter.value, point);
                }
            }
            data.numSamples = frames; context.projectTimeSamples = position;
            context.continousTimeSamples = position; context.state = ProcessContext::kPlaying | ProcessContext::kContTimeValid;
            for (int i = 0; i < data.numInputs; ++i) {
                data.inputs[i].silenceFlags = 0;
                if (i > 0) for (int c = 0; c < data.inputs[i].numChannels; ++c) memset(data.inputs[i].channelBuffers32[c], 0, frames * sizeof(float));
            }
            for (int i = 0; i < data.numOutputs; ++i) data.outputs[i].silenceFlags = 0;
            try { if (processor->process(data) != kResultOk) { failure.store(kAudioUnitErr_CannotDoInCurrentContext); suspended = true; } }
            catch (...) { failure.store(kAudioUnitErr_CannotDoInCurrentContext); suspended = true; }
            for (int c = 0; c < pluginChannels; ++c) {
                if (data.outputs[0].silenceFlags & (uint64_t(1) << c))
                    memset(data.outputs[0].channelBuffers32[c], 0, frames * sizeof(float));
            }
            for (int i = 0; i < outputChanges.used; ++i) {
                auto q = outputChanges.active[i];
                if (q->count) if (auto p = parameter(q->id)) {
                    p->value.store(q->values[q->count - 1]); p->controllerPending.store(true, std::memory_order_release);
                }
            }
        }
        bool dry = suspended || bypassed.load(std::memory_order_relaxed);
        for (int c = 0; c < channels; ++c) {
            float *source = dry ? dryOutput.data() + (size_t)c * maxFrames : data.outputs[0].channelBuffers32[c];
            if (!dry && channels == 1 && pluginChannels == 2) {
                float *right = data.outputs[0].channelBuffers32[1];
                for (uint32_t i = 0; i < frames; ++i) source[i] = 0.5f * (source[i] + right[i]);
            }
            if (output->mNumberBuffers <= (UInt32)c) { rendering.fetch_sub(1); return kAudioUnitErr_FormatNotSupported; }
            if (output->mBuffers[c].mData && output->mBuffers[c].mData != source)
                memcpy(output->mBuffers[c].mData, source, frames * sizeof(float));
            else output->mBuffers[c].mData = source;
            output->mBuffers[c].mDataByteSize = frames * sizeof(float);
        }
        position += frames; rendering.fetch_sub(1, std::memory_order_seq_cst);
        return failure.load(std::memory_order_relaxed) ? kAudioUnitErr_CannotDoInCurrentContext : noErr;
    }

    void closeEditor() {
        if (view) { view->removed(); view->setFrame(nullptr); view.reset(); }
        editor = nil;
    }
};
}

@interface EPVSTEditorView : NSView {
@public std::shared_ptr<Host> host;
}
@end
@implementation EPVSTEditorView
- (void)dealloc { if (host) host->closeEditor(); }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    if (!host->view || !characters.length || host->view->onKeyDown([characters characterAtIndex:0], 0, 0) != kResultTrue) [super keyDown:event];
}
- (void)keyUp:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    if (!host->view || !characters.length || host->view->onKeyUp([characters characterAtIndex:0], 0, 0) != kResultTrue) [super keyUp:event];
}
- (void)scrollWheel:(NSEvent *)event {
    if (!host->view || host->view->onWheel(event.scrollingDeltaY) != kResultTrue) [super scrollWheel:event];
}
@end

@implementation EPVST3AudioUnit {
    std::shared_ptr<Host> _host;
    AUAudioUnitBusArray *_inputs, *_outputs;
    AUAudioUnitBus *_input, *_output;
    AUParameterTree *_parameters;
    NSTimer *_parameterTimer;
}
+ (AudioComponentDescription)componentDescription { return {'aufx', 'EPv3', 'EPod', 0, 0}; }
+ (void)registerComponent {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ [AUAudioUnit registerSubclass:self asComponentDescription:self.componentDescription name:@"EasyPod: VST3 Bridge" version:1]; });
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (self) {
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        _input = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
        _output = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
        if (!_input || !_output) return nil;
        _input.maximumChannelCount = _output.maximumChannelCount = 2;
        _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];
        _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
        self.maximumFramesToRender = 4096;
    }
    return self;
}
- (void)dealloc { [_parameterTimer invalidate]; _host.reset(); }
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (AUParameterTree *)parameterTree { return _parameters; }
- (BOOL)configureWithPath:(NSString *)path classID:(NSString *)classID sampleRate:(double)sampleRate channels:(NSInteger)channels offline:(BOOL)offline error:(NSError **)error {
    if (self.renderResourcesAllocated || channels < 1 || channels > 2 || sampleRate < 8000 || sampleRate > 192000) {
        if (error) *error = hostError(@"プラグインは音声処理停止中に設定してください。"); return NO;
    }
    auto host = std::make_shared<Host>();
    try { if (!host->load(path, classID, sampleRate, (int)channels, offline, error)) return NO; }
    catch (const std::exception &exception) { if (error) *error = hostError(text(exception.what())); return NO; }
    catch (...) { if (error) *error = hostError(@"VST3 の初期化中にエラーが発生しました。"); return NO; }
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:(AVAudioChannelCount)channels];
    if (![_input setFormat:format error:error] || ![_output setFormat:format error:error]) return NO;
    _host = host;
    NSMutableArray<AUParameter *> *params = [NSMutableArray array];
    for (auto &p : host->parameters) {
        NSString *title = text(StringConvert::convert(p->info.title));
        AUParameter *param = [AUParameterTree createParameterWithIdentifier:[NSString stringWithFormat:@"vst3_%u", p->info.id]
            name:title address:p->info.id min:0 max:1 unit:kAudioUnitParameterUnit_Generic unitName:nil
            flags:(kAudioUnitParameterFlag_IsReadable | ((p->info.flags & ParameterInfo::kIsReadOnly) ? 0 : kAudioUnitParameterFlag_IsWritable)) valueStrings:nil dependentParameters:nil];
        param.value = p->value.load(); [params addObject:param];
    }
    _parameters = [AUParameterTree createTreeWithChildren:params];
    _parameters.implementorValueObserver = ^(AUParameter *parameter, AUValue value) {
        bool onMain = [NSThread isMainThread];
        host->edit((ParamID)parameter.address, value, onMain);
        if (!onMain) if (auto p = host->parameter((ParamID)parameter.address)) p->controllerPending.store(true, std::memory_order_release);
    };
    _parameters.implementorValueProvider = ^AUValue(AUParameter *parameter) { auto p = host->parameter((ParamID)parameter.address); return p ? (AUValue)p->value.load() : 0; };
    _parameters.implementorStringFromValueCallback = ^NSString *(AUParameter *parameter, const AUValue *value) {
        String128 result{}; double current = value ? *value : parameter.value;
        if (host->controller && host->controller->getParamStringByValue((ParamID)parameter.address, current, result) == kResultOk)
            return text(StringConvert::convert(result));
        return [NSString stringWithFormat:@"%.3f", current];
    };
    [_parameterTimer invalidate];
    _parameterTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        if (!host->controller) return;
        for (auto &p : host->parameters) if (p->controllerPending.exchange(false, std::memory_order_acquire)) host->controller->setParamNormalized(p->info.id, p->value.load());
    }];
    return YES;
}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (!_host) { if (error) *error = hostError(@"VST3 が設定されていません。"); return NO; }
    if (_input.format.channelCount != _host->channels || _output.format.channelCount != _host->channels ||
        _input.format.sampleRate != _host->sampleRate || _output.format.sampleRate != _host->sampleRate) {
        if (error) *error = hostError(@"VST3 とエンジンの音声形式が一致しません。"); return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    try {
        if (!_host->activate(self.maximumFramesToRender, error)) { [super deallocateRenderResources]; return NO; }
    } catch (...) {
        _host->deactivate(); [super deallocateRenderResources];
        if (error) *error = hostError(@"VST3 の音声処理用メモリを確保できませんでした。"); return NO;
    }
    return YES;
}
- (void)deallocateRenderResources { if (_host) _host->deactivate(); [super deallocateRenderResources]; }
- (AUInternalRenderBlock)internalRenderBlock {
    auto host = _host;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
        NSInteger bus, AudioBufferList *output, const AURenderEvent *events, AURenderPullInputBlock pull) {
        if (!host || bus != 0) return kAudioUnitErr_Uninitialized;
        return host->render(flags, timestamp, frames, output, events, pull);
    };
}
- (BOOL)shouldBypassEffect { return _host ? _host->bypassed.load() : NO; }
- (void)setShouldBypassEffect:(BOOL)bypass { if (_host) _host->bypassed.store(bypass); }
- (NSTimeInterval)latency { return _host ? _host->latencyReported.load() / _host->sampleRate : 0; }
- (NSTimeInterval)tailTime {
    if (!_host || !_host->processor) return 0;
    uint32 tail = _host->processor->getTailSamples();
    return tail == kInfiniteTail ? INFINITY : tail / _host->sampleRate;
}
- (BOOL)hasInfiniteTail { return isinf(self.tailTime); }
- (NSInteger)processingFailure { return _host ? _host->failure.load() : 0; }
- (BOOL)requiresReconfiguration { return _host && (_host->restartFlags.load() & (kIoChanged | kLatencyChanged | kReloadComponent)); }
- (void)reset {
    [super reset];
    if (_host && _host->processing && !_host->rendering.load()) {
        _host->processor->setProcessing(false); _host->processor->setProcessing(true); _host->position = 0; _host->failure.store(0);
        std::fill(_host->dryDelay.begin(), _host->dryDelay.end(), 0);
        _host->dryDelayPosition = 0;
    }
}
- (NSData *)savePluginStateWithError:(NSError **)error { return _host ? _host->save(error) : nil; }
- (BOOL)restorePluginState:(NSData *)state error:(NSError **)error { return _host && _host->restore(state, error); }
- (NSView *)makeEditorView {
    if (!_host || !_host->controller) return nil;
    if (_host->editor) return _host->editor;
    _host->view = owned(_host->controller->createView(ViewType::kEditor));
    if (!_host->view || _host->view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultOk) { _host->view.reset(); return nil; }
    ViewRect rect(0, 0, 640, 480); _host->view->getSize(&rect);
    EPVSTEditorView *editor = [[EPVSTEditorView alloc] initWithFrame:NSMakeRect(0, 0, rect.getWidth(), rect.getHeight())];
    editor->host = _host; _host->editor = editor; _host->view->setFrame(_host.get());
    if (_host->view->attached((__bridge void *)editor, kPlatformTypeNSView) != kResultOk) { _host->closeEditor(); return nil; }
    _host->view->onSize(&rect); return editor;
}
- (void)closeEditor { if (_host) _host->closeEditor(); }
@end

NSArray<NSDictionary *> *EPScanVST3(NSString *path, NSError **error) {
    NSURL *url = [NSURL fileURLWithPath:path];
    NSArray<NSNumber *> *architectures = CFBridgingRelease(CFBundleCopyExecutableArchitecturesForURL((__bridge CFURLRef)url));
    if (![architectures containsObject:@(0x0100000c)]) { if (error) *error = hostError(@"Apple Silicon (arm64) に対応していません。"); return nil; }
    std::string message;
    auto module = VST3::Hosting::Module::create(path.UTF8String, message);
    if (!module) { if (error) *error = hostError(text(message)); return nil; }
    auto factory = module->getFactory(); factory.setHostContext(application());
    NSMutableArray *results = [NSMutableArray array];
    for (const auto &info : factory.classInfos()) {
        if (info.category() != kVstAudioEffectClass || info.subCategoriesString().find("Instrument") != std::string::npos) continue;
        NSError *loadError = nil;
        EPVST3AudioUnit *unit = [[EPVST3AudioUnit alloc] initWithComponentDescription:EPVST3AudioUnit.componentDescription options:0 error:&loadError];
        BOOL compatible = [unit configureWithPath:path classID:text(info.ID().toString()) sampleRate:48000 channels:2 offline:NO error:&loadError];
        if (!compatible) compatible = [unit configureWithPath:path classID:text(info.ID().toString()) sampleRate:48000 channels:1 offline:NO error:&loadError];
        if (compatible) compatible = [unit allocateRenderResourcesAndReturnError:&loadError];
        if (unit.renderResourcesAllocated) [unit deallocateRenderResources];
        NSMutableDictionary *descriptor = [@{@"id": [@"vst3:" stringByAppendingString:text(info.ID().toString())],
            @"name": text(info.name()), @"manufacturer": text(info.vendor()), @"format": @"VST3",
            @"path": path, @"classID": text(info.ID().toString()), @"version": text(info.version())} mutableCopy];
        if (!compatible) descriptor[@"unavailableReason"] = loadError.localizedDescription ?: @"初期化に失敗しました。";
        [results addObject:descriptor];
    }
    if (!results.count) { if (error) *error = hostError(@"利用可能な音声エフェクトがありません。"); return nil; }
    return results;
}
