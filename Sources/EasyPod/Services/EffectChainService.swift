import AVFoundation
import AudioToolbox
import Foundation

enum EffectChainError: LocalizedError {
  case unavailable(String)
  case unsupportedFormat(String)
  case invalidState(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message), .unsupportedFormat(let message), .invalidState(let message):
      message
    }
  }
}

@MainActor
final class EffectChainService {
  func build(
    slots: [EffectSlot], sampleRate: Double, channels: Int, offline: Bool = false
  ) async throws -> EffectChain {
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
      channels == 1 || channels == 2
    else {
      throw EffectChainError.unsupportedFormat("モノラルまたはステレオの音声形式を選んでください。")
    }
    EPVST3AudioUnit.registerComponent()
    var nodes: [EffectChain.Entry] = []
    for slot in slots {
      if let reason = slot.plugin.unavailableReason { throw EffectChainError.unavailable(reason) }
      let unit: AVAudioUnit
      if slot.plugin.format == .vst3 {
        guard let path = slot.plugin.path, let classID = slot.plugin.classID,
          FileManager.default.fileExists(atPath: path)
        else {
          throw EffectChainError.unavailable("\(slot.plugin.name) が見つかりません。")
        }
        unit = try await AVAudioUnit.instantiate(
          with: EPVST3AudioUnit.componentDescription(), options: [])
        guard let adapter = unit.auAudioUnit as? EPVST3AudioUnit else {
          throw EffectChainError.unavailable("VST3 ホストを初期化できません。")
        }
        try adapter.configure(
          path: path, classID: classID, sampleRate: sampleRate, channels: channels, offline: offline
        )
      } else {
        guard let type = slot.plugin.componentType, let subtype = slot.plugin.componentSubType,
          let manufacturer = slot.plugin.componentManufacturer
        else {
          throw EffectChainError.unavailable("AU の識別情報がありません。")
        }
        let description = AudioComponentDescription(
          componentType: type, componentSubType: subtype, componentManufacturer: manufacturer,
          componentFlags: 0, componentFlagsMask: 0)
        unit = try await AVAudioUnit.instantiate(with: description, options: [])
      }
      let au = unit.auAudioUnit
      au.isRenderingOffline = offline
      au.maximumFramesToRender = 4096
      if let state = slot.state {
        if let adapter = au as? EPVST3AudioUnit {
          try adapter.restorePluginState(state)
        } else {
          guard
            let saved = try PropertyListSerialization.propertyList(from: state, format: nil)
              as? [String: Any]
          else {
            throw EffectChainError.invalidState("\(slot.plugin.name) の保存状態を読み込めません。")
          }
          au.fullStateForDocument = saved
        }
      }
      guard au.inputBusses.count > 0, au.outputBusses.count > 0 else {
        throw EffectChainError.unsupportedFormat("\(slot.plugin.name) に音声入力／出力がありません。")
      }
      let processingFormat: AVAudioFormat
      do {
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        processingFormat = format
      } catch {
        guard slot.plugin.format == .au,
          let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { throw error }
        do {
          try au.inputBusses[0].setFormat(stereo)
          try au.outputBusses[0].setFormat(stereo)
          processingFormat = stereo
        } catch {
          throw EffectChainError.unsupportedFormat(
            "\(slot.plugin.name) は選択した音声形式で処理できません。\(error.localizedDescription)")
        }
      }
      // Setup failures are reported before an effect is inserted into the capture graph.
      try au.allocateRenderResources()
      au.deallocateRenderResources()
      au.shouldBypassEffect = slot.bypassed
      nodes.append(EffectChain.Entry(slot: slot, unit: unit, format: processingFormat))
    }
    return EffectChain(entries: nodes, format: format)
  }
}

@MainActor
final class EffectChain {
  struct Entry {
    var slot: EffectSlot
    let unit: AVAudioUnit
    let format: AVAudioFormat
  }

  private var entries: [Entry]
  private let format: AVAudioFormat
  private var converters: [AVAudioMixerNode] = []
  private let editors = PluginEditorService()
  private var attachment: AVAudioEngine?

  var units: [AVAudioUnit] { entries.map(\.unit) }
  var latency: TimeInterval { units.reduce(0) { $0 + $1.auAudioUnit.latency } }
  var tail: TimeInterval { units.reduce(0) { $0 + $1.auAudioUnit.tailTime } }
  var hasInfiniteTail: Bool { !tail.isFinite }
  var requiresReconfiguration: Bool {
    units.contains { ($0.auAudioUnit as? EPVST3AudioUnit)?.requiresReconfiguration == true }
  }
  var processingFailure: String? {
    for entry in entries {
      if let adapter = entry.unit.auAudioUnit as? EPVST3AudioUnit {
        if adapter.processingFailure != 0 {
          return "\(entry.slot.plugin.name) の音声処理に失敗しました (\(adapter.processingFailure))。原音は保持します。"
        }
        if adapter.requiresReconfiguration {
          return "\(entry.slot.plugin.name) の遅延または音声バスが変化しました。録音停止後に再構成してください。"
        }
      }
    }
    return nil
  }

  init(entries: [Entry], format: AVAudioFormat) {
    self.entries = entries
    self.format = format
  }

  func attach(
    to engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode,
    format: AVAudioFormat
  ) {
    precondition(!engine.isRunning, "Effect graph changes require a stopped engine")
    if let previous = attachment { detach(from: previous) }
    attachment = engine
    var previous = source
    var previousFormat = format
    for entry in entries {
      engine.attach(entry.unit)
      if previousFormat.channelCount != entry.format.channelCount {
        let converter = AVAudioMixerNode()
        engine.attach(converter)
        converters.append(converter)
        engine.connect(previous, to: converter, format: previousFormat)
        previous = converter
      }
      engine.connect(previous, to: entry.unit, format: entry.format)
      previous = entry.unit
      previousFormat = entry.format
    }
    if previousFormat.channelCount != format.channelCount {
      let converter = AVAudioMixerNode()
      engine.attach(converter)
      converters.append(converter)
      engine.connect(previous, to: converter, format: previousFormat)
      previous = converter
    }
    engine.connect(previous, to: destination, format: format)
  }

  func detach(from engine: AVAudioEngine) {
    guard attachment === engine else { return }
    precondition(!engine.isRunning, "Effect graph changes require a stopped engine")
    for node in units {
      engine.disconnectNodeOutput(node)
      engine.detach(node)
    }
    for node in converters {
      engine.disconnectNodeOutput(node)
      engine.detach(node)
    }
    converters.removeAll()
    attachment = nil
  }

  func snapshot() throws -> [EffectSlot] {
    try entries.map { entry in
      var slot = entry.slot
      let au = entry.unit.auAudioUnit
      slot.bypassed = au.shouldBypassEffect
      if let adapter = au as? EPVST3AudioUnit {
        slot.state = try adapter.savePluginState()
      } else if let state = au.fullStateForDocument ?? au.fullState {
        slot.state = try PropertyListSerialization.data(
          fromPropertyList: state, format: .binary, options: 0)
      }
      return slot
    }
  }

  func setBypass(id: UUID, bypassed: Bool) {
    guard let index = entries.firstIndex(where: { $0.slot.id == id }) else { return }
    entries[index].slot.bypassed = bypassed
    entries[index].unit.auAudioUnit.shouldBypassEffect = bypassed
  }

  func showEditor(id: UUID) {
    guard let entry = entries.first(where: { $0.slot.id == id }) else { return }
    editors.show(id: id, title: entry.slot.plugin.name, unit: entry.unit)
  }

  func reset() {
    precondition(attachment?.isRunning != true, "Plugin reset requires a stopped engine")
    for unit in units { unit.auAudioUnit.reset() }
  }
}
