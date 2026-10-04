import AVFoundation
import AudioToolbox
import Darwin
import Foundation

@MainActor
final class PluginCatalogService {
  private struct CacheEntry: Codable, Sendable {
    var fingerprint: String
    var descriptors: [PluginDescriptor]
  }

  private var catalog: [PluginDescriptor] = []
  private var scanning = false

  func discover(force: Bool = false) async -> [PluginDescriptor] {
    if scanning { return catalog }
    scanning = true
    defer { scanning = false }
    var found: [PluginDescriptor] = []
    for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
      let description = AudioComponentDescription(
        componentType: type, componentSubType: 0, componentManufacturer: 0,
        componentFlags: 0, componentFlagsMask: 0)
      for component in AVAudioUnitComponentManager.shared().components(matching: description) {
        let code = component.audioComponentDescription
        if code.componentManufacturer == 0x4550_6f64 { continue }
        found.append(
          PluginDescriptor(
            id: "au:\(code.componentType):\(code.componentSubType):\(code.componentManufacturer)",
            name: component.name, manufacturer: component.manufacturerName, format: .au,
            componentType: code.componentType, componentSubType: code.componentSubType,
            componentManufacturer: code.componentManufacturer, version: component.versionString))
      }
    }
    let helper = scannerURL()
    let vst = await Task.detached(priority: .utility) {
      Self.scanVST3(helper: helper, force: force)
    }.value
    found.append(contentsOf: vst)
    catalog = found.sorted {
      if $0.name == $1.name { return $0.format.rawValue < $1.format.rawValue }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return catalog
  }

  private func scannerURL() -> URL? {
    if let executable = Bundle.main.url(forAuxiliaryExecutable: "EasyPodPluginScanner") {
      return executable
    }
    let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/EasyPodPluginScanner")
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    return nil
  }

  nonisolated static func scanVST3(
    helper: URL?, force: Bool, directories: [URL]? = nil, cacheURL: URL? = nil,
    timeout: TimeInterval = 20
  ) -> [PluginDescriptor] {
    let manager = FileManager.default
    let cacheURL =
      cacheURL
      ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "EasyPod", directoryHint: .isDirectory)
      .appending(path: "plugin-scan-cache.json")
    var cache =
      (try? Data(contentsOf: cacheURL)).flatMap {
        try? JSONDecoder().decode([String: CacheEntry].self, from: $0)
      } ?? [:]
    var results: [PluginDescriptor] = []
    let directories =
      directories ?? [
        URL(filePath: "/Library/Audio/Plug-Ins/VST3"),
        manager.homeDirectoryForCurrentUser.appending(path: "Library/Audio/Plug-Ins/VST3"),
      ]
    for directory in directories {
      guard
        let enumerator = manager.enumerator(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
          options: [.skipsPackageDescendants, .skipsHiddenFiles])
      else { continue }
      for case let candidate as URL in enumerator
      where candidate.pathExtension.lowercased() == "vst3" {
        let bundle = Bundle(url: candidate)
        let date =
          (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate?.timeIntervalSince1970 ?? 0
        let executableDate =
          bundle?.executableURL.flatMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
              .contentModificationDate
          }?.timeIntervalSince1970 ?? 0
        let fingerprint =
          "v1:\(date):\(executableDate):\(bundle?.object(forInfoDictionaryKey: "CFBundleVersion") ?? "")"
        if !force, let cached = cache[candidate.path], cached.fingerprint == fingerprint {
          results.append(contentsOf: cached.descriptors)
          continue
        }
        let descriptors: [PluginDescriptor]
        if let helper {
          descriptors = scanOne(candidate, helper: helper, timeout: timeout)
        } else {
          descriptors = [failed(candidate, reason: "プラグイン検査用ヘルパーが見つかりません。アプリを再構築してください。")]
        }
        cache[candidate.path] = CacheEntry(fingerprint: fingerprint, descriptors: descriptors)
        results.append(contentsOf: descriptors)
        // Save every candidate so a later scanner crash cannot erase earlier failure evidence.
        if helper != nil, let data = try? JSONEncoder().encode(cache) {
          try? manager.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? data.write(to: cacheURL, options: .atomic)
        }
      }
    }
    return results
  }

  nonisolated private static func scanOne(
    _ candidate: URL, helper: URL, timeout: TimeInterval
  ) -> [PluginDescriptor] {
    let output = FileManager.default.temporaryDirectory.appending(
      path: "EasyPod-scan-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = helper
    process.arguments = [candidate.path, output.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
      return [failed(candidate, reason: "検査ヘルパーを起動できません: \(error.localizedDescription)")]
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      return [
        failed(
          candidate,
          reason: "検査が \(String(format: "%g", timeout)) 秒でタイムアウトしました。再検査を選ぶまで再試行しません。")
      ]
    }
    process.waitUntilExit()
    guard let data = try? Data(contentsOf: output) else {
      return [
        failed(candidate, reason: "検査が終了しました (終了コード \(process.terminationStatus))。再検査を選ぶまで再試行しません。")
      ]
    }
    if let descriptors = try? JSONDecoder().decode([PluginDescriptor].self, from: data) {
      return descriptors
    }
    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
    return [failed(candidate, reason: detail ?? "プラグイン検査結果を読み込めませんでした。")]
  }

  nonisolated private static func failed(_ candidate: URL, reason: String) -> PluginDescriptor {
    PluginDescriptor(
      id: "vst3-failed:\(candidate.path)",
      name: candidate.deletingPathExtension().lastPathComponent,
      manufacturer: "", format: .vst3, path: candidate.path, unavailableReason: reason)
  }
}
