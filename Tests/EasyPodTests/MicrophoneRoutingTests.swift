import AVFoundation
import CoreAudio
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
