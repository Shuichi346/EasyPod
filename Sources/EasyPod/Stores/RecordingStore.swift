import AVFoundation
import Foundation
import OSLog
import Observation

enum TransportPhase: String {
  case idle, preparing, recording, paused, finalizing, completed, interrupted
  var label: String {
    switch self {
    case .idle: "録音の準備ができました"
    case .preparing: "準備中…"
    case .recording: "録音中…"
    case .paused: "一時停止中"
    case .finalizing: "保存・確定中…"
    case .completed: "録音完了"
    case .interrupted: "録音が中断されました"
    }
  }
}

enum RecordingLibraryFilter: Hashable {
  case all, unfiled
  case folder(UUID)
  case trash
}

@MainActor @Observable final class RecordingStore {
  var preferences = PreferencesStore()
  let transcription = TranscriptionService()
  var sessions: [RecordingSession] = []
  var selectedID: UUID?
  private(set) var selectedIDs: Set<UUID> = []
  private(set) var pendingTrashIDs: [UUID] = []
  var showTrashConfirmation = false
  var phase: TransportPhase = .idle
  var title = "新しい録音"
  var level: Float = 0
  var peaks: [Float] = []
  var elapsed: Double = 0
  var monitor = false
  var effects: [EffectSlot] = []
  var plugins: [PluginDescriptor] = []
  var scanning = false
  var error: String?
  var exporting = false
  var exportProgress = 0.0
  var folders: [RecordingFolder] = []
  var trashedSessions: [RecordingSession] = []
  var libraryFilter: RecordingLibraryFilter = .all
  var refining = false
  var refinementProgress = 0.0
  var refinementCancelling = false
  private var refinementTask: Task<Void, Never>?
  private var refinementID: UUID?
  private var playbackStartTime = 0.0
  private let refinement: TranscriptRefinementService
  private let customMarker: URL?
  private let permissionRequest: @MainActor () async -> Bool
  var inputDevices: [AudioInputDevice] = []
  var showExportSheet = false
  private var files: SessionFileService?
  private let capture = AudioCaptureService()
  private let playback: PlaybackService
  private let exporter = AudioExportService()
  private let effectService = EffectChainService()
  private let catalog = PluginCatalogService()
  private var chain: EffectChain?
  private var activeID: UUID?
  private var terminating = false
  private var playbackGeneration = UUID()
  private var lastSavedFrame: Int64 = 0
  private let logger = Logger(subsystem: "local.EasyPod", category: "session")

  var selected: RecordingSession? {
    (libraryFilter == .trash ? trashedSessions : sessions).first { $0.id == selectedID }
  }
  var visibleSessions: [RecordingSession] {
    switch libraryFilter {
    case .all: sessions
    case .unfiled: sessions.filter { $0.folderID == nil }
    case .folder(let id): sessions.filter { $0.folderID == id }
    case .trash: trashedSessions
    }
  }
  var isPlaying: Bool { playback.isPlaying }
  var playbackPosition: Double { playback.duration > 0 ? playback.currentTime : playbackStartTime }
  var playbackDuration: Double {
    playback.duration > 0 ? playback.duration : selected?.duration ?? 0
  }
  var playbackLevel: Float { playback.level }
  var canPlay: Bool {
    !isCapturing && !transportBusy && !exporting && !refining && libraryFilter != .trash
      && (selected?.frameCount ?? 0) > 0
  }
  var canOrganize: Bool { !isCapturing && !transportBusy && !exporting && !refining }
  var canTrashSelection: Bool {
    canOrganize && libraryFilter != .trash
      && visibleSessions.contains { selectedIDs.contains($0.id) }
  }
  var trashConfirmationMessage: String {
    if pendingTrashIDs.count == 1,
      let session = sessions.first(where: { $0.id == pendingTrashIDs.first })
    {
      return "「\(session.title)」をごみ箱へ移動します。ごみ箱から戻せます。"
    }
    return "\(pendingTrashIDs.count)件の録音をごみ箱へ移動します。ごみ箱から戻せます。"
  }
  var canRefine: Bool { canPlay && selected?.status == .completed }
  var canRestoreTranscript: Bool {
    canOrganize && libraryFilter != .trash && selected?.originalTranscript != nil
  }
  private var selectedDirectory: URL? {
    guard let files, let selectedID else { return nil }
    return libraryFilter == .trash
      ? files.trashDirectory(selectedID)
      : files.directory(selectedID)
  }
  var isCapturing: Bool { activeID != nil }
  var transportBusy: Bool { phase == .preparing || phase == .finalizing }
  var canExport: Bool { canPlay }
  var canEditChain: Bool {
    !transportBusy && !isPlaying && !refining && !exporting && libraryFilter != .trash
      && (!isCapturing || preferences.settings.effectTiming == .afterRecording)
  }
  private var marker: URL {
    if let customMarker { return customMarker }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/EasyPod/active-recording")
  }

  init(
    loadSessions: Bool = true, sessionRoot: URL? = nil,
    preferences: PreferencesStore? = nil,
    playback: PlaybackService? = nil,
    refinement: TranscriptRefinementService = TranscriptRefinementService(),
    permissionRequest: @escaping @MainActor () async -> Bool = {
      await AudioDeviceService.requestPermission()
    }
  ) {
    self.playback = playback ?? PlaybackService()
    self.refinement = refinement
    self.permissionRequest = permissionRequest
    self.customMarker = sessionRoot?.appendingPathComponent(".active-recording")
    if let preferences { self.preferences = preferences }
    guard loadSessions else { return }
    do {
      let files = try SessionFileService(root: sessionRoot)
      self.files = files
      sessions = try files.load()
      trashedSessions = try files.loadTrashed()
      do { folders = try files.loadFolders() } catch { self.error = error.localizedDescription }
      if let first = sessions.first { select(first.id) }
    } catch { self.error = error.localizedDescription }
    transcription.onChange = { [weak self] segments, status in
      guard let self, let id = self.activeID,
        let index = self.sessions.firstIndex(where: { $0.id == id })
      else { return }
      self.sessions[index].transcript = segments
      self.sessions[index].transcriptionStatus = status
      self.persist(self.sessions[index])
    }
    refreshInputs()
  }

  func refreshInputs() { inputDevices = AudioDeviceService.inputs() }

  func select(_ id: UUID) {
    guard canOrganize, visibleSessions.contains(where: { $0.id == id }) else { return }
    selectedIDs = [id]
    displaySelection(id)
  }

  func setLibrarySelection(_ ids: Set<UUID>) {
    guard canOrganize else { return }
    let rows = visibleSessions.filter { ids.contains($0.id) }
    let valid = Set(rows.map(\.id))
    let added = valid.subtracting(selectedIDs)
    let target =
      rows.first(where: { added.contains($0.id) })?.id
      ?? rows.first(where: { $0.id == selectedID })?.id ?? rows.first?.id
    selectedIDs = valid
    if let target {
      if selectedID != target { displaySelection(target) }
    } else {
      clearSelection()
    }
  }

  private func displaySelection(_ id: UUID) {
    stopPlayback()
    saveEffects()
    selectedID = id
    guard let selected else { return }
    title = selected.title
    elapsed = selected.duration
    effects = selected.effects
    chain = nil
    peaks = []
    phase = selected.status == .interrupted ? .interrupted : .completed
    if let directory = selectedDirectory {
      Task { [weak self] in
        let waveform = try? await WaveformService.load(
          directory.appendingPathComponent("source.caf"))
        guard let self, self.selectedID == id, !self.isCapturing else { return }
        self.peaks = waveform ?? []
      }
    }
  }

  func newRecording() {
    guard canOrganize else { return }
    cancelTrashRequest()
    if libraryFilter == .trash { libraryFilter = .all }
    clearSelection()
  }

  private func clearSelection() {
    stopPlayback()
    saveEffects()
    selectedID = nil
    selectedIDs = []
    title = "新しい録音"
    elapsed = 0
    peaks = []
    effects = []
    chain = nil
    preferences.settings.effectTiming = .afterRecording
    phase = .idle
  }

  func rename() {
    guard let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
    sessions[index].title =
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "無題の録音" : title
    persist(sessions[index])
  }

  func start() async {
    guard !terminating, canOrganize, libraryFilter != .trash, let files else { return }
    stopPlayback()
    phase = .preparing
    do {
      let allowed = await permissionRequest()
      guard !terminating else {
        phase = .idle
        return
      }
      guard allowed else {
        throw EasyPodError.message(
          "マイクの使用が許可されていません。システム設定の「プライバシーとセキュリティ → マイク」でEasyPodを許可してください。")
      }
      saveEffects()
      let settings = preferences.settings
      let live = settings.effectTiming == .duringRecording
      let newChain =
        live
        ? try await effectService.build(
          slots: effects, sampleRate: settings.sampleRate, channels: settings.channels) : nil
      guard !terminating else {
        phase = .idle
        return
      }
      var session = RecordingSession(title: title, settings: settings, effects: effects)
      session.transcriptionStatus = preferences.transcriptionEnabled ? "モデルを読み込み中" : "文字起こし オフ"
      if session.title == "新しい録音" {
        session.title = Date.now.formatted(.dateTime.month().day().hour().minute()) + " の録音"
      }
      try files.save(session)
      if case .folder(let folderID) = libraryFilter {
        session = try files.move(session, to: folderID)
      }
      try Data(session.id.uuidString.utf8).write(to: marker, options: .atomic)
      sessions.insert(session, at: 0)
      selectedID = session.id
      selectedIDs = [session.id]
      activeID = session.id
      lastSavedFrame = 0
      title = session.title
      chain = newChain
      try await capture.start(
        directory: files.directory(session.id), settings: settings,
        inputID: preferences.inputID, effects: newChain, monitor: monitor,
        onUpdate: { [weak self] update in self?.captureUpdated(update) })
      phase = .recording
      if preferences.transcriptionEnabled {
        transcription.start(
          modelPath: preferences.modelPath,
          source: files.directory(session.id).appendingPathComponent("source.caf"),
          sampleRate: settings.sampleRate)
      }
      logger.info("Recording started")
    } catch {
      if let id = activeID, let index = sessions.firstIndex(where: { $0.id == id }) {
        sessions[index].status = .interrupted
        sessions[index].warning = error.localizedDescription
        persist(sessions[index])
      }
      activeID = nil
      try? FileManager.default.removeItem(at: marker)
      phase = .idle
      self.error = error.localizedDescription
    }
  }

  private func captureUpdated(_ update: CaptureUpdate) {
    guard let id = activeID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    level = update.level
    peaks = Array(update.peaks.suffix(160))
    sessions[index].frameCount = update.frameCount
    elapsed = sessions[index].duration
    transcription.updateAvailable(frames: update.frameCount)
    if let warning = update.warning {
      sessions[index].warning = combinedWarning(sessions[index].warning, warning)
      if update.mustStop && phase == .recording { Task { await self.stop() } }
    }
    if update.isPaused && phase == .recording { phase = .paused }
    if update.frameCount - lastSavedFrame >= Int64(sessions[index].settings.sampleRate * 2) {
      lastSavedFrame = update.frameCount
      persist(sessions[index])
    }
  }

  func pauseOrResume() async {
    guard !transportBusy, let id = activeID else { return }
    do {
      if phase == .recording {
        phase = .finalizing
        try await capture.pause()
        if let session = sessions.first(where: { $0.id == id }) {
          await transcription.pause(frames: session.frameCount)
        }
        phase = .paused
        if let index = sessions.firstIndex(where: { $0.id == id }) {
          sessions[index].status = .paused
          persist(sessions[index])
        }
        saveEffects()
      } else if phase == .paused {
        phase = .preparing
        try await capture.resume()
        phase = .recording
        if let index = sessions.firstIndex(where: { $0.id == id }) {
          sessions[index].status = .recording
          persist(sessions[index])
        }
      }
    } catch {
      self.error = error.localizedDescription
      if let index = sessions.firstIndex(where: { $0.id == id }) {
        sessions[index].warning = combinedWarning(
          sessions[index].warning, "録音の一時停止／再開に失敗したため停止しました: \(error.localizedDescription)")
      }
      phase = .paused
      await stop()
    }
  }

  func stop() async {
    guard let id = activeID, phase != .finalizing else { return }
    phase = .finalizing
    var result: CaptureResult?
    do {
      result = try await capture.stop()
    } catch {
      self.error = error.localizedDescription
      if let index = sessions.firstIndex(where: { $0.id == id }) {
        sessions[index].warning = combinedWarning(
          sessions[index].warning, error.localizedDescription)
      }
    }
    if let result, let index = sessions.firstIndex(where: { $0.id == id }) {
      sessions[index].frameCount = result.frameCount
      sessions[index].processedComplete = result.processedComplete
      sessions[index].warning = combinedWarning(sessions[index].warning, result.warning)
      elapsed = sessions[index].duration
      sessions[index].status = .finalizing
      // Metadata failure must not bypass ASR finalization and native-handle cleanup.
      persist(sessions[index])
    }
    let finalFrames = result?.frameCount ?? sessions.first(where: { $0.id == id })?.frameCount ?? 0
    await transcription.finish(frames: finalFrames)
    saveEffects()
    let sourceComplete = result?.sourceComplete == true
    var finalPhase: TransportPhase = sourceComplete ? .completed : .interrupted
    if let index = sessions.firstIndex(where: { $0.id == id }) {
      if preferences.transcriptionEnabled { sessions[index].transcript = transcription.segments }
      sessions[index].status = sourceComplete ? .completed : .interrupted
      do {
        try files?.save(sessions[index])
      } catch {
        self.error = error.localizedDescription
        sessions[index].status = .interrupted
        sessions[index].warning = combinedWarning(
          sessions[index].warning, error.localizedDescription)
        finalPhase = .interrupted
      }
    }
    activeID = nil
    try? FileManager.default.removeItem(at: marker)
    phase = finalPhase
    level = 0
    logger.info("Recording finalized")
  }

  func recover() {
    guard canOrganize, libraryFilter != .trash else { return }
    guard let index = sessions.firstIndex(where: { $0.id == selectedID }), let files else { return }
    do {
      let audio = try AVAudioFile(
        forReading: files.directory(sessions[index].id).appendingPathComponent("source.caf"))
      sessions[index].frameCount = audio.length
      sessions[index].status = .completed
      sessions[index].processedComplete = false
      sessions[index].warning = "中断前に保存されたオリジナル音声を復旧しました。"
      try files.save(sessions[index])
      phase = .completed
    } catch { self.error = error.localizedDescription }
  }

  func discoverPlugins(force: Bool = false) async {
    guard !scanning else { return }
    scanning = true
    plugins = await catalog.discover(force: force)
    scanning = false
  }

  func addEffect(_ plugin: PluginDescriptor) async {
    guard canEditChain, plugin.unavailableReason == nil else { return }
    stopPlayback()
    saveEffects()
    effects.append(EffectSlot(plugin: plugin))
    await prepareEditorChain()
    persistEffects()
  }

  func removeEffect(_ id: UUID) async {
    guard canEditChain else { return }
    stopPlayback()
    saveEffects()
    effects.removeAll { $0.id == id }
    await prepareEditorChain()
    persistEffects()
  }

  func moveEffect(_ id: UUID, delta: Int) async {
    guard canEditChain, let index = effects.firstIndex(where: { $0.id == id }),
      effects.indices.contains(index + delta)
    else { return }
    stopPlayback()
    saveEffects()
    effects.swapAt(index, index + delta)
    await prepareEditorChain()
    persistEffects()
  }

  func bypass(_ id: UUID) {
    guard !transportBusy, !refining, !exporting, libraryFilter != .trash,
      let index = effects.firstIndex(where: { $0.id == id })
    else { return }
    effects[index].bypassed.toggle()
    chain?.setBypass(id: id, bypassed: effects[index].bypassed)
    persistEffects()
  }

  func editEffect(_ id: UUID) async {
    if chain == nil { await prepareEditorChain() }
    chain?.showEditor(id: id)
  }

  private func prepareEditorChain() async {
    guard !isCapturing else {
      chain = nil
      return
    }
    do {
      chain = try await effectService.build(
        slots: effects,
        sampleRate: selected?.settings.sampleRate ?? preferences.settings.sampleRate,
        channels: selected?.settings.channels ?? preferences.settings.channels)
    } catch {
      chain = nil
      self.error = error.localizedDescription
    }
  }

  func saveEffects() {
    guard !isPlaying, phase != .recording else { return }
    do {
      if let chain { effects = try chain.snapshot() }
      persistEffects()
    } catch { self.error = error.localizedDescription }
  }

  private func persistEffects() {
    guard let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
    sessions[index].effects = effects
    persist(sessions[index])
  }

  func togglePlayback(original: Bool = false) async {
    guard canPlay, let session = selected, let files else { return }
    do {
      if isPlaying {
        playback.pause()
        return
      }
      if playback.duration > 0, playback.currentTime < playback.duration {
        try playback.resume()
        return
      }
      saveEffects()
      let useProcessed =
        !original && session.settings.effectTiming == .duringRecording && session.processedComplete
      let generation = playbackGeneration
      let preparedChain =
        !original && !useProcessed
        ? try await effectService.build(
          slots: effects, sampleRate: session.settings.sampleRate,
          channels: session.settings.channels) : nil
      guard canPlay, selectedID == session.id, playbackGeneration == generation else { return }
      chain = preparedChain
      let startTime = playbackPosition >= session.duration ? 0 : playbackPosition
      try playback.play(
        url: files.directory(session.id).appendingPathComponent(
          useProcessed ? "processed.caf" : "source.caf"), effects: chain, startTime: startTime
      ) {}
    } catch { self.error = error.localizedDescription }
  }

  func seekPlayback(to seconds: Double) {
    guard canPlay, seconds.isFinite else { return }
    let position = min(playbackDuration, max(0, seconds))
    do {
      if playback.duration > 0 {
        try playback.seek(to: position)
      } else {
        playbackStartTime = position
      }
    } catch { self.error = error.localizedDescription }
  }

  func skipPlayback(seconds: Double) { seekPlayback(to: playbackPosition + seconds) }

  func stopPlayback() {
    playbackGeneration = UUID()
    playback.stop()
    playbackStartTime = 0
  }

  func setLibraryFilter(_ filter: RecordingLibraryFilter) {
    guard canOrganize else { return }
    cancelTrashRequest()
    stopPlayback()
    saveEffects()
    libraryFilter = filter
    selectedID = nil
    selectedIDs = []
    if let first = visibleSessions.first { select(first.id) } else { clearSelection() }
  }

  private func reloadLibrary(preferredID: UUID? = nil, preservingSelection: Bool = false) throws {
    guard let files else { return }
    sessions = try files.load()
    trashedSessions = try files.loadTrashed()
    do { folders = try files.loadFolders() } catch {
      folders = []
      self.error = error.localizedDescription
    }
    reconcileLibrarySelection(preferredID: preferredID, preservingSelection: preservingSelection)
  }

  private func reconcileLibrarySelection(
    preferredID: UUID? = nil, preservingSelection: Bool = false
  ) {
    if preservingSelection {
      selectedIDs.formIntersection(Set(visibleSessions.map(\.id)))
      if !selectedIDs.isEmpty {
        let rows = visibleSessions.filter { selectedIDs.contains($0.id) }
        let target = rows.first(where: { $0.id == selectedID })?.id ?? rows.first?.id
        if let target { displaySelection(target) }
        return
      }
    }
    let target = preferredID ?? selectedID
    if let target, visibleSessions.contains(where: { $0.id == target }) {
      select(target)
    } else if let first = visibleSessions.first {
      select(first.id)
    } else {
      clearSelection()
    }
  }

  func createFolder(named name: String) {
    guard canOrganize, let files else { return }
    do {
      let folder = try files.createFolder(named: name)
      folders = try files.loadFolders()
      setLibraryFilter(.folder(folder.id))
    } catch { self.error = error.localizedDescription }
  }

  func renameFolder(_ id: UUID, to name: String) {
    guard canOrganize, let files else { return }
    do {
      _ = try files.renameFolder(id, to: name)
      folders = try files.loadFolders()
    } catch { self.error = error.localizedDescription }
  }

  func deleteFolder(_ id: UUID) {
    guard canOrganize, let files else { return }
    do {
      stopPlayback()
      saveEffects()
      try files.deleteFolder(id)
      if libraryFilter == .folder(id) { libraryFilter = .unfiled }
      try reloadLibrary()
    } catch { self.error = error.localizedDescription }
  }

  func moveRecording(_ id: UUID, to folderID: UUID?) {
    guard canOrganize, libraryFilter != .trash, let files else { return }
    do {
      stopPlayback()
      saveEffects()
      guard let session = sessions.first(where: { $0.id == id }) else { return }
      _ = try files.move(session, to: folderID)
      try reloadLibrary(preferredID: id)
    } catch { self.error = error.localizedDescription }
  }

  func trashRecording(_ id: UUID) {
    guard canOrganize, libraryFilter != .trash, let files else { return }
    do {
      stopPlayback()
      saveEffects()
      try files.trash(id)
      // Do not let selection cleanup re-save a directory after moving it to Trash.
      selectedID = nil
      selectedIDs = []
      chain = nil
      try reloadLibrary()
    } catch { self.error = error.localizedDescription }
  }

  func requestTrashSelection() {
    requestTrash(ids: selectedIDs)
  }

  func requestTrashRecording(_ id: UUID) {
    requestTrash(ids: selectedIDs.contains(id) ? selectedIDs : [id])
  }

  private func requestTrash(ids: Set<UUID>) {
    guard !terminating, canOrganize, libraryFilter != .trash else { return }
    pendingTrashIDs = visibleSessions.filter { ids.contains($0.id) }.map(\.id)
    showTrashConfirmation = !pendingTrashIDs.isEmpty
  }

  func cancelTrashRequest() {
    showTrashConfirmation = false
    pendingTrashIDs = []
  }

  func confirmRequestedTrash() {
    // Consume the immutable target snapshot once; later selection changes cannot expand it.
    let ids = pendingTrashIDs
    cancelTrashRequest()
    guard !terminating, canOrganize, libraryFilter != .trash, let files, !ids.isEmpty else {
      return
    }
    let visibleIDs = Set(visibleSessions.map(\.id))
    guard ids.allSatisfy({ visibleIDs.contains($0) }) else {
      error = "削除する録音の一覧が変わりました。もう一度選択してください。"
      return
    }
    stopPlayback()
    do {
      if let chain { effects = try chain.snapshot() }
      if let index = sessions.firstIndex(where: { $0.id == selectedID }) {
        var updated = sessions[index]
        updated.effects = effects
        try files.save(updated)
        sessions[index] = updated
      }
    } catch {
      self.error = "録音の変更を保存できなかったため、削除を中止しました。\n\(error.localizedDescription)"
      return
    }
    let targets = sessions.filter { ids.contains($0.id) }
    var moved: Set<UUID> = []
    var failures: [String] = []
    for id in ids {
      do {
        try files.trash(id)
        moved.insert(id)
      } catch {
        let name = targets.first(where: { $0.id == id })?.title ?? "録音"
        failures.append("\(name): \(error.localizedDescription)")
      }
    }
    // Reconcile successful moves before any selection cleanup can save old session state.
    sessions.removeAll { moved.contains($0.id) }
    trashedSessions.append(contentsOf: targets.filter { moved.contains($0.id) })
    selectedIDs.subtract(moved)
    if let selectedID, moved.contains(selectedID) {
      self.selectedID = nil
      chain = nil
    }
    var reloadFailure: String?
    do {
      try reloadLibrary(preservingSelection: true)
    } catch {
      reconcileLibrarySelection(preservingSelection: true)
      reloadFailure = "一覧を更新できませんでした: \(error.localizedDescription)"
    }
    if !failures.isEmpty {
      let details = failures.prefix(3).joined(separator: "\n")
      let remaining = failures.count > 3 ? "\nほか\(failures.count - 3)件" : ""
      error =
        "\(ids.count)件中\(moved.count)件をごみ箱へ移動しました。"
        + "\(failures.count)件は移動できませんでした。\n\(details)\(remaining)"
      if let reloadFailure { error = (error ?? "") + "\n" + reloadFailure }
    } else if let reloadFailure {
      error = "ごみ箱への移動は完了しました。\n" + reloadFailure
    }
  }

  func restoreRecording(_ id: UUID) {
    guard canOrganize, let files else { return }
    do {
      let restored = try files.restore(id)
      selectedID = nil
      selectedIDs = []
      libraryFilter = .all
      try reloadLibrary(preferredID: restored.id)
    } catch { self.error = error.localizedDescription }
  }

  func refineTranscript() {
    guard canRefine, let session = selected, let files else { return }
    stopPlayback()
    let job = UUID()
    refinementID = job
    refining = true
    refinementCancelling = false
    refinementProgress = 0
    let source = files.directory(session.id).appendingPathComponent("source.caf")
    let model = preferences.modelPath
    refinementTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.refining = false
        self.refinementCancelling = false
        self.refinementID = nil
        self.refinementTask = nil
      }
      do {
        let segments = try await self.refinement.recognize(
          source: source, modelPath: model,
          onProgress: { [weak self] progress in
            Task { @MainActor in
              guard let self, self.refinementID == job else { return }
              self.refinementProgress = max(self.refinementProgress, progress)
            }
          })
        try Task.checkCancellation()
        guard let index = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var updated = self.sessions[index]
        if updated.originalTranscript == nil {
          updated.originalTranscript = updated.transcript
          updated.originalTranscriptionStatus = updated.transcriptionStatus
        }
        updated.transcript = segments
        updated.transcriptionStatus = "清書完了 · ローカル再認識"
        // Publish new text only after the commit-last manifest save succeeds.
        try files.save(updated)
        self.sessions[index] = updated
        self.refinementProgress = 1
      } catch is CancellationError {
        // The previous transcript remains authoritative until a complete successful save.
      } catch { self.error = "清書に失敗しました: \(error.localizedDescription)" }
    }
  }

  func cancelRefinement() {
    guard refining else { return }
    refinementCancelling = true
    refinementTask?.cancel()
  }

  func restoreOriginalTranscript() {
    guard canRestoreTranscript, let files,
      let index = sessions.firstIndex(where: { $0.id == selectedID }),
      let original = sessions[index].originalTranscript
    else { return }
    do {
      var updated = sessions[index]
      updated.transcript = original
      updated.transcriptionStatus = updated.originalTranscriptionStatus
      updated.originalTranscript = nil
      updated.originalTranscriptionStatus = nil
      try files.save(updated)
      sessions[index] = updated
    } catch { self.error = error.localizedDescription }
  }

  func export(destination: URL, request: ExportRequest) async {
    guard canExport, let session = selected, let files else { return }
    stopPlayback()
    saveEffects()
    exporting = true
    exportProgress = 0
    defer { exporting = false }
    do {
      let snapshot = effects
      let applyChain = request.includeEffects && request.source == .original
      let exportChain =
        applyChain
        ? try await effectService.build(
          slots: snapshot, sampleRate: request.settings.sampleRate,
          channels: request.settings.channels, offline: true) : nil
      _ = try await exporter.export(
        session: session, directory: files.directory(session.id), destination: destination,
        request: request, effects: exportChain,
        onProgress: { [weak self] in self?.exportProgress = $0 })
      logger.info("Export completed")
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }

  func cancelExport() { exporter.cancel() }

  func setMonitoring(_ enabled: Bool) {
    monitor = enabled
    capture.setMonitoring(enabled)
  }

  func prepareForTermination() async {
    terminating = true
    if phase == .preparing && !isCapturing { phase = .idle }
    cancelExport()
    cancelRefinement()
    if let refinementTask { await refinementTask.value }
    while isCapturing || exporting {
      if isCapturing && !transportBusy {
        await stop()
      } else {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    stopPlayback()
    saveEffects()
  }

  private func persist(_ session: RecordingSession) {
    do { try files?.save(session) } catch {
      let reason = "保存に失敗しました: \(error.localizedDescription)"
      self.error = reason
      if let index = sessions.firstIndex(where: { $0.id == session.id }) {
        sessions[index].warning = combinedWarning(sessions[index].warning, reason)
      }
      if isCapturing && phase == .recording { Task { await self.stop() } }
    }
  }

  private func combinedWarning(_ existing: String?, _ incoming: String?) -> String? {
    guard let incoming, !incoming.isEmpty else { return existing }
    guard let existing, !existing.isEmpty else { return incoming }
    return existing.contains(incoming) ? existing : existing + "\n" + incoming
  }
}
