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

@MainActor @Observable final class RecordingStore {
  var preferences = PreferencesStore()
  let transcription = TranscriptionService()
  var sessions: [RecordingSession] = []
  var selectedID: UUID?
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
  var isPlaying = false
  var inputDevices: [AudioInputDevice] = []
  var showExportSheet = false
  private var files: SessionFileService?
  private let capture = AudioCaptureService()
  private let playback = PlaybackService()
  private let exporter = AudioExportService()
  private let effectService = EffectChainService()
  private let catalog = PluginCatalogService()
  private var chain: EffectChain?
  private var activeID: UUID?
  private var lastSavedFrame: Int64 = 0
  private let logger = Logger(subsystem: "local.EasyPod", category: "session")

  var selected: RecordingSession? { sessions.first { $0.id == selectedID } }
  var isCapturing: Bool { activeID != nil }
  var transportBusy: Bool { phase == .preparing || phase == .finalizing }
  var canExport: Bool { !isCapturing && !exporting && (selected?.frameCount ?? 0) > 0 }
  var canEditChain: Bool {
    !transportBusy && !isPlaying
      && (!isCapturing || preferences.settings.effectTiming == .afterRecording)
  }
  private var marker: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/EasyPod/active-recording")
  }

  init(loadSessions: Bool = true) {
    guard loadSessions else { return }
    do {
      let files = try SessionFileService()
      self.files = files
      sessions = try files.load()
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
    guard !isCapturing, !exporting else { return }
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
    if let files {
      Task { [weak self] in
        let waveform = try? await WaveformService.load(
          files.directory(id).appendingPathComponent("source.caf"))
        guard let self, self.selectedID == id, !self.isCapturing else { return }
        self.peaks = waveform ?? []
      }
    }
  }

  func newRecording() {
    guard !isCapturing, !exporting else { return }
    stopPlayback()
    saveEffects()
    selectedID = nil
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
    guard !isCapturing, !exporting, let files else { return }
    stopPlayback()
    phase = .preparing
    do {
      let allowed = await AudioDeviceService.requestPermission()
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
      var session = RecordingSession(title: title, settings: settings, effects: effects)
      session.transcriptionStatus = preferences.transcriptionEnabled ? "モデルを読み込み中" : "文字起こし オフ"
      if session.title == "新しい録音" {
        session.title = Date.now.formatted(.dateTime.month().day().hour().minute()) + " の録音"
      }
      try files.save(session)
      try Data(session.id.uuidString.utf8).write(to: marker, options: .atomic)
      sessions.insert(session, at: 0)
      selectedID = session.id
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
      sessions[index].transcript = transcription.segments
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
    saveEffects()
    effects.append(EffectSlot(plugin: plugin))
    await prepareEditorChain()
    persistEffects()
  }

  func removeEffect(_ id: UUID) async {
    guard canEditChain else { return }
    saveEffects()
    effects.removeAll { $0.id == id }
    await prepareEditorChain()
    persistEffects()
  }

  func moveEffect(_ id: UUID, delta: Int) async {
    guard canEditChain, let index = effects.firstIndex(where: { $0.id == id }),
      effects.indices.contains(index + delta)
    else { return }
    saveEffects()
    effects.swapAt(index, index + delta)
    await prepareEditorChain()
    persistEffects()
  }

  func bypass(_ id: UUID) {
    guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
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
    guard !isCapturing, let session = selected, let files else { return }
    if isPlaying {
      stopPlayback()
      return
    }
    do {
      saveEffects()
      let useProcessed =
        !original && session.settings.effectTiming == .duringRecording && session.processedComplete
      let useChain = !original && !useProcessed
      chain =
        useChain
        ? try await effectService.build(
          slots: effects, sampleRate: session.settings.sampleRate,
          channels: session.settings.channels) : nil
      try playback.play(
        url: files.directory(session.id).appendingPathComponent(
          useProcessed ? "processed.caf" : "source.caf"), effects: chain
      ) { [weak self] in self?.isPlaying = false }
      isPlaying = true
    } catch { self.error = error.localizedDescription }
  }

  func stopPlayback() {
    playback.stop()
    isPlaying = false
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
    cancelExport()
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
