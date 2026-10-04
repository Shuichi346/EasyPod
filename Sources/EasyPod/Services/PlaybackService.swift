import AVFoundation
import Foundation

@MainActor
final class PlaybackService {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var file: AVAudioFile?
  private var effects: EffectChain?
  private var generation = UUID()
  private(set) var isPlaying = false

  func play(url: URL, effects: EffectChain?, onFinish: @escaping @MainActor () -> Void) throws {
    stop()
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else { throw EasyPodError.message("録音ファイルに音声がありません。") }
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
    generation = UUID()
    let currentGeneration = generation
    player.scheduleFile(
      file, at: nil, completionCallbackType: .dataPlayedBack,
      completionHandler: Self.completion(
        service: self, generation: currentGeneration,
        onFinish: onFinish))
    do {
      engine.prepare()
      try engine.start()
      player.play()
      isPlaying = true
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    generation = UUID()
    player?.stop()
    engine?.stop()
    if let engine { effects?.detach(from: engine) }
    engine = nil
    player = nil
    file = nil
    effects = nil
    isPlaying = false
  }

  private nonisolated static func completion(
    service: PlaybackService, generation: UUID,
    onFinish: @escaping @MainActor () -> Void
  )
    -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
  {
    { [weak service] _ in
      Task { @MainActor in await service?.finish(generation: generation, onFinish: onFinish) }
    }
  }

  private func finish(generation: UUID, onFinish: @escaping @MainActor () -> Void) async {
    guard self.generation == generation else { return }
    let tail = min(30, max(0, effects?.tail ?? 0))
    if tail > 0 { try? await Task.sleep(for: .seconds(tail)) }
    guard self.generation == generation else { return }
    stop()
    onFinish()
  }
}
