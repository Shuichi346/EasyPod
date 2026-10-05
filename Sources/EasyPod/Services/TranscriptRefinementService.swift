import AVFoundation
import CNeMoASR
import Foundation
import Synchronization

/// Reads saved original audio and returns a complete replacement only after every chunk succeeds.
struct TranscriptRefinementService: Sendable {
  private let backendFactory: @Sendable () -> any TranscriptRefinementBackend

  init() { backendFactory = { NativeTranscriptRefinementBackend() } }

  init(backendFactory: @escaping @Sendable () -> any TranscriptRefinementBackend) {
    self.backendFactory = backendFactory
  }

  func recognize(
    source: URL, modelPath: String,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> [TranscriptSegment] {
    let cancelled = TranscriptRefinementCancellation()
    let factory = backendFactory
    let model = UserPath.url(modelPath)
    let queue = DispatchQueue(label: "local.EasyPod.asr.refinement", qos: .utility)
    let segments = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[TranscriptSegment], Error>) in
        queue.async {
          do {
            let worker = TranscriptRefinementWorker(
              source: source, model: model, backend: factory(), cancelled: cancelled,
              onProgress: onProgress)
            continuation.resume(returning: try worker.run())
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: {
      cancelled.flag.withLock { $0 = true }
    }
    // Cancellation may arrive between the worker's last check and continuation delivery.
    try Task.checkCancellation()
    return segments
  }
}

struct TranscriptRefinementHypothesis: Sendable {
  var text: String
  var start: Double
  var end: Double
}

/// Instances and native handles are used and closed exclusively on the worker's serial queue.
protocol TranscriptRefinementBackend: AnyObject, Sendable {
  func open(model: URL) throws
  func recognize(samples: [Float], sampleRate: Int32) throws -> TranscriptRefinementHypothesis
  func close()
}

private final class TranscriptRefinementCancellation: Sendable {
  let flag = Mutex(false)
}

private final class TranscriptRefinementWorker {
  private let source: URL
  private let model: URL
  private let backend: any TranscriptRefinementBackend
  private let cancelled: TranscriptRefinementCancellation
  private let onProgress: @Sendable (Double) -> Void

  init(
    source: URL, model: URL, backend: any TranscriptRefinementBackend,
    cancelled: TranscriptRefinementCancellation, onProgress: @escaping @Sendable (Double) -> Void
  ) {
    self.source = source
    self.model = model
    self.backend = backend
    self.cancelled = cancelled
    self.onProgress = onProgress
  }

  func run() throws -> [TranscriptSegment] {
    defer { backend.close() }
    try checkCancellation()
    guard FileManager.default.fileExists(atPath: model.path) else {
      throw EasyPodError.message("モデルが見つかりません。設定で場所を指定してください。")
    }
    let file = try AVAudioFile(forReading: source)
    let rate = file.processingFormat.sampleRate
    guard rate.isFinite, (8_000...96_000).contains(rate), rate.rounded() == rate,
      file.length > 0, file.processingFormat.channelCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)
    else { throw EasyPodError.message("清書に利用できる音声がありません。") }
    let totalFrames = file.length
    // Whole-file requests can exceed encoder positions and fall back to streaming. Bounded
    // offline requests also limit PCM/attention memory and allow cancellation between calls.
    let maximumFrames = Int64(rate * 30)
    onProgress(0)
    try backend.open(model: model)
    try checkCancellation()
    var cursor: Int64 = 0
    var segments: [TranscriptSegment] = []
    while cursor < totalFrames {
      try checkCancellation()
      let count = Int(min(maximumFrames, totalFrames - cursor))
      var samples = [Float](repeating: 0, count: count)
      file.framePosition = cursor
      var readCount = 0
      while readCount < count {
        try checkCancellation()
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, count - readCount)))
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
          throw EasyPodError.message("元の音声を最後まで読み込めませんでした。")
        }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
          for frame in 0..<frames {
            samples[readCount + frame] += channels[channel][frame] / Float(channelCount)
          }
        }
        readCount += frames
      }
      // Prefer silence to cutting speech. Continuous speech still has a 30-second hard limit;
      // context across requests is not retained, and no audio is skipped or duplicated.
      let cut =
        cursor + Int64(count) < totalFrames
        ? TranscriptRefinementChunking.boundary(samples: samples, sampleRate: Int(rate)) : count
      if cut < count { samples.removeSubrange(cut..<count) }
      try checkCancellation()
      let hypothesis = try backend.recognize(samples: samples, sampleRate: Int32(rate))
      // The C ABI cannot interrupt an in-flight offline call. Discard its result on cancel.
      try checkCancellation()
      let text = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let offset = Double(cursor) / rate
      let duration = Double(cut) / rate
      if !text.isEmpty {
        guard hypothesis.start.isFinite, hypothesis.end.isFinite else {
          throw EasyPodError.message("清書結果の時刻を確認できませんでした。")
        }
        let start = min(duration, max(0, hypothesis.start))
        let end = min(duration, max(start, hypothesis.end))
        segments.append(
          TranscriptSegment(start: offset + start, end: offset + end, text: text, isFinal: true))
      }
      cursor += Int64(cut)
      onProgress(Double(cursor) / Double(totalFrames))
    }
    try checkCancellation()
    guard !segments.isEmpty else {
      throw EasyPodError.message("音声から文字を認識できなかったため、元の文字起こしを保持しました。")
    }
    return segments
  }

  private func checkCancellation() throws {
    if cancelled.flag.withLock({ $0 }) { throw CancellationError() }
  }
}

enum TranscriptRefinementChunking {
  static func boundary(samples: [Float], sampleRate: Int) -> Int {
    let window = max(1, sampleRate / 4)
    let minimum = max(window, samples.count - sampleRate * 5)
    guard samples.count >= window, minimum < samples.count else { return samples.count }
    // Search backwards for 250 ms below approximately -40 dBFS; choosing the latest
    // quiet point preserves as much utterance context as the bounded request allows.
    var end = samples.count
    while end - window >= minimum {
      let begin = end - window
      var sum: Double = 0
      for sample in samples[begin..<end] { sum += Double(sample) * Double(sample) }
      if sum / Double(window) < 0.0001 { return begin + window / 2 }
      end -= window
    }
    return samples.count
  }
}

private final class NativeTranscriptRefinementBackend: TranscriptRefinementBackend,
  @unchecked Sendable
{
  private var recognizer: OpaquePointer?

  func open(model: URL) throws {
    do { try load(model: model, gpu: 0) } catch { try load(model: model, gpu: -1) }
  }

  private func load(model: URL, gpu: Int32) throws {
    var backend = nemo_speech_asr_backend_config()
    backend.size = MemoryLayout<nemo_speech_asr_backend_config>.size
    backend.gpu = gpu
    var modelConfig = nemo_speech_asr_model_config()
    modelConfig.size = MemoryLayout<nemo_speech_asr_model_config>.size
    var config = nemo_speech_asr_recognizer_config()
    config.size = MemoryLayout<nemo_speech_asr_recognizer_config>.size
    let status = model.path.withCString { path in
      modelConfig.path = path
      return withUnsafePointer(to: &backend) { backendPointer in
        withUnsafePointer(to: &modelConfig) { modelPointer in
          config.backend = backendPointer
          config.model = modelPointer
          return nemo_speech_asr_create(&config, &recognizer)
        }
      }
    }
    guard status == NEMO_SPEECH_ASR_OK, recognizer != nil else {
      let error = lastError()
      close()
      throw error
    }
  }

  func recognize(samples: [Float], sampleRate: Int32) throws -> TranscriptRefinementHypothesis {
    var options = nemo_speech_asr_recognition_options_default()
    options.interim_results = false
    options.enable_word_time_offsets = true
    options.enable_automatic_punctuation = true
    var result: OpaquePointer?
    defer { if let result { nemo_speech_asr_result_destroy(result) } }
    let status = "ja-JP".withCString { language in
      options.language_code = language
      return samples.withUnsafeBufferPointer { pcm in
        nemo_speech_asr_recognize_f32(
          recognizer, &options, pcm.baseAddress, pcm.count, sampleRate, &result)
      }
    }
    guard status == NEMO_SPEECH_ASR_OK else { throw lastError() }
    guard let result, nemo_speech_asr_result_is_final(result),
      nemo_speech_asr_result_alternative_count(result) > 0,
      let transcript = nemo_speech_asr_result_transcript(result, 0)
    else { throw EasyPodError.message("清書の認識結果を取得できませんでした。") }
    let count = nemo_speech_asr_result_word_count(result, 0)
    let start =
      count > 0
      ? Double(nemo_speech_asr_result_word_start_time(result, 0, 0)) / 1_000 : 0
    let end =
      count > 0
      ? Double(nemo_speech_asr_result_word_end_time(result, 0, count - 1)) / 1_000
      : Double(samples.count) / Double(sampleRate)
    return TranscriptRefinementHypothesis(text: String(cString: transcript), start: start, end: end)
  }

  func close() {
    if let recognizer {
      nemo_speech_asr_destroy(recognizer)
      self.recognizer = nil
    }
  }

  private func lastError() -> EasyPodError {
    .message(nemo_speech_asr_last_error().map { String(cString: $0) } ?? "清書の認識に失敗しました。")
  }
}
