import SwiftUI

struct ContentView: View {
  @Bindable var store: RecordingStore
  @State private var settingsExpanded = true

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        let expansion = min(1, max(0, (geometry.size.width - 1100) / 180))
        HStack(spacing: 0) {
          SidebarView(store: store).frame(width: 220 + 16 * expansion).background(Theme.sidebar)
          Divider()
          RecorderView(store: store).frame(maxWidth: .infinity).background(Theme.canvas)
          Divider()
          TranscriptView(store: store).frame(width: 300 + 28 * expansion).background(
            Theme.inspector)
        }
      }
      Divider()
      DisclosureGroup(isExpanded: $settingsExpanded) {
        QualityControls(settings: $store.preferences.settings)
          .disabled(store.isCapturing).padding(.top, 12)
      } label: {
        Text("録音・書き出し設定").font(.headline)
      }
      .padding(.horizontal, 20).padding(.vertical, 16)
      .background(Theme.settings)
    }
    .frame(minWidth: 1100, minHeight: 708)
    .background(Theme.canvas)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.showExportSheet = true
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .help("書き出す（⌘E）").accessibilityLabel("音声を書き出す").disabled(!store.canExport)
      }
      ToolbarItem(placement: .primaryAction) {
        SettingsLink { Image(systemName: "gearshape") }
          .help("設定").accessibilityLabel("設定を開く")
      }
    }
    .sheet(isPresented: $store.showExportSheet) { ExportSheet(store: store) }
    .alert(
      "EasyPod",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("閉じる") { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
}

#Preview("Dark compact", traits: .fixedLayout(width: 1100, height: 708)) {
  ContentView(store: RecordingStore(loadSessions: false)).preferredColorScheme(.dark)
}

#Preview("Light regular", traits: .fixedLayout(width: 1280, height: 848)) {
  ContentView(store: RecordingStore(loadSessions: false)).preferredColorScheme(.light)
}
