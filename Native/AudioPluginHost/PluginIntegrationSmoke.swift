import AVFoundation
import Foundation

@main
struct PluginIntegrationSmoke {
  @MainActor
  static func main() async throws {
    // An external timeout is preferred; this guard avoids indefinite waits without invoking plugin finalizers from a worker.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { _exit(124) }
    func stage(_ name: String) {
      print(name)
      fflush(stdout)
    }
    stage("AU component discovery")
    let component = AVAudioUnitComponentManager.shared().components(
      matching: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0,
        componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
    ).first { $0.name.localizedCaseInsensitiveContains("Supercharger") }
    guard let component else {
      throw EffectChainError.unavailable("Installed Supercharger AU is missing")
    }
    let code = component.audioComponentDescription
    let au = PluginDescriptor(
      id: "au-smoke", name: component.name, manufacturer: component.manufacturerName,
      format: .au, componentType: code.componentType, componentSubType: code.componentSubType,
      componentManufacturer: code.componentManufacturer, version: component.versionString)
    let vst = PluginDescriptor(
      id: "vst-smoke", name: "DeepFilter Noise Reduction", manufacturer: "DeepFilterNet",
      format: .vst3,
      path: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Audio/Plug-Ins/VST3/deepfilter-vst.vst3").path,
      classID: "4465657046696C7465724E5230303100", version: "0.7.0")
    let chain = try await EffectChainService().build(
      slots: [EffectSlot(plugin: au), EffectSlot(plugin: vst)], sampleRate: 48000, channels: 1,
      offline: true)
    stage("mixed chain built")
    var editedValue: AUValue?
    if let parameter = chain.units.last?.auAudioUnit.parameterTree?.allParameters.first(where: {
      $0.flags.contains(.flag_IsWritable)
    }) {
      editedValue = parameter.minValue + 0.35 * (parameter.maxValue - parameter.minValue)
      parameter.value = editedValue!
    }
    let snapshot = try chain.snapshot()
    guard snapshot.allSatisfy({ $0.state != nil }) else {
      throw EffectChainError.invalidState("Plugin state was not saved")
    }
    let restored = try await EffectChainService().build(
      slots: snapshot, sampleRate: 48000, channels: 1, offline: true)
    stage("mixed state restored")
    if let editedValue,
      let parameter = restored.units.last?.auAudioUnit.parameterTree?.allParameters.first(where: {
        $0.flags.contains(.flag_IsWritable)
      })
    {
      guard abs(parameter.value - editedValue) < 0.0001 else {
        throw EffectChainError.invalidState("Edited parameter was not restored")
      }
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    restored.attach(to: engine, from: player, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 51200)!
    input.frameLength = 51200
    for frame in 0..<51200 {
      input.floatChannelData![0][frame] = 0.2 * sin(Float(frame) * 2 * .pi * 220 / 48000)
    }
    player.scheduleBuffer(input, completionHandler: nil)
    try engine.start()
    stage("engine started")
    player.play()
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    var peak: Float = 0
    var rendered = 0
    for _ in 0..<60 {
      switch try engine.renderOffline(1024, to: output) {
      case .success:
        rendered += Int(output.frameLength)
        for frame in 0..<Int(output.frameLength) {
          let value = output.floatChannelData![0][frame]
          guard value.isFinite else {
            throw EffectChainError.unavailable("Nonfinite mixed-chain audio")
          }
          peak = max(peak, abs(value))
        }
      case .cannotDoInCurrentContext: continue
      default: throw EffectChainError.unavailable("Offline render could not provide audio")
      }
    }
    engine.stop()
    stage("engine rendered")
    if let failure = restored.processingFailure { throw EffectChainError.unavailable(failure) }
    restored.reset()
    restored.detach(from: engine)
    restored.detach(from: engine)
    guard peak > 0.001, rendered >= 51200 else {
      throw EffectChainError.unavailable("Mixed chain did not render audible audio")
    }
    print(
      "mixedRenderFrames=\(rendered) peak=\(peak) latency=\(restored.latency) stateRestoration=passed"
    )
  }
}
