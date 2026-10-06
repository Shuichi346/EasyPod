import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

struct AudioInputDevice: Identifiable, Hashable, Sendable {
  let id: UInt32
  let name: String
}

struct CaptureDeviceInfo: Equatable, Sendable {
  let id: UInt32
  let name: String
  let uid: String
  let inputChannels: UInt32
  let outputChannels: UInt32
  let sampleRate: Double
  let isAlive: Bool
}

struct CaptureDeviceRoutePlan: Sendable {
  let input: CaptureDeviceInfo
  let output: CaptureDeviceInfo

  init(input: CaptureDeviceInfo, output: CaptureDeviceInfo) throws {
    guard input.isAlive, input.inputChannels > 0, input.sampleRate.isFinite,
      input.sampleRate > 0, !input.uid.isEmpty
    else { throw EasyPodError.message("選択したマイクを利用できません。接続を確認してください。") }
    guard output.isAlive, output.outputChannels > 0, output.sampleRate.isFinite,
      output.sampleRate > 0, !output.uid.isEmpty
    else { throw EasyPodError.message("再生出力を利用できません。Macのサウンド出力を確認してください。") }
    self.input = input
    self.output = output
  }

  var needsAggregate: Bool { input.id != output.id }

  func composition(uid: String) -> [String: Any] {
    [
      kAudioAggregateDeviceNameKey: "EasyPod Capture",
      kAudioAggregateDeviceUIDKey: uid,
      kAudioAggregateDeviceIsPrivateKey: 1,
      kAudioAggregateDeviceIsStackedKey: 1,
      kAudioAggregateDeviceMainSubDeviceKey: input.uid,
      kAudioAggregateDeviceSubDeviceListKey: [
        [
          kAudioSubDeviceUIDKey: input.uid,
          kAudioSubDeviceDriftCompensationKey: 0,
        ],
        [
          kAudioSubDeviceUIDKey: output.uid,
          kAudioSubDeviceDriftCompensationKey: 1,
          kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality,
        ],
      ],
    ]
  }

  func inputMap(hardwareChannels: UInt32) throws -> [Int32] {
    guard hardwareChannels >= input.inputChannels else {
      throw EasyPodError.message("マイクの入力チャンネルを準備できませんでした。")
    }
    return (0..<hardwareChannels).map { $0 < input.inputChannels ? Int32($0) : -1 }
  }

  func outputMap(hardwareChannels: UInt32) throws -> [Int32] {
    if hardwareChannels == output.outputChannels { return (0..<hardwareChannels).map(Int32.init) }
    guard needsAggregate, hardwareChannels == input.outputChannels + output.outputChannels else {
      throw EasyPodError.message("再生出力のチャンネルを準備できませんでした。")
    }
    return (0..<hardwareChannels).map {
      $0 < input.outputChannels ? -1 : Int32($0 - input.outputChannels)
    }
  }
}

@MainActor
enum CaptureRouteReadiness {
  static func matches(
    _ device: CaptureDeviceInfo?, activeDeviceUIDs: [String], plan: CaptureDeviceRoutePlan
  ) -> Bool {
    guard let device, device.isAlive, device.sampleRate.isFinite, device.sampleRate > 0,
      device.inputChannels >= plan.input.inputChannels,
      device.outputChannels >= plan.output.outputChannels
    else { return false }
    return !plan.needsAggregate
      || (activeDeviceUIDs.contains(plan.input.uid) && activeDeviceUIDs.contains(plan.output.uid))
  }

  static func wait(
    isReady: () -> Bool, timeout: Duration = .seconds(1)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      if isReady() { return }
      // HAL device publication can follow successful creation; let property notifications settle.
      try await Task.sleep(for: .milliseconds(20))
    }
    throw EasyPodError.message("マイクと再生出力の音声接続を準備できませんでした。接続を確認してください。")
  }
}

@MainActor
final class CaptureAudioRoute {
  private static var pendingCleanup: CaptureAudioRoute?
  let deviceID: UInt32
  let input: CaptureDeviceInfo
  private var ownedID: UInt32?
  private let destroy: (UInt32) -> OSStatus

  init(
    plan: CaptureDeviceRoutePlan,
    existingDeviceID: UInt32? = nil,
    create: @MainActor ([String: Any]) throws -> UInt32 = AudioDeviceService.createAggregate,
    destroy: @escaping (UInt32) -> OSStatus = AudioHardwareDestroyAggregateDevice
  ) throws {
    input = plan.input
    self.destroy = destroy
    if let existingDeviceID {
      guard existingDeviceID != kAudioObjectUnknown else {
        throw EasyPodError.message("録音用の音声接続を確認できませんでした。")
      }
      deviceID = existingDeviceID
    } else if plan.needsAggregate {
      let id = try create(plan.composition(uid: "local.EasyPod.capture.\(UUID())"))
      guard id != kAudioObjectUnknown else {
        throw EasyPodError.message("録音用の音声接続を作成できませんでした。")
      }
      deviceID = id
      ownedID = id
    } else {
      deviceID = plan.input.id
    }
  }

  // Release only the process-private device, after all engine rendering has stopped.
  @discardableResult func close() -> OSStatus {
    guard let id = ownedID else { return noErr }
    let status = destroy(id)
    if status == noErr {
      ownedID = nil
      if Self.pendingCleanup === self { Self.pendingCleanup = nil }
    } else {
      Self.pendingCleanup = self
    }
    return status
  }

  static func configured(
    plan: CaptureDeviceRoutePlan,
    existingDeviceID: UInt32? = nil,
    create: @MainActor ([String: Any]) throws -> UInt32 = AudioDeviceService.createAggregate,
    destroy: @escaping (UInt32) -> OSStatus = AudioHardwareDestroyAggregateDevice,
    configure: (UInt32) throws -> Void
  ) throws -> CaptureAudioRoute {
    guard retryCleanup() == noErr else {
      throw EasyPodError.message("前の音声接続を解放できませんでした。アプリを再起動すると解放されます。")
    }
    let route = try CaptureAudioRoute(
      plan: plan, existingDeviceID: existingDeviceID, create: create, destroy: destroy)
    do {
      try configure(route.deviceID)
      return route
    } catch {
      let status = route.close()
      if status != noErr {
        throw EasyPodError.message("\(error.localizedDescription) 音声接続の解放にも失敗しました（\(status)）。")
      }
      throw error
    }
  }

  static func configuredAsync(
    plan: CaptureDeviceRoutePlan,
    existingDeviceID: UInt32? = nil,
    create: @MainActor ([String: Any]) throws -> UInt32 = AudioDeviceService.createAggregate,
    destroy: @escaping (UInt32) -> OSStatus = AudioHardwareDestroyAggregateDevice,
    configure: @MainActor (UInt32) async throws -> Void
  ) async throws -> CaptureAudioRoute {
    let route = try configured(
      plan: plan, existingDeviceID: existingDeviceID, create: create, destroy: destroy
    ) { _ in }
    do {
      try await configure(route.deviceID)
      return route
    } catch {
      let status = route.close()
      if status != noErr {
        throw EasyPodError.message("\(error.localizedDescription) 音声接続の解放にも失敗しました（\(status)）。")
      }
      throw error
    }
  }

  @discardableResult static func retryCleanup() -> OSStatus {
    pendingCleanup?.close() ?? noErr
  }
}

@MainActor
enum AudioDeviceService {
  private static let logger = Logger(subsystem: "local.EasyPod", category: "capture")
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
    guard size > 0 else { return [] }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = devices.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { return [] }
    return devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { device in
      guard let info = deviceInfo(device), info.isAlive, info.inputChannels > 0,
        !info.uid.hasPrefix("local.EasyPod.capture."),
        property(device, kAudioDevicePropertyIsHidden, initial: UInt32(0)) != 1
      else { return nil }
      return AudioInputDevice(id: device, name: info.name)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // Capture requires only the chosen input; playback availability never gates original recording.
  static func captureInput(_ selectedID: UInt32?) throws -> CaptureDeviceInfo {
    let id =
      selectedID ?? property(
        AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
        initial: UInt32(0)) ?? 0
    guard let input = deviceInfo(id), input.isAlive, input.inputChannels > 0,
      input.sampleRate.isFinite, input.sampleRate > 0
    else { throw EasyPodError.message("選択したマイクを利用できません。接続を確認してください。") }
    return input
  }

  static func configureCapture(inputID: UInt32?, engine: AVAudioEngine) async throws
    -> CaptureAudioRoute
  {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard
      let defaultInputID = property(
        system, kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0)),
      let input = deviceInfo(inputID ?? defaultInputID),
      let outputID = property(
        system, kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0)),
      let output = deviceInfo(outputID)
    else {
      throw EasyPodError.message("選択したマイクが見つかりません。接続を確認してください。")
    }
    let selectedID = input.id
    let plan = try CaptureDeviceRoutePlan(input: input, output: output)
    logger.info(
      "Capture route request input=\(input.id) rate=\(input.sampleRate) output=\(output.id) rate=\(output.sampleRate)"
    )
    // AVAudioEngine owns the default input/output route, including its hardware clock conversion.
    // Keep that route when the selected input is already the system input instead of replacing it.
    let inputNode = engine.inputNode
    let outputNode = engine.outputNode
    var existingDeviceID: UInt32?
    if selectedID == defaultInputID {
      guard let unit = inputNode.audioUnit else {
        throw EasyPodError.message("録音用の入出力を準備できませんでした。")
      }
      existingDeviceID = try currentDevice(of: unit)
    }
    return try await CaptureAudioRoute.configuredAsync(
      plan: plan, existingDeviceID: existingDeviceID
    ) { deviceID in
      do {
        do {
          try await CaptureRouteReadiness.wait {
            CaptureRouteReadiness.matches(
              deviceInfo(deviceID),
              activeDeviceUIDs: plan.needsAggregate ? activeSubdeviceUIDs(deviceID) : [], plan: plan
            )
          }
        } catch {
          let observed = deviceInfo(deviceID)
          let active = plan.needsAggregate ? activeSubdeviceUIDs(deviceID) : []
          logger.error(
            "Capture route readiness failed device=\(deviceID) alive=\(observed?.isAlive ?? false) rate=\(observed?.sampleRate ?? 0) inputChannels=\(observed?.inputChannels ?? 0) outputChannels=\(observed?.outputChannels ?? 0) expectedInput=\(plan.input.uid, privacy: .public) expectedOutput=\(plan.output.uid, privacy: .public) active=\(active.description, privacy: .public)"
          )
          throw error
        }
        if existingDeviceID != nil { return }
        // The two engine nodes can share one duplex AUHAL; retargeting only input also retargets output.
        guard let inputUnit = inputNode.audioUnit,
          let outputUnit = outputNode.audioUnit
        else {
          throw EasyPodError.message("録音用の入出力を準備できませんでした。")
        }
        let sharedUnit = inputUnit == outputUnit
        try setIO(inputUnit, scope: kAudioUnitScope_Input, bus: 1, enabled: true)
        try setIO(inputUnit, scope: kAudioUnitScope_Output, bus: 0, enabled: sharedUnit)
        if !sharedUnit {
          try setIO(outputUnit, scope: kAudioUnitScope_Input, bus: 1, enabled: false)
          try setIO(outputUnit, scope: kAudioUnitScope_Output, bus: 0, enabled: true)
        }
        try assign(deviceID, to: inputUnit)
        if !sharedUnit { try assign(deviceID, to: outputUnit) }
        if plan.needsAggregate {
          let inputChannels = inputNode.inputFormat(forBus: 0).channelCount
          let outputChannels = outputNode.outputFormat(forBus: 0).channelCount
          try setMap(
            plan.inputMap(hardwareChannels: inputChannels), unit: inputUnit,
            scope: kAudioUnitScope_Output, bus: 1)
          try setMap(
            plan.outputMap(hardwareChannels: outputChannels), unit: outputUnit,
            scope: kAudioUnitScope_Input, bus: 0)
        }
      } catch {
        engine.stop()
        throw error
      }
    }
  }

  static func deviceInfo(_ id: UInt32) -> CaptureDeviceInfo? {
    guard id != kAudioObjectUnknown,
      let name = stringProperty(id, kAudioObjectPropertyName),
      let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
      let rate = property(id, kAudioDevicePropertyNominalSampleRate, initial: 0.0),
      let alive = property(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
    else { return nil }
    return CaptureDeviceInfo(
      id: id, name: name, uid: uid,
      inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
      outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
      sampleRate: rate, isAlive: alive != 0)
  }

  static func createAggregate(_ composition: [String: Any]) throws -> UInt32 {
    var id = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &id)
    guard status == noErr else {
      if id != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(id) }
      throw EasyPodError.message("マイクと再生出力を接続できませんでした（\(status)）。")
    }
    return id
  }

  private static func setIO(
    _ unit: AudioUnit, scope: AudioUnitScope, bus: AudioUnitElement, enabled: Bool
  ) throws {
    var value: UInt32 = enabled ? 1 : 0
    let status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_EnableIO, scope, bus, &value, UInt32(MemoryLayout<UInt32>.size)
    )
    guard status == noErr else { throw EasyPodError.message("音声の入出力を準備できませんでした（\(status)）。") }
  }

  private static func assign(_ id: UInt32, to unit: AudioUnit) throws {
    var device = id
    let status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
      UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else {
      logger.error("Capture device assignment failed requested=\(id) status=\(status)")
      throw EasyPodError.message("選択したマイクへの切り替えに失敗しました（\(status)）。")
    }
    let observed = try currentDevice(of: unit)
    guard observed == id else {
      logger.error("Capture device readback mismatch requested=\(id) observed=\(observed)")
      throw EasyPodError.message("選択したマイクの接続情報が一致しないため、録音を開始できませんでした。")
    }
  }

  private static func currentDevice(of unit: AudioUnit) throws -> UInt32 {
    var observed: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let readStatus = AudioUnitGetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &observed, &size)
    guard readStatus == noErr, size == UInt32(MemoryLayout<UInt32>.size),
      observed != kAudioObjectUnknown
    else {
      logger.error(
        "Capture device readback failed observed=\(observed) size=\(size) status=\(readStatus)"
      )
      if readStatus != noErr {
        throw EasyPodError.message("マイクの接続先を確認できませんでした（\(readStatus)）。")
      }
      throw EasyPodError.message("選択したマイクの接続情報が一致しないため、録音を開始できませんでした。")
    }
    return observed
  }

  private static func activeSubdeviceUIDs(_ id: UInt32) -> [String] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let stride = UInt32(MemoryLayout<UInt32>.stride)
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
      size > 0, size % stride == 0
    else { return [] }
    let capacity = size
    var devices = [UInt32](repeating: 0, count: Int(size / stride))
    let status = devices.withUnsafeMutableBufferPointer {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr, size <= capacity, size % stride == 0 else { return [] }
    // Active entries are HAL subdevice objects; compare their persistent device identity.
    return devices.prefix(Int(size / stride)).compactMap {
      stringProperty($0, kAudioDevicePropertyDeviceUID)
    }
  }

  private static func setMap(
    _ map: [Int32], unit: AudioUnit, scope: AudioUnitScope, bus: AudioUnitElement
  ) throws {
    guard !map.isEmpty else { throw EasyPodError.message("利用できる音声チャンネルがありません。") }
    let size = UInt32(map.count * MemoryLayout<Int32>.size)
    let status = map.withUnsafeBufferPointer {
      AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_ChannelMap, scope, bus, $0.baseAddress, size)
    }
    guard status == noErr else { throw EasyPodError.message("音声チャンネルを接続できませんでした（\(status)）。") }
    var observed = [Int32](repeating: -2, count: map.count)
    var observedSize = size
    let readStatus = observed.withUnsafeMutableBufferPointer {
      AudioUnitGetProperty(
        unit, kAudioOutputUnitProperty_ChannelMap, scope, bus, $0.baseAddress!, &observedSize)
    }
    guard readStatus == noErr, observedSize == size, observed == map else {
      throw EasyPodError.message("音声チャンネルの接続を確認できませんでした（\(readStatus)）。")
    }
  }

  private static func property<T>(_ id: UInt32, _ selector: AudioObjectPropertySelector, initial: T)
    -> T?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var result = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    return status == noErr && size == UInt32(MemoryLayout<T>.size) ? result : nil
  }

  private static func stringProperty(_ id: UInt32, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &result) {
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let result else { return nil }
    // CoreAudio transfers ownership of returned CF objects to the property caller.
    return result.takeRetainedValue() as String
  }

  private static func channelCount(_ id: UInt32, scope: AudioObjectPropertyScope) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
      size >= UInt32(MemoryLayout<AudioBufferList>.size)
    else { return 0 }
    let capacity = Int(size)
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr,
      Int(size) <= capacity
    else { return 0 }
    let list = storage.assumingMemoryBound(to: AudioBufferList.self)
    let offset =
      MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? MemoryLayout<AudioBufferList>.size
    guard
      Int(list.pointee.mNumberBuffers) <= (Int(size) - offset) / MemoryLayout<AudioBuffer>.stride
    else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
  }
}
