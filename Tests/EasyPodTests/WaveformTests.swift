import AVFoundation
import Foundation
import XCTest

@testable import EasyPod

@MainActor final class WaveformTests: XCTestCase {
  func testWaveformCacheReusesIdentityInvalidatesReplacementAndBoundsRecency() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let other = directory.appendingPathComponent("other.caf")
    try Data([1]).write(to: source, options: .atomic)
    try Data([3]).write(to: other, options: .atomic)
    let reader = WaveformTestReader(suspended: false)
    let cache = WaveformCache(capacity: 1, reader: { try await reader.read($0) })
    let first = try await cache.load(source)
    let reused = try await cache.load(source)
    XCTAssertEqual(first, [1])
    XCTAssertEqual(reused, first)
    var state = await reader.snapshot()
    XCTAssertEqual(state.calls, 1)
    // Atomic replacement changes the file identity even when byte length is unchanged.
    try Data([2]).write(to: source, options: .atomic)
    let replaced = try await cache.load(source)
    XCTAssertEqual(replaced, [2])
    state = await reader.snapshot()
    XCTAssertEqual(state.calls, 2)
    _ = try await cache.load(other)
    _ = try await cache.load(source)
    state = await reader.snapshot()
    XCTAssertEqual(state.calls, 4)
  }

  func testSharedWaveformCancellationPreservesSubscriberAndSerializesLoads() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let other = directory.appendingPathComponent("other.caf")
    try Data([1]).write(to: source)
    try Data([2]).write(to: other)
    let reader = WaveformTestReader(suspended: true)
    let cache = WaveformCache(reader: { try await reader.read($0) })
    let first = Task { try await cache.load(source) }
    try await waitForCalls(1, reader: reader)
    let shared = Task { try await cache.load(source) }
    let next = Task { try await cache.load(other) }
    defer {
      first.cancel()
      shared.cancel()
      next.cancel()
    }
    try await waitForRequests(3, cache: cache)
    var state = await reader.snapshot()
    XCTAssertEqual(state.calls, 1)
    first.cancel()
    do {
      _ = try await first.value
      XCTFail("A cancelled subscriber must not receive peaks")
    } catch { XCTAssertTrue(error is CancellationError) }
    state = await reader.snapshot()
    XCTAssertEqual(state.cancelled, 0)
    await reader.release(1, peaks: [0.5])
    let sharedResult = try await shared.value
    XCTAssertEqual(sharedResult, [0.5])
    try await waitForCalls(2, reader: reader)
    next.cancel()
    do {
      _ = try await next.value
      XCTFail("The final cancelled subscriber must cancel its decoder")
    } catch { XCTAssertTrue(error is CancellationError) }
    try await waitForCancellations(1, reader: reader)
    state = await reader.snapshot()
    XCTAssertEqual(state.maximumActive, 1)
  }

  func testCancelledWaveformDecoderRetiresBeforeReplacementRequest() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    try Data([1]).write(to: source)
    let reader = WaveformTestReader(suspended: true)
    let cache = WaveformCache(reader: { try await reader.read($0) })
    let first = Task { try await cache.load(source) }
    defer { first.cancel() }
    try await waitForCalls(1, reader: reader)
    first.cancel()
    do {
      _ = try await first.value
      XCTFail("Cancellation must be forwarded to a detached decoder")
    } catch { XCTAssertTrue(error is CancellationError) }
    let replacement = Task { try await cache.load(source) }
    defer { replacement.cancel() }
    try await waitForCalls(2, reader: reader)
    await reader.release(2, peaks: [0.9])
    let peaks = try await replacement.value
    XCTAssertEqual(peaks, [0.9])
    let state = await reader.snapshot()
    XCTAssertEqual(state.cancelled, 1)
    XCTAssertEqual(state.maximumActive, 1)
  }

  func testSavedWaveformIncludesFinalShortBufferAndBothChannels() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    do {
      let file = try AVAudioFile(forWriting: source, settings: format.settings)
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4100))
      buffer.frameLength = 4100
      let channels = try XCTUnwrap(buffer.floatChannelData)
      channels[0].initialize(repeating: 0, count: 4100)
      channels[1].initialize(repeating: 0, count: 4100)
      channels[0][0] = 0.25
      channels[1][0] = -0.5
      channels[0][4099] = 0.75
      channels[1][4099] = -0.9
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    let peaks = try await WaveformService.load(source)
    XCTAssertEqual(peaks.count, 160)
    XCTAssertEqual(peaks[0], 0.5)
    XCTAssertEqual(peaks[159], 0.9)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodWaveform-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func waitForRequests(_ count: Int, cache: WaveformCache) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await cache.pendingRequestCount < count && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let requests = await cache.pendingRequestCount
    guard requests == count else {
      throw EasyPodError.message("Waveform subscribers did not arrive")
    }
  }

  private func waitForCalls(_ count: Int, reader: WaveformTestReader) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await reader.snapshot().calls < count && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let state = await reader.snapshot()
    guard state.calls == count else { throw EasyPodError.message("Waveform decoder did not start") }
  }

  private func waitForCancellations(_ count: Int, reader: WaveformTestReader) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await reader.snapshot().cancelled < count && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let state = await reader.snapshot()
    guard state.cancelled == count else {
      throw EasyPodError.message("Waveform decoder did not observe cancellation")
    }
  }

  func testLiveBarsKeepFixedPitchAndMoveLeftAsHistoryGrows() {
    let width: CGFloat = 400
    let first = LiveWaveformLayout.xPosition(index: 0, count: 3, width: width, phase: 0)
    let nextFirst = LiveWaveformLayout.xPosition(index: 0, count: 4, width: width, phase: 0)
    XCTAssertEqual(nextFirst, first - LiveWaveformLayout.pitch)
    XCTAssertEqual(LiveWaveformLayout.barWidth, 2)
    XCTAssertEqual(
      LiveWaveformLayout.xPosition(index: 2, count: 3, width: width, phase: 0),
      width - LiveWaveformLayout.barWidth)
    XCTAssertEqual(
      LiveWaveformLayout.xPosition(index: 159, count: 160, width: width, phase: 0),
      width - LiveWaveformLayout.barWidth)
    let adjacent = LiveWaveformLayout.xPosition(index: 1, count: 3, width: width, phase: 0)
    XCTAssertEqual(adjacent - first, LiveWaveformLayout.pitch)
    let halfway = LiveWaveformLayout.xPosition(index: 0, count: 3, width: width, phase: 0.5)
    XCTAssertEqual(halfway, first - LiveWaveformLayout.pitch / 2)
    // A retained sample lands at the same position on either side of a full-window update.
    XCTAssertEqual(
      LiveWaveformLayout.xPosition(index: 10, count: 160, width: width, phase: 1),
      LiveWaveformLayout.xPosition(index: 9, count: 160, width: width, phase: 0))
  }

  func testRecentWindowIsBoundedAndKeepsNewestSamples() {
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 1000, width: 1000), 160)
    XCTAssertEqual(
      Double(LiveWaveformLayout.maximumBars) * LiveWaveformLayout.sampleInterval, 16,
      accuracy: 0.00001)
    let visible = LiveWaveformLayout.visibleCount(peakCount: 1000, width: 40)
    XCTAssertEqual(visible, 11)
    let recent = Array((0..<1000).suffix(visible))
    XCTAssertEqual(recent.first, 989)
    XCTAssertEqual(recent.last, 999)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 3, width: 40), 3)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 0, width: 40), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: 0), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: -1), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: .infinity), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: .nan), 0)
  }

  func testScrollPhaseFreezesDuringPauseAndContinuesOnResume() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var motion = LiveWaveformMotion(at: start)
    motion.setActive(true, at: start)
    XCTAssertEqual(motion.phase(at: start.addingTimeInterval(0.025)), 0.25, accuracy: 0.00001)
    motion.setActive(false, at: start.addingTimeInterval(0.025))
    XCTAssertEqual(motion.phase(at: start.addingTimeInterval(100)), 0.25, accuracy: 0.00001)
    motion.receivedSample(at: start.addingTimeInterval(100))
    XCTAssertEqual(motion.phase(at: start.addingTimeInterval(200)), 0.25, accuracy: 0.00001)
    let resume = start.addingTimeInterval(300)
    motion.setActive(true, at: resume)
    XCTAssertEqual(motion.phase(at: resume), 0.25, accuracy: 0.00001)
    XCTAssertEqual(motion.phase(at: resume.addingTimeInterval(0.025)), 0.5, accuracy: 0.00001)
    XCTAssertEqual(motion.phase(at: resume.addingTimeInterval(0.1)), 1)
    motion.receivedSample(at: resume.addingTimeInterval(0.1))
    XCTAssertEqual(motion.phase(at: resume.addingTimeInterval(0.1)), 0)
    XCTAssertEqual(LiveWaveformLayout.phase(elapsed: -1), 0)
    XCTAssertEqual(LiveWaveformLayout.phase(elapsed: .infinity), 1)
    XCTAssertEqual(LiveWaveformLayout.phase(elapsed: .nan), 0)
  }
}

private actor WaveformTestReader {
  struct State: Sendable {
    var calls = 0
    var active = 0
    var maximumActive = 0
    var cancelled = 0
  }

  private let suspended: Bool
  private var state = State()
  private var continuations: [Int: CheckedContinuation<[Float], Error>] = [:]

  init(suspended: Bool) { self.suspended = suspended }

  func snapshot() -> State { state }

  func read(_ source: URL) async throws -> [Float] {
    state.calls += 1
    state.active += 1
    state.maximumActive = max(state.maximumActive, state.active)
    let call = state.calls
    defer { state.active -= 1 }
    guard suspended else { return [Float(try Data(contentsOf: source).first ?? 0)] }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuations[call] = $0 }
    } onCancel: {
      Task { await self.cancel(call) }
    }
  }

  func release(_ call: Int, peaks: [Float]) {
    continuations.removeValue(forKey: call)?.resume(returning: peaks)
  }

  private func cancel(_ call: Int) {
    guard let continuation = continuations.removeValue(forKey: call) else { return }
    state.cancelled += 1
    continuation.resume(throwing: CancellationError())
  }
}
