import AVFoundation
import XCTest

@testable import EasyPod

@MainActor final class TranscriptionTests: XCTestCase {
  func testJapaneseStreamingAndFinalFlush() async throws {
    let path = Bundle(for: TranscriptionTests.self).url(
      forResource: "japanese-speech", withExtension: "aiff")
    let input = try AVAudioFile(forReading: XCTUnwrap(path))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodASRTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    do {
      let output = try AVAudioFile(forWriting: source, settings: input.processingFormat.settings)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: UInt32(input.length)))
      try input.read(into: buffer)
      try output.write(from: buffer)
      let silence = try XCTUnwrap(
        AVAudioPCMBuffer(
          pcmFormat: input.processingFormat,
          frameCapacity: UInt32(input.processingFormat.sampleRate * 2)))
      silence.frameLength = silence.frameCapacity
      if let channels = silence.floatChannelData {
        for channel in 0..<Int(silence.format.channelCount) {
          channels[channel].initialize(repeating: 0, count: Int(silence.frameLength))
        }
      }
      try output.write(from: silence)
      try output.write(from: buffer)
    }
    let sourceFrames = try AVAudioFile(forReading: source).length
    let service = TranscriptionService()
    service.start(
      modelPath: UserPath.defaultModel, source: source,
      sampleRate: input.processingFormat.sampleRate)
    service.updateAvailable(frames: sourceFrames)
    let deadline = ContinuousClock.now + .seconds(120)
    while !service.segments.contains(where: \.isFinal) && ContinuousClock.now < deadline
      && !service.status.hasPrefix("文字起こし:")
    {
      try await Task.sleep(for: .milliseconds(200))
    }
    let finalizedWhileRecording = service.segments.contains(where: \.isFinal)
    await service.finish(frames: sourceFrames)
    let text = service.segments.map(\.text).joined()
    XCTAssertFalse(text.isEmpty, service.status)
    XCTAssertTrue(service.segments.contains(where: \.isFinal), "Final utterance must survive stop")
    XCTAssertTrue(finalizedWhileRecording, "Silence must finalize speech before stop")
    XCTAssertGreaterThanOrEqual(service.segments.count, 2)
    XCTAssertGreaterThan(service.segments.last?.start ?? 0, 0)
    XCTAssertGreaterThan(
      service.segments.last?.end ?? 0,
      Double(input.length) / input.processingFormat.sampleRate)
    XCTAssertTrue(text.contains("こんにちは") || text.contains("録音") || text.contains("日本語"), text)
  }

  func testInvalidModelDoesNotChangeOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodASRFailure-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let original = Data("preserved audio".utf8)
    try original.write(to: source)
    let service = TranscriptionService()
    service.start(
      modelPath: directory.appendingPathComponent("missing.gguf").path, source: source,
      sampleRate: 48_000)
    for _ in 0..<20 {
      if service.status.hasPrefix("文字起こし:") { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    await service.finish(frames: 0)
    XCTAssertTrue(service.status.contains("モデルが見つかりません"), service.status)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }
}
