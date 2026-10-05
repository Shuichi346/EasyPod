import AVFoundation
import XCTest

@testable import EasyPod

@MainActor final class LibraryTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodLibraryTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func completedSession(in files: SessionFileService) throws -> RecordingSession {
    let session = RecordingSession(
      title: "Library fixture", status: .completed, frameCount: 32,
      transcript: [TranscriptSegment(start: 0, end: 0.0005, text: "保存する文字起こし", isFinal: true)])
    try files.save(session)
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
    buffer.frameLength = 32
    for index in 0..<32 { buffer.floatChannelData![0][index] = Float(index) / 64 }
    let audio = try AVAudioFile(
      forWriting: files.directory(session.id).appendingPathComponent("source.caf"),
      settings: format.settings)
    try audio.write(from: buffer)
    return session
  }

  private func manifestObject(_ session: RecordingSession) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
  }

  func testLegacyManifestDecodesWithoutFolderField() throws {
    let session = RecordingSession(title: "Before folders", status: .completed)
    var object = try manifestObject(session)
    object.removeValue(forKey: "folderID")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(RecordingSession.self, from: legacy)
    XCTAssertEqual(decoded.id, session.id)
    XCTAssertEqual(decoded.title, session.title)
    XCTAssertNil(decoded.folderID)
    XCTAssertNil(decoded.originalTranscript)
    XCTAssertNil(decoded.originalTranscriptionStatus)
  }

  func testFoldersPersistMoveAndDeleteWithoutChangingRecordingFiles() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let session = try completedSession(in: files)
    let sourceURL = files.directory(session.id).appendingPathComponent("source.caf")
    let originalAudio = try Data(contentsOf: sourceURL)
    let transcriptURL = files.directory(session.id).appendingPathComponent("transcript.json")
    let originalTranscript = try Data(contentsOf: transcriptURL)
    let folder = try files.createFolder(named: "  Interview  ")
    XCTAssertEqual(folder.name, "Interview")
    XCTAssertThrowsError(try files.createFolder(named: "interview"))
    XCTAssertThrowsError(try files.createFolder(named: " \n "))
    let moved = try files.move(session, to: folder.id)
    XCTAssertEqual(moved.folderID, folder.id)

    let reopened = try SessionFileService(root: root)
    XCTAssertEqual(try reopened.loadFolders(), [folder])
    XCTAssertEqual(try reopened.load().first?.folderID, folder.id)
    let renamed = try reopened.renameFolder(folder.id, to: "対談")
    XCTAssertEqual(renamed.id, folder.id)
    XCTAssertEqual(try files.loadFolders().first?.name, "対談")
    XCTAssertThrowsError(try files.move(session, to: UUID()))
    try files.deleteFolder(folder.id)
    XCTAssertTrue(try reopened.loadFolders().isEmpty)
    XCTAssertNil(try reopened.load().first?.folderID)
    // A cached session can retain a removed ID; the authoritative index prevents resurrection.
    try reopened.save(moved)
    XCTAssertNil(try reopened.load().first?.folderID)
    XCTAssertEqual(try Data(contentsOf: sourceURL), originalAudio)
    XCTAssertEqual(try Data(contentsOf: transcriptURL), originalTranscript)
    XCTAssertEqual(try reopened.load().first?.transcript, session.transcript)
  }

  func testTrashAndRestorePreserveAudioTranscriptAndAdditionalFiles() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let session = try completedSession(in: files)
    let folder = try files.createFolder(named: "収録")
    var moved = try files.move(session, to: folder.id)
    try FileManager.default.copyItem(
      at: files.directory(session.id).appendingPathComponent("source.caf"),
      to: files.directory(session.id).appendingPathComponent("processed.caf"))
    moved.processedComplete = true
    try files.save(moved)
    let sessionRoot = files.directory(session.id)
    let payloadURL = sessionRoot.appendingPathComponent("notes.txt")
    try Data("Keep all session files".utf8).write(to: payloadURL)
    let names = ["source.caf", "processed.caf", "session.json", "transcript.json", "notes.txt"]
    let original = try names.map { try Data(contentsOf: sessionRoot.appendingPathComponent($0)) }

    try files.trash(session.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
    XCTAssertTrue(try files.load().isEmpty)
    let trashed = try XCTUnwrap(files.loadTrashed().first)
    XCTAssertEqual(trashed.id, session.id)
    XCTAssertEqual(trashed.folderID, folder.id)
    XCTAssertEqual(trashed.transcript, session.transcript)
    XCTAssertThrowsError(try files.save(moved))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
    let restored = try files.restore(session.id)
    XCTAssertEqual(restored.folderID, folder.id)
    XCTAssertEqual(restored.status, .completed)
    XCTAssertTrue(restored.processedComplete)
    XCTAssertTrue(try files.loadTrashed().isEmpty)
    XCTAssertEqual(
      try names.map { try Data(contentsOf: sessionRoot.appendingPathComponent($0)) }, original)

    try files.trash(session.id)
    try files.deleteFolder(folder.id)
    XCTAssertNil(try files.loadTrashed().first?.folderID)
    XCTAssertNil(try files.restore(session.id).folderID)
  }

  func testTrashAndRestoreCollisionsLeaveBothDirectoriesIntact() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let session = try completedSession(in: files)
    let liveDirectory = files.directory(session.id)
    let originalAudio = try Data(contentsOf: liveDirectory.appendingPathComponent("source.caf"))
    let trashDirectory = files.trashDirectory(session.id)
    try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
    let sentinel = Data("Existing destination".utf8)
    try sentinel.write(to: trashDirectory.appendingPathComponent("sentinel"))
    XCTAssertThrowsError(try files.trash(session.id))
    XCTAssertEqual(
      try Data(contentsOf: liveDirectory.appendingPathComponent("source.caf")), originalAudio)
    XCTAssertEqual(
      try Data(contentsOf: trashDirectory.appendingPathComponent("sentinel")), sentinel)

    try FileManager.default.removeItem(at: trashDirectory)
    try files.trash(session.id)
    try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
    try sentinel.write(to: liveDirectory.appendingPathComponent("sentinel"))
    XCTAssertThrowsError(try files.restore(session.id))
    XCTAssertEqual(
      try Data(contentsOf: trashDirectory.appendingPathComponent("source.caf")), originalAudio)
    XCTAssertEqual(try Data(contentsOf: liveDirectory.appendingPathComponent("sentinel")), sentinel)
  }

  func testCorruptIndexPreservesRecordingsAndRejectsMutations() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let session = try completedSession(in: files)
    let folder = try files.createFolder(named: "Original folder")
    _ = try files.move(session, to: folder.id)
    let indexURL = root.appendingPathComponent(".library-index.json")
    let invalidIndexes = [
      Data("{broken JSON".utf8),
      try JSONSerialization.data(withJSONObject: [
        "version": 1, "folders": [], "assignments": [session.id.uuidString: folder.id.uuidString],
      ]),
    ]
    for invalid in invalidIndexes {
      try invalid.write(to: indexURL, options: .atomic)
      let recovered = try XCTUnwrap(files.load().first)
      XCTAssertEqual(recovered.id, session.id)
      XCTAssertEqual(recovered.transcript, session.transcript)
      XCTAssertNil(recovered.folderID)
      XCTAssertTrue(recovered.warning?.contains("フォルダー情報") == true)
      XCTAssertThrowsError(try files.loadFolders())
      XCTAssertThrowsError(try files.createFolder(named: "Must not overwrite"))
      XCTAssertThrowsError(try files.move(session, to: nil))
      XCTAssertThrowsError(try files.deleteFolder(folder.id))
      XCTAssertEqual(try Data(contentsOf: indexURL), invalid)
    }
    // Reversible deletion and restoration remain available with a damaged organization index.
    try files.trash(session.id)
    XCTAssertEqual(try files.restore(session.id).id, session.id)
    XCTAssertEqual(try Data(contentsOf: indexURL), invalidIndexes.last)
  }

  func testForeignManifestIdentityAndInvalidAudioMetadataRecoverAtActualDirectory() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let session = try completedSession(in: files)
    let folder = try files.createFolder(named: "Recovered")
    _ = try files.move(session, to: folder.id)
    let manifestURL = files.directory(session.id).appendingPathComponent("session.json")
    let sourceURL = files.directory(session.id).appendingPathComponent("source.caf")
    let originalAudio = try Data(contentsOf: sourceURL)
    var foreign = try manifestObject(session)
    foreign["id"] = UUID().uuidString
    var invalid = try manifestObject(session)
    var settings = try XCTUnwrap(invalid["settings"] as? [String: Any])
    settings["sampleRate"] = 0
    invalid["settings"] = settings
    invalid["frameCount"] = -1
    for object in [foreign, invalid] {
      try JSONSerialization.data(withJSONObject: object).write(to: manifestURL, options: .atomic)
      let recovered = try XCTUnwrap(files.load().first)
      XCTAssertEqual(recovered.id, session.id)
      XCTAssertEqual(recovered.status, .interrupted)
      XCTAssertEqual(recovered.frameCount, 32)
      XCTAssertEqual(recovered.settings.sampleRate, 48_000)
      XCTAssertEqual(recovered.folderID, folder.id)
      XCTAssertEqual(recovered.transcript, session.transcript)
      XCTAssertEqual(try Data(contentsOf: sourceURL), originalAudio)
      try files.trash(session.id)
      XCTAssertEqual(try files.restore(session.id).id, session.id)
    }
  }

  func testRefinementSaveFailureAndStaleSidecarKeepCommittedTranscript() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    var original = try completedSession(in: files)
    original.transcriptionStatus = "文字起こし完了 · ライブ"
    try files.save(original)
    let manifestURL = files.directory(original.id).appendingPathComponent("session.json")
    let committedManifest = try Data(contentsOf: manifestURL)
    let sidecarURL = files.directory(original.id).appendingPathComponent("transcript.json")
    var refined = original
    refined.originalTranscript = original.transcript
    refined.originalTranscriptionStatus = original.transcriptionStatus
    refined.transcript = [
      TranscriptSegment(start: 0, end: 0.0005, text: "精密化した文字起こし", isFinal: true)
    ]
    refined.transcriptionStatus = "文字起こし完了 · 精密化"

    // A failed sidecar write never publishes the candidate manifest.
    try FileManager.default.removeItem(at: sidecarURL)
    try FileManager.default.createDirectory(at: sidecarURL, withIntermediateDirectories: true)
    XCTAssertThrowsError(try files.save(refined))
    XCTAssertEqual(try Data(contentsOf: manifestURL), committedManifest)
    XCTAssertEqual(try files.load().first?.transcript, original.transcript)
    XCTAssertEqual(try files.load().first?.transcriptionStatus, original.transcriptionStatus)

    // A newer recovery copy cannot override an older committed manifest.
    try FileManager.default.removeItem(at: sidecarURL)
    try JSONEncoder().encode(refined.transcript).write(to: sidecarURL, options: .atomic)
    XCTAssertEqual(try files.load().first?.transcript, original.transcript)
    try files.save(refined)
    let loaded = try XCTUnwrap(files.load().first)
    XCTAssertEqual(loaded.transcript, refined.transcript)
    XCTAssertEqual(loaded.originalTranscript, original.transcript)
    XCTAssertEqual(loaded.originalTranscriptionStatus, original.transcriptionStatus)
  }
}
