import Foundation
import Observation

@MainActor @Observable final class PreferencesStore {
  var settings: RecordingSettings { didSet { save() } }
  var modelPath: String { didSet { save() } }
  var transcriptionEnabled: Bool { didSet { save() } }
  var transcriptionLanguage: TranscriptionLanguage { didSet { save() } }
  var inputID: UInt32? {
    didSet {
      guard !refreshingInput else { return }
      inputUID = inputID.map { id in
        if let device = deviceLookup(id), !device.uid.isEmpty { return device.uid }
        return "unavailable-legacy:\(id)"
      }
      save()
    }
  }
  private(set) var inputUID: String?
  private var refreshingInput = false
  private let deviceLookup: @MainActor (UInt32) -> CaptureDeviceInfo?
  private let uidResolver: @MainActor (String) -> UInt32?

  private let defaults: UserDefaults

  init(
    defaults: UserDefaults = .standard,
    deviceLookup: @escaping @MainActor (UInt32) -> CaptureDeviceInfo? = AudioDeviceService
      .deviceInfo,
    uidResolver: @escaping @MainActor (String) -> UInt32? = AudioDeviceService.deviceID
  ) {
    self.defaults = defaults
    self.deviceLookup = deviceLookup
    self.uidResolver = uidResolver
    settings =
      defaults.data(forKey: "recordingSettings")
      .flatMap { try? JSONDecoder().decode(RecordingSettings.self, from: $0) }
      ?? RecordingSettings()
    modelPath = defaults.string(forKey: "modelPath") ?? UserPath.defaultModel
    transcriptionEnabled = defaults.object(forKey: "transcriptionEnabled") as? Bool ?? true
    // Preserve Japanese recognition for preferences saved before language selection existed.
    transcriptionLanguage =
      defaults.string(forKey: "transcriptionLanguage")
      .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .japanese
    let legacyID = (defaults.object(forKey: "inputID") as? NSNumber)?.uint32Value
    if let uid = defaults.string(forKey: "inputUID"), !uid.isEmpty {
      inputUID = uid
      inputID = uidResolver(uid) ?? UInt32.max
    } else if let legacyID {
      let device = deviceLookup(legacyID)
      inputUID =
        device?.isAlive == true && (device?.inputChannels ?? 0) > 0 && device?.uid.isEmpty == false
        ? device?.uid : "unavailable-legacy:\(legacyID)"
      inputID = legacyID
    } else {
      inputUID = nil
      inputID = nil
    }
    // Numeric object IDs are session-local; migrate known devices to their persistent identity.
    defaults.set(inputUID, forKey: "inputUID")
  }

  func refreshInputIdentity() {
    guard let inputUID else { return }
    refreshingInput = true
    inputID = uidResolver(inputUID) ?? UInt32.max
    refreshingInput = false
  }

  func captureInputID() throws -> UInt32? {
    guard let inputUID else { return nil }
    guard let id = uidResolver(inputUID), let device = deviceLookup(id),
      device.uid == inputUID, device.isAlive, device.inputChannels > 0
    else {
      throw EasyPodError.message("選択したマイクを利用できません。接続を確認するか、入力デバイスを選び直してください。")
    }
    return id
  }

  private func save() {
    if let data = try? JSONEncoder().encode(settings) {
      defaults.set(data, forKey: "recordingSettings")
    }
    defaults.set(modelPath, forKey: "modelPath")
    defaults.set(transcriptionEnabled, forKey: "transcriptionEnabled")
    defaults.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage")
    defaults.set(inputUID, forKey: "inputUID")
    defaults.removeObject(forKey: "inputID")
  }
}
