import Foundation

enum UserPath {
  static func url(_ input: String) -> URL {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count >= 2, let first = text.first, let last = text.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    {
      text.removeFirst()
      text.removeLast()
    }
    text = text.replacingOccurrences(of: "\\ ", with: " ")
    return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
  }

  static var defaultModel: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Caches/NeMoSpeech/models/nvidia/nemotron-3.5-asr-streaming-0.6b/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"
      ).path
  }
}
