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

  func resetForRecording(enabled: Bool) {
    // Reset presentation only after the previous worker has retired its native handles.
    guard worker == nil else { return }
    generation = UUID()
    lastSequence = 0
    segments = []
    status = enabled ? "モデルを読み込み中" : "文字起こし オフ"
  }

  func start(
    modelPath: String, source: URL, sampleRate: Double,
    language: TranscriptionLanguage = .japanese,
    beforePush: (@Sendable () -> Void)? = nil
  ) {
    guard worker == nil else { return }
    resetForRecording(enabled: true)
    let newWorker = ASRWorker(
      model: UserPath.url(modelPath), source: source, rate: sampleRate, language: language,
      beforePush: beforePush, event: snapshotReceiver())
    worker = newWorker
    newWorker.start()
  }

  func updateAvailable(frames: Int64) { worker?.available.withLock { $0 = frames } }

  func pause(frames: Int64) async {
    guard let worker else { return }
    let current = generation
    let snapshot = await worker.flush(frames: frames, stop: false)
    guard generation == current else { return }
    apply(snapshot)
  }

  func finish(frames: Int64) async {
    guard let worker else { return }
    let current = generation
    if !status.hasPrefix("文字起こし:") { status = "最後の発話を確定中" }
    let snapshot = await worker.flush(frames: frames, stop: true)
    guard generation == current else { return }
    apply(snapshot)
    self.worker = nil
  }

  func snapshotReceiver() -> @Sendable (ASRSnapshot) -> Void {
    let current = generation
    let mailbox = ASRSnapshotMailbox()
    return { [weak self] snapshot in
      guard mailbox.offer(snapshot) else { return }
      DispatchQueue.main.async {
        guard let snapshot = mailbox.take(), let self, self.generation == current else { return }
        self.apply(snapshot)
      }
    }
  }

  private func apply(_ snapshot: ASRSnapshot) {
    guard snapshot.sequence > lastSequence else { return }
    lastSequence = snapshot.sequence
    segments = snapshot.segments
    status = snapshot.status
    onChange?(segments, status)
  }
}

struct ASRSnapshot: Sendable {
  var sequence: Int
  var segments: [TranscriptSegment]
  var status: String
}

/// Retains one newest snapshot and allows only one queued MainActor delivery per worker.
final class ASRSnapshotMailbox: Sendable {
  private struct State {
    var latest: ASRSnapshot?
    var scheduled = false
  }

  private let state = Mutex(State())

  func offer(_ snapshot: ASRSnapshot) -> Bool {
    state.withLock {
      if let latest = $0.latest, latest.sequence > snapshot.sequence { return false }
      $0.latest = snapshot
      guard !$0.scheduled else { return false }
      $0.scheduled = true
      return true
    }
  }

  func take() -> ASRSnapshot? {
    state.withLock {
      let latest = $0.latest
      $0.latest = nil
      $0.scheduled = false
      return latest
    }
  }
}

private final class ASRWorker: @unchecked Sendable {
  let available = Mutex<Int64>(0)
  private let queue = DispatchQueue(label: "local.EasyPod.asr", qos: .utility)
  private let model: URL
  private let source: URL
  private let rate: Double
  private let language: TranscriptionLanguage
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
  private var mono = [Float](repeating: 0, count: 8_192)
  private var inputBuffer: AVAudioPCMBuffer?

  init(
    model: URL, source: URL, rate: Double, language: TranscriptionLanguage,
    beforePush: (@Sendable () -> Void)?,
    event: @escaping @Sendable (ASRSnapshot) -> Void
  ) {
    self.model = model
    self.source = source
    self.rate = rate
    self.language = language
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
    let result = language.rawValue.withCString { language in
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
    guard end > cursor else { return }
    if inputBuffer?.format != file.processingFormat {
      inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)
    }
    guard let buffer = inputBuffer else { return }
    try openStream()
    file.framePosition = cursor
    while cursor < end {
      try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, end - cursor)))
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
      let count = Int(buffer.frameLength)
      let channelCount = Int(buffer.format.channelCount)
      if channelCount > 1 {
        let scale = 1 / Float(channelCount)
        for sample in 0..<count { mono[sample] = channels[0][sample] * scale }
        for channel in 1..<channelCount {
          for sample in 0..<count { mono[sample] += channels[channel][sample] * scale }
        }
      }
      updateLagStatus()
      // This optional test gate runs on the ASR queue, never on a realtime audio callback.
      beforePush?()
      let result =
        channelCount == 1
        ? nemo_speech_asr_stream_push_f32(stream, channels[0], count, Int32(rate))
        : mono.withUnsafeBufferPointer {
          nemo_speech_asr_stream_push_f32(stream, $0.baseAddress, count, Int32(rate))
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
      if snapshot.segments.last?.isFinal == false { snapshot.segments.removeLast() }
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
    inputBuffer = nil
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
