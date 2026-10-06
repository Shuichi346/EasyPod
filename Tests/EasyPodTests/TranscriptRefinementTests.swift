import AVFoundation
import Foundation
import Synchronization
import XCTest

@testable import EasyPod

@MainActor final class TranscriptRefinementTests: XCTestCase {
  func testSelectedLanguagesInNativeOfflineRecognition() async throws {
    let cases: [(TranscriptionLanguage, String, String)] = [
      (.japanese, "japanese-speech", "日本語"), (.auto, "japanese-speech", "日本語"),
      (.english, "english-speech", "english"), (.auto, "english-speech", "english"),
    ]
    for (language, name, expected) in cases {
      let source = try XCTUnwrap(
        Bundle(for: TranscriptRefinementTests.self).url(forResource: name, withExtension: "aiff"))
      let original = try Data(contentsOf: source)
      let segments = try await TranscriptRefinementService().recognize(
        source: source, modelPath: UserPath.defaultModel, language: language)
      XCTAssertTrue(
        segments.map(\.text).joined().lowercased().contains(expected),
        "\(name)/\(language): \(segments)")
      XCTAssertTrue(segments.allSatisfy { $0.isFinal && $0.end >= $0.start })
      XCTAssertEqual(try Data(contentsOf: source), original)
    }
  }

  func testJapaneseOfflineRecognitionPreservesSource() async throws {
    let fixture = try XCTUnwrap(
      Bundle(for: TranscriptRefinementTests.self).url(
        forResource: "japanese-speech", withExtension: "aiff"))
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    do {
      let input = try AVAudioFile(forReading: fixture)
      let output = try AVAudioFile(forWriting: source, settings: input.processingFormat.settings)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192))
      while input.framePosition < input.length {
        try input.read(into: buffer)
        try output.write(from: buffer)
      }
    }
    let original = try Data(contentsOf: source)
    let progress = RefinementTestProgress()
    let result = try await TranscriptRefinementService().recognize(
      source: source, modelPath: UserPath.defaultModel,
      onProgress: { fraction in progress.values.withLock { $0.append(fraction) } })
    let text = result.map(\.text).joined()
    XCTAssertTrue(text.contains("こんにちは") || text.contains("録音") || text.contains("日本語"), text)
    XCTAssertTrue(result.allSatisfy { $0.isFinal && $0.end >= $0.start && $0.start >= 0 })
    let input = try AVAudioFile(forReading: source)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(result.last).end, Double(input.length) / input.processingFormat.sampleRate)
    XCTAssertEqual(progress.values.withLock { $0.first }, 0)
    XCTAssertEqual(progress.values.withLock { $0.last }, 1)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testMissingModelLeavesOriginalFilesAndTranscriptUntouched() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeAudio(in: directory, seconds: 1)
    let original = try Data(contentsOf: source)
    let live = [TranscriptSegment(start: 0, end: 1, text: "元の文字起こし", isFinal: true)]
    var retained = live
    do {
      retained = try await TranscriptRefinementService().recognize(
        source: source, modelPath: directory.appendingPathComponent("missing.gguf").path)
      XCTFail("Missing model must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("モデルが見つかりません"))
    }
    XCTAssertEqual(retained, live)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testCancellationDiscardsInFlightResultAndClosesBackend() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeAudio(in: directory, seconds: 1)
    let original = try Data(contentsOf: source)
    let backend = RefinementTestBackend(blockRecognition: true)
    let service = TranscriptRefinementService(backendFactory: { backend })
    let model = try makeModelPlaceholder(in: directory)
    let live = [TranscriptSegment(start: 0, end: 1, text: "元の文字起こし", isFinal: true)]
    var retained = live
    let task = Task { try await service.recognize(source: source, modelPath: model.path) }
    for _ in 0..<150 {
      if backend.state.withLock({ $0.enteredRecognition }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(backend.state.withLock { $0.enteredRecognition })
    task.cancel()
    backend.release.signal()
    do {
      retained = try await task.value
      XCTFail("Cancelled results must never be returned")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(retained, live)
    XCTAssertTrue(backend.state.withLock { $0.closed })
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testFailureAfterFirstChunkDiscardsPartialResults() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeAudio(in: directory, seconds: 31)
    let original = try Data(contentsOf: source)
    let backend = RefinementTestBackend(failAtCall: 2)
    let model = try makeModelPlaceholder(in: directory)
    let live = [TranscriptSegment(start: 0, end: 31, text: "元の文字起こし", isFinal: true)]
    var retained = live
    do {
      retained = try await TranscriptRefinementService(backendFactory: { backend }).recognize(
        source: source, modelPath: model.path)
      XCTFail("Partial success must not replace the transcript")
    } catch { XCTAssertTrue(error.localizedDescription.contains("injected native failure")) }
    XCTAssertEqual(retained, live)
    XCTAssertEqual(backend.state.withLock { $0.calls }, 2)
    XCTAssertTrue(backend.state.withLock { $0.closed })
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testLongAudioUsesBoundedRequestsWithContinuousTimestamps() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeAudio(in: directory, seconds: 61)
    let backend = RefinementTestBackend()
    let model = try makeModelPlaceholder(in: directory)
    let progress = RefinementTestProgress()
    let result = try await TranscriptRefinementService(backendFactory: { backend }).recognize(
      source: source, modelPath: model.path,
      onProgress: { fraction in progress.values.withLock { $0.append(fraction) } })
    XCTAssertEqual(backend.state.withLock { $0.sampleCounts }, [240_000, 240_000, 8_000])
    XCTAssertEqual(result.map(\.start), [0, 30, 60])
    XCTAssertEqual(result.map(\.end), [30, 60, 61])
    XCTAssertTrue(backend.state.withLock { $0.validMono })
    let fractions = progress.values.withLock { $0 }
    XCTAssertEqual(fractions, fractions.sorted())
    XCTAssertEqual(fractions.last, 1)
  }

  func testQuietBoundaryKeepsContinuousSpeechAtHardLimit() {
    var samples = [Float](repeating: 0.1, count: 240_000)
    XCTAssertEqual(
      TranscriptRefinementChunking.boundary(samples: samples, sampleRate: 8_000), 240_000)
    samples.replaceSubrange(232_000..<234_000, with: repeatElement(Float(0), count: 2_000))
    XCTAssertEqual(
      TranscriptRefinementChunking.boundary(samples: samples, sampleRate: 8_000), 233_000)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodRefinementTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeModelPlaceholder(in directory: URL) throws -> URL {
    let model = directory.appendingPathComponent("test.gguf")
    try Data("injected backend".utf8).write(to: model)
    return model
  }

  private func makeAudio(in directory: URL, seconds: Int) throws -> URL {
    let source = directory.appendingPathComponent("source.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
    let output = try AVAudioFile(forWriting: source, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
    buffer.frameLength = 8_000
    let channels = try XCTUnwrap(buffer.floatChannelData)
    channels[0].initialize(repeating: 0.05, count: 8_000)
    channels[1].initialize(repeating: 0.15, count: 8_000)
    for _ in 0..<seconds { try output.write(from: buffer) }
    return source
  }
}

private final class RefinementTestProgress: Sendable {
  let values = Mutex<[Double]>([])
}

private final class RefinementTestBackend: TranscriptRefinementBackend, @unchecked Sendable {
  struct State {
    var calls = 0
    var sampleCounts: [Int] = []
    var validMono = true
    var enteredRecognition = false
    var closed = false
  }

  let state = Mutex(State())
  let release = DispatchSemaphore(value: 0)
  private let blockRecognition: Bool
  private let failAtCall: Int?

  init(blockRecognition: Bool = false, failAtCall: Int? = nil) {
    self.blockRecognition = blockRecognition
    self.failAtCall = failAtCall
  }

  func open(model: URL, language: TranscriptionLanguage) throws {}

  func recognize(samples: [Float], sampleRate: Int32) throws -> TranscriptRefinementHypothesis {
    let call = state.withLock {
      $0.calls += 1
      $0.sampleCounts.append(samples.count)
      $0.enteredRecognition = true
      $0.validMono = $0.validMono && samples.allSatisfy { abs($0 - 0.1) < 0.0001 }
      return $0.calls
    }
    if blockRecognition { _ = release.wait(timeout: .now() + 5) }
    if call == failAtCall { throw EasyPodError.message("injected native failure") }
    return TranscriptRefinementHypothesis(
      text: "再認識 \(call)", start: 0, end: Double(samples.count) / Double(sampleRate))
  }

  func close() { state.withLock { $0.closed = true } }
}
