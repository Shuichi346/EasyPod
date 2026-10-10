import AVFoundation
import Foundation
import Synchronization

@MainActor final class SessionFileService {
  let root: URL
  private let persistence: SessionPersistence

  private struct LibraryIndex: Codable {
    var version = 1
    var folders: [RecordingFolder] = []
    var assignments: [String: UUID] = [:]
  }

  private var indexURL: URL { root.appendingPathComponent(".library-index.json") }
  private var trashRoot: URL { root.appendingPathComponent(".Trash", isDirectory: true) }

  init(root: URL? = nil, checkpointDelay: TimeInterval = 0.25) throws {
    self.root =
      root
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/EasyPod/Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    persistence = SessionPersistence(root: self.root, delay: checkpointDelay)
  }

  func directory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  func save(_ session: RecordingSession) throws {
    try persistence.save(session)
  }

  // Only the latest checkpoint is retained; explicit saves supersede it on the same owner.
  func checkpoint(_ session: RecordingSession, onFailure: @escaping @Sendable (String) -> Void) {
    persistence.checkpoint(session, onFailure: onFailure)
  }

  func flushCheckpoints() async throws { try await persistence.flush() }

  var checkpointWriteCount: Int { persistence.checkpointWriteCount }

  func load() throws -> [RecordingSession] {
    try loadSessions(at: root)
  }

  func loadTrashed() throws -> [RecordingSession] {
    guard FileManager.default.fileExists(atPath: trashRoot.path) else { return [] }
    try requireDirectory(trashRoot)
    return try loadSessions(at: trashRoot)
  }

  func loadFolders() throws -> [RecordingFolder] {
    try readIndex().folders.sorted { $0.createdAt < $1.createdAt }
  }

  @discardableResult func createFolder(named name: String) throws -> RecordingFolder {
    var index = try readIndex()
    let folder = RecordingFolder(name: try validatedName(name, excluding: nil, in: index))
    index.folders.append(folder)
    try writeIndex(index)
    return folder
  }

  @discardableResult func renameFolder(_ id: UUID, to name: String) throws -> RecordingFolder {
    var index = try readIndex()
    guard let position = index.folders.firstIndex(where: { $0.id == id }) else {
      throw EasyPodError.message("フォルダーが見つかりません。一覧を更新してください。")
    }
    index.folders[position].name = try validatedName(name, excluding: id, in: index)
    try writeIndex(index)
    return index.folders[position]
  }

  func deleteFolder(_ id: UUID) throws {
    var index = try readIndex()
    guard index.folders.contains(where: { $0.id == id }) else {
      throw EasyPodError.message("フォルダーが見つかりません。一覧を更新してください。")
    }
    index.folders.removeAll { $0.id == id }
    index.assignments = index.assignments.filter { $0.value != id }
    // One atomic index write returns every member to unfiled without touching its audio.
    try writeIndex(index)
  }

  @discardableResult func move(_ session: RecordingSession, to folderID: UUID?) throws
    -> RecordingSession
  {
    try requireDirectory(directory(session.id))
    var index = try readIndex()
    if let folderID, !index.folders.contains(where: { $0.id == folderID }) {
      throw EasyPodError.message("移動先のフォルダーが見つかりません。")
    }
    index.assignments[session.id.uuidString] = folderID
    try writeIndex(index)
    var moved = session
    moved.folderID = folderID
    return moved
  }

  func trash(_ id: UUID) throws {
    try persistence.finishCheckpoint(for: id)
    let source = directory(id)
    try requireDirectory(source)
    let destination = trashDirectory(id)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw EasyPodError.message("同じ録音がゴミ箱にあるため削除できません。")
    }
    try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
    try requireDirectory(trashRoot)
    // Both locations share the session root, so the complete recording moves together.
    try FileManager.default.moveItem(at: source, to: destination)
  }

  @discardableResult func restore(_ id: UUID) throws -> RecordingSession {
    let source = trashDirectory(id)
    try requireDirectory(trashRoot)
    try requireDirectory(source)
    guard !FileManager.default.fileExists(atPath: directory(id).path) else {
      throw EasyPodError.message("同じ録音が一覧にあるため復元できません。")
    }
    guard let session = try loadTrashed().first(where: { $0.id == id }) else {
      throw EasyPodError.message("録音の保存情報とオリジナル音声を読み込めません。")
    }
    try FileManager.default.moveItem(at: source, to: directory(id))
    return session
  }

  func trashDirectory(_ id: UUID) -> URL {
    trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private func readIndex() throws -> LibraryIndex {
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return LibraryIndex() }
    do {
      let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: indexURL))
      let folderIDs = Set(index.folders.map(\.id))
      guard index.version == 1, folderIDs.count == index.folders.count,
        index.folders.allSatisfy({
          !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }),
        index.assignments.allSatisfy({
          UUID(uuidString: $0.key)?.uuidString == $0.key && folderIDs.contains($0.value)
        })
      else {
        throw EasyPodError.message("フォルダー情報の形式が不正です。")
      }
      return index
    } catch {
      throw EasyPodError.message("フォルダー情報を読み込めません。保存ファイルを保護するため変更を中止しました。")
    }
  }

  private func writeIndex(_ index: LibraryIndex) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(index).write(to: indexURL, options: .atomic)
  }

  private func validatedName(_ name: String, excluding id: UUID?, in index: LibraryIndex) throws
    -> String
  {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
      throw EasyPodError.message("フォルダー名を1〜80文字で入力してください。")
    }
    guard
      !index.folders.contains(where: {
        $0.id != id
          && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
      })
    else {
      throw EasyPodError.message("同じ名前のフォルダーがあります。")
    }
    return trimmed
  }

  private func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw EasyPodError.message("録音の保存先が通常のフォルダーではありません。")
    }
  }

  private func loadSessions(at location: URL) throws -> [RecordingSession] {
    let folders = try FileManager.default.contentsOfDirectory(
      at: location, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let index: LibraryIndex?
    do {
      index = try readIndex()
    } catch {
      index = nil
    }
    var sessions: [RecordingSession] = []
    for folder in folders {
      guard let id = UUID(uuidString: folder.lastPathComponent),
        (try? requireDirectory(folder)) != nil
      else { continue }
      let audio = try? AVAudioFile(forReading: folder.appendingPathComponent("source.caf"))
      let manifest = folder.appendingPathComponent("session.json")
      var session: RecordingSession
      let hasValidManifest: Bool
      if let data = try? Data(contentsOf: manifest),
        let saved = try? JSONDecoder().decode(RecordingSession.self, from: data),
        saved.id == id, saved.settings.sampleRate.isFinite, saved.settings.sampleRate > 0,
        saved.settings.channels > 0, saved.frameCount >= 0
      {
        session = saved
        hasValidManifest = true
      } else if let audio {
        session = RecordingSession(id: id, title: "復旧した録音", status: .interrupted)
        hasValidManifest = false
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
      if !hasValidManifest,
        let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
        let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data)
      {
        session.transcript = segments
      }
      session.folderID = index?.assignments[id.uuidString]
      if index == nil {
        let reason = "フォルダー情報を読み込めません。録音は未分類として表示しています。"
        if let warning = session.warning, !warning.isEmpty {
          session.warning = warning.contains(reason) ? warning : warning + "\n" + reason
        } else {
          session.warning = reason
        }
      }
      sessions.append(session)
    }
    return sessions.sorted { $0.createdAt > $1.createdAt }
  }
}

// Encoding and file replacement run on one serial owner, outside the UI and audio callbacks.
private final class SessionPersistence: @unchecked Sendable {
  private struct Pending: Sendable {
    let session: RecordingSession
    let onFailure: @Sendable (String) -> Void
  }
  private struct State: Sendable {
    var pending: Pending?
    var scheduled = false
  }
  private let root: URL
  private let delay: TimeInterval
  private let queue = DispatchQueue(label: "local.EasyPod.session.persistence", qos: .utility)
  private let state = Mutex(State())
  private var failures: [UUID: String] = [:]
  private var writes = 0

  init(root: URL, delay: TimeInterval) {
    self.root = root
    self.delay = max(0, delay)
  }

  var checkpointWriteCount: Int { queue.sync { writes } }

  func checkpoint(_ session: RecordingSession, onFailure: @escaping @Sendable (String) -> Void) {
    let schedule = state.withLock { state in
      state.pending = Pending(session: session, onFailure: onFailure)
      guard !state.scheduled else { return false }
      state.scheduled = true
      return true
    }
    if schedule { queue.asyncAfter(deadline: .now() + delay) { self.drain() } }
  }

  func save(_ session: RecordingSession) throws {
    try queue.sync {
      // A delayed recording checkpoint must never overwrite a final manifest or restored text.
      state.withLock { if $0.pending?.session.id == session.id { $0.pending = nil } }
      if let failure = failures.removeValue(forKey: session.id) {
        throw EasyPodError.message(failure)
      }
      try write(session)
    }
  }

  func finishCheckpoint(for id: UUID) throws {
    try queue.sync {
      drain()
      if let reason = failures.removeValue(forKey: id) { throw EasyPodError.message(reason) }
    }
  }

  func flush() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        self.drain()
        if let failure = self.failures.first {
          self.failures.removeValue(forKey: failure.key)
          continuation.resume(throwing: EasyPodError.message(failure.value))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func drain() {
    let pending = state.withLock { state in
      let value = state.pending
      state.pending = nil
      state.scheduled = false
      return value
    }
    guard let pending else { return }
    do {
      try write(pending.session)
      writes += 1
    } catch {
      let reason = error.localizedDescription
      failures[pending.session.id] = reason
      pending.onFailure(reason)
    }
  }

  private func write(_ session: RecordingSession) throws {
    let trash = root.appendingPathComponent(".Trash").appendingPathComponent(session.id.uuidString)
    guard !FileManager.default.fileExists(atPath: trash.path) else {
      throw EasyPodError.message("この録音はゴミ箱にあります。復元してから変更してください。")
    }
    let folder = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw EasyPodError.message("録音の保存先が通常のフォルダーではありません。")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(session.transcript).write(
      to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    // The manifest commits last; the sidecar remains a recovery copy.
    try encoder.encode(session).write(
      to: folder.appendingPathComponent("session.json"), options: .atomic)
  }
}
