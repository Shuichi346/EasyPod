import Foundation

enum SessionStatus: String, Codable, Sendable {
  case recording, paused, finalizing, completed, interrupted
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
  var id = UUID()
  var start: Double
  var end: Double
  var text: String
  var isFinal: Bool
}

struct RecordingSession: Identifiable, Codable, Sendable {
  var id = UUID()
  var title: String
  var folderID: UUID?
  var createdAt = Date()
  var settings = RecordingSettings()
  var status: SessionStatus = .recording
  var frameCount: Int64 = 0
  var processedComplete = false
  var effects: [EffectSlot] = []
  var transcript: [TranscriptSegment] = []
  var transcriptionStatus: String?
  var originalTranscript: [TranscriptSegment]?
  var originalTranscriptionStatus: String?
  var warning: String?
  var duration: Double { Double(frameCount) / settings.sampleRate }
}

struct RecordingFolder: Identifiable, Codable, Equatable, Sendable {
  var id = UUID()
  var name: String
  var createdAt = Date()
}

struct CaptureUpdate: Sendable {
  var frameCount: Int64
  var level: Float
  var peaks: [Float]
  var warning: String?
  var mustStop = false
  var isPaused = false
}

struct CaptureResult: Sendable {
  var frameCount: Int64
  var processedComplete: Bool
  var warning: String?
  var sourceComplete = true
}
