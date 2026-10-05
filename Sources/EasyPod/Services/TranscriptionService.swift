import AVFoundation
import CNeMoASR
import Foundation
import Observation
import Synchronization

@MainActor @Observable final class TranscriptionService {
  var status = "録音開始を待っています"
  var segments: [TranscriptSegment] = []
  var onChange: (@MainActor ([TranscriptSegment], String) -> Void)?
  private var worker: ASRWorker?
  private var generation = UUID()
  private var lastSequence = 0

  func start(
    modelPath: String, source: URL, sampleRate: Double,
    beforePush: (@Sendable () -> Void)? = nil
  ) {
    segments = []
    status = "モデルを読み込み中"
    generation = UUID()
    lastSequence = 0
    let current = generation
    let newWorker = ASRWorker(
      model: UserPath.url(modelPath), source: source, rate: sampleRate, beforePush: beforePush
    ) {
      [weak self] snapshot in
      DispatchQueue.main.async {
        guard let self, self.generation == current else { return }
        self.apply(snapshot)
      }
    }
    worker = newWorker
    newWorker.start()
  }

  func updateAvailable(frames: Int64) { worker?.available.withLock { $0 = frames } }

  func pause(frames: Int64) async {
    guard let worker else { return }
    apply(await worker.flush(frames: frames, stop: false))
  }

  func finish(frames: Int64) async {
    guard let worker else { return }
    if !status.hasPrefix("文字起こし:") { status = "最後の発話を確定中" }
    apply(await worker.flush(frames: frames, stop: true))
    self.worker = nil
  }

  private func apply(_ snapshot: ASRSnapshot) {
    guard snapshot.sequence >= lastSequence else { return }
    lastSequence = snapshot.sequence
    segments = snapshot.segments
    status = snapshot.status
    onChange?(segments, status)
  }
}

private struct ASRSnapshot: Sendable {
  var sequence: Int
  var segments: [TranscriptSegment]
  var status: String
}

private final class ASRWorker: @unchecked Sendable {
  let available = Mutex<Int64>(0)
  private let queue = DispatchQueue(label: "local.EasyPod.asr", qos: .utility)
  private let model: URL
  private let source: URL
  private let rate: Double
  private let beforePush: (@Sendable () -> Void)?
  private let event: @Sendable (ASRSnapshot) -> Void
  private var snapshot = ASRSnapshot(sequence: 0, segments: [], status: "モデルを読み込み中")
  private var recognizer: OpaquePointer?
  private var stream: OpaquePointer?
  private var timer: DispatchSourceTimer?
  private var cursor: Int64 = 0
  private var streamStart: Double = 0
  private var utteranceStart: Double = 0
  private var failed = false

  init(
    model: URL, source: URL, rate: Double, beforePush: (@Sendable () -> Void)?,
    event: @escaping @Sendable (ASRSnapshot) -> Void
  ) {
    self.model = model
    self.source = source
    self.rate = rate
    self.beforePush = beforePush
    self.event = event
  }

  func start() {
    queue.async { [self] in
      do {
        guard FileManager.default.fileExists(atPath: model.path) else {
          throw EasyPodError.message("モデルが見つかりません。設定で場所を指定してください。")
        }
        try load(gpu: 0)
        emit(nil, "Nemotron 3.5 · ローカル")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(600))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
      } catch { fail(error) }
    }
  }

  private func lastError() -> EasyPodError {
    let text = nemo_speech_asr_last_error().map { String(cString: $0) } ?? "ASRの処理に失敗しました。"
    return .message(text)
  }

  private func load(gpu: Int32) throws {
    var backend = nemo_speech_asr_backend_config()
    backend.size = MemoryLayout<nemo_speech_asr_backend_config>.size
    backend.gpu = gpu
    var config = nemo_speech_asr_recognizer_config()
    config.size = MemoryLayout<nemo_speech_asr_recognizer_config>.size
    var modelConfig = nemo_speech_asr_model_config()
    modelConfig.size = MemoryLayout<nemo_speech_asr_model_config>.size
    var endpointing = nemo_speech_asr_endpointing_config()
    endpointing.size = MemoryLayout<nemo_speech_asr_endpointing_config>.size
    endpointing.enable = true
    endpointing.stop_history_eou_ms = 800
    let result = model.path.withCString { path in
      modelConfig.path = path
      return withUnsafePointer(to: &backend) { backendPointer in
        withUnsafePointer(to: &modelConfig) { modelPointer in
          config.backend = backendPointer
          config.model = modelPointer
          return withUnsafePointer(to: &endpointing) { endpointingPointer in
            config.endpointing = endpointingPointer
            return nemo_speech_asr_create(&config, &recognizer)
          }
        }
      }
    }
    if result != NEMO_SPEECH_ASR_OK {
      if let recognizer {
        nemo_speech_asr_destroy(recognizer)
        self.recognizer = nil
      }
      if gpu >= 0 { try load(gpu: -1) } else { throw lastError() }
    }
  }

  private func openStream() throws {
    guard stream == nil else { return }
    var options = nemo_speech_asr_recognition_options_default()
    options.interim_results = true
    options.enable_word_time_offsets = true
    let result = "ja-JP".withCString { language in
      options.language_code = language
      return nemo_speech_asr_streaming_recognize(recognizer, &options, &stream)
    }
    guard result == NEMO_SPEECH_ASR_OK else { throw lastError() }
    streamStart = Double(cursor) / rate
    utteranceStart = streamStart
  }

  private func tick() {
    guard !failed else { return }
    do { try read(until: available.withLock { $0 }) } catch { fail(error) }
  }

  // A growing file is the bounded backlog. Inference never owns the capture worker.
  private func read(until target: Int64) throws {
    guard target > cursor else { return }
    let file = try AVAudioFile(forReading: source)
    let end = min(file.length, target)
    guard end > cursor,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)
    else { return }
    try openStream()
    file.framePosition = cursor
    while cursor < end {
      try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, end - cursor)))
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
      let count = Int(buffer.frameLength)
      var mono = [Float](repeating: 0, count: count)
      for channel in 0..<Int(buffer.format.channelCount) {
        for sample in 0..<count {
          mono[sample] += channels[channel][sample] / Float(buffer.format.channelCount)
        }
      }
      updateLagStatus()
      // This optional test gate runs on the ASR queue, never on a realtime audio callback.
      beforePush?()
      let result = mono.withUnsafeBufferPointer {
        nemo_speech_asr_stream_push_f32(stream, $0.baseAddress, $0.count, Int32(rate))
      }
      guard result == NEMO_SPEECH_ASR_OK else { throw lastError() }
      cursor += Int64(count)
      try drain()
    }
    updateLagStatus()
  }

  private func processingStatus() -> String {
    let lag = Double(max(0, available.withLock { $0 } - cursor)) / rate
    return lag > 3
      ? "保存済み音声から認識中（約\(Int(lag))秒の遅れ）" : "Nemotron 3.5 · ローカル"
  }

  private func updateLagStatus() {
    let status = processingStatus()
    if snapshot.status != status { emit(nil, status) }
  }

  private func drain() throws {
    while true {
      var result: OpaquePointer?
      guard nemo_speech_asr_stream_next(stream, &result) == NEMO_SPEECH_ASR_OK else {
        throw lastError()
      }
      guard let result else { return }
      defer { nemo_speech_asr_result_destroy(result) }
      let text = nemo_speech_asr_result_transcript(result, 0).map { String(cString: $0) } ?? ""
      let end = streamStart + Double(nemo_speech_asr_result_audio_processed(result))
      let final = nemo_speech_asr_result_is_final(result)
      emit(
        TranscriptSegment(start: utteranceStart, end: end, text: text, isFinal: final),
        processingStatus())
      if final { utteranceStart = end }
    }
  }

  func flush(frames: Int64, stop: Bool) async -> ASRSnapshot {
    available.withLock { $0 = frames }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<ASRSnapshot, Never>) in
      queue.async { [self] in
        defer { continuation.resume(returning: snapshot) }
        if !failed {
          do {
            try read(until: frames)
            guard cursor == frames else {
              throw EasyPodError.message("音声の保存を確認できず、文字起こしを完了できませんでした。")
            }
            if let stream {
              guard nemo_speech_asr_stream_finish(stream) == NEMO_SPEECH_ASR_OK else {
                throw lastError()
              }
              try drain()
              nemo_speech_asr_stream_close(stream)
              self.stream = nil
            }
            emit(nil, stop ? "文字起こし完了 · ローカル" : "一時停止")
          } catch { fail(error) }
        }
        if stop { close() }
      }
    }
  }

  private func emit(_ segment: TranscriptSegment?, _ status: String) {
    snapshot.sequence += 1
    snapshot.status = status
    if let segment {
      snapshot.segments.removeAll { !$0.isFinal }
      if !segment.text.isEmpty { snapshot.segments.append(segment) }
    }
    event(snapshot)
  }

  private func fail(_ error: Error) {
    failed = true
    emit(nil, "文字起こし: \(error.localizedDescription)")
    close()
  }

  private func close() {
    timer?.cancel()
    timer = nil
    if let stream {
      nemo_speech_asr_stream_close(stream)
      self.stream = nil
    }
    if let recognizer {
      nemo_speech_asr_destroy(recognizer)
      self.recognizer = nil
    }
  }
}
