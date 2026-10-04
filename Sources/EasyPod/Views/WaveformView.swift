import SwiftUI

extension Color { static let coral = Color(red: 0.91, green: 0.30, blue: 0.25) }

enum AudioTime {
  static func string(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
  }
}

struct WaveformView: View {
  let peaks: [Float]
  let active: Bool
  var body: some View {
    Canvas { context, size in
      if peaks.isEmpty {
        let rect = CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)
        context.fill(Path(rect), with: .color(.coral.opacity(0.25)))
        return
      }
      let values = peaks
      let spacing = size.width / CGFloat(values.count)
      for (index, peak) in values.enumerated() {
        let height = max(
          4, min(size.height * 0.94, CGFloat(sqrt(max(0, peak))) * size.height * 0.94))
        let rect = CGRect(
          x: CGFloat(index) * spacing, y: (size.height - height) / 2,
          width: max(1.5, min(3.5, spacing * 0.5)), height: height)
        context.fill(
          Path(roundedRect: rect, cornerRadius: 2),
          with: .color(.coral.opacity(0.85)))
      }
    }
    .overlay {
      if peaks.isEmpty {
        Text("録音を始めると波形が表示されます").font(.system(size: 12)).foregroundStyle(.secondary)
          .offset(y: 24)
      }
    }
    .accessibilityLabel(active ? "録音中の波形" : "音声の波形")
  }
}
