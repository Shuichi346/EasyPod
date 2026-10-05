import SwiftUI

extension Color { static let coral = Color(red: 0.91, green: 0.30, blue: 0.25) }

enum AudioTime {
  static func string(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
  }
}

enum LiveWaveformLayout {
  static let barWidth: CGFloat = 2
  static let pitch: CGFloat = 4
  static let maximumBars = 160
  // Capture publishes one peak every 100 milliseconds on MainActor.
  static let sampleInterval: TimeInterval = 0.1

  static func visibleCount(peakCount: Int, width: CGFloat) -> Int {
    guard peakCount > 0, width.isFinite, width > 0 else { return 0 }
    // One extra bar can cross the left boundary while the remaining bars move.
    let capacity = Int(min(CGFloat(maximumBars), ceil(width / pitch))) + 1
    return min(peakCount, maximumBars, capacity)
  }

  static func phase(elapsed: TimeInterval) -> Double {
    guard !elapsed.isNaN else { return 0 }
    return min(1, max(0, elapsed / sampleInterval))
  }

  static func xPosition(index: Int, count: Int, width: CGFloat, phase: Double) -> CGFloat {
    let shift = CGFloat(Self.phase(elapsed: phase * sampleInterval)) * pitch
    return width - barWidth - CGFloat(count - 1 - index) * pitch - shift
  }
}

struct LiveWaveformMotion {
  private var sampleDate: Date
  private var active = false
  private var pausedPhase = 0.0

  init(at date: Date = .now) { sampleDate = date }

  func phase(at date: Date) -> Double {
    active ? LiveWaveformLayout.phase(elapsed: date.timeIntervalSince(sampleDate)) : pausedPhase
  }

  mutating func setActive(_ active: Bool, at date: Date) {
    guard self.active != active else { return }
    pausedPhase = phase(at: date)
    self.active = active
    if active {
      sampleDate = date.addingTimeInterval(-pausedPhase * LiveWaveformLayout.sampleInterval)
    }
  }

  mutating func receivedSample(at date: Date) {
    guard active else { return }
    sampleDate = date
  }
}

struct WaveformView: View {
  let peaks: [Float]
  let active: Bool
  var liveTime: TimeInterval?
  var progress: Double?
  @State private var motion = LiveWaveformMotion()
  @State private var latestSampleTime: TimeInterval?

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || liveTime == nil)) {
      timeline in
      Canvas { context, size in
        if peaks.isEmpty {
          let rect = CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)
          context.fill(Path(rect), with: .color(.coral.opacity(0.25)))
          return
        }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let live = liveTime != nil
        let count =
          live
          ? LiveWaveformLayout.visibleCount(peakCount: peaks.count, width: size.width) : peaks.count
        guard count > 0 else { return }
        let values = peaks.suffix(count)
        let spacing = size.width / CGFloat(count)
        // A newly published column starts at the right edge before onChange updates its clock.
        let phase = active && latestSampleTime != liveTime ? 0 : motion.phase(at: timeline.date)
        for (index, peak) in values.enumerated() {
          let height = max(
            4, min(size.height * 0.94, CGFloat(sqrt(max(0, peak))) * size.height * 0.94))
          let x =
            live
            ? LiveWaveformLayout.xPosition(
              index: index, count: count, width: size.width, phase: phase)
            : CGFloat(index) * spacing
          let width = live ? LiveWaveformLayout.barWidth : max(1.5, min(3.5, spacing * 0.5))
          let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
          context.fill(
            Path(roundedRect: rect, cornerRadius: 2),
            with: .color(.coral.opacity(0.85)))
        }
      }
    }
    .onAppear {
      latestSampleTime = liveTime
      motion.setActive(active && liveTime != nil, at: .now)
    }
    .onChange(of: active) { _, active in
      motion.setActive(active && liveTime != nil, at: .now)
    }
    .onChange(of: liveTime) { _, time in
      latestSampleTime = time
      if time == nil {
        motion = LiveWaveformMotion()
      } else {
        motion.setActive(active, at: .now)
        // The sample clock changes even when a full window contains identical peaks.
        motion.receivedSample(at: .now)
      }
    }
    .overlay {
      if peaks.isEmpty {
        Text("録音を始めると波形が表示されます").font(.system(size: 12)).foregroundStyle(.secondary)
          .offset(y: 24)
      }
    }
    .overlay {
      if let progress {
        GeometryReader { geometry in
          let position = min(1, max(0, progress)) * geometry.size.width
          Rectangle().fill(Color.coral.opacity(0.08)).frame(width: position)
          Rectangle().fill(Color.coral).frame(width: 2).offset(x: position)
        }.allowsHitTesting(false)
      }
    }
    .accessibilityLabel(active ? "録音中の波形" : liveTime != nil ? "一時停止中の波形" : "音声の波形")
    .accessibilityValue(
      liveTime != nil
        ? "直近の録音波形"
        : progress.map { "再生位置 \(Int($0 * 100))パーセント" } ?? "")
  }
}
