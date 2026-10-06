import AVFoundation
import CoreAudio
import Foundation

@MainActor
enum MicrophoneRouteVerification {
  static var isRequested: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--verify-microphone-routes")
    #else
      false
    #endif
  }

  #if DEBUG
    static func run() async {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--verify-microphone-routes"),
        index + 1 < arguments.count
      else { return }
      let output = URL(fileURLWithPath: arguments[index + 1])
      var report: [String: Any] = ["state": "running", "checks": [[String: Any]]()]
      do {
        try save(report, to: output)
        let manager = FileManager.default
        let marker = manager.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Application Support/EasyPod/active-recording")
        guard !manager.fileExists(atPath: marker.path) else {
          throw EasyPodError.message("A real recording is active")
        }
        guard await AudioDeviceService.requestPermission() else {
          throw EasyPodError.message("App microphone authorization was not granted")
        }
        let defaultInput = try defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutput = try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard let originalOutput = AudioDeviceService.deviceInfo(defaultOutput) else {
          throw EasyPodError.message("Default output unavailable")
        }
        let inputs = AudioDeviceService.inputs()
        var checks: [[String: Any]] = []
        guard
          let external = inputs.first(where: {
            $0.name == "外部マイク" || $0.name == "External Microphone"
          }), let usb = inputs.first(where: { $0.name == "US-2x2HR" })
        else {
          throw EasyPodError.message("External microphone and US-2x2HR are required")
        }
        report["defaultOutputName"] = originalOutput.name
        report["defaultOutputUID"] = originalOutput.uid
        report["availableInputs"] = inputs.map(\.name)
        let bluetooth = inputs.first { device in
          AudioDeviceService.deviceInfo(device.id)?.uid.hasSuffix(":input") == true
        }
        let selectedInputs: [UInt32?] =
          [nil, external.id, usb.id, external.id] + (bluetooth.map { [$0.id] } ?? [])
        for (operation, selectedID) in selectedInputs.enumerated() {
          guard !manager.fileExists(atPath: marker.path) else {
            throw EasyPodError.message("A real recording started")
          }
          let inputID = selectedID ?? defaultInput
          guard let originalInput = AudioDeviceService.deviceInfo(inputID) else {
            throw EasyPodError.message("Selected input unavailable: \(inputID)")
          }
          let name = selectedID == nil ? "System microphone" : originalInput.name
          let directory = manager.temporaryDirectory.appendingPathComponent(
            "EasyPodMicrophoneVerification-\(UUID())")
          try manager.createDirectory(at: directory, withIntermediateDirectories: true)
          defer { try? manager.removeItem(at: directory) }
          let capture = AudioCaptureService()
          var settings = RecordingSettings()
          let live = operation == 2
          if live { settings.effectTiming = .duringRecording }
          let chain =
            live
            ? try await EffectChainService().build(
              slots: [], sampleRate: settings.sampleRate, channels: settings.channels) : nil
          try await capture.start(
            directory: directory, settings: settings, inputID: selectedID, effects: chain,
            monitor: operation == 3
          ) { _ in }
          // Stop remains unconditional after successful start, even if the diagnostic task is cancelled.
          try? await Task.sleep(for: .milliseconds(300))
          if live {
            try await capture.pause()
            try? await Task.sleep(for: .milliseconds(80))
            try await capture.resume()
            try? await Task.sleep(for: .milliseconds(300))
          }
          let result = try await capture.stop()
          let file = try AVAudioFile(forReading: directory.appendingPathComponent("source.caf"))
          let inputAfter = AudioDeviceService.deviceInfo(inputID)
          let outputAfter = AudioDeviceService.deviceInfo(defaultOutput)
          guard result.sourceComplete, result.warning == nil, result.frameCount > 0,
            file.length == result.frameCount,
            file.processingFormat.sampleRate == settings.sampleRate,
            file.processingFormat.channelCount == UInt32(settings.channels),
            try defaultDevice(kAudioHardwarePropertyDefaultInputDevice) == defaultInput,
            try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == defaultOutput,
            inputAfter?.sampleRate == originalInput.sampleRate,
            originalOutput.uid.hasSuffix(":output")
              || outputAfter?.sampleRate == originalOutput.sampleRate
          else {
            throw EasyPodError.message("Selected input preservation/frame check failed: \(name)")
          }
          if live {
            let processed = try AVAudioFile(
              forReading: directory.appendingPathComponent("processed.caf"))
            guard result.processedComplete, processed.length == file.length else {
              throw EasyPodError.message("Live processing/pause alignment failed")
            }
          }
          let check: [String: Any] = [
            "name": name, "inputID": inputID,
            "nativeRate": originalInput.sampleRate,
            "recordingRate": file.processingFormat.sampleRate,
            "channels": file.processingFormat.channelCount, "frames": result.frameCount,
            "complete": result.sourceComplete, "defaultsAndInputRateUnchanged": true,
            "monitoring": operation == 3, "liveProcessing": live,
            "processedComplete": result.processedComplete,
          ]
          checks.append(check)
          report["checks"] = checks
          try save(report, to: output)
        }
        report["state"] = "passed"
      } catch {
        report["state"] = "failed"
        report["error"] = error.localizedDescription
      }
      try? save(report, to: output)
    }

    private static func save(_ report: [String: Any], to output: URL) throws {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var id: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
      guard status == noErr, id != kAudioObjectUnknown else {
        throw EasyPodError.message("Default device read failed: \(status)")
      }
      return id
    }
  #endif
}
