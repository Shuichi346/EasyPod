import AVFoundation
import Darwin
import Foundation

struct CapturePipelineState: Sendable {
  var inputError: Int32 = 0
  var processingError: Int32 = 0
  var monitoringError: Int32 = 0
  var cleanupError: Int32 = 0
}

// Implementations are used only by the pipeline's serial owner after construction.
protocol CaptureInputSource: Sendable {
  var sampleRate: Double { get }
  var channels: UInt32 { get }
  func start() -> Int32
  func stop() -> Int32
  func close() -> Int32
  func read(_ buffers: UnsafeMutablePointer<AudioBufferList>, maximumFrames: UInt32) -> UInt32
  func error() -> Int32
}

final class CaptureInputDevice: CaptureInputSource, @unchecked Sendable {
  let sampleRate: Double
  let channels: UInt32
  private var handle: OpaquePointer?

  init(deviceID: UInt32) throws {
    var code: Int32 = 0
    guard let handle = ep_input_create(deviceID, &code) else {
      throw EasyPodError.message("マイク入力を準備できませんでした（\(code)）。")
    }
    self.handle = handle
    sampleRate = ep_input_sample_rate(handle)
    channels = ep_input_channels(handle)
  }

  func start() -> Int32 { handle.map(ep_input_start) ?? -50 }
  func stop() -> Int32 { handle.map(ep_input_stop) ?? 0 }
  func close() -> Int32 {
    guard let handle else { return 0 }
    let code = ep_input_destroy(handle)
    if code == 0 { self.handle = nil }
    return code
  }
  func read(_ buffers: UnsafeMutablePointer<AudioBufferList>, maximumFrames: UInt32) -> UInt32 {
    guard let handle else { return 0 }
    return ep_input_read(handle, buffers, maximumFrames)
  }
  func error() -> Int32 { handle.map(ep_input_error) ?? -50 }
}

// After construction, converter, input and render engine belong exclusively to queue.
// MainActor controls effects only while the queue is suspended and rendering has stopped.
final class CaptureInputPipeline: @unchecked Sendable {
  let feed: OpaquePointer
  let monitorFeed: OpaquePointer
  private let input: any CaptureInputSource
  private let writer: CaptureWriterHandle
  private let engine: AVAudioEngine
  private let converter: AVAudioConverter
  private let raw: AVAudioPCMBuffer
  private let converted: AVAudioPCMBuffer
  private let chunk: AVAudioPCMBuffer
  private let rendered: AVAudioPCMBuffer
  private let render: AVAudioEngineManualRenderingBlock
  private let sampleRate: Double
  private let queue = DispatchQueue(label: "local.EasyPod.capture.processing", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var frame: Int64 = 0
  private var anchorFrame: Int64 = 0
  private var anchorHost: UInt64 = 0
  private var state = CapturePipelineState()
  private var processing: Bool
  private var monitoring = false
  private var closed = false
  private var lastInput: ContinuousClock.Instant?
  private var segmentInputFrames: UInt64 = 0
  private var segmentOutputFrames: UInt64 = 0

  init(
    input: any CaptureInputSource, writer: CaptureWriterHandle, engine: AVAudioEngine,
    feed: OpaquePointer, monitorFeed: OpaquePointer, format: AVAudioFormat,
    processing: Bool
  ) throws {
    let inputFormat = AVAudioFormat(
      standardFormatWithSampleRate: input.sampleRate, channels: input.channels)
    guard let inputFormat,
      let converter = AVAudioConverter(from: inputFormat, to: format),
      let raw = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8192),
      let converted = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: UInt32(ceil(8192 * format.sampleRate / inputFormat.sampleRate)) + 256),
      let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
      let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
    else { throw EasyPodError.message("マイクの音声形式を変換できませんでした。") }
    converter.primeMethod = .none
    self.input = input
    self.writer = writer
    self.engine = engine
    self.feed = feed
    self.monitorFeed = monitorFeed
    self.converter = converter
    self.raw = raw
    self.converted = converted
    self.chunk = chunk
    self.rendered = rendered
    self.render = engine.manualRenderingBlock
    self.sampleRate = format.sampleRate
    self.processing = processing
  }

  private func perform<T: Sendable>(
    _ operation: @escaping @Sendable (CaptureInputPipeline) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try operation(self)) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func start() async throws {
    try await perform { pipeline in
      guard !pipeline.closed else { throw EasyPodError.message("録音の接続は終了しています。") }
      pipeline.converter.reset()
      pipeline.segmentInputFrames = 0
      pipeline.segmentOutputFrames = 0
      pipeline.anchorFrame = pipeline.frame
      pipeline.anchorHost = mach_absolute_time()
      pipeline.lastInput = ContinuousClock.now
      try pipeline.engine.start()
      let code = pipeline.input.start()
      guard code == 0 else {
        pipeline.engine.pause()
        throw EasyPodError.message("マイク入力を開始できませんでした（\(code)）。")
      }
      let timer = DispatchSource.makeTimerSource(queue: pipeline.queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
      timer.setEventHandler { [weak pipeline] in pipeline?.pump() }
      pipeline.timer = timer
      timer.resume()
    }
  }

  func snapshot() async -> CapturePipelineState {
    (try? await perform { $0.state }) ?? CapturePipelineState(inputError: -1)
  }

  func arm(latencyFrames: UInt64, processed: Bool) async throws {
    try await perform { pipeline in
      guard pipeline.state.inputError == 0 else {
        throw EasyPodError.message("マイク入力が中断されました（\(pipeline.state.inputError)）。")
      }
      guard !processed || pipeline.state.processingError == 0 else {
        throw EasyPodError.message("録音中エフェクトを準備できませんでした（\(pipeline.state.processingError)）。")
      }
      // Both branches are serialized here, so the very next frame is a shared stable boundary.
      ep_capture_segment(pipeline.writer.pointer, pipeline.frame, latencyFrames)
      ep_capture_enable_source(pipeline.writer.pointer, true)
      if processed { ep_capture_enable_processed(pipeline.writer.pointer, true) }
    }
  }

  func setMonitoring(_ enabled: Bool) async {
    _ = try? await perform { pipeline in
      if enabled { pipeline.state.monitoringError = 0 }
      pipeline.monitoring = enabled
    }
  }

  // Stop hardware first, then drain queued native and converter samples before disabling the writer.
  func pause(latency: Double, tail: Double) async {
    _ = try? await perform { pipeline in
      pipeline.timer?.cancel()
      pipeline.timer = nil
      let code = pipeline.input.stop()
      if code != 0 { pipeline.state.inputError = code }
      pipeline.pump(checkLiveness: false)
      pipeline.convert(endOfStream: true)
      ep_capture_enable_source(pipeline.writer.pointer, false)
      pipeline.drain(latency: latency, tail: tail)
      ep_capture_enable_processed(pipeline.writer.pointer, false)
      pipeline.engine.pause()
    }
  }

  func finishPaused(latency: Double, tail: Double) async {
    _ = try? await perform { pipeline in
      guard pipeline.processing, pipeline.state.processingError == 0 else { return }
      try pipeline.engine.start()
      ep_capture_enable_processed(pipeline.writer.pointer, true)
      pipeline.drain(latency: latency, tail: tail)
      ep_capture_enable_processed(pipeline.writer.pointer, false)
      pipeline.engine.pause()
    }
  }

  func close() async {
    _ = try? await perform { pipeline in
      if pipeline.closed {
        if pipeline.state.cleanupError != 0 { pipeline.state.cleanupError = pipeline.input.close() }
        return
      }
      pipeline.timer?.cancel()
      pipeline.timer = nil
      let stopError = pipeline.input.stop()
      if stopError != 0 { pipeline.state.inputError = stopError }
      pipeline.engine.stop()
      pipeline.state.cleanupError = pipeline.input.close()
      pipeline.closed = true
    }
  }

  func disableProcessing() async {
    _ = try? await perform { pipeline in
      pipeline.processing = false
      ep_capture_enable_processed(pipeline.writer.pointer, false)
    }
  }

  private func pump(checkLiveness: Bool = true) {
    guard !closed, !checkLiveness || state.inputError == 0 else { return }
    if checkLiveness {
      let code = input.error()
      if code != 0 {
        state.inputError = code
        return
      }
    }
    // Bound each event so control operations remain schedulable even during a backlog.
    for _ in 0..<64 {
      raw.frameLength = raw.frameCapacity
      let count = input.read(raw.mutableAudioBufferList, maximumFrames: raw.frameCapacity)
      guard count > 0 else { break }
      lastInput = ContinuousClock.now
      raw.frameLength = count
      segmentInputFrames += UInt64(count)
      convert(endOfStream: false)
      if checkLiveness, state.inputError != 0 { return }
    }
    if checkLiveness, let lastInput, ContinuousClock.now - lastInput > .seconds(2) {
      state.inputError = -71003
    }
  }

  private func convert(endOfStream: Bool) {
    var supplied = false
    // One persistent converter keeps interpolation history across hardware buffers.
    for _ in 0..<32 {
      var error: NSError?
      converted.frameLength = 0
      let result = converter.convert(to: converted, error: &error) { _, status in
        if endOfStream {
          status.pointee = .endOfStream
          return nil
        }
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return self.raw
      }
      if let error {
        state.inputError = Int32(error.code)
        return
      }
      if endOfStream {
        // Resamplers may flush filter-padding after the real input duration. Retire
        // converter state, but never append that padding to the recorded program.
        let target = UInt64(
          (Double(segmentInputFrames) * sampleRate / input.sampleRate).rounded(.down))
        let remaining = target > segmentOutputFrames ? target - segmentOutputFrames : 0
        converted.frameLength = UInt32(min(UInt64(converted.frameLength), remaining))
      }
      if converted.frameLength > 0 {
        segmentOutputFrames += UInt64(converted.frameLength)
        consume(converted)
      }
      if result == .error {
        state.inputError = -71004
        return
      }
      if result != .haveData || converted.frameLength == 0 { return }
    }
    state.inputError = -71004
  }

  private func consume(_ buffer: AVAudioPCMBuffer) {
    var offset: UInt32 = 0
    while offset < buffer.frameLength {
      let count = min(chunk.frameCapacity, buffer.frameLength - offset)
      chunk.frameLength = count
      for channel in 0..<Int(chunk.format.channelCount) {
        chunk.floatChannelData![channel].update(
          from: buffer.floatChannelData![channel] + Int(offset), count: Int(count))
      }
      let host =
        anchorHost + AVAudioTime.hostTime(forSeconds: Double(frame - anchorFrame) / sampleRate)
      ep_capture_push_source_clocked(
        writer.pointer, chunk.audioBufferList, count, frame, sampleRate, host, sampleRate)
      renderChunk(count: count, host: host)
      frame += Int64(count)
      offset += count
    }
  }

  private func renderChunk(count: UInt32, host: UInt64) {
    if processing, state.processingError == 0 {
      guard ep_pcm_push(feed, chunk.audioBufferList, count) else {
        state.processingError = ep_pcm_error(feed)
        return
      }
      var code: OSStatus = 0
      rendered.frameLength = count
      let result = render(count, rendered.mutableAudioBufferList, &code)
      guard result == .success, code == 0, ep_pcm_available(feed) == 0 else {
        state.processingError = code == 0 ? -71005 : code
        ep_capture_enable_processed(writer.pointer, false)
        return
      }
      ep_capture_push_processed_clocked(
        writer.pointer, rendered.audioBufferList, count, frame, sampleRate, host, sampleRate)
    }
    if monitoring, state.monitoringError == 0 {
      let buffer = processing && state.processingError == 0 ? rendered : chunk
      if !ep_pcm_push(monitorFeed, buffer.audioBufferList, count) {
        state.monitoringError = ep_pcm_error(monitorFeed)
        monitoring = false
      }
    }
  }

  private func drain(latency: Double, tail: Double) {
    guard processing, state.processingError == 0 else { return }
    let sourceFrames = ep_capture_status(writer.pointer).sourceQueuedFrames
    let maximum = UInt64(max(0, sourceFrames)) + UInt64((tail * sampleRate).rounded(.up))
    ep_capture_processed_limit(writer.pointer, maximum)
    let remaining = UInt64(((latency + tail) * sampleRate).rounded(.up)) + 4096
    var silenceFrames: UInt64 = 0
    while silenceFrames < remaining,
      ep_capture_status(writer.pointer).processedQueuedFrames < Int64(maximum),
      state.processingError == 0
    {
      let count = UInt32(min(UInt64(chunk.frameCapacity), remaining - silenceFrames))
      chunk.frameLength = count
      for channel in 0..<Int(chunk.format.channelCount) {
        chunk.floatChannelData![channel].update(repeating: 0, count: Int(count))
      }
      let host =
        anchorHost + AVAudioTime.hostTime(forSeconds: Double(frame - anchorFrame) / sampleRate)
      renderChunk(count: count, host: host)
      frame += Int64(count)
      silenceFrames += UInt64(count)
    }
  }
}
