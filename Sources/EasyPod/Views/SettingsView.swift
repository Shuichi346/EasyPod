import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var store: RecordingStore
  var body: some View {
    Form {
      Section("文字起こし") {
        Toggle("Nemotron 3.5 でローカル文字起こし", isOn: $store.preferences.transcriptionEnabled)
        TextField("GGUF モデル", text: $store.preferences.modelPath)
        Button("モデルを選択…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          if panel.runModal() == .OK, let url = panel.url { store.preferences.modelPath = url.path }
        }
        Text("インストール済みモデルを使います。音声を外部へ送信しません。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("エフェクト") {
        Stepper(
          "余韻の上限: \(Int(store.preferences.settings.tailLimit)) 秒",
          value: $store.preferences.settings.tailLimit, in: 0...30, step: 1)
        Text("長い余韻や無限の余韻は、この上限で書き出します。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped).padding().frame(width: 620, height: 330).disabled(store.isCapturing)
  }
}
