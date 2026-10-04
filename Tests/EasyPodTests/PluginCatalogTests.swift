import Foundation
import XCTest

@testable import EasyPod

@MainActor final class PluginCatalogTests: XCTestCase {
  func testScannerTimeoutAndFailureCache() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.resolvingSymlinksInPath()
      .appending(path: "EasyPodScannerTests-\(UUID())")
    defer { try? manager.removeItem(at: directory) }
    let plugins = directory.appending(path: "plugins")
    let candidate = plugins.appending(path: "Timeout.vst3")
    try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
    let cache = directory.appending(path: "cache/plugin-scan-cache.json")
    let helper = directory.appending(path: "scanner.sh")
    let count = directory.appending(path: "scanner.sh.count")
    let launchCounter = "printf 'launch\\n' >> \"$0.count\"\n"
    try ("#!/bin/sh\n" + launchCounter + "exec /bin/sleep 30\n")
      .write(to: helper, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

    let started = Date()
    let first = PluginCatalogService.scanVST3(
      helper: helper, force: false, directories: [plugins], cacheURL: cache, timeout: 0.5)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertEqual(first.count, 1)
    let failure = try XCTUnwrap(first.first)
    let scannedPath = try XCTUnwrap(failure.path)
    XCTAssertEqual(
      URL(fileURLWithPath: scannedPath).resolvingSymlinksInPath(),
      candidate.resolvingSymlinksInPath())
    XCTAssertTrue(try XCTUnwrap(failure.unavailableReason).contains("タイムアウト"))
    XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "launch\n")
    let saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: [String: Any]])
    let savedDescriptors = try XCTUnwrap(saved[scannedPath]?["descriptors"] as? [[String: Any]])
    XCTAssertEqual(
      savedDescriptors.first?["unavailableReason"] as? String, failure.unavailableReason)

    let cached = PluginCatalogService.scanVST3(
      helper: helper, force: false, directories: [plugins], cacheURL: cache, timeout: 0.5)
    XCTAssertEqual(cached, first)
    XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "launch\n")

    // Forced discovery bypasses the cached failure and makes malformed helper output visible.
    try ("#!/bin/sh\n" + launchCounter + "printf 'not valid JSON' > \"$2\"\n")
      .write(to: helper, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let forced = PluginCatalogService.scanVST3(
      helper: helper, force: true, directories: [plugins], cacheURL: cache, timeout: 0.5)
    XCTAssertEqual(forced.count, 1)
    XCTAssertEqual(forced.first?.path, scannedPath)
    XCTAssertEqual(forced.first?.unavailableReason, "プラグイン検査結果を読み込めませんでした。")
    XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "launch\nlaunch\n")
  }
}
