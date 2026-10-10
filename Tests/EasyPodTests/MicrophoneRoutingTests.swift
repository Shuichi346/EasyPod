import AVFoundation
import CoreAudio
import Darwin
import XCTest

@testable import EasyPod

@MainActor final class MicrophoneRoutingTests: XCTestCase {
  private func device(_ id: UInt32, rate: Double, input: UInt32, output: UInt32)
    -> CaptureDeviceInfo
  {
    CaptureDeviceInfo(
      id: id, name: "Device \(id)", uid: "fixture-\(id)", inputChannels: input,
      outputChannels: output, sampleRate: rate, isAlive: true)
  }

  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodRouteTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writer(_ directory: URL, processed: Bool = false) throws -> OpaquePointer {
    var code: Int32 = 0
    return try XCTUnwrap(
      directory.appendingPathComponent("source.caf").path.withCString { source in
        directory.appendingPathComponent("processed.caf").path.withCString { wet in
          ep_capture_create(source, processed ? wet : nil, 48_000, 1, &code)
        }
      })
  }

  private func buffer(_ count: UInt32 = 4) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
    buffer.frameLength = count
    for index in 0..<Int(count) { buffer.floatChannelData![0][index] = Float(index) / 100 }
    return buffer
  }

  private func clock(sequence: UInt64 = 2, sample: Int64 = 104, hostOffset: Double = 0)
    -> EPCaptureClock
  {
    EPCaptureClock(
      sequence: sequence, sampleTime: sample, previousSampleTime: sample - 4,
      hostTime: AVAudioTime.hostTime(forSeconds: 1 + Double(sample) / 48_000 + hostOffset),
      previousHostTime: AVAudioTime.hostTime(
        forSeconds: 1 + Double(sample - 4) / 48_000 + hostOffset),
      clockRate: 192_000, formatRate: 48_000, frames: 4, valid: true)
  }

  func testInputOnlyRouteUsesDefaultOutputAndOwnsOnlyPrivateAggregate() throws {
    let input = device(1, rate: 16_000, input: 1, output: 0)
    let output = device(2, rate: 48_000, input: 0, output: 2)
    let plan = try CaptureDeviceRoutePlan(input: input, output: output)
    XCTAssertEqual(try plan.inputMap(hardwareChannels: 3), [0, -1, -1])
    XCTAssertEqual(try plan.outputMap(hardwareChannels: 2), [0, 1])
    XCTAssertThrowsError(try plan.outputMap(hardwareChannels: 4))
    var creations = 0
    var releases: [UInt32] = []
    let route = try CaptureAudioRoute.configured(
      plan: plan,
      create: { composition in
        creations += 1
        XCTAssertEqual(composition[kAudioAggregateDeviceIsPrivateKey] as? Int, 1)
        XCTAssertEqual(composition[kAudioAggregateDeviceMainSubDeviceKey] as? String, input.uid)
        let parts = try XCTUnwrap(
          composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0][kAudioSubDeviceUIDKey] as? String, input.uid)
        XCTAssertNil(parts[0][kAudioSubDeviceOutputChannelsKey])
        XCTAssertNil(parts[0][kAudioSubDeviceInputChannelsKey])
        XCTAssertEqual(parts[1][kAudioSubDeviceUIDKey] as? String, output.uid)
        XCTAssertNil(parts[1][kAudioSubDeviceInputChannelsKey])
        XCTAssertNil(parts[1][kAudioSubDeviceOutputChannelsKey])
        XCTAssertEqual(parts[1][kAudioSubDeviceDriftCompensationKey] as? Int, 1)
        return 900
      },
      destroy: {
        releases.append($0)
        return noErr
      }, configure: { XCTAssertEqual($0, 900) })
    XCTAssertEqual(route.input, input)
    XCTAssertEqual(route.close(), noErr)
    XCTAssertEqual(route.close(), noErr)
    XCTAssertEqual(creations, 1)
    XCTAssertEqual(releases, [900])

    let duplex = device(3, rate: 192_000, input: 2, output: 2)
    let split = try CaptureDeviceRoutePlan(input: duplex, output: output)
    XCTAssertEqual(try split.outputMap(hardwareChannels: 4), [-1, -1, 0, 1])
    let direct = try CaptureAudioRoute.configured(
      plan: CaptureDeviceRoutePlan(input: duplex, output: duplex),
      create: { _ in
        XCTFail("A coherent duplex device needs no aggregate")
        return 901
      },
      destroy: { _ in
        XCTFail("Physical devices must never be destroyed")
        return noErr
      },
      configure: { XCTAssertEqual($0, duplex.id) })
    XCTAssertEqual(direct.close(), noErr)
  }

  func testSwitchingNativeRatesLeavesDeviceFormatsIntactAndFailureReleasesRoute() throws {
    let inputA = device(1, rate: 16_000, input: 1, output: 0)
    let inputB = device(2, rate: 192_000, input: 2, output: 2)
    let output = device(3, rate: 48_000, input: 0, output: 2)
    var releases: [UInt32] = []
    for (index, input) in [inputA, inputB, inputA].enumerated() {
      let native = try XCTUnwrap(
        AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: input.inputChannels)
      )
      let format = try AudioCaptureService.inputFormat(native)
      XCTAssertEqual(format.sampleRate, input.sampleRate)
      XCTAssertEqual(format.channelCount, input.inputChannels)
      let id = UInt32(900 + index)
      let route = try CaptureAudioRoute.configured(
        plan: CaptureDeviceRoutePlan(input: input, output: output),
        create: { _ in id },
        destroy: {
          releases.append($0)
          return noErr
        }, configure: { XCTAssertEqual($0, id) })
      route.close()
    }
    XCTAssertEqual(releases, [900, 901, 902])
    XCTAssertEqual(output.sampleRate, 48_000)
    XCTAssertThrowsError(
      try CaptureAudioRoute.configured(
        plan: CaptureDeviceRoutePlan(input: inputA, output: output),
        create: { _ in 903 },
        destroy: {
          releases.append($0)
          return noErr
        },
        configure: { _ in throw EasyPodError.message("Fixture initialization failure") }))
    XCTAssertEqual(releases, [900, 901, 902, 903])
    var destroyAttempts = 0
    do {
      _ = try CaptureAudioRoute.configured(
        plan: CaptureDeviceRoutePlan(input: inputA, output: output),
        create: { _ in 904 },
        destroy: { id in
          XCTAssertEqual(id, 904)
          destroyAttempts += 1
          return destroyAttempts == 1 ? -50 : noErr
        }, configure: { _ in throw EasyPodError.message("Fixture failure") })
      XCTFail("Failed route cleanup must be visible")
    } catch { XCTAssertTrue(error.localizedDescription.contains("解放にも失敗")) }
    XCTAssertEqual(destroyAttempts, 1)
    XCTAssertEqual(CaptureAudioRoute.retryCleanup(), noErr)
    XCTAssertEqual(CaptureAudioRoute.retryCleanup(), noErr)
    XCTAssertEqual(destroyAttempts, 2)
    XCTAssertThrowsError(
      try CaptureDeviceRoutePlan(input: device(4, rate: 0, input: 0, output: 2), output: output))
    XCTAssertThrowsError(
      try CaptureDeviceRoutePlan(
        input: inputA, output: device(5, rate: 48_000, input: 1, output: 0)))
  }

  func testEngineOwnedDefaultRouteIsBorrowedWithoutCreatingOrDestroyingDevices() async throws {
    let plan = try CaptureDeviceRoutePlan(
      input: device(1, rate: 48_000, input: 1, output: 0),
      output: device(2, rate: 192_000, input: 2, output: 2))
    var configurations: [UInt32] = []
    let route = try await CaptureAudioRoute.configuredAsync(
      plan: plan, existingDeviceID: 900,
      create: { _ in
        XCTFail("The engine's default route must not be replaced")
        return 901
      },
      destroy: { _ in
        XCTFail("The engine owns its own route")
        return noErr
      },
      configure: { configurations.append($0) })
    XCTAssertEqual(route.deviceID, 900)
    XCTAssertEqual(configurations, [900])
    XCTAssertEqual(route.close(), noErr)
    XCTAssertEqual(route.close(), noErr)
    do {
      _ = try await CaptureAudioRoute.configuredAsync(
        plan: plan, existingDeviceID: 900,
        destroy: { _ in
          XCTFail("Failed preparation must not destroy an engine-owned route")
          return noErr
        },
        configure: { _ in throw CancellationError() })
      XCTFail("Cancelled route preparation must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testAggregateReadinessWaitsForBothDevicesAndReleasesOnFailure() async throws {
    let input = device(1, rate: 16_000, input: 1, output: 0)
    let output = device(2, rate: 48_000, input: 0, output: 2)
    let plan = try CaptureDeviceRoutePlan(input: input, output: output)
    let ready = device(900, rate: 16_000, input: 1, output: 2)
    let active = [input.uid, output.uid]
    XCTAssertFalse(CaptureRouteReadiness.matches(nil, activeDeviceUIDs: active, plan: plan))
    XCTAssertFalse(
      CaptureRouteReadiness.matches(ready, activeDeviceUIDs: [input.uid], plan: plan))
    XCTAssertFalse(
      CaptureRouteReadiness.matches(
        device(900, rate: 16_000, input: 1, output: 0), activeDeviceUIDs: active, plan: plan))
    XCTAssertFalse(
      CaptureRouteReadiness.matches(
        device(900, rate: .nan, input: 1, output: 2), activeDeviceUIDs: active, plan: plan))
    XCTAssertTrue(CaptureRouteReadiness.matches(ready, activeDeviceUIDs: active, plan: plan))
    var polls = 0
    var releases: [UInt32] = []
    let route = try await CaptureAudioRoute.configuredAsync(
      plan: plan, create: { _ in 900 },
      destroy: {
        releases.append($0)
        return noErr
      },
      configure: { _ in
        try await CaptureRouteReadiness.wait(
          isReady: {
            polls += 1
            return CaptureRouteReadiness.matches(
              ready, activeDeviceUIDs: polls < 3 ? [input.uid] : active, plan: plan)
          }, timeout: .milliseconds(400))
      })
    XCTAssertEqual(polls, 3)
    XCTAssertTrue(releases.isEmpty)
    XCTAssertEqual(route.close(), noErr)
    XCTAssertEqual(releases, [900])

    do {
      _ = try await CaptureAudioRoute.configuredAsync(
        plan: plan, create: { _ in 901 },
        destroy: {
          releases.append($0)
          return noErr
        },
        configure: { _ in
          try await CaptureRouteReadiness.wait(isReady: { false }, timeout: .milliseconds(50))
        })
      XCTFail("An unavailable aggregate must fail within the readiness deadline")
    } catch { XCTAssertFalse(error is CancellationError) }
    XCTAssertEqual(releases, [900, 901])

    var cancellationReady = false
    let preparation = Task { @MainActor in
      try await CaptureAudioRoute.configuredAsync(
        plan: plan, create: { _ in 902 },
        destroy: {
          releases.append($0)
          return noErr
        },
        configure: { _ in
          try await CaptureRouteReadiness.wait {
            cancellationReady = true
            return false
          }
        })
    }
    // Wait only for the owned route to enter readiness, without involving any hardware.
    for _ in 0..<50 where !cancellationReady { await Task.yield() }
    preparation.cancel()
    do {
      _ = try await preparation.value
      XCTFail("Cancelled preparation must close its private route")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(releases, [900, 901, 902])
  }

  func testHardwareClockNormalizationAndSharedLatencyBoundary() throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let handle = try writer(directory, processed: true)
    let samples = try buffer()
    for position: Int64 in [100, 104] {
      let host = AVAudioTime.hostTime(forSeconds: 1 + Double(position) / 48_000)
      ep_capture_push_source_clocked(
        handle, samples.audioBufferList, 4, position * 4, 192_000, host, 48_000)
      ep_capture_push_processed_clocked(
        handle, samples.audioBufferList, 4, position, 48_000, host, 48_000)
    }
    let source = ep_capture_clock(handle, false)
    let wet = ep_capture_clock(handle, true)
    XCTAssertEqual(source.sampleTime, 104)
    XCTAssertEqual(source.previousSampleTime, 100)
    XCTAssertEqual(source.clockRate, 192_000)
    XCTAssertTrue(source.valid)
    XCTAssertEqual(ep_capture_status(handle).sourceFrames, 0)
    let boundary = try XCTUnwrap(
      CaptureClockReadiness.boundary(
        source: source, processed: wet, sourceBaseline: 0, processedBaseline: 0, sampleRate: 48_000)
    )
    ep_capture_segment(handle, boundary, 2)
    ep_capture_processed_limit(handle, 8)
    ep_capture_enable_source(handle, true)
    ep_capture_enable_processed(handle, true)
    samples.frameLength = 4
    for start in [boundary - 4, boundary, boundary + 4, boundary + 8] {
      let host = AVAudioTime.hostTime(forSeconds: 1 + Double(start) / 48_000)
      for index in 0..<4 {
        samples.floatChannelData![0][index] = Float(start + Int64(index) - boundary - 2) / 100
      }
      ep_capture_push_processed_clocked(
        handle, samples.audioBufferList, 4, start, 48_000, host, 48_000)
      if start < boundary + 8 {
        for index in 0..<4 {
          samples.floatChannelData![0][index] = Float(start + Int64(index) - boundary) / 100
        }
        ep_capture_push_source_clocked(
          handle, samples.audioBufferList, 4, start * 4, 192_000, host, 48_000)
      }
    }
    let result = ep_capture_finalize(handle)
    XCTAssertEqual(result.sourceError, 0)
    XCTAssertEqual(result.processedError, 0)
    XCTAssertEqual(result.sourceFrames, 8)
    XCTAssertEqual(result.processedFrames, 8)
    let dry = try AVAudioFile(forReading: directory.appendingPathComponent("source.caf"))
    let processed = try AVAudioFile(forReading: directory.appendingPathComponent("processed.caf"))
    let reading = try buffer(8)
    try dry.read(into: reading)
    let original = Array(UnsafeBufferPointer(start: reading.floatChannelData![0], count: 8))
    try processed.read(into: reading, frameCount: 8)
    XCTAssertEqual(
      original, Array(UnsafeBufferPointer(start: reading.floatChannelData![0], count: 8)))
  }

  func testReadinessRejectsStaleInvalidAndDifferentEpochClocks() throws {
    let source = clock()
    XCTAssertNil(
      CaptureClockReadiness.boundary(
        source: source, processed: nil, sourceBaseline: 1, processedBaseline: 0, sampleRate: 48_000)
    )
    var invalid = source
    invalid.valid = false
    XCTAssertNil(
      CaptureClockReadiness.boundary(
        source: invalid, processed: nil, sourceBaseline: 0, processedBaseline: 0, sampleRate: 48_000
      ))
    var stale = source
    stale.previousSampleTime = stale.sampleTime
    XCTAssertNil(
      CaptureClockReadiness.boundary(
        source: stale, processed: nil, sourceBaseline: 0, processedBaseline: 0, sampleRate: 48_000))
    XCTAssertNil(
      CaptureClockReadiness.boundary(
        source: source, processed: clock(hostOffset: 0.05), sourceBaseline: 0, processedBaseline: 0,
        sampleRate: 48_000))
    XCTAssertNotNil(
      CaptureClockReadiness.boundary(
        source: clock(sequence: 4), processed: clock(sequence: 4), sourceBaseline: 2,
        processedBaseline: 2, sampleRate: 48_000))
    XCTAssertNil(
      CaptureClockReadiness.boundary(
        source: clock(sequence: 12), processed: nil,
        sourceBaseline: 12, processedBaseline: 0, sampleRate: 48_000))
    XCTAssertNil(
      CaptureClockReadiness.boundary(
        source: clock(sequence: 14), processed: nil,
        sourceBaseline: 12, processedBaseline: 0, sampleRate: 48_000,
        earliestHostTime: source.hostTime + 1))
    var largeSource = source
    largeSource.frames = 4800
    var largeProcessed = clock(sample: 108)
    largeProcessed.frames = 9600
    let future = try XCTUnwrap(
      CaptureClockReadiness.boundary(
        source: largeSource, processed: largeProcessed, sourceBaseline: 0, processedBaseline: 0,
        sampleRate: 48_000))
    XCTAssertEqual(future, largeProcessed.sampleTime + Int64(largeProcessed.frames) + 4096)
    XCTAssertGreaterThan(future, largeSource.sampleTime + Int64(largeSource.frames))
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let handle = try writer(directory)
    let samples = try buffer()
    ep_capture_segment(handle, 0, 0)
    ep_capture_enable_source(handle, true)
    ep_capture_push_source_clocked(handle, samples.audioBufferList, 4, 100, 44_100, 1000, 44_100)
    XCTAssertFalse(ep_capture_clock(handle, false).valid)
    let result = ep_capture_finalize(handle)
    XCTAssertEqual(result.sourceFrames, 0)
    XCTAssertEqual(result.sourceError, -71002)
  }

  func testReadinessAcceptsTapAfterTwoHundredMillisecondsAndBoundsFailures() async throws {
    let began = ContinuousClock.now
    let ready = clock()
    let boundary = try await CaptureClockReadiness.wait(
      sourceBaseline: 0, processedBaseline: 0, sampleRate: 48_000,
      isRunning: { true },
      source: { ContinuousClock.now - began >= .milliseconds(280) ? ready : EPCaptureClock() },
      processed: nil)
    XCTAssertEqual(boundary, ready.sampleTime + Int64(ready.frames) + 4096)
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(280))
    let timeoutBegan = ContinuousClock.now
    do {
      _ = try await CaptureClockReadiness.wait(
        sourceBaseline: 0, processedBaseline: 0, sampleRate: 48_000,
        isRunning: { true }, source: { EPCaptureClock() }, processed: nil,
        timeout: .milliseconds(60))
      XCTFail("An absent stream must have a bounded failure")
    } catch { XCTAssertLessThan(ContinuousClock.now - timeoutBegan, .seconds(1)) }
    do {
      _ = try await CaptureClockReadiness.wait(
        sourceBaseline: 0, processedBaseline: 0, sampleRate: 48_000,
        isRunning: { false }, source: { ready }, processed: nil)
      XCTFail("A stopped engine must fail before arming")
    } catch { XCTAssertTrue(error.localizedDescription.contains("停止")) }
  }

  func testSelectedMicrophonesStartAndStopWithoutChangingSystemDevices() async throws {
    let marker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/EasyPod/active-recording")
    guard !FileManager.default.fileExists(atPath: marker.path) else {
      throw XCTSkip("A real recording is active")
    }
    guard AudioDeviceService.authorizationStatus == .authorized else {
      throw XCTSkip("The app host needs existing microphone authorization")
    }
    let devices = AudioDeviceService.inputs()
    let selected = try ["SAudio", "US-2x2HR"].map { name -> AudioInputDevice in
      guard let device = devices.first(where: { $0.name == name }) else {
        throw XCTSkip("Selected device unavailable: \(name)")
      }
      return device
    }
    func defaultID(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var value: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
      XCTAssertEqual(status, noErr)
      return value
    }
    let defaultInput = try defaultID(kAudioHardwarePropertyDefaultInputDevice)
    let defaultOutput = try defaultID(kAudioHardwarePropertyDefaultOutputDevice)
    let outputBefore = try XCTUnwrap(AudioDeviceService.deviceInfo(defaultOutput))
    for device in selected {
      guard !FileManager.default.fileExists(atPath: marker.path) else {
        throw XCTSkip("A real recording started")
      }
      let inputBefore = try XCTUnwrap(AudioDeviceService.deviceInfo(device.id))
      let directory = try folder()
      defer { try? FileManager.default.removeItem(at: directory) }
      let capture = AudioCaptureService()
      var settings = RecordingSettings()
      settings.sampleRate = 48_000
      settings.channels = 1
      settings.effectTiming = .afterRecording
      do {
        try await capture.start(
          directory: directory, settings: settings, inputID: device.id, effects: nil, monitor: false
        ) { _ in }
      } catch {
        XCTFail("Selected input \(device.name) did not initialize: \(error.localizedDescription)")
        throw error
      }
      try await Task.sleep(for: .milliseconds(300))
      let result = try await capture.stop()
      XCTAssertTrue(result.sourceComplete, device.name)
      XCTAssertNil(result.warning, device.name)
      XCTAssertGreaterThan(result.frameCount, 0, device.name)
      let file = try AVAudioFile(forReading: directory.appendingPathComponent("source.caf"))
      XCTAssertEqual(file.length, result.frameCount)
      XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
      XCTAssertEqual(file.processingFormat.channelCount, 1)
      XCTAssertEqual(try defaultID(kAudioHardwarePropertyDefaultInputDevice), defaultInput)
      XCTAssertEqual(try defaultID(kAudioHardwarePropertyDefaultOutputDevice), defaultOutput)
      XCTAssertEqual(
        AudioDeviceService.deviceInfo(device.id)?.sampleRate, inputBefore.sampleRate, device.name)
      XCTAssertEqual(
        AudioDeviceService.deviceInfo(defaultOutput)?.sampleRate, outputBefore.sampleRate,
        device.name)
      XCTAssertFalse(AudioDeviceService.inputs().contains(where: { $0.name == "EasyPod Capture" }))
      print(
        "Selected microphone \(device.name): \(result.frameCount) frames, 48 kHz mono, complete")
    }
  }
}

private final class BufferedCaptureInput: CaptureInputSource, @unchecked Sendable {
  let sampleRate: Double
  let channels: UInt32 = 1
  let bridge: OpaquePointer
  private let samples: Int
  private var segment = 0

  init(sampleRate: Double, samples: Int = 8192) {
    self.sampleRate = sampleRate
    self.samples = samples
    bridge = ep_pcm_create(1, 131072)!
  }
  deinit { ep_pcm_destroy(bridge) }
  func start() -> Int32 {
    ep_pcm_clear(bridge)
    segment += 1
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples))!
    buffer.frameLength = UInt32(samples)
    for index in 0..<samples {
      buffer.floatChannelData![0][index] = Float(segment) * 0.1 + Float(index % 31) * 0.001
    }
    return ep_pcm_push(bridge, buffer.audioBufferList, buffer.frameLength)
      ? 0 : ep_pcm_error(bridge)
  }
  func stop() -> Int32 { 0 }
  func close() -> Int32 { 0 }
  func read(_ buffers: UnsafeMutablePointer<AudioBufferList>, maximumFrames: UInt32) -> UInt32 {
    ep_pcm_read(bridge, buffers, maximumFrames)
  }
  func error() -> Int32 { ep_pcm_error(bridge) }
}

private final class TestPCMHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

// The manual-render serial owner alone mutates this deterministic latency/tail filter.
private final class DelayTailCaptureState: @unchecked Sendable {
  let feed: OpaquePointer
  private let latencyFrames: Int
  private let tailFrames: Int
  private let capacity: Int
  private let history: UnsafeMutablePointer<Float>
  private var position = 0

  init(feed: OpaquePointer, latencyFrames: Int, tailFrames: Int) {
    self.feed = feed
    self.latencyFrames = latencyFrames
    self.tailFrames = tailFrames
    capacity = latencyFrames + tailFrames + 1
    history = .allocate(capacity: capacity)
    history.initialize(repeating: 0, count: capacity)
  }

  deinit {
    history.deinitialize(count: capacity)
    history.deallocate()
  }

  func render(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> OSStatus {
    let code = ep_pcm_render_strict(feed, buffers, frames)
    guard code == 0 else { return code }
    guard buffers.pointee.mNumberBuffers == 1,
      let samples = buffers.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
    else { return -50 }
    for index in 0..<Int(frames) {
      history[position] = samples[index]
      let delayed = (position + capacity - latencyFrames) % capacity
      let tail = (delayed + capacity - tailFrames) % capacity
      samples[index] = history[delayed] + 0.25 * history[tail]
      position = (position + 1) % capacity
    }
    return 0
  }
}

@MainActor
final class SeparatedCaptureTests: XCTestCase {
  private nonisolated static func source(format: AVAudioFormat, handle: TestPCMHandle)
    -> AVAudioSourceNode
  {
    AVAudioSourceNode(format: format) { _, _, frames, buffers in
      ep_pcm_render_strict(handle.pointer, buffers, frames)
    }
  }

  private nonisolated static func delayedSource(
    format: AVAudioFormat, state: DelayTailCaptureState
  ) -> AVAudioSourceNode {
    AVAudioSourceNode(format: format) { _, _, frames, buffers in
      state.render(buffers, frames: frames)
    }
  }

  private func latencyTailFixture(paused: Bool, latencyFrames: Int, tailFrames: Int) async throws
    -> (original: [Float], processed: [Float])
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PausedTailCapture-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var code: Int32 = 0
    let pointer = try XCTUnwrap(
      directory.appendingPathComponent("source.caf").path.withCString { source in
        directory.appendingPathComponent("processed.caf").path.withCString { processed in
          ep_capture_create(source, processed, 48_000, 1, &code)
        }
      })
    var finalized = false
    defer { if !finalized { ep_capture_destroy(pointer) } }
    let feed = try XCTUnwrap(ep_pcm_create(1, 16_384))
    let monitor = try XCTUnwrap(ep_pcm_create(1, 32_768))
    defer {
      ep_pcm_destroy(feed)
      ep_pcm_destroy(monitor)
    }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 4096)
    let state = DelayTailCaptureState(
      feed: feed, latencyFrames: latencyFrames, tailFrames: tailFrames)
    let source = Self.delayedSource(format: format, state: state)
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    let pipeline = try CaptureInputPipeline(
      input: BufferedCaptureInput(sampleRate: 48_000), writer: CaptureWriterHandle(pointer),
      engine: engine, feed: feed, monitorFeed: monitor, format: format, processing: true)
    let latency = Double(latencyFrames) / 48_000
    let tail = Double(tailFrames) / 48_000
    do {
      try await pipeline.arm(latencyFrames: UInt64(latencyFrames), processed: true)
      try await pipeline.start()
      await pipeline.pause(latency: latency, tail: paused ? 0 : tail)
      if paused { await pipeline.finishPaused(latency: latency, tail: tail) }
      await pipeline.close()
    } catch {
      await pipeline.close()
      throw error
    }
    let pipelineState = await pipeline.snapshot()
    XCTAssertEqual(pipelineState.inputError, 0)
    XCTAssertEqual(pipelineState.processingError, 0)
    XCTAssertEqual(pipelineState.cleanupError, 0)
    engine.detach(source)
    let status = ep_capture_finalize(pointer)
    finalized = true
    XCTAssertEqual(status.sourceError, 0)
    XCTAssertEqual(status.processedError, 0)
    XCTAssertEqual(status.sourceFrames, 8192)
    XCTAssertEqual(status.processedFrames, 8192 + Int64(tailFrames))

    func samples(_ name: String) throws -> [Float] {
      let file = try AVAudioFile(forReading: directory.appendingPathComponent(name))
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
      try file.read(into: buffer)
      let data = try XCTUnwrap(buffer.floatChannelData?[0])
      return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
    return (try samples("source.caf"), try samples("processed.caf"))
  }

  func testPauseThenStopPreservesLatencyAndTailIncludingShortSource() async throws {
    let tailFrames = 1536
    // The second case ends before latency has elapsed; both use non-chunk-aligned latency.
    for latencyFrames in [5280, 12_000] {
      let continuous = try await latencyTailFixture(
        paused: false, latencyFrames: latencyFrames, tailFrames: tailFrames)
      let paused = try await latencyTailFixture(
        paused: true, latencyFrames: latencyFrames, tailFrames: tailFrames)
      XCTAssertEqual(continuous.original, paused.original)
      XCTAssertEqual(continuous.processed.count, paused.processed.count)
      var maximumError: Float = 0
      for index in 0..<min(continuous.processed.count, paused.processed.count) {
        let original = index < continuous.original.count ? continuous.original[index] : 0
        let tailIndex = index - tailFrames
        let tail =
          tailIndex >= 0 && tailIndex < continuous.original.count
          ? 0.25 * continuous.original[tailIndex] : 0
        let expected = original + tail
        maximumError = max(
          maximumError, abs(continuous.processed[index] - expected),
          abs(paused.processed[index] - expected))
      }
      XCTAssertLessThan(maximumError, 0.000001, "latencyFrames=\(latencyFrames)")
      XCTAssertGreaterThan(abs(try XCTUnwrap(paused.processed.last)), 0.01)
    }
  }

  func testBoundedPCMBridgePreservesChannelsAndRejectsOverflowAndRenderUnderflow() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
    let bridge = try XCTUnwrap(ep_pcm_create(2, 8))
    defer { ep_pcm_destroy(bridge) }
    input.frameLength = 8
    output.frameLength = 8
    for i in 0..<8 {
      input.floatChannelData![0][i] = Float(i)
      input.floatChannelData![1][i] = -Float(i)
    }
    XCTAssertTrue(ep_pcm_push(bridge, input.audioBufferList, 8))
    XCTAssertEqual(ep_pcm_render_strict(bridge, output.mutableAudioBufferList, 4), 0)
    for i in 0..<4 {
      XCTAssertEqual(output.floatChannelData![0][i], Float(i))
      XCTAssertEqual(output.floatChannelData![1][i], -Float(i))
    }
    output.frameLength = 8
    XCTAssertEqual(ep_pcm_render_strict(bridge, output.mutableAudioBufferList, 8), -71006)
    XCTAssertEqual(ep_pcm_available(bridge), 4)
    ep_pcm_clear(bridge)
    XCTAssertTrue(ep_pcm_push(bridge, input.audioBufferList, 8))
    XCTAssertFalse(ep_pcm_push(bridge, input.audioBufferList, 1))
    XCTAssertEqual(ep_pcm_error(bridge), -71001)
    ep_pcm_clear(bridge)
    output.frameLength = 8
    XCTAssertEqual(ep_pcm_render(bridge, output.mutableAudioBufferList, 8), 0)
    for i in 0..<8 { XCTAssertEqual(output.floatChannelData![0][i], 0) }
    XCTAssertEqual(ep_pcm_error(bridge), 0)
  }

  func testNativeRateConversionManualEffectsAndPauseResumePreserveOriginal() async throws {
    for rate in [16000.0, 48000.0, 192000.0] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SeparatedCapture-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      var code: Int32 = 0
      let pointer = try XCTUnwrap(
        directory.appendingPathComponent("source.caf").path.withCString { source in
          directory.appendingPathComponent("processed.caf").path.withCString { processed in
            ep_capture_create(source, processed, 48000, 1, &code)
          }
        })
      let feed = try XCTUnwrap(ep_pcm_create(1, 16384))
      let monitor = try XCTUnwrap(ep_pcm_create(1, 32768))
      defer {
        ep_pcm_destroy(feed)
        ep_pcm_destroy(monitor)
      }
      let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
      let engine = AVAudioEngine()
      try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 4096)
      let source = Self.source(format: format, handle: TestPCMHandle(feed))
      engine.attach(source)
      let equalizer = AVAudioUnitEQ(numberOfBands: 1)
      equalizer.bands[0].bypass = true
      equalizer.globalGain = -6.0206
      engine.attach(equalizer)
      engine.connect(source, to: equalizer, format: format)
      engine.connect(equalizer, to: engine.mainMixerNode, format: format)
      let pipeline = try CaptureInputPipeline(
        input: BufferedCaptureInput(sampleRate: rate), writer: CaptureWriterHandle(pointer),
        engine: engine, feed: feed, monitorFeed: monitor, format: format, processing: true)
      ep_capture_segment(pointer, 0, 0)
      ep_capture_enable_source(pointer, true)
      ep_capture_enable_processed(pointer, true)
      try await pipeline.start()
      try await Task.sleep(for: .milliseconds(40))
      await pipeline.pause(latency: 0, tail: 0)
      let first = ep_capture_status(pointer).sourceQueuedFrames
      XCTAssertEqual(first, Int64(8192 * 48000 / rate))
      let frozen = ep_capture_status(pointer).sourceQueuedFrames
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertEqual(ep_capture_status(pointer).sourceQueuedFrames, frozen)
      ep_capture_segment(pointer, Int64.min, 0)
      ep_capture_enable_source(pointer, true)
      ep_capture_enable_processed(pointer, true)
      try await pipeline.start()
      try await Task.sleep(for: .milliseconds(40))
      await pipeline.pause(latency: 0, tail: 0)
      await pipeline.close()
      let state = await pipeline.snapshot()
      XCTAssertEqual(state.inputError, 0)
      XCTAssertEqual(state.processingError, 0)
      XCTAssertEqual(state.cleanupError, 0)
      engine.detach(source)
      engine.detach(equalizer)
      let result = ep_capture_finalize(pointer)
      XCTAssertEqual(result.sourceError, 0)
      XCTAssertEqual(result.processedError, 0)
      XCTAssertEqual(result.sourceFrames, first * 2)
      XCTAssertEqual(result.processedFrames, result.sourceFrames)
      let original = try AVAudioFile(forReading: directory.appendingPathComponent("source.caf"))
      let processed = try AVAudioFile(forReading: directory.appendingPathComponent("processed.caf"))
      let originalBuffer = try XCTUnwrap(
        AVAudioPCMBuffer(
          pcmFormat: original.processingFormat, frameCapacity: UInt32(original.length)))
      let processedBuffer = try XCTUnwrap(
        AVAudioPCMBuffer(
          pcmFormat: processed.processingFormat, frameCapacity: UInt32(processed.length)))
      try original.read(into: originalBuffer)
      try processed.read(into: processedBuffer)
      XCTAssertEqual(originalBuffer.frameLength, processedBuffer.frameLength)
      var maximumError: Float = 0
      for i in 0..<Int(originalBuffer.frameLength) {
        maximumError = max(
          maximumError,
          abs(
            processedBuffer.floatChannelData![0][i] - originalBuffer.floatChannelData![0][i] * 0.5))
      }
      XCTAssertLessThan(maximumError, 0.00001)
    }
  }

  func testReadinessRechecksFreshClockAfterDelayedMainActorWakeup() async throws {
    let began = ContinuousClock.now
    let host = mach_absolute_time()
    let ready = EPCaptureClock(
      sequence: 12, sampleTime: 52800, previousSampleTime: 48000,
      hostTime: host + 100000, previousHostTime: host, clockRate: 48000,
      formatRate: 48000, frames: 4800, valid: true)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(30))
      usleep(180000)
    }
    let boundary = try await CaptureClockReadiness.wait(
      sourceBaseline: 0, processedBaseline: 0, sampleRate: 48000, earliestHostTime: host,
      isRunning: { true },
      source: { ContinuousClock.now - began > .milliseconds(80) ? ready : EPCaptureClock() },
      processed: nil, timeout: .milliseconds(120))
    XCTAssertEqual(boundary, 61696)
  }
}
