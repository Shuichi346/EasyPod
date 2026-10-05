import AVFoundation
import Foundation
import Observation

// Each closure retains the handoff until AVFAudio retires it. Destruction stays off the render thread.
@MainActor
private final class PlaybackHandoff: @unchecked Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer

  init() throws {
    guard let pointer = ep_playback_create() else {
      throw EasyPodError.message("再生状態を準備できませんでした。")
    }
    self.pointer = pointer
  }

  isolated deinit { ep_playback_destroy(pointer) }
}

@Observable @MainActor
final class PlaybackService {
  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var player: AVAudioPlayerNode?
  @ObservationIgnored private var file: AVAudioFile?
  @ObservationIgnored private var effects: EffectChain?
  @ObservationIgnored private var handoff: PlaybackHandoff?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var onFinish: (@MainActor () -> Void)?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var segmentStartFrame: AVAudioFramePosition = 0
  @ObservationIgnored private var presentationLatency: TimeInterval = 0
  @ObservationIgnored private var effectLatency: TimeInterval = 0
  @ObservationIgnored private var tail: TimeInterval = 0
  @ObservationIgnored private var drainUntil: TimeInterval?
  @ObservationIgnored private var meterTapInstalled = false
  @ObservationIgnored private let manualRendering: Bool

  private(set) var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var level: Float = 0
  private(set) var isPlaying = false
  private(set) var isPaused = false

  // Manual rendering exercises the same graph without a speaker or a wall-clock dependency.
  init(manualRendering: Bool = false) { self.manualRendering = manualRendering }

  isolated deinit {
    ticker?.cancel()
    player?.stop()
    engine?.stop()
    if meterTapInstalled { engine?.mainMixerNode.removeTap(onBus: 0) }
    if let engine { effects?.detach(from: engine) }
  }

  func play(
    url: URL, effects: EffectChain?, startTime: TimeInterval = 0,
    onFinish: @escaping @MainActor () -> Void
  ) throws {
    stop()
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else { throw EasyPodError.message("録音ファイルに音声がありません。") }
    let handoff = try PlaybackHandoff()
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    if let effects {
      effects.attach(
        to: engine, from: player, to: engine.mainMixerNode, format: file.processingFormat)
    } else {
      engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    }
    self.engine = engine
    self.player = player
    self.file = file
    self.effects = effects
    self.handoff = handoff
    self.onFinish = onFinish
    duration = Double(file.length) / file.processingFormat.sampleRate
    do {
      if manualRendering {
        try engine.enableManualRenderingMode(
          .offline, format: file.processingFormat, maximumFrameCount: 4096)
      }
      engine.mainMixerNode.installTap(
        onBus: 0, bufferSize: 1024, format: nil, block: Self.meterTap(handoff: handoff))
      meterTapInstalled = true
      engine.prepare()
      let target = startTime.isNaN ? 0 : min(duration, max(0, startTime))
      let frame =
        target >= duration
        ? file.length
        : AVAudioFramePosition(
          (target * file.processingFormat.sampleRate).rounded(.down))
      currentTime = Double(frame) / file.processingFormat.sampleRate
      if frame == file.length {
        finish()
        return
      }
      schedule(from: frame)
      try startEngine()
      player.play()
      isPlaying = true
      if !manualRendering { startTicker() }
    } catch {
      stop()
      throw error
    }
  }

  func pause() {
    guard isPlaying else { return }
    publish()
    guard isPlaying else { return }
    player?.pause()
    engine?.pause()
    isPlaying = false
    isPaused = true
    level = 0
  }

  func resume() throws {
    guard isPaused, let player else { return }
    guard currentTime < duration || drainUntil != nil else {
      finish()
      return
    }
    do {
      try startEngine()
      player.play()
      isPlaying = true
      isPaused = false
    } catch {
      stop()
      throw error
    }
  }

  func seek(to seconds: TimeInterval) throws {
    guard let file, let player, let engine, !seconds.isNaN else { return }
    let wasPlaying = isPlaying
    let target = min(duration, max(0, seconds))
    // The exact file endpoint avoids a floating-point conversion one frame beyond the file.
    let frame =
      target >= duration
      ? file.length
      : AVAudioFramePosition(
        (target * file.processingFormat.sampleRate).rounded(.down))
    retireSchedule()
    player.stop()
    engine.pause()
    engine.reset()
    effects?.reset()
    currentTime = Double(frame) / file.processingFormat.sampleRate
    level = 0
    isPlaying = false
    isPaused = !wasPlaying
    if frame == file.length {
      segmentStartFrame = frame
      if wasPlaying { finish() }
      return
    }
    schedule(from: frame)
    if wasPlaying {
      do {
        try startEngine()
        player.play()
        isPlaying = true
      } catch {
        stop()
        throw error
      }
    }
  }

  func skip(seconds: TimeInterval) throws {
    if isPlaying { publish() }
    try seek(to: currentTime + seconds)
  }

  func stop() {
    releasePlayback()
    currentTime = 0
    duration = 0
  }

  private func startEngine() throws {
    guard let engine, let player else { return }
    try engine.start()
    // Allocation determines live plugin latency; cached preflight values can be different.
    effectLatency = max(0, effects?.latency ?? 0)
    guard effectLatency.isFinite else {
      throw EasyPodError.message("エフェクトの再生遅延が対応範囲外です。")
    }
    presentationLatency =
      manualRendering
      ? effectLatency
      : max(
        effectLatency, max(0, player.outputPresentationLatency))
    let reportedTail = effects?.tail ?? 0
    tail = reportedTail.isFinite ? min(30, max(0, reportedTail)) : 30
  }

  private func schedule(from frame: AVAudioFramePosition) {
    guard let file, let player, let handoff else { return }
    segmentStartFrame = frame
    drainUntil = nil
    generation += 1
    ep_playback_arm(handoff.pointer, generation)
    var cursor = frame
    // Segment counts are UInt32; consecutive segments also support recordings longer than that.
    while cursor < file.length {
      let count = AVAudioFrameCount(min(Int64(UInt32.max), file.length - cursor))
      let final = cursor + Int64(count) == file.length
      player.scheduleSegment(
        file, startingFrame: cursor, frameCount: count, at: nil,
        completionCallbackType: manualRendering ? .dataRendered : .dataPlayedBack,
        completionHandler: final ? Self.completion(handoff: handoff, generation: generation) : nil)
      cursor += Int64(count)
    }
    player.prepare(withFrameCount: AVAudioFrameCount(min(4096, file.length - frame)))
  }

  private func retireSchedule() {
    generation += 1
    if let handoff { ep_playback_arm(handoff.pointer, generation) }
    drainUntil = nil
  }

  private func releasePlayback() {
    retireSchedule()
    ticker?.cancel()
    ticker = nil
    player?.stop()
    engine?.stop()
    if meterTapInstalled { engine?.mainMixerNode.removeTap(onBus: 0) }
    meterTapInstalled = false
    if let engine { effects?.detach(from: engine) }
    engine = nil
    player = nil
    file = nil
    effects = nil
    handoff = nil
    onFinish = nil
    isPlaying = false
    isPaused = false
    level = 0
  }

  private func finish() {
    let completion = onFinish
    let end = duration
    releasePlayback()
    currentTime = end
    duration = end
    completion?()
  }

  private func startTicker() {
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, let self else { return }
        self.publish()
      }
    }
  }

  private func publish() {
    guard isPlaying, let player, let file, let handoff else { return }
    let seconds: Double
    if manualRendering, let engine {
      seconds = Double(engine.manualRenderingSampleTime) / engine.manualRenderingFormat.sampleRate
    } else {
      guard let rendered = player.lastRenderTime,
        let time = player.playerTime(forNodeTime: rendered), time.isSampleTimeValid,
        time.sampleRate > 0
      else { return }
      seconds = Double(time.sampleTime) / time.sampleRate
    }
    let offset = Double(segmentStartFrame) / file.processingFormat.sampleRate
    currentTime = min(duration, max(offset, offset + seconds - presentationLatency))
    let status = ep_playback_status(handoff.pointer, generation)
    level = min(1, max(0, status.level))
    if manualRendering {
      // Offline completion is measured on the render clock, including the effect's drain.
      if seconds >= duration - offset + effectLatency + tail { finish() }
    } else if status.completed {
      currentTime = duration
      if drainUntil == nil { drainUntil = seconds + tail }
      if seconds >= (drainUntil ?? seconds) { finish() }
    }
  }

  private nonisolated static func meterTap(handoff: PlaybackHandoff) -> AVAudioNodeTapBlock {
    let callback: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
      ep_playback_meter(handoff.pointer, buffer.audioBufferList, buffer.frameLength)
    }
    return callback
  }

  private nonisolated static func completion(handoff: PlaybackHandoff, generation: UInt64)
    -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
  {
    { _ in ep_playback_complete(handoff.pointer, generation) }
  }

  // The test driver supplies its own PCM buffer, so this seam never renders to an audio device.
  func renderPreview(frames: AVAudioFrameCount, into buffer: AVAudioPCMBuffer) throws
    -> AVAudioEngineManualRenderingStatus
  {
    guard manualRendering, let engine, let handoff, isPlaying else {
      throw EasyPodError.message("オフライン再生が開始されていません。")
    }
    let result = try engine.renderOffline(frames, to: buffer)
    // Offline taps may be delivered later; the rendered output provides deterministic meter PCM.
    ep_playback_meter(handoff.pointer, buffer.audioBufferList, buffer.frameLength)
    publish()
    return result
  }
}
