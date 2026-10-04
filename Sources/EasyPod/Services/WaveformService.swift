import AVFoundation
import Foundation

enum WaveformService {
  static func load(_ source: URL) async throws -> [Float] {
    try await Task.detached(priority: .utility) {
      let file = try AVAudioFile(forReading: source)
      guard file.length > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
      else { return [] }
      var peaks = [Float](repeating: 0, count: 160)
      let framesPerBin = max(1, Double(file.length) / Double(peaks.count))
      while file.framePosition < file.length {
        try Task.checkCancellation()
        let start = file.framePosition
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { break }
        for frame in 0..<Int(buffer.frameLength) {
          let bin = min(peaks.count - 1, Int(Double(start + Int64(frame)) / framesPerBin))
          for channel in 0..<Int(buffer.format.channelCount) {
            peaks[bin] = max(peaks[bin], abs(channels[channel][frame]))
          }
        }
      }
      return peaks
    }.value
  }
}
