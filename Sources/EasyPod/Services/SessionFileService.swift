import AVFoundation
import Foundation

@MainActor final class SessionFileService {
  let root: URL

  init(root: URL? = nil) throws {
    self.root =
      root
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/EasyPod/Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
  }

  func directory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  func save(_ session: RecordingSession) throws {
    let folder = directory(session.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(session.transcript).write(
      to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    try encoder.encode(session).write(
      to: folder.appendingPathComponent("session.json"), options: .atomic)
  }

  func load() throws -> [RecordingSession] {
    let folders = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    var sessions: [RecordingSession] = []
    for folder in folders {
      guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
      let audio = try? AVAudioFile(forReading: folder.appendingPathComponent("source.caf"))
      let manifest = folder.appendingPathComponent("session.json")
      var session: RecordingSession
      if let data = try? Data(contentsOf: manifest),
        let saved = try? JSONDecoder().decode(RecordingSession.self, from: data)
      {
        session = saved
      } else if let audio {
        session = RecordingSession(id: id, title: "復旧した録音", status: .interrupted)
        session.settings.sampleRate = audio.processingFormat.sampleRate
        session.settings.channels = Int(audio.processingFormat.channelCount)
        session.warning = "保存情報を復旧しました。オリジナル音声を確認してください。"
      } else {
        continue
      }
      if session.status != .completed {
        session.status = .interrupted
        session.processedComplete = false
        session.frameCount = audio?.length ?? session.frameCount
        session.warning = session.warning ?? "録音が中断されました。保存済みの音声を復旧できます。"
      } else if let audio, audio.length != session.frameCount {
        session.status = .interrupted
        session.frameCount = audio.length
        session.processedComplete = false
        session.warning = "音声の長さと保存情報が一致しません。音声を確認してください。"
      } else if audio == nil {
        session.status = .interrupted
        session.processedComplete = false
        session.warning = "オリジナル音声を開けません。保存先を確認してください。"
      }
      if session.processedComplete {
        do {
          let processed = try AVAudioFile(
            forReading: folder.appendingPathComponent("processed.caf"))
          guard processed.length >= session.frameCount,
            processed.processingFormat.sampleRate == session.settings.sampleRate,
            Int(processed.processingFormat.channelCount) == session.settings.channels,
            processed.length > 0,
            let probe = AVAudioPCMBuffer(pcmFormat: processed.processingFormat, frameCapacity: 1)
          else {
            throw EasyPodError.message("処理済み音声の形式または長さが保存情報と一致しません。")
          }
          processed.framePosition = processed.length - 1
          try processed.read(into: probe, frameCount: 1)
          guard probe.frameLength == 1 else {
            throw EasyPodError.message("処理済み音声を最後まで読み込めません。")
          }
        } catch {
          session.processedComplete = false
          let reason = "処理済み音声が見つからないか破損しています。オリジナル音声を使用してください。"
          if let previous = session.warning, !previous.isEmpty {
            if !previous.contains(reason) { session.warning = previous + "\n" + reason }
          } else {
            session.warning = reason
          }
        }
      }
      if let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
        let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data)
      {
        session.transcript = segments
      }
      sessions.append(session)
    }
    return sessions.sorted { $0.createdAt > $1.createdAt }
  }
}
