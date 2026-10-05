import Foundation
import XCTest

@testable import EasyPod

final class WaveformTests: XCTestCase {
  func testLiveBarsKeepFixedPitchAndMoveLeftAsHistoryGrows() {
    let width: CGFloat = 400
    let first = LiveWaveformLayout.xPosition(index: 0, count: 3, width: width, phase: 0)
    let nextFirst = LiveWaveformLayout.xPosition(index: 0, count: 4, width: width, phase: 0)
    XCTAssertEqual(nextFirst, first - LiveWaveformLayout.pitch)
    XCTAssertEqual(LiveWaveformLayout.barWidth, 2)
    XCTAssertEqual(
      LiveWaveformLayout.xPosition(index: 2, count: 3, width: width, phase: 0),
      width - LiveWaveformLayout.barWidth)
    XCTAssertEqual(
      LiveWaveformLayout.xPosition(index: 159, count: 160, width: width, phase: 0),
      width - LiveWaveformLayout.barWidth)
    let adjacent = LiveWaveformLayout.xPosition(index: 1, count: 3, width: width, phase: 0)
    XCTAssertEqual(adjacent - first, LiveWaveformLayout.pitch)
    let halfway = LiveWaveformLayout.xPosition(index: 0, count: 3, width: width, phase: 0.5)
    XCTAssertEqual(halfway, first - LiveWaveformLayout.pitch / 2)
    // A retained sample lands at the same position on either side of a full-window update.
    XCTAssertEqual(
      LiveWaveformLayout.xPosition(index: 10, count: 160, width: width, phase: 1),
      LiveWaveformLayout.xPosition(index: 9, count: 160, width: width, phase: 0))
  }

  func testRecentWindowIsBoundedAndKeepsNewestSamples() {
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 1000, width: 1000), 160)
    XCTAssertEqual(
      Double(LiveWaveformLayout.maximumBars) * LiveWaveformLayout.sampleInterval, 16,
      accuracy: 0.00001)
    let visible = LiveWaveformLayout.visibleCount(peakCount: 1000, width: 40)
    XCTAssertEqual(visible, 11)
    let recent = Array((0..<1000).suffix(visible))
    XCTAssertEqual(recent.first, 989)
    XCTAssertEqual(recent.last, 999)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 3, width: 40), 3)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 0, width: 40), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: 0), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: -1), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: .infinity), 0)
    XCTAssertEqual(LiveWaveformLayout.visibleCount(peakCount: 10, width: .nan), 0)
  }

  func testScrollPhaseFreezesDuringPauseAndContinuesOnResume() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var motion = LiveWaveformMotion(at: start)
    motion.setActive(true, at: start)
    XCTAssertEqual(motion.phase(at: start.addingTimeInterval(0.025)), 0.25, accuracy: 0.00001)
    motion.setActive(false, at: start.addingTimeInterval(0.025))
    XCTAssertEqual(motion.phase(at: start.addingTimeInterval(100)), 0.25, accuracy: 0.00001)
    motion.receivedSample(at: start.addingTimeInterval(100))
    XCTAssertEqual(motion.phase(at: start.addingTimeInterval(200)), 0.25, accuracy: 0.00001)
    let resume = start.addingTimeInterval(300)
    motion.setActive(true, at: resume)
    XCTAssertEqual(motion.phase(at: resume), 0.25, accuracy: 0.00001)
    XCTAssertEqual(motion.phase(at: resume.addingTimeInterval(0.025)), 0.5, accuracy: 0.00001)
    XCTAssertEqual(motion.phase(at: resume.addingTimeInterval(0.1)), 1)
    motion.receivedSample(at: resume.addingTimeInterval(0.1))
    XCTAssertEqual(motion.phase(at: resume.addingTimeInterval(0.1)), 0)
    XCTAssertEqual(LiveWaveformLayout.phase(elapsed: -1), 0)
    XCTAssertEqual(LiveWaveformLayout.phase(elapsed: .infinity), 1)
    XCTAssertEqual(LiveWaveformLayout.phase(elapsed: .nan), 0)
  }
}
