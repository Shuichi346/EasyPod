import AVFoundation
import Darwin
import Foundation
import OSLog

@MainActor
enum CaptureClockReadiness {
  static func boundary(
    source: EPCaptureClock, processed: EPCaptureClock?,
    sourceBaseline: UInt64, processedBaseline: UInt64, sampleRate: Double,
    earliestHostTime: UInt64 = 0
  ) -> Int64? {
    func advances(_ clock: EPCaptureClock, baseline: UInt64) -> Bool {
      clock.valid && clock.sequence > baseline + 1 && clock.formatRate == sampleRate
        && clock.previousSampleTime != Int64.min && clock.sampleTime > clock.previousSampleTime
        && clock.previousHostTime > 0 && clock.previousHostTime >= earliestHostTime
        && clock.hostTime > clock.previousHostTime
    }
    guard advances(source, baseline: sourceBaseline) else { return nil }
    guard source.sampleTime < Int64.max / 2 - Int64(source.frames) - 4096 else { return nil }
    var latestEnd = source.sampleTime + Int64(source.frames)
    if let processed {
      guard advances(processed, baseline: processedBaseline) else { return nil }
      let hostDelta =
        processed.hostTime >= source.hostTime
        ? AVAudioTime.seconds(forHostTime: processed.hostTime - source.hostTime)
        : -AVAudioTime.seconds(forHostTime: source.hostTime - processed.hostTime)
      let sampleDelta = Double(processed.sampleTime) - Double(source.sampleTime)
      guard abs(sampleDelta - hostDelta * sampleRate) <= 2 else { return nil }
      guard processed.sampleTime < Int64.max / 2 - Int64(processed.frames) - 4096 else {
        return nil
      }
      latestEnd = max(latestEnd, processed.sampleTime + Int64(processed.frames))
    }
    return latestEnd + 4096
  }

  static func wait(
    sourceBaseline: UInt64, processedBaseline: UInt64, sampleRate: Double,
    earliestHostTime: UInt64 = 0,
    isRunning: () -> Bool, source: () -> EPCaptureClock, processed: (() -> EPCaptureClock)?,
    timeout: Duration = .seconds(1)
  ) async throws -> Int64 {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard isRunning() else { throw EasyPodError.message("録音の音声接続が停止しました。接続を確認してください。") }
      if let value = boundary(
        source: source(), processed: processed?(), sourceBaseline: sourceBaseline,
        processedBaseline: processedBaseline, sampleRate: sampleRate,
        earliestHostTime: earliestHostTime)
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw EasyPodError.message("マイクから音声を受け取れませんでした。接続や他のアプリの使用状況を確認してください。")
  }
}

// The render closures retain this handle until taps have been removed and the engine has stopped.
private final class CaptureWriterHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

@MainActor
final class AudioCaptureService {
  private var engine: AVAudioEngine?
  private var route: CaptureAudioRoute?
  private let logger = Logger(subsystem: "local.EasyPod", category: "capture")
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
    var newRoute: CaptureAudioRoute?
    var stage = "device route"
    do {
      newRoute = try await AudioDeviceService.configureCapture(inputID: inputID, engine: newEngine)
      stage = "hardware formats"
      let hardwareFormat = try Self.inputFormat(newEngine.inputNode.inputFormat(forBus: 0))
      let outputFormat = newEngine.outputNode.outputFormat(forBus: 0)
      guard outputFormat.sampleRate.isFinite, outputFormat.sampleRate > 0,
        outputFormat.channelCount > 0
      else {
        throw EasyPodError.message("再生出力を準備できませんでした。Macのサウンド出力を確認してください。")
      }
      logger.info(
        "Capture route input=\(inputID ?? 0) device=\(newRoute?.deviceID ?? 0) hardware=\(hardwareFormat.sampleRate)/\(hardwareFormat.channelCount) output=\(outputFormat.sampleRate)/\(outputFormat.channelCount) recording=\(settings.sampleRate)/\(settings.channels)"
      )
      stage = "graph connection"
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
        block: Self.sourceTap(writer: handle))
      sourceTapInstalled = true
      if hasProcessed {
        processed.installTap(
          onBus: 0, bufferSize: 1024, format: format,
          block: Self.processedTap(writer: handle))
        processedTapInstalled = true
      }
      stage = "engine start"
      let sourceBaseline = ep_capture_clock(pointer, false).sequence
      let processedBaseline = ep_capture_clock(pointer, true).sequence
      let earliestHostTime = mach_absolute_time()
      newEngine.prepare()
      try newEngine.start()
      stage = "tap clock readiness"
      try await armSegment(
        engine: newEngine, writer: handle,
        sourceBaseline: sourceBaseline, processedBaseline: processedBaseline,
        earliestHostTime: earliestHostTime,
        settings: settings, effects: effects, hasProcessed: hasProcessed)
    } catch {
      logger.error(
        "Capture preparation failed stage=\(stage, privacy: .public) input=\(inputID ?? 0) error=\(error.localizedDescription, privacy: .public)"
      )
      newEngine.stop()
      if sourceTapInstalled { original.removeTap(onBus: 0) }
      if processedTapInstalled { processed.removeTap(onBus: 0) }
      effects?.detach(from: newEngine)
      if let newRoute, newRoute.close() != 0 {
        logger.error("Capture preparation route cleanup failed")
      }
      ep_capture_destroy(pointer)
      throw error
    }
    self.engine = newEngine
    self.route = newRoute
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
  private nonisolated static func sourceTap(writer: CaptureWriterHandle)
    -> AVAudioNodeTapBlock
  {
    let callback: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, time in
      ep_capture_push_source_clocked(
        writer.pointer, buffer.audioBufferList, buffer.frameLength,
        time.isSampleTimeValid ? time.sampleTime : Int64.min, time.sampleRate,
        time.isHostTimeValid ? time.hostTime : 0, buffer.format.sampleRate)
    }
    return callback
  }

  private nonisolated static func processedTap(writer: CaptureWriterHandle)
    -> AVAudioNodeTapBlock
  {
    let callback: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, time in
      ep_capture_push_processed_clocked(
        writer.pointer, buffer.audioBufferList, buffer.frameLength,
        time.isSampleTimeValid ? time.sampleTime : Int64.min, time.sampleRate,
        time.isHostTimeValid ? time.hostTime : 0, buffer.format.sampleRate)
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
    guard sourceMixer != nil else { throw EasyPodError.message("マイク入力を再開できません。") }
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
      let sourceBaseline = ep_capture_clock(writer.pointer, false).sequence
      let processedBaseline = ep_capture_clock(writer.pointer, true).sequence
      let earliestHostTime = mach_absolute_time()
      try engine.start()
      try await armSegment(
        engine: engine, writer: writer,
        sourceBaseline: sourceBaseline, processedBaseline: processedBaseline,
        earliestHostTime: earliestHostTime,
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
    if let route, route.close() != noErr, warning == nil {
      warning = "録音は保存されましたが、音声接続の後片付けに失敗しました。アプリを終了すると解放されます。"
    }
    self.route = nil
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
    engine: AVAudioEngine, writer: CaptureWriterHandle,
    sourceBaseline: UInt64, processedBaseline: UInt64,
    earliestHostTime: UInt64,
    settings: RecordingSettings, effects: EffectChain?, hasProcessed: Bool
  ) async throws {
    // Starting the hardware allocates the actual effect render size, which can change latency.
    let boundary: Int64
    do {
      boundary = try await CaptureClockReadiness.wait(
        sourceBaseline: sourceBaseline, processedBaseline: processedBaseline,
        sampleRate: settings.sampleRate, earliestHostTime: earliestHostTime,
        isRunning: { engine.isRunning }, source: { ep_capture_clock(writer.pointer, false) },
        processed: hasProcessed ? { ep_capture_clock(writer.pointer, true) } : nil)
    } catch {
      let source = ep_capture_clock(writer.pointer, false)
      let processed = ep_capture_clock(writer.pointer, true)
      logger.error(
        "Capture clock source=\(source.clockRate)/\(source.formatRate) seq=\(source.sequence) sample=\(source.sampleTime) valid=\(source.valid) processed=\(processed.clockRate)/\(processed.formatRate) seq=\(processed.sequence) sample=\(processed.sampleTime) valid=\(processed.valid)"
      )
      throw error
    }
    let latency = hasProcessed ? max(0, effects?.latency ?? 0) : 0
    let delayedFrames = (latency * settings.sampleRate).rounded(.up)
    guard delayedFrames.isFinite, delayedFrames < Double(Int64.max / 2),
      boundary < Int64.max / 2 - Int64(delayedFrames)
    else {
      throw EasyPodError.message("エフェクトの遅延が対応範囲外です。")
    }
    // A future sample boundary prevents independently queued taps from starting one block apart.
    ep_capture_segment(writer.pointer, boundary, UInt64(delayedFrames))
    ep_capture_enable_source(writer.pointer, true)
    if hasProcessed { ep_capture_enable_processed(writer.pointer, true) }
  }

  static func inputFormat(_ hardware: AVAudioFormat) throws -> AVAudioFormat {
    guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0,
      let format = AVAudioFormat(
        standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
    else { throw EasyPodError.message("利用できるマイク入力がありません。") }
    return format
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
