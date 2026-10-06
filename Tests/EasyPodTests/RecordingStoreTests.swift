import AVFoundation
import XCTest

@testable import EasyPod

@MainActor final class RecordingStoreTests: XCTestCase {
  private func fixture() throws -> (URL, RecordingSession, PreferencesStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "EasyPodStoreTests-\(UUID())")
    let files = try SessionFileService(root: root)
    var session = RecordingSession(title: "Saved", status: .completed, frameCount: 48_000)
    session.transcript = [TranscriptSegment(start: 0, end: 1, text: "元の文字起こし", isFinal: true)]
    session.transcriptionStatus = "文字起こし完了 · ローカル"
    try files.save(session)
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for frame in 0..<48_000 { buffer.floatChannelData![0][frame] = 0.2 }
    do {
      let source = try AVAudioFile(
        forWriting: files.directory(session.id).appendingPathComponent("source.caf"),
        settings: format.settings)
      try source.write(from: buffer)
    }
    let prefs = PreferencesStore(
      defaults: try XCTUnwrap(UserDefaults(suiteName: "EasyPodStore-\(UUID())")))
    prefs.modelPath = root.appendingPathComponent("model.gguf").path
    try Data([1]).write(to: URL(fileURLWithPath: prefs.modelPath))
    return (root, session, prefs)
  }

  private func batchFixture() throws -> (URL, [RecordingSession], PreferencesStore) {
    let (root, first, prefs) = try fixture()
    let files = try SessionFileService(root: root)
    let source = files.directory(first.id).appendingPathComponent("source.caf")
    var sessions = [first]
    for index in 1...2 {
      var session = first
      session.id = UUID()
      session.title = "Saved \(index + 1)"
      session.createdAt = first.createdAt.addingTimeInterval(Double(index))
      try files.save(session)
      try FileManager.default.copyItem(
        at: source, to: files.directory(session.id).appendingPathComponent("source.caf"))
      sessions.append(session)
    }
    return (root, sessions, prefs)
  }

  func testTrashConfirmationCancelAndContextTargetsLeaveFilesUntouched() throws {
    let (root, sessions, prefs) = try batchFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    let chosen: Set<UUID> = [sessions[0].id, sessions[1].id]
    store.setLibrarySelection(chosen)
    let primary = store.selectedID
    let title = store.title
    let manifest = try Data(
      contentsOf: files.directory(sessions[1].id).appendingPathComponent("session.json"))
    store.requestTrashRecording(sessions[0].id)
    XCTAssertTrue(store.showTrashConfirmation)
    XCTAssertEqual(Set(store.pendingTrashIDs), chosen)
    XCTAssertTrue(store.trashConfirmationMessage.contains("2件"))
    store.cancelTrashRequest()
    XCTAssertFalse(store.showTrashConfirmation)
    XCTAssertTrue(store.pendingTrashIDs.isEmpty)
    XCTAssertEqual(store.selectedIDs, chosen)
    XCTAssertEqual(store.selectedID, primary)
    XCTAssertEqual(store.title, title)
    store.requestTrashRecording(sessions[2].id)
    XCTAssertEqual(store.pendingTrashIDs, [sessions[2].id])
    XCTAssertTrue(store.trashConfirmationMessage.contains(sessions[2].title))
    store.cancelTrashRequest()
    store.confirmRequestedTrash()
    XCTAssertEqual(try files.load().count, 3)
    XCTAssertTrue(try files.loadTrashed().isEmpty)
    XCTAssertEqual(
      try Data(contentsOf: files.directory(sessions[1].id).appendingPathComponent("session.json")),
      manifest)
  }

  func testConfirmedBatchTrashUsesSnapshotPreservesFoldersAndRestores() throws {
    let (root, sessions, prefs) = try batchFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let folder = try files.createFolder(named: "Batch")
    var originals: [UUID: Data] = [:]
    for session in sessions {
      _ = try files.move(session, to: folder.id)
      originals[session.id] = try Data(
        contentsOf: files.directory(session.id).appendingPathComponent("source.caf"))
    }
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    store.setLibraryFilter(.folder(folder.id))
    let chosen: Set<UUID> = [sessions[0].id, sessions[1].id]
    store.setLibrarySelection(chosen)
    store.requestTrashSelection()
    store.setLibrarySelection([sessions[2].id])
    XCTAssertEqual(Set(store.pendingTrashIDs), chosen)
    store.confirmRequestedTrash()
    XCTAssertEqual(store.sessions.map(\.id), [sessions[2].id])
    XCTAssertEqual(store.selectedIDs, [sessions[2].id])
    XCTAssertEqual(store.selectedID, sessions[2].id)
    XCTAssertEqual(store.libraryFilter, .folder(folder.id))
    XCTAssertEqual(Set(store.trashedSessions.map(\.id)), chosen)
    XCTAssertTrue(store.trashedSessions.allSatisfy { $0.folderID == folder.id })
    for session in sessions {
      let directory =
        chosen.contains(session.id) ? files.trashDirectory(session.id) : files.directory(session.id)
      XCTAssertEqual(
        try Data(contentsOf: directory.appendingPathComponent("source.caf")), originals[session.id])
    }
    store.confirmRequestedTrash()
    XCTAssertEqual(try files.load().count, 1)
    XCTAssertEqual(try files.loadTrashed().count, 2)
    store.setLibraryFilter(.trash)
    store.restoreRecording(sessions[0].id)
    XCTAssertEqual(store.selectedID, sessions[0].id)
    XCTAssertEqual(store.selectedIDs, [sessions[0].id])
    XCTAssertEqual(store.selected?.folderID, folder.id)
    XCTAssertEqual(store.selected?.transcript, sessions[0].transcript)
    XCTAssertEqual(
      try Data(contentsOf: files.directory(sessions[0].id).appendingPathComponent("source.caf")),
      originals[sessions[0].id])
  }

  func testBatchTrashCollisionRetainsFailedRecordingAndReportsPartialSuccess() throws {
    let (root, sessions, prefs) = try batchFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    let failed = sessions[1]
    let original = try Data(
      contentsOf: files.directory(failed.id).appendingPathComponent("source.caf"))
    let destination = files.trashDirectory(failed.id)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sentinel = Data("existing destination".utf8)
    try sentinel.write(to: destination)
    store.select(sessions[0].id)
    store.setLibrarySelection(Set(sessions.map(\.id)))
    XCTAssertEqual(store.selectedID, sessions[2].id)
    store.requestTrashSelection()
    store.confirmRequestedTrash()
    XCTAssertEqual(store.sessions.map(\.id), [failed.id])
    XCTAssertEqual(store.selectedID, failed.id)
    XCTAssertEqual(store.selectedIDs, [failed.id])
    XCTAssertEqual(store.selected?.transcript, failed.transcript)
    XCTAssertEqual(store.trashedSessions.count, 2)
    XCTAssertTrue(store.error?.contains("3件中2件") == true)
    XCTAssertTrue(store.error?.contains("1件は移動できません") == true)
    XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    XCTAssertEqual(
      try Data(contentsOf: files.directory(failed.id).appendingPathComponent("source.caf")),
      original)
    store.saveEffects()
    XCTAssertEqual(try files.load().count, 1)
    XCTAssertEqual(try files.loadTrashed().count, 2)
    XCTAssertFalse(store.showTrashConfirmation)
  }

  func testTrashConfirmationBusyGuardsAndSelectionReset() throws {
    let (root, sessions, prefs) = try batchFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    let chosen: Set<UUID> = [sessions[0].id, sessions[1].id]
    store.setLibrarySelection(chosen.union([UUID()]))
    XCTAssertEqual(store.selectedIDs, chosen)
    store.requestTrashSelection()
    store.exporting = true
    store.confirmRequestedTrash()
    XCTAssertTrue(store.pendingTrashIDs.isEmpty)
    store.requestTrashSelection()
    XCTAssertFalse(store.showTrashConfirmation)
    store.setLibrarySelection([sessions[2].id])
    XCTAssertEqual(store.selectedIDs, chosen)
    store.exporting = false
    for phase in [TransportPhase.preparing, .finalizing] {
      store.phase = phase
      store.requestTrashSelection()
      XCTAssertFalse(store.showTrashConfirmation)
    }
    store.phase = .completed
    store.refining = true
    store.requestTrashSelection()
    XCTAssertFalse(store.showTrashConfirmation)
    store.refining = false
    store.requestTrashSelection()
    store.setLibraryFilter(.unfiled)
    XCTAssertTrue(store.pendingTrashIDs.isEmpty)
    XCTAssertEqual(store.selectedIDs.count, 1)
    store.requestTrashSelection()
    store.newRecording()
    XCTAssertTrue(store.pendingTrashIDs.isEmpty)
    XCTAssertTrue(store.selectedIDs.isEmpty)
    XCTAssertNil(store.selectedID)
    store.setLibraryFilter(.trash)
    store.requestTrashRecording(sessions[0].id)
    XCTAssertFalse(store.showTrashConfirmation)
    XCTAssertEqual(try files.load().count, 3)
    XCTAssertTrue(try files.loadTrashed().isEmpty)
  }

  func testTrashConfirmationManifestSaveFailurePreservesRecordings() throws {
    let (root, sessions, prefs) = try batchFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    store.setLibrarySelection(Set(sessions.map(\.id)))
    let selected = try XCTUnwrap(store.selectedID)
    let source = files.directory(selected).appendingPathComponent("source.caf")
    let original = try Data(contentsOf: source)
    let sidecar = files.directory(selected).appendingPathComponent("transcript.json")
    try FileManager.default.removeItem(at: sidecar)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
    store.requestTrashSelection()
    store.confirmRequestedTrash()
    XCTAssertTrue(store.error?.contains("削除を中止") == true)
    XCTAssertEqual(store.selectedIDs.count, 3)
    XCTAssertEqual(store.selectedID, selected)
    XCTAssertEqual(try files.load().count, 3)
    XCTAssertTrue(try files.loadTrashed().isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testTrashFolderRestoreAndSelectionCannotRecreateRecording() throws {
    let (root, session, prefs) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    store.createFolder(named: "ポッドキャスト")
    let folder = try XCTUnwrap(store.folders.first)
    store.setLibraryFilter(.all)
    store.moveRecording(session.id, to: folder.id)
    XCTAssertEqual(store.selected?.folderID, folder.id)
    store.trashRecording(session.id)
    store.saveEffects()
    XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory(session.id).path))
    store.setLibraryFilter(.trash)
    XCTAssertEqual(store.selectedID, session.id)
    XCTAssertFalse(store.canPlay)
    XCTAssertFalse(store.canRefine)
    store.restoreRecording(session.id)
    XCTAssertEqual(store.selectedID, session.id)
    XCTAssertEqual(store.selected?.transcript, session.transcript)
    XCTAssertEqual(store.selected?.folderID, folder.id)
    store.deleteFolder(folder.id)
    XCTAssertNil(store.selected?.folderID)
    XCTAssertEqual(try files.load().count, 1)
    XCTAssertTrue(try files.loadTrashed().isEmpty)
  }

  func testCorruptFolderIndexStillExposesTrashAndRestoresRecording() throws {
    let (root, session, prefs) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    try files.trash(session.id)
    let index = root.appendingPathComponent(".library-index.json")
    let corrupt = Data("corrupt index".utf8)
    try corrupt.write(to: index)
    let store = RecordingStore(sessionRoot: root, preferences: prefs)
    XCTAssertNotNil(store.error)
    XCTAssertEqual(store.trashedSessions.count, 1)
    store.setLibraryFilter(.trash)
    XCTAssertEqual(store.selectedID, session.id)
    store.restoreRecording(session.id)
    XCTAssertEqual(store.selectedID, session.id)
    XCTAssertEqual(store.selected?.transcript, session.transcript)
    XCTAssertTrue(store.trashedSessions.isEmpty)
    XCTAssertEqual(try Data(contentsOf: index), corrupt)
  }

  func testQuitDuringPermissionPreparationCannotStartLateRecording() async throws {
    let (root, session, prefs) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var permission: CheckedContinuation<Bool, Never>?
    let store = RecordingStore(
      sessionRoot: root, preferences: prefs,
      permissionRequest: {
        await withCheckedContinuation { permission = $0 }
      })
    let started = Task { await store.start() }
    for _ in 0..<100 {
      if permission != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let reply = try XCTUnwrap(permission)
    XCTAssertEqual(store.phase, .preparing)
    await store.prepareForTermination()
    reply.resume(returning: true)
    await started.value
    XCTAssertFalse(store.isCapturing)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertEqual(store.sessions.count, 1)
    XCTAssertEqual(store.selected?.transcript, session.transcript)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".active-recording").path))
  }

  func testRefusedPermissionAndMissingPluginPreserveSavedOriginal() async throws {
    let (root, session, prefs) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try SessionFileService(root: root).directory(session.id).appendingPathComponent(
      "source.caf")
    let original = try Data(contentsOf: source)
    let store = RecordingStore(sessionRoot: root, preferences: prefs, permissionRequest: { false })
    await store.start()
    XCTAssertFalse(store.isCapturing)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertTrue(store.error?.contains("許可") == true)
    XCTAssertEqual(store.sessions.count, 1)
    store.effects = [
      EffectSlot(
        plugin: PluginDescriptor(
          id: "missing", name: "Missing", manufacturer: "Test", format: .vst3,
          path: root.appendingPathComponent("Missing.vst3").path, classID: "missing"))
    ]
    await store.togglePlayback()
    XCTAssertFalse(store.isPlaying)
    XCTAssertTrue(store.error?.contains("見つかりません") == true)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".active-recording").path))
    await store.prepareForTermination()
    XCTAssertEqual(store.selected?.transcript, session.transcript)
  }

  func testRefinementCommitsBackupGuardsMutationsAndRestoresLiveText() async throws {
    let (root, session, prefs) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = TranscriptRefinementService(backendFactory: { StoreRefinementBackend() })
    let store = RecordingStore(sessionRoot: root, preferences: prefs, refinement: service)
    XCTAssertTrue(store.canRefine)
    store.refineTranscript()
    XCTAssertTrue(store.refining)
    XCTAssertFalse(store.canPlay)
    XCTAssertFalse(store.canOrganize)
    store.trashRecording(session.id)
    XCTAssertEqual(store.sessions.count, 1)
    let deadline = ContinuousClock.now + .seconds(5)
    while store.refining && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(store.refining)
    XCTAssertEqual(store.selected?.transcript.first?.text, "清書した文字")
    XCTAssertEqual(store.selected?.originalTranscript, session.transcript)
    let saved = try XCTUnwrap(SessionFileService(root: root).load().first)
    XCTAssertEqual(saved.originalTranscript, session.transcript)
    store.restoreOriginalTranscript()
    XCTAssertEqual(store.selected?.transcript, session.transcript)
    XCTAssertNil(store.selected?.originalTranscript)
    XCTAssertEqual(try SessionFileService(root: root).load().first?.transcript, session.transcript)
  }

  func testFailedRefinementSaveKeepsVisibleAndCommittedLiveText() async throws {
    let (root, session, prefs) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try SessionFileService(root: root)
    let store = RecordingStore(
      sessionRoot: root, preferences: prefs,
      refinement: TranscriptRefinementService(backendFactory: { StoreRefinementBackend() }))
    let sidecar = files.directory(session.id).appendingPathComponent("transcript.json")
    try FileManager.default.removeItem(at: sidecar)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
    store.refineTranscript()
    let deadline = ContinuousClock.now + .seconds(5)
    while store.refining && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(store.refining)
    XCTAssertNotNil(store.error)
    XCTAssertEqual(store.selected?.transcript, session.transcript)
    XCTAssertNil(store.selected?.originalTranscript)
    XCTAssertEqual(try files.load().first?.transcript, session.transcript)
  }
}

private final class StoreRefinementBackend: TranscriptRefinementBackend, Sendable {
  func open(model: URL, language: TranscriptionLanguage) throws {}
  func recognize(samples: [Float], sampleRate: Int32) throws -> TranscriptRefinementHypothesis {
    .init(text: "清書した文字", start: 0, end: Double(samples.count) / Double(sampleRate))
  }
  func close() {}
}
