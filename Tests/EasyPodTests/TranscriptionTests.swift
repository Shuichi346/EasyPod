import AVFoundation
import Foundation
import Synchronization
import XCTest

@testable import EasyPod

@MainActor final class TranscriptionTests: XCTestCase {
  func testLanguagePreferencePersistsAndPreservesJapaneseDefault() throws {
    let suite = "EasyPodLanguageTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(PreferencesStore(defaults: defaults).transcriptionLanguage, .japanese)
    for language in TranscriptionLanguage.allCases {
      let preferences = PreferencesStore(defaults: defaults)
      preferences.transcriptionLanguage = language
      XCTAssertEqual(PreferencesStore(defaults: defaults).transcriptionLanguage, language)
    }
    defaults.set("unsupported", forKey: "transcriptionLanguage")
    XCTAssertEqual(PreferencesStore(defaults: defaults).transcriptionLanguage, .japanese)
  }

  func testSelectedLanguagesSurviveStreamingPauseAndResume() async throws {
    let cases: [(TranscriptionLanguage, String, String)] = [
      (.japanese, "japanese-speech", "日本語"), (.auto, "japanese-speech", "日本語"),
      (.english, "english-speech", "english"), (.auto, "english-speech", "english"),
    ]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodLanguageStreaming-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (language, name, expected) in cases {
      let fixture = try XCTUnwrap(
        Bundle(for: TranscriptionTests.self).url(forResource: name, withExtension: "aiff"))
      let input = try AVAudioFile(forReading: fixture)
      let source = directory.appendingPathComponent("\(name)-\(language.rawValue).caf")
      do {
        let output = try AVAudioFile(forWriting: source, settings: input.processingFormat.settings)
        let buffer = try XCTUnwrap(
          AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: UInt32(input.length)))
        try input.read(into: buffer)
        try output.write(from: buffer)
        try output.write(from: buffer)
      }
      let original = try Data(contentsOf: source)
      let service = TranscriptionService()
      service.start(
        modelPath: UserPath.defaultModel, source: source,
        sampleRate: input.processingFormat.sampleRate, language: language)
      await service.pause(frames: input.length)
      XCTAssertEqual(service.status, "一時停止", "\(name)/\(language): \(service.status)")
      let paused = service.segments
      XCTAssertTrue(paused.map(\.text).joined().lowercased().contains(expected), "\(paused)")
      await service.finish(frames: input.length * 2)
      XCTAssertEqual(service.status, "文字起こし完了 · ローカル")
      XCTAssertEqual(Array(service.segments.prefix(paused.count)), paused)
      let resumed = Array(service.segments.dropFirst(paused.count))
      XCTAssertTrue(resumed.map(\.text).joined().lowercased().contains(expected), "\(resumed)")
      XCTAssertTrue(
        resumed.allSatisfy {
          $0.isFinal && $0.start >= Double(input.length) / input.processingFormat.sampleRate
        })
      XCTAssertEqual(try Data(contentsOf: source), original)
    }
  }

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

  func testDelayedBacklogReportsCatchUpAndFinalizationWaitsBeforeReload() async throws {
    let deadline = ContinuousClock.now + .seconds(110)
    let fixture = try XCTUnwrap(
      Bundle(for: TranscriptionTests.self).url(
        forResource: "japanese-speech", withExtension: "aiff"))
    let input = try AVAudioFile(forReading: fixture)
    let rate = input.processingFormat.sampleRate
    let duration = Double(input.length) / rate
    guard duration > 0 else { throw EasyPodError.message("The speech fixture is empty") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodASRBacklog-\(UUID())")
    let files = try SessionFileService(root: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var session = RecordingSession(title: "ASR backlog", status: .finalizing)
    session.settings.sampleRate = rate
    session.settings.channels = Int(input.processingFormat.channelCount)
    try files.save(session)
    let source = files.directory(session.id).appendingPathComponent("source.caf")
    do {
      let output = try AVAudioFile(forWriting: source, settings: input.processingFormat.settings)
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192))
      // More than eight seconds gives recognition results room to arrive while lag exceeds three.
      for _ in 0..<max(2, Int(ceil(8 / duration))) {
        input.framePosition = 0
        while input.framePosition < input.length {
          try input.read(into: buffer)
          try output.write(from: buffer)
        }
      }
    }
    let frames = try AVAudioFile(forReading: source).length
    session.frameCount = frames
    try files.save(session)
    let original = try Data(contentsOf: source)
    let gate = ASRBacklogTestGate()
    defer { gate.release.signal() }
    let service = TranscriptionService()
    var sawCatchUp = false
    var sawTextDuringCatchUp = false
    var sawNormalAfterCatchUp = false
    var previousSegments: [TranscriptSegment] = []
    service.onChange = { segments, status in
      if status.contains("秒の遅れ") {
        sawCatchUp = true
        if !segments.isEmpty && segments != previousSegments { sawTextDuringCatchUp = true }
      } else if sawCatchUp && status == "Nemotron 3.5 · ローカル" {
        sawNormalAfterCatchUp = true
      }
      previousSegments = segments
    }
    service.start(
      modelPath: UserPath.defaultModel, source: source, sampleRate: rate,
      beforePush: { gate.waitOnce() })
    service.updateAvailable(frames: frames)
    while (!gate.state.withLock({ $0.entered }) || !sawCatchUp)
      && ContinuousClock.now < deadline && !service.status.hasPrefix("文字起こし:")
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(gate.state.withLock { $0.entered }, service.status)
    XCTAssertTrue(sawCatchUp, "Saved audio backlog must be reported before the blocked push")
    XCTAssertTrue(service.status.contains("秒の遅れ"), service.status)
    XCTAssertEqual(try Data(contentsOf: source), original)
    var finished = false
    let finishing = Task {
      await service.finish(frames: frames)
      finished = true
    }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(finished, "Finalization must wait for the serial ASR backlog")
    XCTAssertFalse(service.status.hasPrefix("文字起こし完了"))
    gate.release.signal()
    while !finished && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard finished else {
      finishing.cancel()
      XCTFail("Backlog finalization exceeded its 110-second deadline")
      return
    }
    await finishing.value
    XCTAssertFalse(gate.state.withLock { $0.timedOut }, "The test must release the bounded gate")
    XCTAssertTrue(sawTextDuringCatchUp, "Recognition results must retain the live catch-up status")
    XCTAssertTrue(sawNormalAfterCatchUp, "Status must return to normal once the backlog clears")
    XCTAssertEqual(service.status, "文字起こし完了 · ローカル")
    XCTAssertFalse(service.segments.isEmpty, service.status)
    XCTAssertTrue(service.segments.allSatisfy(\.isFinal))
    session.transcript = service.segments
    session.transcriptionStatus = service.status
    session.status = .completed
    try files.save(session)
    let reloaded = try XCTUnwrap(files.load().first)
    XCTAssertEqual(reloaded.status, .completed)
    XCTAssertEqual(reloaded.frameCount, frames)
    XCTAssertEqual(reloaded.transcript, service.segments)
    XCTAssertEqual(reloaded.transcriptionStatus, "文字起こし完了 · ローカル")
    XCTAssertEqual(try Data(contentsOf: source), original)
  }
}

private final class ASRBacklogTestGate: Sendable {
  struct State {
    var entered = false
    var timedOut = false
  }

  let state = Mutex(State())
  let release = DispatchSemaphore(value: 0)

  func waitOnce() {
    let shouldWait = state.withLock {
      guard !$0.entered else { return false }
      $0.entered = true
      return true
    }
    guard shouldWait else { return }
    let result = release.wait(timeout: .now() + 8)
    state.withLock { $0.timedOut = result == .timedOut }
  }
}
