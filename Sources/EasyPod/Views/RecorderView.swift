import SwiftUI

struct RecorderView: View {
  @Bindable var store: RecordingStore
  @State private var pluginPicker = false

  @FocusState private var titleFocused: Bool
  @State private var editingTitle = false

  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 18) {
        inputControls(narrow: geometry.size.width < 640)
        HStack {
          if editingTitle {
            TextField("録音の名前", text: $store.title)
              .font(.system(size: 18, weight: .medium)).textFieldStyle(.plain)
              .focused($titleFocused).onAppear { titleFocused = true }
              .onSubmit {
                store.rename()
                editingTitle = false
              }
              .onExitCommand {
                store.rename()
                editingTitle = false
              }
              .accessibilityLabel("録音の名前")
          } else {
            Button {
              editingTitle = true
            } label: {
              HStack(spacing: 8) {
                Text(store.title).font(.system(size: 18, weight: .medium)).lineLimit(1)
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(.secondary)
              }.frame(minHeight: 28)
            }.buttonStyle(.plain).help("録音の名前を変更").accessibilityLabel("録音の名前を変更: \(store.title)")
          }
          Spacer(minLength: 0)
        }
        EffectRackView(store: store, showPicker: $pluginPicker)
        VStack(spacing: 24) {
          WaveformView(peaks: store.peaks, active: store.phase == .recording)
            .frame(minHeight: 80, maxHeight: 196)
          TransportView(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        if let warning = store.selected?.warning {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(warning).font(.caption).foregroundStyle(.secondary)
            if store.selected?.status == .interrupted {
              Button("復旧") { store.recover() }.disabled(store.isCapturing)
            }
          }.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }
      }.padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: 728, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .sheet(isPresented: $pluginPicker) { PluginPickerView(store: store) }
  }

  private func inputControls(narrow: Bool) -> some View {
    HStack(alignment: .bottom, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("入力デバイス").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        ChoiceMenu(
          title: "入力デバイス", selection: $store.preferences.inputID,
          choices: [("システムのマイク", UInt32?.none)]
            + store.inputDevices.map { ($0.name, Optional($0.id)) }
        )
        .disabled(store.isCapturing)
      }.frame(width: narrow ? 176 : 188, alignment: .leading)
      VStack(alignment: .leading, spacing: 6) {
        Text("入力レベル").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        LevelMeter(level: store.level).frame(height: 32)
      }.frame(maxWidth: 249, alignment: .leading)
      VStack(alignment: .leading, spacing: 6) {
        Text("モニター").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        Toggle("モニター", isOn: Binding(get: { store.monitor }, set: { store.setMonitoring($0) }))
          .toggleStyle(.switch).labelsHidden().frame(height: 32, alignment: .leading)
          .help("ヘッドホンを使用して入力音声を確認します")
      }.frame(width: 68, alignment: .leading)
      Spacer(minLength: 0)
    }
  }
}

struct TransportView: View {
  @Bindable var store: RecordingStore
  var body: some View {
    HStack(spacing: 18) {
      Button {
        Task { if store.isCapturing { await store.stop() } else { await store.start() } }
      } label: {
        Image(systemName: store.isCapturing ? "stop.fill" : "circle.fill")
          .font(.system(size: store.isCapturing ? 23 : 25)).foregroundStyle(.white)
          .frame(width: 72, height: 72).background(Color.coral, in: Circle())
      }
      .buttonStyle(.plain).help(store.isCapturing ? "録音を停止（⌘R）" : "録音を開始（⌘R）")
      .accessibilityLabel(store.isCapturing ? "録音を停止" : "録音を開始")
      .disabled(store.transportBusy || store.exporting)
      Button {
        Task {
          if store.isCapturing { await store.pauseOrResume() } else { await store.togglePlayback() }
        }
      } label: {
        Image(
          systemName: store.isCapturing
            ? (store.phase == .paused ? "play.fill" : "pause.fill")
            : (store.isPlaying ? "stop.fill" : "play.fill")
        )
        .font(.system(size: 18, weight: .semibold)).frame(width: 48, height: 48)
        .background(Theme.control, in: Circle()).overlay(
          Circle().stroke(Theme.border, lineWidth: 1))
      }
      .buttonStyle(.plain).help(store.isCapturing ? "一時停止・再開（Space）" : "再生・停止（⌘P）")
      .accessibilityLabel(store.isCapturing ? "一時停止または再開" : "再生または停止")
      .disabled(store.transportBusy || (!store.isCapturing && store.selected == nil))
      VStack(alignment: .leading, spacing: 6) {
        Text(AudioTime.string(store.elapsed)).font(
          .system(size: 28, weight: .regular, design: .monospaced)
        ).monospacedDigit()
        Text(store.isPlaying ? "再生中…" : store.phase.label).foregroundStyle(.secondary)
      }
    }
  }
}

struct LevelMeter: View {
  let level: Float
  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 3) {
        ForEach(0..<28) { index in
          RoundedRectangle(cornerRadius: 1).fill(
            index < Int(sqrt(max(0, level)) * 28)
              ? (index > 24 ? Color.coral : index > 20 ? Color.yellow : Color.green)
              : Color.secondary.opacity(0.15))
        }
      }.frame(width: min(249, geometry.size.width), height: 18, alignment: .leading)
        .frame(height: geometry.size.height)
    }.accessibilityLabel("入力レベル").accessibilityValue("\(Int(level * 100))パーセント")
  }
}
