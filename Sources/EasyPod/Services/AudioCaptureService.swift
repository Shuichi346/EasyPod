import AVFoundation
import Foundation

// The render closures retain this handle until taps have been removed and the engine has stopped.
private final class CaptureWriterHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

@MainActor
final class AudioCaptureService {
  private var engine: AVAudioEngine?
  private var sourceMixer: AVAudioMixerNode?
  private var gateMixer: AVAudioMixerNode?
  private var processedMixer: AVAudioMixerNode?
  private var writer: CaptureWriterHandle?
  private var effects: EffectChain?
  private var settings = RecordingSettings()
  private var ticker: Task<Void, Never>?
  private var configurationObserver: NSObjectProtocol?
  private var onUpdate: (@MainActor @Sendable (CaptureUpdate) -> Void)?
  private var peaks: [Float] = []
  private var warning: String?
  private(set) var isPaused = false
  private var isFinalizing = false
  private var isPreparing = false
  private var pauseInProgress = false
  private var resumeInProgress = false
  private var lastSourceError: Int32 = 0
  private var processedFailed = false
  private var expectedProcessedFrames: Int64 = 0

  func start(
    directory: URL, settings: RecordingSettings, inputID: UInt32?,
    effects: EffectChain?, monitor: Bool,
    onUpdate: @escaping @MainActor @Sendable (CaptureUpdate) -> Void
  ) async throws {
    guard engine == nil, !isPreparing else { throw EasyPodError.message("録音はすでに開始されています。") }
    isPreparing = true
    defer { isPreparing = false }
    guard await AudioDeviceService.requestPermission() else {
      throw EasyPodError.message("マイクの使用が許可されていません。システム設定のプライバシーとセキュリティで EasyPod を許可してください。")
    }
    guard settings.channels == 1 || settings.channels == 2,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: settings.sampleRate,
        channels: AVAudioChannelCount(settings.channels), interleaved: false)
    else { throw EasyPodError.message("録音形式が対応範囲外です。") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent("source.caf")
    guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw EasyPodError.message("このセッションには録音が存在します。新しい録音を作成してください。")
    }
    let hasProcessed = settings.effectTiming == .duringRecording
    let processedURL = directory.appendingPathComponent("processed.caf")
    var code: Int32 = 0
    let pointer = sourceURL.path.withCString { source in
      processedURL.path.withCString { processed in
        ep_capture_create(
          source, hasProcessed ? processed : nil,
          settings.sampleRate, UInt32(settings.channels), &code)
      }
    }
    guard let pointer else { throw EasyPodError.message("録音ファイルを作成できませんでした（\(code)）。") }
    let handle = CaptureWriterHandle(pointer)
    let newEngine = AVAudioEngine()
    let original = AVAudioMixerNode()
    let gate = AVAudioMixerNode()
    let processed = AVAudioMixerNode()
    var sourceTapInstalled = false
    var processedTapInstalled = false
    do {
      if let inputID { try AudioDeviceService.selectInput(inputID, engine: newEngine) }
      let hardwareFormat = newEngine.inputNode.outputFormat(forBus: 0)
      guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
        throw EasyPodError.message("利用できるマイク入力がありません。")
      }
      newEngine.attach(original)
      newEngine.attach(gate)
      newEngine.attach(processed)
      newEngine.connect(newEngine.inputNode, to: original, format: hardwareFormat)
      newEngine.connect(original, to: gate, format: format)
      if hasProcessed, let effects {
        effects.attach(to: newEngine, from: gate, to: processed, format: format)
      } else {
        newEngine.connect(gate, to: processed, format: format)
      }
      newEngine.connect(processed, to: newEngine.mainMixerNode, format: format)
      newEngine.mainMixerNode.outputVolume = monitor ? 1 : 0
      original.installTap(
        onBus: 0, bufferSize: 1024, format: format,
        block: Self.sourceTap(writer: handle, sampleRate: settings.sampleRate))
      sourceTapInstalled = true
      if hasProcessed {
        processed.installTap(
          onBus: 0, bufferSize: 1024, format: format,
          block: Self.processedTap(writer: handle, sampleRate: settings.sampleRate))
        processedTapInstalled = true
      }
      newEngine.prepare()
      try newEngine.start()
      try await armSegment(
        engine: newEngine, source: original, writer: handle,
        settings: settings, effects: effects, hasProcessed: hasProcessed)
    } catch {
      newEngine.stop()
      if sourceTapInstalled { original.removeTap(onBus: 0) }
      if processedTapInstalled { processed.removeTap(onBus: 0) }
      effects?.detach(from: newEngine)
      ep_capture_destroy(pointer)
      throw error
    }
    self.engine = newEngine
    self.sourceMixer = original
    self.gateMixer = gate
    self.processedMixer = processed
    self.writer = handle
    self.effects = effects
    self.settings = settings
    self.onUpdate = onUpdate
    self.warning = nil
    self.lastSourceError = 0
    self.processedFailed = false
    self.expectedProcessedFrames = 0
    self.peaks = []
    self.isPaused = false
    self.isFinalizing = false
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.engine != nil, !self.isFinalizing else { return }
        self.warning = "音声デバイスの構成が変わりました。録音を一時停止しました。保存済みの音声は保持されています。"
        try? await self.pause()
        self.publish()
      }
    }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self else { return }
        self.publish()
      }
    }
  }

  func setMonitoring(_ enabled: Bool) { engine?.mainMixerNode.outputVolume = enabled ? 1 : 0 }

  // AVAudioNodeTapBlock is imported as non-Sendable; creating it in MainActor would
  // inherit actor checks even though AVFAudio invokes it on its audio thread.
  private nonisolated static func sourceTap(writer: CaptureWriterHandle, sampleRate: Double)
    -> AVAudioNodeTapBlock
  {
    let callback: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, time in
      ep_capture_push_source_at(
        writer.pointer, buffer.audioBufferList, buffer.frameLength,
        time.isSampleTimeValid && time.sampleRate == sampleRate ? time.sampleTime : Int64.min)
    }
    return callback
  }

  private nonisolated static func processedTap(writer: CaptureWriterHandle, sampleRate: Double)
    -> AVAudioNodeTapBlock
  {
    let callback: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, time in
      ep_capture_push_processed_at(
        writer.pointer, buffer.audioBufferList, buffer.frameLength,
        time.isSampleTimeValid && time.sampleRate == sampleRate ? time.sampleTime : Int64.min)
    }
    return callback
  }

  func pause() async throws {
    guard let engine, let writer, !isPaused, !isFinalizing else { return }
    pauseInProgress = true
    defer { pauseInProgress = false }
    isPaused = true
    ep_capture_enable_source(writer.pointer, false)
    gateMixer?.outputVolume = 0
    await drainProcessed(includeTail: false)
    engine.pause()
    let result = await Task.detached { ep_capture_flush(writer.pointer) }.value
    publish()
    if result != 0 { throw EasyPodError.message(storageError(result)) }
  }

  func resume() async throws {
    guard !pauseInProgress else { throw EasyPodError.message("一時停止の保存が完了するまでお待ちください。") }
    guard !resumeInProgress else { throw EasyPodError.message("録音の再開が完了するまでお待ちください。") }
    guard let engine, let writer, isPaused, !isFinalizing else { return }
    guard let sourceMixer else { throw EasyPodError.message("マイク入力を再開できません。") }
    resumeInProgress = true
    defer { resumeInProgress = false }
    let sourceError = ep_capture_status(writer.pointer).sourceError
    guard sourceError == 0 else {
      warning = storageError(sourceError)
      throw EasyPodError.message("保存エラーが発生した録音は再開できません。停止して新しい録音を作成してください。")
    }
    // A fresh effect segment excludes paused speech and compensates its startup latency.
    if !processedFailed { effects?.reset() }
    gateMixer?.outputVolume = 1
    do {
      try engine.start()
      try await armSegment(
        engine: engine, source: sourceMixer, writer: writer,
        settings: settings, effects: processedFailed ? nil : effects,
        hasProcessed: settings.effectTiming == .duringRecording && !processedFailed)
    } catch {
      ep_capture_enable_source(writer.pointer, false)
      ep_capture_enable_processed(writer.pointer, false)
      warning = "録音を再開できませんでした: \(error.localizedDescription) 保存済みのオリジナル音声は保持されています。"
      throw error
    }
    isPaused = false
  }

  func stop() async throws -> CaptureResult {
    guard !isFinalizing else { throw EasyPodError.message("録音の保存を完了しています。") }
    while pauseInProgress || resumeInProgress { try? await Task.sleep(for: .milliseconds(10)) }
    guard !isFinalizing else { throw EasyPodError.message("録音の保存を完了しています。") }
    guard let engine, let writer else { throw EasyPodError.message("録音が開始されていません。") }
    isFinalizing = true
    ticker?.cancel()
    ticker = nil
    ep_capture_enable_source(writer.pointer, false)
    gateMixer?.outputVolume = 0
    if isPaused, settings.effectTiming == .duringRecording && !processedFailed {
      let tail = min(max(0, effects?.tail ?? 0), min(30, max(0, settings.tailLimit)))
      let maximum =
        UInt64(max(0, ep_capture_status(writer.pointer).sourceQueuedFrames))
        + UInt64((tail * settings.sampleRate).rounded(.up))
      ep_capture_processed_limit(writer.pointer, maximum)
      ep_capture_enable_processed(writer.pointer, true)
      try? engine.start()
    }
    await drainProcessed(includeTail: true)
    engine.stop()
    sourceMixer?.removeTap(onBus: 0)
    if settings.effectTiming == .duringRecording { processedMixer?.removeTap(onBus: 0) }
    effects?.detach(from: engine)
    _ = await Task.detached { ep_capture_flush(writer.pointer) }.value
    let status = await Task.detached { ep_capture_finalize(writer.pointer) }.value
    if status.sourceError != 0 {
      warning = storageError(status.sourceError)
    } else if status.processedError != 0 {
      warning = "処理済み音声の保存が中断されました（\(status.processedError)）。オリジナル音声は保存されています。"
    }
    let processedComplete =
      settings.effectTiming == .duringRecording
      && !processedFailed && status.processedError == 0
      && status.processedFrames >= max(status.sourceFrames, expectedProcessedFrames)
    if settings.effectTiming == .duringRecording, !processedComplete, warning == nil {
      warning = "処理済み音声を最後まで保存できませんでした。オリジナル音声を使用してください。"
    }
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = nil
    self.writer = nil
    self.engine = nil
    self.sourceMixer = nil
    self.gateMixer = nil
    self.processedMixer = nil
    self.effects = nil
    isPaused = false
    isFinalizing = false
    let sourceComplete = status.sourceError == 0
    onUpdate?(
      CaptureUpdate(
        frameCount: status.sourceFrames, level: 0, peaks: peaks, warning: warning,
        mustStop: !sourceComplete, isPaused: false))
    onUpdate = nil
    return CaptureResult(
      frameCount: status.sourceFrames, processedComplete: processedComplete,
      warning: warning, sourceComplete: sourceComplete)
  }

  private func drainProcessed(includeTail: Bool) async {
    guard let writer, settings.effectTiming == .duringRecording, !processedFailed else { return }
    let tail =
      includeTail ? min(max(0, effects?.tail ?? 0), min(30, max(0, settings.tailLimit))) : 0
    let status = ep_capture_status(writer.pointer)
    let maximum =
      UInt64(max(0, status.sourceQueuedFrames)) + UInt64((tail * settings.sampleRate).rounded(.up))
    expectedProcessedFrames = Int64(maximum)
    ep_capture_processed_limit(writer.pointer, maximum)
    let duration = max(0, effects?.latency ?? 0) + tail + 4096 / settings.sampleRate + 0.1
    // The engine receives silence through the gate while delayed samples and tails are written.
    let deadline = ContinuousClock.now + .seconds(duration)
    while ContinuousClock.now < deadline {
      if ep_capture_status(writer.pointer).processedQueuedFrames >= Int64(maximum) { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    ep_capture_enable_processed(writer.pointer, false)
  }

  private func armSegment(
    engine: AVAudioEngine, source: AVAudioMixerNode, writer: CaptureWriterHandle,
    settings: RecordingSettings, effects: EffectChain?, hasProcessed: Bool
  ) async throws {
    // Starting the hardware allocates the actual effect render size, which can change latency.
    let previousTime = source.lastRenderTime
    var renderTime: AVAudioTime?
    for _ in 0..<10 {
      try await Task.sleep(for: .milliseconds(20))
      if let time = source.lastRenderTime, time.isSampleTimeValid, time.isHostTimeValid,
        previousTime?.isHostTimeValid != true || time.hostTime > (previousTime?.hostTime ?? 0)
      {
        renderTime = time
        break
      }
    }
    guard engine.isRunning, let renderTime, renderTime.sampleRate == settings.sampleRate else {
      throw EasyPodError.message("マイクの音声クロックを開始できませんでした。")
    }
    let latency = hasProcessed ? max(0, effects?.latency ?? 0) : 0
    let delayedFrames = (latency * settings.sampleRate).rounded(.up)
    guard delayedFrames.isFinite, delayedFrames < Double(Int64.max / 2),
      renderTime.sampleTime < Int64.max / 2 - 4096
    else {
      throw EasyPodError.message("エフェクトの遅延が対応範囲外です。")
    }
    // A future sample boundary prevents independently queued taps from starting one block apart.
    ep_capture_segment(writer.pointer, renderTime.sampleTime + 4096, UInt64(delayedFrames))
    ep_capture_enable_source(writer.pointer, true)
    if hasProcessed { ep_capture_enable_processed(writer.pointer, true) }
  }

  private func publish() {
    guard let writer else { return }
    if !processedFailed, settings.effectTiming == .duringRecording, let effects {
      if let failure = effects.processingFailure {
        disableFailedProcessing(reason: failure)
      } else if effects.requiresReconfiguration {
        disableFailedProcessing(reason: "エフェクトの音声構成または遅延が変更されました。")
      }
    }
    let status = ep_capture_status(writer.pointer)
    if !isPaused {
      peaks.append(min(1, status.peak))
      if peaks.count > 240 { peaks.removeFirst(peaks.count - 240) }
    }
    if status.sourceError != 0 {
      warning = storageError(status.sourceError)
      if lastSourceError == 0 {
        lastSourceError = status.sourceError
        Task { [weak self] in try? await self?.pause() }
      }
    } else if status.processedError != 0 {
      warning = "処理済み音声の保存が中断されました。オリジナル音声の録音は継続しています（\(status.processedError)）。"
    }
    onUpdate?(
      CaptureUpdate(
        frameCount: status.sourceFrames,
        level: isPaused ? 0 : min(1, status.level), peaks: peaks, warning: warning,
        mustStop: status.sourceError != 0, isPaused: isPaused))
  }

  private func disableFailedProcessing(reason: String) {
    guard let engine, let writer, let gateMixer, let processedMixer else { return }
    processedFailed = true
    ep_capture_enable_processed(writer.pointer, false)
    let wasPaused = isPaused
    ep_capture_enable_source(writer.pointer, false)
    engine.pause()
    effects?.detach(from: engine)
    engine.disconnectNodeOutput(gateMixer)
    engine.disconnectNodeInput(processedMixer)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: settings.sampleRate,
      channels: AVAudioChannelCount(settings.channels), interleaved: false)!
    engine.connect(gateMixer, to: processedMixer, format: format)
    warning = "\(reason) 処理済み音声を中断し、オリジナル音声の録音を継続します。"
    if !wasPaused {
      ep_capture_enable_source(writer.pointer, true)
      do { try engine.start() } catch {
        ep_capture_enable_source(writer.pointer, false)
        isPaused = true
        warning = "\(reason) 録音を一時停止しました。保存済みのオリジナル音声は保持されています。"
      }
    }
  }

  private func storageError(_ code: Int32) -> String {
    if code == -71002 {
      return "マイクの音声時刻を取得できず録音を一時停止しました。保存済みの音声は保持されています。"
    }
    if code == -71001 {
      return "音声の保存が録音に追いつかず一時停止しました。保存済みの音声は保持されています。"
    }
    return "音声を保存できず一時停止しました（\(code)）。空き容量と保存先を確認してください。保存済みの音声は保持されています。"
  }
}
