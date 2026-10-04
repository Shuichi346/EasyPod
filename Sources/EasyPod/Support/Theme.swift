import AppKit
import SwiftUI

enum Theme {
  static let canvas = adaptive(light: 0.975, dark: 0.12)
  static let sidebar = adaptive(light: 0.955, dark: 0.105)
  static let inspector = adaptive(light: 0.968, dark: 0.13)
  static let settings = adaptive(light: 0.955, dark: 0.145)
  static let control = adaptive(light: 0.995, dark: 0.21)
  static let track = adaptive(light: 0.93, dark: 0.17)
  static let border = adaptive(light: 0.86, dark: 0.29)

  private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(calibratedWhite: value, alpha: 1)
      })
  }
}
