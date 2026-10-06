import Foundation
import Observation

@MainActor @Observable final class PreferencesStore {
  var settings: RecordingSettings { didSet { save() } }
  var modelPath: String { didSet { save() } }
  var transcriptionEnabled: Bool { didSet { save() } }
  var transcriptionLanguage: TranscriptionLanguage { didSet { save() } }
  var inputID: UInt32? { didSet { save() } }
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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
    inputID = (defaults.object(forKey: "inputID") as? NSNumber)?.uint32Value
  }

  private func save() {
    if let data = try? JSONEncoder().encode(settings) {
      defaults.set(data, forKey: "recordingSettings")
    }
    defaults.set(modelPath, forKey: "modelPath")
    defaults.set(transcriptionEnabled, forKey: "transcriptionEnabled")
    defaults.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage")
    defaults.set(inputID, forKey: "inputID")
  }
}
