import AVFoundation
import Darwin
import Foundation

struct WAVSplitRequiredError: LocalizedError, Sendable {
  let partCount: Int
  var errorDescription: String? {
    "WAV の 4 GB 制限を超えます。\(partCount) 個の WAV ファイルに分割して書き出してください。"
  }
}

private final class ExportCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  func check() throws {
    if lock.withLock({ cancelled }) { throw CancellationError() }
  }
}

// Configured on MainActor, then exclusively rendered by one export worker.
private final class ExportRenderContext: @unchecked Sendable {
  let engine: AVAudioEngine
  let player: AVAudioPlayerNode
  let file: AVAudioFile
  let units: [AVAudioUnit]
  let format: AVAudioFormat
  private(set) var latency: Double = 0
  private(set) var tail: Double = 0
  private let tailLimit: Double

  @MainActor
  init(source: URL, settings: RecordingSettings, effects: EffectChain?) throws {
    file = try AVAudioFile(forReading: source)
    guard file.length > 0,
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: settings.sampleRate,
        channels: AVAudioChannelCount(settings.channels),
        interleaved: false)
    else { throw EasyPodError.message("書き出す音声がありません。") }
    format = outputFormat
    engine = AVAudioEngine()
    player = AVAudioPlayerNode()
    units = effects?.units ?? []
    tailLimit = min(30, max(0, settings.tailLimit))
    engine.attach(player)
    if let effects {
      effects.attach(
        to: engine, from: player, to: engine.mainMixerNode, format: file.processingFormat)
    } else {
      engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    }
  }

  func configure(realtime: Bool) throws {
    player.stop()
    engine.stop()
    engine.disableManualRenderingMode()
    engine.reset()
    for unit in units {
      unit.auAudioUnit.reset()
      unit.auAudioUnit.isRenderingOffline = !realtime
    }
    file.framePosition = 0
    try engine.enableManualRenderingMode(
      realtime ? .realtime : .offline,
      format: format, maximumFrameCount: 4096)
    player.scheduleFile(file, at: nil)
    try engine.start()
    // Actual render allocation can change a plugin's preflight latency and tail.
    latency = max(0, units.reduce(0) { $0 + $1.auAudioUnit.latency })
    tail = min(max(0, units.reduce(0) { $0 + $1.auAudioUnit.tailTime }), tailLimit)
    guard latency.isFinite, latency < Double(Int64.max / 2) / format.sampleRate else {
      throw EasyPodError.message("エフェクトの遅延が対応範囲外です。")
    }
    player.play()
  }

  func stop() {
    player.stop()
    engine.stop()
    engine.disableManualRenderingMode()
  }
}

private final class ExportFileWriter {
  private let destination: URL
  private let settings: RecordingSettings
  private let format: AVAudioFormat
  private let maximumFramesPerPart: Int64
  private let split: Bool
  private var file: AVAudioFile?
  private var partFrames: Int64 = 0
  private var temporaryURLs: [URL] = []
  private var finalURLs: [URL] = []
  private var published: [URL] = []
  private var completed = false

  init(
    destination: URL, settings: RecordingSettings, format: AVAudioFormat,
    totalFrames: Int64, splitAllowed: Bool
  ) throws {
    self.destination = destination
    self.settings = settings
    self.format = format
    let bytesPerFrame = Int64(settings.channels * settings.bitDepth / 8)
    maximumFramesPerPart =
      settings.format == .wav ? (Int64(UInt32.max) - 4096) / bytesPerFrame : Int64.max
    split = settings.format == .wav && totalFrames > maximumFramesPerPart
    if split && !splitAllowed {
      throw WAVSplitRequiredError(
        partCount: Int((totalFrames + maximumFramesPerPart - 1) / maximumFramesPerPart))
    }
    let parent = destination.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: parent.path) else {
      throw EasyPodError.message("書き出し先のフォルダが存在しません。")
    }
    let estimatedBytes =
      settings.format == .wav
      ? totalFrames * bytesPerFrame + 4096
      : Int64(Double(totalFrames) / settings.sampleRate * Double(settings.bitrate) / 8) + 1_048_576
    let values = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    if let available = values.volumeAvailableCapacityForImportantUsage,
      available < estimatedBytes + 16_777_216
    {
      throw EasyPodError.message("書き出し先の空き容量が不足しています。")
    }
    try openPart()
  }

  private func openPart() throws {
    let parent = destination.deletingLastPathComponent()
    let extensionName = settings.format.rawValue
    let index = finalURLs.count + 1
    let final =
      split
      ? parent.appendingPathComponent(
        "\(destination.deletingPathExtension().lastPathComponent)-\(String(format: "%03d", index)).\(extensionName)"
      )
      : destination
    if split, FileManager.default.fileExists(atPath: final.path) {
      throw EasyPodError.message("分割ファイル \(final.lastPathComponent) はすでに存在します。別の名前を選択してください。")
    }
    let temporary = parent.appendingPathComponent(".easypod-\(UUID().uuidString).\(extensionName)")
    var outputSettings: [String: Any] = [
      AVSampleRateKey: settings.sampleRate,
      AVNumberOfChannelsKey: settings.channels,
    ]
    switch settings.format {
    case .wav:
      outputSettings[AVFormatIDKey] = kAudioFormatLinearPCM
      outputSettings[AVLinearPCMBitDepthKey] = settings.bitDepth
      outputSettings[AVLinearPCMIsFloatKey] = settings.bitDepth == 32
      outputSettings[AVLinearPCMIsBigEndianKey] = false
      outputSettings[AVLinearPCMIsNonInterleaved] = false
    case .m4a:
      outputSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
      outputSettings[AVEncoderBitRateKey] = settings.bitrate
      outputSettings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
    }
    temporaryURLs.append(temporary)
    finalURLs.append(final)
    file = try AVAudioFile(
      forWriting: temporary, settings: outputSettings,
      commonFormat: .pcmFormatFloat32, interleaved: false)
    partFrames = 0
  }

  func append(_ buffer: AVAudioPCMBuffer, start: Int, count: Int) throws {
    var offset = start
    var remaining = count
    while remaining > 0 {
      if partFrames >= maximumFramesPerPart {
        file = nil
        try openPart()
      }
      let amount = min(remaining, Int(maximumFramesPerPart - partFrames))
      guard
        let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(amount)),
        let source = buffer.floatChannelData, let target = slice.floatChannelData
      else { throw EasyPodError.message("書き出しバッファを確保できませんでした。") }
      slice.frameLength = AVAudioFrameCount(amount)
      let integerOutput = settings.format == .wav && settings.bitDepth != 32
      let ceiling: Float =
        integerOutput ? 1 - pow(2, Float(1 - settings.bitDepth)) : Float.greatestFiniteMagnitude
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<amount {
          let sample = source[channel][offset + frame]
          target[channel][frame] =
            sample.isFinite
            ? min(ceiling, max(integerOutput ? -1 : -Float.greatestFiniteMagnitude, sample)) : 0
        }
      }
      try file?.write(from: slice)
      partFrames += Int64(amount)
      offset += amount
      remaining -= amount
    }
  }

  func finish(cancellation: ExportCancellation) throws -> [URL] {
    // Releasing AVAudioFile finalizes AAC packets and container headers before publication.
    file = nil
    for url in temporaryURLs {
      let descriptor = Darwin.open(url.path, O_RDONLY)
      guard descriptor >= 0 else { throw POSIXError(.EIO) }
      let result = fsync(descriptor)
      Darwin.close(descriptor)
      guard result == 0 else { throw POSIXError(.EIO) }
    }
    try cancellation.check()
    if split {
      // Exclusively create each final name; rollback only files created by this export.
      for (temporary, final) in zip(temporaryURLs, finalURLs) {
        guard link(temporary.path, final.path) == 0 else {
          throw EasyPodError.message("分割ファイルを確定できませんでした（\(errno)）。")
        }
        published.append(final)
      }
      for url in temporaryURLs { try FileManager.default.removeItem(at: url) }
    } else {
      guard let temporary = temporaryURLs.first, let final = finalURLs.first,
        rename(temporary.path, final.path) == 0
      else {
        throw EasyPodError.message("書き出しファイルを確定できませんでした（\(errno)）。")
      }
    }
    completed = true
    return finalURLs
  }

  deinit {
    file = nil
    if !completed {
      for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
      for url in published { try? FileManager.default.removeItem(at: url) }
    }
  }
}

private enum OfflineExportError: Error { case cannotRender }

private final class ExportWorker: @unchecked Sendable {
  let context: ExportRenderContext
  let settings: RecordingSettings
  let destination: URL
  let splitAllowed: Bool
  let cancellation: ExportCancellation

  init(
    context: ExportRenderContext, settings: RecordingSettings, destination: URL,
    splitAllowed: Bool, cancellation: ExportCancellation
  ) {
    self.context = context
    self.settings = settings
    self.destination = destination
    self.splitAllowed = splitAllowed
    self.cancellation = cancellation
  }

  func run(realtime: Bool, progress: @escaping @Sendable (Double) -> Void) throws -> [URL] {
    defer { context.stop() }
    return try render(realtime: realtime, progress: progress)
  }

  private func render(realtime: Bool, progress: @escaping @Sendable (Double) -> Void) throws
    -> [URL]
  {
    do { try context.configure(realtime: realtime) } catch {
      if !realtime { throw OfflineExportError.cannotRender }
      throw error
    }
    let sourceFrames = Int64(
      (Double(context.file.length) * settings.sampleRate / context.file.processingFormat.sampleRate)
        .rounded(.up))
    let skipFrames = Int64((context.latency * settings.sampleRate).rounded(.up))
    let tailFrames = Int64((context.tail * settings.sampleRate).rounded(.up))
    let outputFrames = sourceFrames + tailFrames
    let renderFrames = outputFrames + skipFrames
    let writer = try ExportFileWriter(
      destination: destination, settings: settings, format: context.format,
      totalFrames: outputFrames, splitAllowed: splitAllowed)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: context.format, frameCapacity: 4096) else {
      throw EasyPodError.message("書き出しバッファを確保できませんでした。")
    }
    var rendered: Int64 = 0
    var stalled = 0
    var lastProgress = ContinuousClock.now
    let realtimeBlock = context.engine.manualRenderingBlock
    while rendered < renderFrames {
      try cancellation.check()
      let amount = AVAudioFrameCount(min(4096, renderFrames - rendered))
      let status: AVAudioEngineManualRenderingStatus
      do {
        if realtime {
          var code: OSStatus = noErr
          status = realtimeBlock(amount, buffer.mutableAudioBufferList, &code)
          if code != noErr { throw EasyPodError.message("エフェクトを処理できませんでした（\(code)）。") }
          buffer.frameLength = amount
        } else {
          status = try context.engine.renderOffline(amount, to: buffer)
        }
      } catch {
        if !realtime { throw OfflineExportError.cannotRender }
        throw error
      }
      switch status {
      case .success:
        stalled = 0
        let skipped = Int(min(Int64(buffer.frameLength), max(0, skipFrames - rendered)))
        let count = Int(buffer.frameLength) - skipped
        if count > 0 { try writer.append(buffer, start: skipped, count: count) }
        rendered += Int64(buffer.frameLength)
        if realtime {
          Thread.sleep(forTimeInterval: Double(amount) / settings.sampleRate)
        }
      case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
        stalled += 1
        if stalled > 64 {
          if !realtime { throw OfflineExportError.cannotRender }
          throw EasyPodError.message("エフェクトの音声処理が進みませんでした。オリジナル音声は保持されています。")
        }
        Thread.sleep(forTimeInterval: 0.002)
      case .error:
        if !realtime { throw OfflineExportError.cannotRender }
        throw EasyPodError.message("エフェクトの音声処理に失敗しました。")
      @unknown default:
        throw EasyPodError.message("音声エンジンが未対応の結果を返しました。")
      }
      let now = ContinuousClock.now
      if now - lastProgress > .milliseconds(100) {
        progress(min(0.99, Double(rendered) / Double(max(1, renderFrames))))
        lastProgress = now
      }
    }
    context.stop()
    let result = try writer.finish(cancellation: cancellation)
    progress(1)
    return result
  }
}

@MainActor
final class AudioExportService {
  private var active: ExportCancellation?

  func export(
    session: RecordingSession, directory: URL, destination: URL,
    request: ExportRequest, effects: EffectChain?,
    onProgress: @escaping @MainActor @Sendable (Double) -> Void
  ) async throws -> [URL] {
    guard active == nil else { throw EasyPodError.message("書き出しはすでに実行中です。") }
    guard session.status == .completed || session.status == .interrupted else {
      throw EasyPodError.message("録音を停止してから書き出してください。")
    }
    let settings = request.settings
    guard [44_100.0, 48_000.0].contains(settings.sampleRate), [1, 2].contains(settings.channels),
      [16, 24, 32].contains(settings.bitDepth),
      [96_000, 128_000, 192_000, 256_000].contains(settings.bitrate)
    else {
      throw EasyPodError.message("書き出しの品質設定が対応範囲外です。")
    }
    if request.source == .processed && !session.processedComplete {
      throw EasyPodError.message("処理済み音声は完全に保存されていません。オリジナル音声を選択してください。")
    }
    let source = directory.appendingPathComponent(
      request.source == .processed ? "processed.caf" : "source.caf")
    guard destination.standardizedFileURL != source.standardizedFileURL else {
      throw EasyPodError.message("オリジナルの録音ファイルを上書きできません。別の書き出し先を選択してください。")
    }
    // Saved live audio already contains its recording chain; applying it again changes the sound.
    let selectedEffects = request.source == .original && request.includeEffects ? effects : nil
    let capturedSlots = try selectedEffects?.snapshot() ?? []
    let context = try ExportRenderContext(
      source: source, settings: settings, effects: selectedEffects)
    let token = ExportCancellation()
    active = token
    defer {
      active = nil
      selectedEffects?.detach(from: context.engine)
    }
    onProgress(0)
    return try await withTaskCancellationHandler {
      do {
        return try await run(
          context: context, settings: settings, destination: destination,
          splitAllowed: request.splitOversizedWAV, token: token,
          realtime: false, onProgress: onProgress)
      } catch OfflineExportError.cannotRender {
        try token.check()
        selectedEffects?.detach(from: context.engine)
        // Native VST processing mode is fixed during setup, so fallback uses new instances.
        let realtimeEffects =
          capturedSlots.isEmpty
          ? nil
          : try await EffectChainService().build(
            slots: capturedSlots, sampleRate: context.file.processingFormat.sampleRate,
            channels: Int(context.file.processingFormat.channelCount), offline: false)
        let realtimeContext = try ExportRenderContext(
          source: source, settings: settings,
          effects: realtimeEffects)
        defer { realtimeEffects?.detach(from: realtimeContext.engine) }
        return try await run(
          context: realtimeContext, settings: settings, destination: destination,
          splitAllowed: request.splitOversizedWAV, token: token,
          realtime: true, onProgress: onProgress)
      }
    } onCancel: {
      token.cancel()
    }
  }

  func cancel() { active?.cancel() }

  private func run(
    context: ExportRenderContext, settings: RecordingSettings, destination: URL,
    splitAllowed: Bool, token: ExportCancellation, realtime: Bool,
    onProgress: @escaping @MainActor @Sendable (Double) -> Void
  ) async throws -> [URL] {
    let worker = ExportWorker(
      context: context, settings: settings, destination: destination,
      splitAllowed: splitAllowed, cancellation: token)
    return try await Task.detached(priority: .userInitiated) {
      try worker.run(realtime: realtime) { progress in
        Task { @MainActor in onProgress(progress) }
      }
    }.value
  }
}
