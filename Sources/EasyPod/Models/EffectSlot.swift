import Foundation

enum PluginFormat: String, Codable, Sendable {
  case au = "AU"
  case vst3 = "VST3"
}

struct PluginDescriptor: Identifiable, Codable, Hashable, Sendable {
  var id: String
  var name: String
  var manufacturer: String
  var format: PluginFormat
  var path: String?
  var classID: String?
  var componentType: UInt32?
  var componentSubType: UInt32?
  var componentManufacturer: UInt32?
  var version: String = ""
  var unavailableReason: String?
}

struct EffectSlot: Identifiable, Codable, Sendable {
  var id = UUID()
  var plugin: PluginDescriptor
  var bypassed = false
  var state: Data?
}
