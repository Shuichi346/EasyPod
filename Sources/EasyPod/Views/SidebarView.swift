import SwiftUI

struct SidebarView: View {
  @Bindable var store: RecordingStore
  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Text("録音").font(.system(size: 15, weight: .semibold))
        Spacer()
        Button {
          store.newRecording()
        } label: {
          Image(systemName: "plus").frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless).help("新しい録音（⌘N）")
        .accessibilityLabel("新しい録音").disabled(store.isCapturing || store.exporting)
      }.padding(.horizontal, 16).padding(.top, 14)
      if store.sessions.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tertiary)
          Text("最初の録音を").font(.system(size: 16, weight: .semibold))
          Text("マイクを選び、赤いボタンから始めましょう。")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).lineSpacing(4)
        }.padding(.horizontal, 20).padding(.top, 66)
        Spacer(minLength: 0)
      } else {
        List(
          selection: Binding(
            get: { store.selectedID }, set: { if let id = $0 { store.select(id) } })
        ) {
          ForEach(store.sessions) { session in
            HStack(spacing: 14) {
              Image(
                systemName: session.status == .interrupted ? "exclamationmark.waveform" : "waveform"
              )
              .font(.title2).foregroundStyle(
                store.selectedID == session.id ? Color.coral : Color.secondary)
              VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(
                  session.createdAt.formatted(.dateTime.month().day()) + " · "
                    + AudioTime.string(session.duration)
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 8).tag(session.id)
          }
        }.listStyle(.sidebar).disabled(store.isCapturing || store.exporting)
      }
    }
  }
}
