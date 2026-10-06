import Foundation

enum TranscriptionLanguage: String, CaseIterable, Sendable {
  case auto = "auto"
  case japanese = "ja-JP"
  case english = "en-US"

  var label: String {
    switch self {
    case .auto: "オート"
    case .japanese: "日本語"
    case .english: "英語"
    }
  }
}

enum ExportFormat: String, Codable, CaseIterable, Sendable {
  case wav, m4a
  var label: String { rawValue.uppercased() }
}

enum EffectTiming: String, Codable, CaseIterable, Sendable {
  case afterRecording, duringRecording
  var label: String { self == .afterRecording ? "録音後" : "録音中" }
}

struct RecordingSettings: Codable, Equatable, Sendable {
  var format: ExportFormat = .wav
  var bitDepth: Int = 24
  var sampleRate: Double = 48_000
  var channels: Int = 1
  var bitrate: Int = 192_000
  var tailLimit: Double = 10
  var effectTiming: EffectTiming = .afterRecording
}

enum ExportSource: String, CaseIterable, Sendable {
  case original, processed
  var label: String { self == .original ? "オリジナル" : "録音中の処理済み音声" }
}

struct ExportRequest: Sendable {
  var source: ExportSource = .original
  var includeEffects = true
  var settings: RecordingSettings
  var splitOversizedWAV = false
}

enum EasyPodError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let text): text
    }
  }
}
