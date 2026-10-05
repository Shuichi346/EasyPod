import AVFoundation
import XCTest

@testable import EasyPod

@MainActor final class PlaybackTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodPlaybackTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func fixture(at url: URL, seconds: Double = 2) throws -> AVAudioFormat {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let count = Int(seconds * format.sampleRate)
    var cursor = 0
    while cursor < count {
      buffer.frameLength = UInt32(min(4096, count - cursor))
      for frame in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][frame] = cursor + frame < count / 2 ? 0.2 : 0.4
      }
      try output.write(from: buffer)
      cursor += Int(buffer.frameLength)
    }
    return format
  }

  private func gainChain(format: AVAudioFormat) -> EffectChain {
    let equalizer = AVAudioUnitEQ(numberOfBands: 1)
    equalizer.bands[0].bypass = true
    equalizer.globalGain = -6.0206
    let slot = EffectSlot(
      plugin: PluginDescriptor(
        id: "test-apple-eq", name: "Apple EQ", manufacturer: "Apple", format: .au))
    return EffectChain(
      entries: [.init(slot: slot, unit: equalizer, format: format)], format: format)
  }

  private func render(
    _ playback: PlaybackService, frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    for _ in 0..<8 {
      let status = try playback.renderPreview(frames: frames, into: buffer)
      if status == .success {
        XCTAssertEqual(buffer.frameLength, frames, file: file, line: line)
        return
      }
      guard status == .cannotDoInCurrentContext || status == .insufficientDataFromInputNode else {
        XCTFail("Offline playback failed with status \(status)", file: file, line: line)
        return
      }
      Thread.sleep(forTimeInterval: 0.002)
    }
    XCTFail(
      "Offline playback did not produce PCM within its bounded retries", file: file, line: line)
  }

  func testNativeOutputMeterAndRetiredCompletion() throws {
    let handoff = try XCTUnwrap(ep_playback_create())
    defer { ep_playback_destroy(handoff) }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    buffer.frameLength = 1024
    for frame in 0..<1024 {
      buffer.floatChannelData![0][frame] = 0.3
      buffer.floatChannelData![1][frame] = 0.4
    }
    ep_playback_arm(handoff, 1)
    ep_playback_meter(handoff, buffer.audioBufferList, buffer.frameLength)
    XCTAssertEqual(ep_playback_status(handoff, 1).level, sqrt(0.125), accuracy: 0.00001)
    ep_playback_complete(handoff, 1)
    XCTAssertTrue(ep_playback_status(handoff, 1).completed)
    ep_playback_arm(handoff, 2)
    XCTAssertEqual(ep_playback_status(handoff, 2).level, 0)
    ep_playback_complete(handoff, 1)
    XCTAssertFalse(ep_playback_status(handoff, 2).completed)
    ep_playback_complete(handoff, 2)
    ep_playback_complete(handoff, 1)
    XCTAssertTrue(ep_playback_status(handoff, 2).completed)
    buffer.frameLength = 0
    ep_playback_meter(handoff, buffer.audioBufferList, 0)
    XCTAssertEqual(ep_playback_status(handoff, 2).level, 0)
  }

  func testStartTimeSampleProgressPauseSeekAndFifteenSecondSkip() throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let format = try fixture(at: source, seconds: 40)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    let playback = PlaybackService(manualRendering: true)
    defer { playback.stop() }
    var completions = 0
    try playback.play(url: source, effects: nil, startTime: 20) { completions += 1 }
    XCTAssertEqual(playback.duration, 40)
    XCTAssertEqual(playback.currentTime, 20)
    try render(playback, frames: 1024, into: buffer)
    XCTAssertEqual(playback.currentTime, 20 + 1024.0 / 48_000, accuracy: 1.0 / 48_000)
    XCTAssertEqual(buffer.floatChannelData![0][1023], 0.4, accuracy: 0.001)
    XCTAssertEqual(playback.level, 0.4, accuracy: 0.001)
    let position = playback.currentTime
    try playback.skip(seconds: 15)
    XCTAssertEqual(playback.currentTime, position + 15, accuracy: 1.0 / 48_000)
    try playback.skip(seconds: -15)
    XCTAssertEqual(playback.currentTime, position, accuracy: 2.0 / 48_000)
    playback.pause()
    XCTAssertFalse(playback.isPlaying)
    XCTAssertTrue(playback.isPaused)
    XCTAssertEqual(playback.level, 0)
    XCTAssertThrowsError(try playback.renderPreview(frames: 1024, into: buffer))
    try playback.seek(to: 1)
    XCTAssertEqual(playback.currentTime, 1)
    XCTAssertTrue(playback.isPaused)
    try playback.skip(seconds: -15)
    XCTAssertEqual(playback.currentTime, 0)
    try playback.seek(to: .infinity)
    XCTAssertEqual(playback.currentTime, 40)
    XCTAssertEqual(completions, 0)
    try playback.seek(to: 2)
    try playback.resume()
    try render(playback, frames: 1024, into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][1023], 0.2, accuracy: 0.001)
    XCTAssertEqual(playback.currentTime, 2 + 1024.0 / 48_000, accuracy: 1.0 / 48_000)
    try playback.seek(to: .nan)
    XCTAssertTrue(playback.isPlaying)
    try playback.skip(seconds: .infinity)
    XCTAssertFalse(playback.isPlaying)
    XCTAssertFalse(playback.isPaused)
    XCTAssertEqual(playback.currentTime, playback.duration)
    XCTAssertEqual(completions, 1)
    playback.stop()
    XCTAssertEqual(playback.currentTime, 0)
    XCTAssertEqual(playback.duration, 0)
    XCTAssertEqual(playback.level, 0)
    XCTAssertEqual(completions, 1)
  }

  func testNaturalCompletionAndStopRetireCallbacks() throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let format = try fixture(at: source, seconds: 0.1)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    let playback = PlaybackService(manualRendering: true)
    defer { playback.stop() }
    var first = 0
    var second = 0
    try playback.play(url: source, effects: nil) { first += 1 }
    try render(playback, frames: 1024, into: buffer)
    playback.stop()
    XCTAssertEqual(first, 0)
    try playback.play(url: source, effects: nil, startTime: 0.05) { second += 1 }
    try render(playback, frames: 1024, into: buffer)
    XCTAssertTrue(playback.isPlaying)
    XCTAssertEqual(playback.currentTime, 0.05 + 1024.0 / 48_000, accuracy: 1.0 / 48_000)
    try render(playback, frames: 1376, into: buffer)
    XCTAssertFalse(playback.isPlaying)
    XCTAssertEqual(playback.currentTime, 0.1, accuracy: 1.0 / 48_000)
    XCTAssertEqual(playback.duration, 0.1, accuracy: 1.0 / 48_000)
    XCTAssertEqual(playback.level, 0)
    XCTAssertEqual(first, 0)
    XCTAssertEqual(second, 1)
    playback.stop()
    XCTAssertEqual(second, 1)
  }

  func testEffectPreviewMeterAndExportPreserveOriginal() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let format = try fixture(at: source)
    let original = try Data(contentsOf: source)
    let playback = PlaybackService(manualRendering: true)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    let previewChain = gainChain(format: format)
    try playback.play(url: source, effects: previewChain) {}
    defer { playback.stop() }
    try render(playback, frames: 4096, into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][4095], 0.1, accuracy: 0.002)
    XCTAssertEqual(playback.level, 0.1, accuracy: 0.002)
    let effectID = try XCTUnwrap(previewChain.snapshot().first).id
    previewChain.setBypass(id: effectID, bypassed: true)
    try render(playback, frames: 4096, into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][4095], 0.2, accuracy: 0.002)
    previewChain.setBypass(id: effectID, bypassed: false)
    try render(playback, frames: 4096, into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][4095], 0.1, accuracy: 0.002)
    try playback.seek(to: 1.5)
    try render(playback, frames: 4096, into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][4095], 0.2, accuracy: 0.002)
    XCTAssertEqual(playback.level, 0.2, accuracy: 0.002)
    playback.stop()

    let exportChain = gainChain(format: format)
    var settings = RecordingSettings()
    settings.bitDepth = 32
    settings.tailLimit = 0
    let output = directory.appendingPathComponent("effect.wav")
    _ = try await AudioExportService().export(
      session: RecordingSession(title: "Effect", status: .completed, frameCount: 96_000),
      directory: directory, destination: output,
      request: ExportRequest(includeEffects: true, settings: settings), effects: exportChain,
      onProgress: { _ in })
    let exported = try AVAudioFile(forReading: output)
    XCTAssertEqual(exported.length, 96_000)
    try exported.read(into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][4095], 0.1, accuracy: 0.002)
    exported.framePosition = 72_000
    try exported.read(into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][4095], 0.2, accuracy: 0.002)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }
}
