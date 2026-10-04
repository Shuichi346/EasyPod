import AVFoundation
import XCTest

@testable import EasyPod

@MainActor final class PipelineTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func fixture(at url: URL, seconds: Double = 2, amplitude: Float = 0.2) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    var cursor = 0
    let count = Int(seconds * 48_000)
    while cursor < count {
      buffer.frameLength = UInt32(min(4096, count - cursor))
      for i in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][i] = amplitude * sin(Float(cursor + i) * 2 * .pi * 440 / 48_000)
      }
      try output.write(from: buffer)
      cursor += Int(buffer.frameLength)
    }
  }

  func testPauseSampleClockAndOriginalPreservation() throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf")
    let processed = directory.appendingPathComponent("processed.caf")
    var code: Int32 = 0
    let writer = try XCTUnwrap(
      source.path.withCString { original in
        processed.path.withCString { ep_capture_create(original, $0, 48_000, 1, &code) }
      })
    ep_capture_enable_source(writer, true)
    ep_capture_enable_processed(writer, true)
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    buffer.frameLength = 4096
    for i in 0..<4096 { buffer.floatChannelData![0][i] = 0.2 }
    ep_capture_push_source(writer, buffer.audioBufferList, buffer.frameLength)
    for i in 0..<4096 { buffer.floatChannelData![0][i] = 0.1 }
    ep_capture_push_processed(writer, buffer.audioBufferList, buffer.frameLength)
    XCTAssertEqual(ep_capture_flush(writer), 0)
    ep_capture_enable_source(writer, false)
    ep_capture_enable_processed(writer, false)
    ep_capture_push_source(writer, buffer.audioBufferList, buffer.frameLength)
    ep_capture_enable_source(writer, true)
    ep_capture_enable_processed(writer, true)
    for i in 0..<4096 { buffer.floatChannelData![0][i] = 0.4 }
    ep_capture_push_source(writer, buffer.audioBufferList, buffer.frameLength)
    for i in 0..<4096 { buffer.floatChannelData![0][i] = 0.2 }
    ep_capture_push_processed(writer, buffer.audioBufferList, buffer.frameLength)
    XCTAssertEqual(ep_capture_flush(writer), 0)
    XCTAssertEqual(ep_capture_status(writer).sourceFrames, 8192)
    XCTAssertEqual(ep_capture_status(writer).processedFrames, 8192)
    let finalized = ep_capture_finalize(writer)
    XCTAssertEqual(finalized.sourceError, 0)
    XCTAssertEqual(finalized.processedError, 0)
    XCTAssertEqual(finalized.sourceFrames, 8192)
    XCTAssertEqual(finalized.processedFrames, 8192)
    let file = try AVAudioFile(forReading: source)
    XCTAssertEqual(file.length, 8192)
    try file.read(into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][0], 0.2, accuracy: 0.0001)
    try file.read(into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][0], 0.4, accuracy: 0.0001)
    let wet = try AVAudioFile(forReading: processed)
    try wet.read(into: buffer)
    XCTAssertEqual(buffer.floatChannelData![0][0], 0.1, accuracy: 0.0001)

    let clockSource = directory.appendingPathComponent("clock-source.caf")
    let clockProcessed = directory.appendingPathComponent("clock-processed.caf")
    let timedWriter = try XCTUnwrap(
      clockSource.path.withCString { original in
        clockProcessed.path.withCString { ep_capture_create(original, $0, 48_000, 1, &code) }
      })
    ep_capture_segment(timedWriter, 1004, 2)
    ep_capture_enable_source(timedWriter, true)
    ep_capture_enable_processed(timedWriter, true)
    buffer.frameLength = 10
    // Independent callbacks can arrive in either order and straddle the common boundary.
    for i in 0..<10 { buffer.floatChannelData![0][i] = Float(i - 2) }
    ep_capture_push_processed_at(timedWriter, buffer.audioBufferList, 10, 1000)
    for i in 0..<10 { buffer.floatChannelData![0][i] = Float(i) }
    ep_capture_push_source_at(timedWriter, buffer.audioBufferList, 10, 1000)
    for i in 0..<10 { buffer.floatChannelData![0][i] = Float(i + 10) }
    ep_capture_push_source_at(timedWriter, buffer.audioBufferList, 10, 1010)
    for i in 0..<10 { buffer.floatChannelData![0][i] = Float(i + 8) }
    ep_capture_push_processed_at(timedWriter, buffer.audioBufferList, 10, 1010)
    ep_capture_enable_source(timedWriter, false)
    ep_capture_push_source_at(timedWriter, buffer.audioBufferList, 10, 1020)
    ep_capture_processed_limit(timedWriter, 16)
    for i in 0..<10 { buffer.floatChannelData![0][i] = Float(i + 18) }
    ep_capture_push_processed_at(timedWriter, buffer.audioBufferList, 10, 1020)
    ep_capture_enable_processed(timedWriter, false)
    let timedFinal = ep_capture_finalize(timedWriter)
    XCTAssertEqual(timedFinal.sourceFrames, 16)
    XCTAssertEqual(timedFinal.processedFrames, 16)
    XCTAssertEqual(timedFinal.sourceError, 0)
    XCTAssertEqual(timedFinal.processedError, 0)
    let dryClock = try AVAudioFile(forReading: clockSource)
    let wetClock = try AVAudioFile(forReading: clockProcessed)
    try dryClock.read(into: buffer)
    let drySamples = Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    try wetClock.read(into: buffer)
    let wetSamples = Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    XCTAssertEqual(drySamples, (4..<20).map(Float.init))
    XCTAssertEqual(wetSamples, drySamples)
  }

  func testSessionRecoveryAndPreferences() throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = try SessionFileService(root: directory)
    var session = RecordingSession(title: "復旧テスト")
    session.effects = [
      EffectSlot(
        plugin: PluginDescriptor(id: "test", name: "test", manufacturer: "test", format: .au),
        state: Data([1, 2, 3]))
    ]
    session.transcript = [TranscriptSegment(start: 0, end: 1, text: "こんにちは", isFinal: true)]
    session.transcriptionStatus = "文字起こし完了 · ローカル"
    try files.save(session)
    try fixture(at: files.directory(session.id).appendingPathComponent("source.caf"))
    let loaded = try XCTUnwrap(files.load().first)
    XCTAssertEqual(loaded.status, .interrupted)
    XCTAssertEqual(loaded.frameCount, 96_000)
    XCTAssertEqual(loaded.transcript, session.transcript)
    XCTAssertEqual(loaded.transcriptionStatus, session.transcriptionStatus)
    XCTAssertEqual(loaded.effects.first?.state, Data([1, 2, 3]))
    session.status = .completed
    session.frameCount = 96_000
    session.processedComplete = true
    try files.save(session)
    let missingProcessed = try XCTUnwrap(files.load().first)
    XCTAssertEqual(missingProcessed.status, .completed)
    XCTAssertFalse(missingProcessed.processedComplete)
    XCTAssertNotNil(missingProcessed.warning)
    let processedPath = files.directory(session.id).appendingPathComponent("processed.caf")
    try Data("invalid audio container".utf8).write(to: processedPath)
    let corruptProcessed = try XCTUnwrap(files.load().first)
    XCTAssertFalse(corruptProcessed.processedComplete)
    XCTAssertNotNil(corruptProcessed.warning)
    XCTAssertEqual(
      try AVAudioFile(forReading: files.directory(session.id).appendingPathComponent("source.caf"))
        .length, 96_000)
    try fixture(at: processedPath)
    XCTAssertTrue(try XCTUnwrap(files.load().first).processedComplete)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "EasyPodTests-\(UUID())"))
    let prefs = PreferencesStore(defaults: defaults)
    XCTAssertEqual(prefs.settings.bitDepth, 24)
    XCTAssertEqual(prefs.settings.effectTiming, .afterRecording)
    prefs.settings.bitDepth = 32
    prefs.modelPath = "'/tmp/my model.gguf'"
    XCTAssertEqual(PreferencesStore(defaults: defaults).settings.bitDepth, 32)
    XCTAssertEqual(UserPath.url(prefs.modelPath).path, "/tmp/my model.gguf")
    XCTAssertEqual(UserPath.url("/tmp/my\\ model.gguf").path, "/tmp/my model.gguf")
  }

  func testWAVDepthsAACAndLiveSourceSelection() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    try fixture(at: directory.appendingPathComponent("source.caf"), seconds: 40, amplitude: 0.2)
    try fixture(at: directory.appendingPathComponent("processed.caf"), seconds: 40, amplitude: 0.1)
    var session = RecordingSession(
      title: "Export", status: .completed, frameCount: 1_920_000, processedComplete: true)
    session.settings.effectTiming = .duringRecording
    let exporter = AudioExportService()
    for depth in [16, 24, 32] {
      var settings = RecordingSettings()
      settings.bitDepth = depth
      let output = directory.appendingPathComponent("depth\(depth).wav")
      _ = try await exporter.export(
        session: session, directory: directory, destination: output,
        request: ExportRequest(includeEffects: false, settings: settings), effects: nil,
        onProgress: { _ in })
      let file = try AVAudioFile(forReading: output)
      XCTAssertEqual(file.length, 1_920_000)
      XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, depth)
      XCTAssertEqual(
        file.fileFormat.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        depth == 32)
      XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
      XCTAssertEqual(file.fileFormat.channelCount, 1)
    }
    var sizes: [Int] = []
    for bitrate in [96_000, 192_000] {
      var settings = RecordingSettings()
      settings.format = .m4a
      settings.bitrate = bitrate
      let output = directory.appendingPathComponent("aac\(bitrate).m4a")
      _ = try await exporter.export(
        session: session, directory: directory, destination: output,
        request: ExportRequest(includeEffects: false, settings: settings), effects: nil,
        onProgress: { _ in })
      let file = try AVAudioFile(forReading: output)
      XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 40, accuracy: 0.1)
      XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
      sizes.append(try Data(contentsOf: output).count)
    }
    XCTAssertGreaterThan(sizes[1], sizes[0])
    let processedOutput = directory.appendingPathComponent("processed.wav")
    _ = try await exporter.export(
      session: session, directory: directory, destination: processedOutput,
      request: ExportRequest(
        source: .processed, includeEffects: true, settings: RecordingSettings()), effects: nil,
      onProgress: { _ in })
    let file = try AVAudioFile(forReading: processedOutput)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
    try file.read(into: buffer)
    let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    XCTAssertEqual(peak, 0.1, accuracy: 0.001)
    XCTAssertEqual(
      try AVAudioFile(forReading: directory.appendingPathComponent("source.caf")).length, 1_920_000)
  }

  func testExportCancellationPreservesExistingDestination() async throws {
    let directory = try folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    try fixture(at: directory.appendingPathComponent("source.caf"), seconds: 10)
    let output = directory.appendingPathComponent("prior.wav")
    let prior = Data("prior export must survive".utf8)
    try prior.write(to: output)
    let exporter = AudioExportService()
    do {
      _ = try await exporter.export(
        session: RecordingSession(title: "Cancel", status: .completed), directory: directory,
        destination: output, request: ExportRequest(settings: RecordingSettings()), effects: nil,
        onProgress: { progress in if progress == 0 { exporter.cancel() } })
      XCTFail("Cancellation must not publish output")
    } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: output), prior)
    XCTAssertEqual(
      try AVAudioFile(forReading: directory.appendingPathComponent("source.caf")).length, 480_000)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix(".easypod-")
      })
  }
}
