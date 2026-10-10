// Exercise host-owned parameter state without loading installed plugin modules.
#import "AudioPluginHost.mm"
#include <iostream>
#include <stdexcept>

namespace {
constexpr size_t fixtureParameterCount = 4096;
ParamID fixtureID(size_t index) { return static_cast<ParamID>(90000 + 17 * index); }

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

class FixtureController final : public U::ImplementsNonDestroyable<U::Directly<IEditController>> {
public:
    std::array<double, fixtureParameterCount> values{};
    std::atomic<size_t> queries{0};
    std::atomic<bool> wrongThread{false};
    tresult PLUGIN_API initialize(FUnknown *) override { return kResultOk; }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    tresult PLUGIN_API setComponentState(IBStream *) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream *) override { return kResultOk; }
    tresult PLUGIN_API getState(IBStream *) override { return kResultOk; }
    int32 PLUGIN_API getParameterCount() override { return fixtureParameterCount; }
    tresult PLUGIN_API getParameterInfo(int32, ParameterInfo &) override { return kNotImplemented; }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue, String128) override { return kNotImplemented; }
    tresult PLUGIN_API getParamValueByString(ParamID, TChar *, ParamValue &) override { return kNotImplemented; }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue value) override { return value; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue value) override { return value; }
    ParamValue PLUGIN_API getParamNormalized(ParamID id) override {
        queries.fetch_add(1);
        if (![NSThread isMainThread]) wrongThread.store(true);
        return values[(id - fixtureID(0)) / 17];
    }
    tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue value) override {
        values[(id - fixtureID(0)) / 17] = value;
        return kResultOk;
    }
    tresult PLUGIN_API setComponentHandler(IComponentHandler *) override { return kResultOk; }
    IPlugView *PLUGIN_API createView(FIDString) override { return nullptr; }
};

class FixtureComponent final : public U::ImplementsNonDestroyable<U::Directly<IComponent>> {
public:
    tresult PLUGIN_API initialize(FUnknown *) override { return kResultOk; }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    tresult PLUGIN_API getControllerClassId(TUID) override { return kNotImplemented; }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType, BusDirection) override { return 0; }
    tresult PLUGIN_API getBusInfo(MediaType, BusDirection, int32, BusInfo &) override { return kNotImplemented; }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo &, RoutingInfo &) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) override { return kResultOk; }
    tresult PLUGIN_API setActive(TBool) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream *stream) override {
        char marker = 0;
        return stream->read(&marker, 1, nullptr) == kResultOk && marker == 'S' ? kResultOk : kResultFalse;
    }
    tresult PLUGIN_API getState(IBStream *stream) override {
        char marker = 'S';
        return stream->write(&marker, 1, nullptr);
    }
};

void prepare(Host &host, FixtureController &controller, FixtureComponent &component) {
    host.controller = &controller;
    host.component = &component;
    std::vector<ParamID> ids;
    // Reverse IDs verify that prepared-slot order and ID-search order are independent.
    for (size_t index = fixtureParameterCount; index-- > 0;) {
        auto parameter = std::make_unique<Parameter>();
        parameter->info.id = fixtureID(index);
        parameter->value.store(0.1);
        ids.push_back(parameter->info.id);
        host.parameters.push_back(std::move(parameter));
    }
    host.prepareParameterIndices(ids);
}

void verifyBulkCacheAndStructuralFlags() {
    FixtureController controller;
    FixtureComponent component;
    Host host;
    prepare(host, controller, component);
    controller.values.fill(0.75);
    host.restartComponent(kParamValuesChanged | kIoChanged | kLatencyChanged | kReloadComponent);
    require(controller.queries.load() == fixtureParameterCount, "Bulk refresh did not query every value");
    require(host.restartFlags.load() == (kIoChanged | kLatencyChanged | kReloadComponent), "Structural flags were consumed");
    for (size_t index = 0; index < fixtureParameterCount; ++index)
        require(host.parameter(fixtureID(index))->value.load() == 0.75, "Preset cache stayed stale");
    require(host.parameter(1) == nullptr, "Unknown ID resolved to a parameter");

    controller.values.fill(0.625);
    size_t before = controller.queries.load();
    std::thread publisher([&] { host.restartComponent(kParamValuesChanged); });
    publisher.join();
    require(controller.queries.load() == before, "Controller was queried on a worker");
    NSError *error = nil;
    NSData *state = host.save(&error);
    require(state != nil && error == nil, "State save failed");
    require(!controller.wrongThread.load(), "Controller queries escaped UI ownership");
    require(host.restartFlags.load() == (kIoChanged | kLatencyChanged | kReloadComponent), "Save lost structural flags");

    FixtureController restoredController;
    FixtureComponent restoredComponent;
    Host restored;
    prepare(restored, restoredController, restoredComponent);
    require(restored.restore(state, &error), "State restore failed");
    for (size_t index = 0; index < fixtureParameterCount; ++index) {
        require(restoredController.values[index] == 0.625, "Restore replaced a bulk preset value");
        require(restored.parameter(fixtureID(index))->pending.load(), "Restored values were not queued");
    }
}

void verifyBoundedIndexedQueues() {
    std::vector<ParamID> ids;
    for (size_t index = fixtureParameterCount; index-- > 0;) ids.push_back(fixtureID(index));
    FixedChanges changes;
    changes.prepare(ids);
    auto queueStorage = changes.queues.data();
    auto activeStorage = changes.active.data();
    for (size_t index = 0; index < ids.size(); ++index) {
        int32 activeIndex = -1, point = -1;
        auto queue = changes.addByIndex(index, activeIndex);
        require(queue && queue->getParameterId() == ids[index], "Prepared queue used the wrong ID");
        require(activeIndex == index, "Active queue index was unstable");
        queue->addPoint(0, 0.625, point);
    }
    require(changes.getParameterCount() == fixtureParameterCount, "Bulk queue count exceeded fixed capacity");
    for (size_t index = 0; index < ids.size(); ++index) {
        int32 activeIndex = -1;
        auto queue = changes.addParameterData(ids[index], activeIndex);
        require(queue == changes.getParameterData(index) && activeIndex == index, "ID lookup created a duplicate queue");
    }
    int32 unknownIndex = -1;
    require(changes.addParameterData(1, unknownIndex) == nullptr, "Unknown queue ID was accepted");
    auto queue = changes.getParameterData(0);
    int32 point = -1;
    for (int i = 0; i < 40; ++i) queue->addPoint(i, i / 40., point);
    int32 offset = -1;
    double value = 0;
    require(queue->getPointCount() == 32, "Point storage grew beyond its bound");
    require(queue->getPoint(31, offset, value) == kResultOk && offset == 39, "Latest overflow edit was lost");
    changes.clear();
    require(changes.getParameterCount() == 0 && queue->getPointCount() == 0, "Queue retirement retained old points");
    changes.addParameterData(ids.back(), unknownIndex);
    require(unknownIndex == 0, "Retired queue retained its active index");
    require(changes.queues.data() == queueStorage && changes.active.data() == activeStorage, "Render lookup grew storage");
}
}

int main() {
    @autoreleasepool {
        try {
            verifyBulkCacheAndStructuralFlags();
            verifyBoundedIndexedQueues();
            std::cout << "bulkPresetCache=passed uiOwnership=passed structuralFlags=passed stateRoundTrip=passed indexed4096Queues=passed boundedPoints=passed\n";
            return 0;
        } catch (const std::exception &error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
}
