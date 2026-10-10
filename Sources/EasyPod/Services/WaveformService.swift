import AVFoundation
import Foundation

enum WaveformService {
  private static let cache = WaveformCache()

  static func load(_ source: URL) async throws -> [Float] {
    try await cache.load(source)
  }

  static func read(_ source: URL) throws -> [Float] {
    try Task.checkCancellation()
    let file = try AVAudioFile(forReading: source)
    guard file.length > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
    else { return [] }
    var peaks = [Float](repeating: 0, count: 160)
    let framesPerBin = max(1, Double(file.length) / Double(peaks.count))
    let channelCount = Int(file.processingFormat.channelCount)
    while file.framePosition < file.length {
      try Task.checkCancellation()
      let start = file.framePosition
      try file.read(into: buffer)
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
        throw EasyPodError.message("保存済み音声の波形を最後まで読み込めませんでした。")
      }
      for frame in 0..<Int(buffer.frameLength) {
        let bin = min(peaks.count - 1, Int(Double(start + Int64(frame)) / framesPerBin))
        for channel in 0..<channelCount {
          peaks[bin] = max(peaks[bin], abs(channels[channel][frame]))
        }
      }
    }
    try Task.checkCancellation()
    return peaks
  }
}

private struct WaveformFileIdentity: Hashable, Sendable {
  let source: URL
  let device: UInt64
  let inode: UInt64
  let size: UInt64
  let modified: Date

  init(_ source: URL) throws {
    self.source = source.standardizedFileURL.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: self.source.path)
    device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
    inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    modified = attributes[.modificationDate] as? Date ?? .distantPast
  }
}

/// Shares identical requests and retires a cancelled decoder before starting another one.
actor WaveformCache {
  private struct Job {
    let identity: WaveformFileIdentity
    var waiters: [UUID: CheckedContinuation<[Float], Error>]
    var task: Task<Void, Never>?
  }

  private let capacity: Int
  private let reader: @Sendable (URL) async throws -> [Float]
  private var cached: [WaveformFileIdentity: [Float]] = [:]
  private var recency: [WaveformFileIdentity] = []
  private var jobs: [UUID: Job] = [:]
  private var identities: [WaveformFileIdentity: UUID] = [:]
  private var waiting: [UUID] = []
  private var active: UUID?

  init(
    capacity: Int = 8,
    reader: @escaping @Sendable (URL) async throws -> [Float] = { try WaveformService.read($0) }
  ) {
    self.capacity = max(1, capacity)
    self.reader = reader
  }

  var pendingRequestCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }

  func load(_ source: URL) async throws -> [Float] {
    try Task.checkCancellation()
    let identity = try WaveformFileIdentity(source)
    if let peaks = cached[identity] {
      touch(identity)
      return peaks
    }
    let waiter = UUID()
    let peaks = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[Float], Error>) in
        if let id = identities[identity], var job = jobs[id] {
          job.waiters[waiter] = continuation
          jobs[id] = job
        } else {
          let id = UUID()
          jobs[id] = Job(identity: identity, waiters: [waiter: continuation])
          identities[identity] = id
          waiting.append(id)
        }
        startNext()
      }
    } onCancel: {
      Task { await self.cancel(waiter) }
    }
    // A caller can cancel between decoder completion and continuation delivery.
    try Task.checkCancellation()
    return peaks
  }

  private func touch(_ identity: WaveformFileIdentity) {
    recency.removeAll { $0 == identity }
    recency.append(identity)
  }

  private func startNext() {
    guard active == nil else { return }
    while !waiting.isEmpty {
      let id = waiting.removeFirst()
      guard var job = jobs[id], !job.waiters.isEmpty else { continue }
      active = id
      let source = job.identity.source
      let reader = reader
      job.task = Task.detached(priority: .utility) {
        let result: Result<[Float], Error>
        do {
          let peaks = try await reader(source)
          try Task.checkCancellation()
          result = .success(peaks)
        } catch { result = .failure(error) }
        await self.complete(id, result: result)
      }
      jobs[id] = job
      return
    }
  }

  private func cancel(_ waiter: UUID) {
    for (id, var job) in jobs {
      guard let continuation = job.waiters.removeValue(forKey: waiter) else { continue }
      continuation.resume(throwing: CancellationError())
      if job.waiters.isEmpty {
        if identities[job.identity] == id { identities.removeValue(forKey: job.identity) }
        if active == id {
          job.task?.cancel()
          jobs[id] = job
        } else {
          jobs.removeValue(forKey: id)
          waiting.removeAll { $0 == id }
        }
      } else {
        jobs[id] = job
      }
      return
    }
  }

  private func complete(_ id: UUID, result: Result<[Float], Error>) {
    guard let job = jobs.removeValue(forKey: id) else { return }
    if identities[job.identity] == id { identities.removeValue(forKey: job.identity) }
    if case .success(let peaks) = result, !job.waiters.isEmpty,
      (try? WaveformFileIdentity(job.identity.source)) == job.identity
    {
      // File replacement or growth invalidates an older identity even at the same path.
      for identity in recency where identity.source == job.identity.source {
        cached.removeValue(forKey: identity)
      }
      recency.removeAll { $0.source == job.identity.source }
      cached[job.identity] = peaks
      touch(job.identity)
      while recency.count > capacity { cached.removeValue(forKey: recency.removeFirst()) }
    }
    if active == id { active = nil }
    for continuation in job.waiters.values { continuation.resume(with: result) }
    startNext()
  }
}
