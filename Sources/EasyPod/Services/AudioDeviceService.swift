import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
  let id: UInt32
  let name: String
}

@MainActor
enum AudioDeviceService {
  static var authorizationStatus: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  static func requestPermission() async -> Bool {
    switch authorizationStatus {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
  }

  static func inputs() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address,
        0, nil, &size) == noErr
    else { return [] }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = devices.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { return [] }
    return devices.compactMap { device in
      var streamAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
      var streamSize: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr,
        streamSize > 0
      else { return nil }
      var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var name: Unmanaged<CFString>?
      var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      let nameStatus = withUnsafeMutablePointer(to: &name) { pointer in
        AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
      }
      guard nameStatus == noErr, let name else { return nil }
      // CoreAudio transfers ownership of name CFObjects to the property caller.
      return AudioInputDevice(id: device, name: name.takeRetainedValue() as String)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func selectInput(_ id: UInt32, engine: AVAudioEngine) throws {
    guard inputs().contains(where: { $0.id == id }), let unit = engine.inputNode.audioUnit else {
      throw EasyPodError.message("選択したマイクが見つかりません。接続を確認してください。")
    }
    var device = AudioDeviceID(id)
    let status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global, 0, &device,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
      throw EasyPodError.message("マイクを切り替えられませんでした（\(status)）。")
    }
  }
}
