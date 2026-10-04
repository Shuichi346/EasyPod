import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
  @Bindable var store: RecordingStore
  @Environment(\.dismiss) private var dismiss
  @State private var settings: RecordingSettings
  @State private var source: ExportSource = .original
  @State private var includeEffects = true
  @State private var splitWAV = false
  @State private var destination: URL?

  init(store: RecordingStore) {
    self.store = store
    _settings = State(initialValue: store.preferences.settings)
    if store.selected?.processedComplete == true { _source = State(initialValue: .processed) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("音声を書き出す").font(.title2.bold())
      QualityControls(settings: $settings)
      Divider()
      Picker("音声", selection: $source) {
        Text("オリジナル").tag(ExportSource.original)
        if store.selected?.processedComplete == true {
          Text("録音中の処理済み音声").tag(ExportSource.processed)
        }
      }
      if source == .original {
        Toggle("現在のエフェクトを含める", isOn: $includeEffects).disabled(store.effects.isEmpty)
      } else {
        Text("録音中に保存したエフェクトを使います。").font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Text("余韻の上限")
        Stepper("\(Int(settings.tailLimit)) 秒", value: $settings.tailLimit, in: 0...30)
      }
      if settings.format == .wav {
        Toggle("4 GB を超える WAV を複数ファイルに分割する", isOn: $splitWAV)
      }
      if store.exporting {
        ProgressView(value: store.exportProgress)
        Text("書き出し中… \(Int(store.exportProgress * 100))%").foregroundStyle(.secondary)
      }
      HStack {
        if store.exporting {
          Button("キャンセル") { store.cancelExport() }
        } else {
          Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        Spacer()
        Button("保存先を選んで書き出す…") { chooseAndExport() }
          .keyboardShortcut(.defaultAction).disabled(store.exporting)
      }
    }.padding(28).frame(width: 760).disabled(store.isCapturing)
      .interactiveDismissDisabled(store.exporting)
  }

  private func chooseAndExport() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = (store.selected?.title ?? "録音") + "." + settings.format.rawValue
    panel.allowedContentTypes = settings.format == .wav ? [.wav] : [.mpeg4Audio]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    destination = url
    let request = ExportRequest(
      source: source,
      includeEffects: includeEffects && source == .original && !store.effects.isEmpty,
      settings: settings, splitOversizedWAV: splitWAV)
    Task {
      await store.export(destination: url, request: request)
      if store.error == nil { dismiss() }
    }
  }
}
