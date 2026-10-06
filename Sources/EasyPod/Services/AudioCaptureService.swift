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
    while true {
      try Task.checkCancellation()
      guard isRunning() else { throw EasyPodError.message("録音の音声接続が停止しました。接続を確認してください。") }
      if let value = boundary(
        source: source(), processed: processed?(), sourceBaseline: sourceBaseline,
        processedBaseline: processedBaseline, sampleRate: sampleRate,
        earliestHostTime: earliestHostTime)
      {
        return value
      }
      // Check fresh clocks once after a delayed actor wakeup before reporting a timeout.
      if ContinuousClock.now >= deadline { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw EasyPodError.message("マイクの音声時刻を確認できませんでした。接続を確認して録音を開始し直してください。")
  }
}

// Handles cross serial ownership only after rendering is stopped; callbacks retain PCM handles.
final class CaptureWriterHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

private final class CapturePCMHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

@MainActor
final class AudioCaptureService {
  private static var pendingInputCleanup: [CaptureInputPipeline] = []
  private static var pendingPreparedInputs: [CaptureInputDevice] = []
  private var pipeline: CaptureInputPipeline?
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var monitorEngine: AVAudioEngine?
  private var monitorNode: AVAudioSourceNode?
  private var monitorTask: Task<Void, Never>?
  private var monitorEnabled = false
  private var writer: CaptureWriterHandle?
  private var effects: EffectChain?
  private var settings = RecordingSettings()
  private let logger = Logger(subsystem: "local.EasyPod", category: "capture")
  private var ticker: Task<Void, Never>?
  private var onUpdate: (@MainActor @Sendable (CaptureUpdate) -> Void)?
  private var peaks: [Float] = []
  private var warning: String?
  private(set) var isPaused = false
  private var isPreparing = false
  private var isFinalizing = false
  private var pauseInProgress = false
  private var resumeInProgress = false
  private var processedFailed = false

  func start(
    directory: URL, settings: RecordingSettings, inputID: UInt32?,
    effects: EffectChain?, monitor: Bool,
    onUpdate: @escaping @MainActor @Sendable (CaptureUpdate) -> Void
  ) async throws {
    guard pipeline == nil, !isPreparing else { throw EasyPodError.message("録音はすでに開始されています。") }
    isPreparing = true
    defer { isPreparing = false }
    var retained: [CaptureInputPipeline] = []
    for pending in Self.pendingInputCleanup {
      await pending.close()
      if await pending.snapshot().cleanupError != 0 { retained.append(pending) }
    }
    Self.pendingInputCleanup = retained
    var prepared: [CaptureInputDevice] = []
    for pending in Self.pendingPreparedInputs {
      let code = await Task.detached(priority: .medium) { pending.close() }.value
      if code != 0 { prepared.append(pending) }
    }
    Self.pendingPreparedInputs = prepared
    guard retained.isEmpty, prepared.isEmpty else {
      throw EasyPodError.message("前のマイク接続を解放できませんでした。アプリを終了してから開始してください。")
    }
    guard await AudioDeviceService.requestPermission() else {
      throw EasyPodError.message("マイクの使用が許可されていません。システム設定で EasyPod を許可してください。")
    }
    let inputInfo = try AudioDeviceService.captureInput(inputID)
    guard settings.channels == 1 || settings.channels == 2,
      let format = AVAudioFormat(
        standardFormatWithSampleRate: settings.sampleRate, channels: UInt32(settings.channels))
    else { throw EasyPodError.message("録音形式が対応範囲外です。") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent("source.caf")
    guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw EasyPodError.message("このセッションには録音が存在します。新しい録音を作成してください。")
    }
    let hasProcessed = settings.effectTiming == .duringRecording
    var code: Int32 = 0
    // Driver initialization may synchronously wait for Core Audio's service threads.
    // UI waits asynchronously; the initialization task is retired before ownership transfers.
    let input = try await Task.detached(priority: .medium) {
      try CaptureInputDevice(deviceID: inputInfo.id)
    }.value
    let pointer = sourceURL.path.withCString { source in
      directory.appendingPathComponent("processed.caf").path.withCString { processed in
        ep_capture_create(
          source, hasProcessed ? processed : nil, settings.sampleRate, UInt32(settings.channels),
          &code)
      }
    }
    guard let pointer else {
      await closePreparedInput(input)
      throw EasyPodError.message("録音ファイルを作成できませんでした（\(code)）。")
    }
    guard let feed = ep_pcm_create(UInt32(settings.channels), 16384) else {
      await closePreparedInput(input)
      ep_capture_destroy(pointer)
      throw EasyPodError.message("録音用メモリを確保できませんでした。")
    }
    guard let monitorFeed = ep_pcm_create(UInt32(settings.channels), 32768) else {
      ep_pcm_destroy(feed)
      await closePreparedInput(input)
      ep_capture_destroy(pointer)
      throw EasyPodError.message("録音用メモリを確保できませんでした。")
    }
    let handle = CaptureWriterHandle(pointer)
    let newEngine = AVAudioEngine()
    var newPipeline: CaptureInputPipeline?
    var newSource: AVAudioSourceNode?
    var stage = "input-only processing graph"
    do {
      try Task.checkCancellation()
      // Select manual mode before accessing I/O nodes: this engine never owns a microphone/output route.
      try newEngine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 4096)
      let source = Self.makeSource(format: format, handle: CapturePCMHandle(feed), strict: true)
      newSource = source
      newEngine.attach(source)
      if hasProcessed, let effects {
        effects.attach(to: newEngine, from: source, to: newEngine.mainMixerNode, format: format)
      } else {
        newEngine.connect(source, to: newEngine.mainMixerNode, format: format)
      }
      let worker = try CaptureInputPipeline(
        input: input, writer: handle, engine: newEngine, feed: feed,
        monitorFeed: monitorFeed, format: format, processing: hasProcessed)
      newPipeline = worker
      stage = "input-only start"
      let earliestHostTime = mach_absolute_time()
      try await worker.start()
      stage = "input clock readiness"
      try await armSegment(
        worker: worker, writer: handle, settings: settings, effects: effects,
        hasProcessed: hasProcessed, earliestHostTime: earliestHostTime)
      logger.info(
        "Capture input-only device=\(inputInfo.id) hardware=\(input.sampleRate)/\(input.channels) recording=\(settings.sampleRate)/\(settings.channels)"
      )
    } catch {
      logger.error(
        "Capture preparation failed stage=\(stage, privacy: .public) input=\(inputInfo.id) error=\(error.localizedDescription, privacy: .public)"
      )
      if let newPipeline {
        await newPipeline.close()
        if await newPipeline.snapshot().cleanupError != 0 {
          Self.pendingInputCleanup.append(newPipeline)
        }
      } else {
        await closePreparedInput(input)
        newEngine.stop()
      }
      effects?.detach(from: newEngine)
      if let newSource { newEngine.detach(newSource) }
      ep_pcm_destroy(feed)
      ep_pcm_destroy(monitorFeed)
      ep_capture_destroy(pointer)
      throw error
    }
    pipeline = newPipeline
    engine = newEngine
    sourceNode = newSource
    writer = handle
    self.effects = effects
    self.settings = settings
    self.onUpdate = onUpdate
    peaks = []
    warning = nil
    processedFailed = false
    isPaused = false
    isFinalizing = false
    monitorEnabled = monitor
    await configureMonitoring(monitor)
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self else { return }
        await self.publish()
      }
    }
  }

  private func closePreparedInput(_ input: CaptureInputDevice) async {
    let code = await Task.detached(priority: .medium) { input.close() }.value
    if code != 0 {
      Self.pendingPreparedInputs.append(input)
      logger.error("Capture input cleanup failed: \(code)")
    }
  }

  private nonisolated static func makeSource(
    format: AVAudioFormat, handle: CapturePCMHandle, strict: Bool = false
  )
    -> AVAudioSourceNode
  {
    let callback: AVAudioSourceNodeRenderBlock = { _, _, count, buffers in
      strict
        ? ep_pcm_render_strict(handle.pointer, buffers, count)
        : ep_pcm_render(handle.pointer, buffers, count)
    }
    return AVAudioSourceNode(format: format, renderBlock: callback)
  }

  func setMonitoring(_ enabled: Bool) {
    monitorEnabled = enabled
    let previous = monitorTask
    monitorTask = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self else { return }
      await self.configureMonitoring(enabled)
    }
  }

  private func configureMonitoring(_ enabled: Bool) async {
    guard let pipeline else { return }
    await pipeline.setMonitoring(false)
    monitorEngine?.stop()
    if let monitorNode { monitorEngine?.detach(monitorNode) }
    monitorNode = nil
    monitorEngine = nil
    ep_pcm_clear(pipeline.monitorFeed)
    guard enabled, !isPaused, !isFinalizing,
      let format = AVAudioFormat(
        standardFormatWithSampleRate: settings.sampleRate, channels: UInt32(settings.channels))
    else { return }
    do {
      let output = AVAudioEngine()
      let source = Self.makeSource(format: format, handle: CapturePCMHandle(pipeline.monitorFeed))
      output.attach(source)
      output.connect(source, to: output.mainMixerNode, format: format)
      try output.start()
      monitorEngine = output
      monitorNode = source
      await pipeline.setMonitoring(true)
    } catch {
      warning = "モニター出力を開始できませんでした。オリジナル録音は継続します（\(error.localizedDescription)）。"
      logger.error("Monitor start failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func pause() async throws {
    guard let pipeline, !isPaused, !isFinalizing else { return }
    pauseInProgress = true
    defer { pauseInProgress = false }
    isPaused = true
    await pipeline.pause(latency: liveLatency, tail: 0)
    await configureMonitoring(false)
    guard let writer else { return }
    let code = await Task.detached { ep_capture_flush(writer.pointer) }.value
    await publish()
    if code != 0 { throw EasyPodError.message(storageError(code)) }
  }

  func resume() async throws {
    guard !pauseInProgress, !resumeInProgress else {
      throw EasyPodError.message("録音の準備が完了するまでお待ちください。")
    }
    guard let pipeline, let writer, isPaused, !isFinalizing else { return }
    resumeInProgress = true
    defer { resumeInProgress = false }
    let state = await pipeline.snapshot()
    guard ep_capture_status(writer.pointer).sourceError == 0, state.inputError == 0 else {
      throw EasyPodError.message("音声または保存エラーのある録音は再開できません。停止して新しい録音を作成してください。")
    }
    if !processedFailed { effects?.reset() }
    let sourceBaseline = ep_capture_clock(writer.pointer, false).sequence
    let processedBaseline = ep_capture_clock(writer.pointer, true).sequence
    let earliestHostTime = mach_absolute_time()
    do {
      try await pipeline.start()
      try await armSegment(
        worker: pipeline, writer: writer, settings: settings,
        effects: processedFailed ? nil : effects,
        hasProcessed: settings.effectTiming == .duringRecording && !processedFailed,
        earliestHostTime: earliestHostTime, sourceBaseline: sourceBaseline,
        processedBaseline: processedBaseline)
    } catch {
      await pipeline.pause(latency: 0, tail: 0)
      warning = "録音を再開できませんでした: \(error.localizedDescription) 保存済みの音声は保持されています。"
      throw error
    }
    isPaused = false
    await configureMonitoring(monitorEnabled)
  }

  private var liveLatency: Double { processedFailed ? 0 : max(0, effects?.latency ?? 0) }
  private var liveTail: Double {
    processedFailed ? 0 : min(max(0, effects?.tail ?? 0), min(30, max(0, settings.tailLimit)))
  }

  func stop() async throws -> CaptureResult {
    guard !isFinalizing else { throw EasyPodError.message("録音の保存を完了しています。") }
    while pauseInProgress || resumeInProgress { try? await Task.sleep(for: .milliseconds(10)) }
    guard let pipeline, let writer, let engine else { throw EasyPodError.message("録音が開始されていません。") }
    isFinalizing = true
    ticker?.cancel()
    ticker = nil
    monitorTask?.cancel()
    await monitorTask?.value
    monitorTask = nil
    await configureMonitoring(false)
    if isPaused {
      await pipeline.finishPaused(latency: liveLatency, tail: liveTail)
    } else {
      await pipeline.pause(latency: liveLatency, tail: liveTail)
    }
    await pipeline.close()
    let pipelineState = await pipeline.snapshot()
    if pipelineState.cleanupError != 0 { Self.pendingInputCleanup.append(pipeline) }
    effects?.detach(from: engine)
    if let sourceNode { engine.detach(sourceNode) }
    ep_pcm_destroy(pipeline.feed)
    ep_pcm_destroy(pipeline.monitorFeed)
    let status = await Task.detached { ep_capture_finalize(writer.pointer) }.value
    if status.sourceError != 0 { warning = storageError(status.sourceError) }
    if pipelineState.inputError != 0 { warning = storageError(pipelineState.inputError) }
    if pipelineState.cleanupError != 0 {
      warning = "録音は保存されましたが、マイクの接続を解放できませんでした（\(pipelineState.cleanupError)）。"
    }
    let processedComplete =
      settings.effectTiming == .duringRecording && !processedFailed
      && pipelineState.processingError == 0 && status.processedError == 0
      && status.processedFrames >= status.sourceFrames
    if settings.effectTiming == .duringRecording, !processedComplete, warning == nil {
      warning = "処理済み音声を最後まで保存できませんでした。オリジナル音声を使用してください。"
    }
    self.pipeline = nil
    self.writer = nil
    self.engine = nil
    self.sourceNode = nil
    self.effects = nil
    isPaused = false
    isFinalizing = false
    let sourceComplete = status.sourceError == 0 && pipelineState.inputError == 0
    onUpdate?(
      CaptureUpdate(
        frameCount: status.sourceFrames, level: 0, peaks: peaks, warning: warning,
        mustStop: !sourceComplete, isPaused: false))
    onUpdate = nil
    return CaptureResult(
      frameCount: status.sourceFrames, processedComplete: processedComplete, warning: warning,
      sourceComplete: sourceComplete)
  }

  private func armSegment(
    worker: CaptureInputPipeline, writer: CaptureWriterHandle, settings: RecordingSettings,
    effects: EffectChain?, hasProcessed: Bool, earliestHostTime: UInt64,
    sourceBaseline: UInt64 = 0, processedBaseline: UInt64 = 0
  ) async throws {
    let boundary = try await CaptureClockReadiness.wait(
      sourceBaseline: sourceBaseline, processedBaseline: processedBaseline,
      sampleRate: settings.sampleRate, earliestHostTime: earliestHostTime,
      isRunning: { ep_capture_status(writer.pointer).sourceError == 0 },
      source: { ep_capture_clock(writer.pointer, false) },
      processed: hasProcessed ? { ep_capture_clock(writer.pointer, true) } : nil)
    let state = await worker.snapshot()
    guard state.inputError == 0 else { throw EasyPodError.message(storageError(state.inputError)) }
    guard !hasProcessed || state.processingError == 0 else {
      throw EasyPodError.message("録音中エフェクトを準備できませんでした（\(state.processingError)）。")
    }
    let latency = hasProcessed ? max(0, effects?.latency ?? 0) : 0
    let frames = (latency * settings.sampleRate).rounded(.up)
    guard frames.isFinite, frames < Double(Int64.max / 2), boundary < Int64.max / 2 - Int64(frames)
    else { throw EasyPodError.message("エフェクトの遅延が対応範囲外です。") }
    try await worker.arm(latencyFrames: UInt64(frames), processed: hasProcessed)
  }

  static func inputFormat(_ hardware: AVAudioFormat) throws -> AVAudioFormat {
    guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0,
      let format = AVAudioFormat(
        standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
    else { throw EasyPodError.message("利用できるマイク入力がありません。") }
    return format
  }

  private func publish() async {
    guard let pipeline, let writer else { return }
    let state = await pipeline.snapshot()
    guard self.pipeline === pipeline, !isFinalizing else { return }
    if !processedFailed, settings.effectTiming == .duringRecording {
      let failure = effects?.processingFailure
      if state.processingError != 0 || failure != nil || effects?.requiresReconfiguration == true {
        processedFailed = true
        await pipeline.disableProcessing()
        warning = "\(failure ?? "エフェクトの音声処理が中断されました。") オリジナル録音は継続します。"
      }
    }
    if state.monitoringError != 0, monitorEngine != nil {
      await configureMonitoring(false)
      warning = "モニター出力が録音に追いつかず中断しました。オリジナル録音は継続します。"
    }
    let status = ep_capture_status(writer.pointer)
    if !isPaused {
      peaks.append(min(1, status.peak))
      if peaks.count > 240 { peaks.removeFirst(peaks.count - 240) }
    }
    let sourceError = status.sourceError != 0 ? status.sourceError : state.inputError
    if sourceError != 0 {
      warning = storageError(sourceError)
      if !isPaused { try? await pause() }
    }
    onUpdate?(
      CaptureUpdate(
        frameCount: status.sourceFrames, level: isPaused ? 0 : min(1, status.level), peaks: peaks,
        warning: warning, mustStop: sourceError != 0, isPaused: isPaused))
  }

  private func storageError(_ code: Int32) -> String {
    if code == -71002 { return "マイクの音声時刻が変わり録音を一時停止しました。保存済みの音声は保持されています。" }
    if code == -71003 { return "マイクの接続または音声形式が変わりました。保存済みの音声は保持されています。" }
    if code == -71001 { return "音声処理または保存が録音に追いつかず一時停止しました。保存済みの音声は保持されています。" }
    return "音声の録音または保存が中断されました（\(code)）。保存済みの音声は保持されています。"
  }
}
