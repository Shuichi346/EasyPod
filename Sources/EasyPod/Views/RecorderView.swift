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
          WaveformView(
            peaks: store.peaks, active: store.phase == .recording,
            liveTime: store.isCapturing ? store.elapsed : nil,
            progress: store.canPlay && store.playbackDuration > 0
              ? store.playbackPosition / store.playbackDuration : nil
          )
          .frame(minHeight: 80, maxHeight: 196)
          TransportView(store: store)
          if store.selected != nil && !store.isCapturing && store.libraryFilter != .trash {
            PlaybackControls(store: store)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        if let warning = store.selected?.warning {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(warning).font(.caption).foregroundStyle(.secondary)
            if store.selected?.status == .interrupted && store.libraryFilter != .trash {
              Button {
                store.recover()
              } label: {
                Image(systemName: "arrow.clockwise")
              }.disabled(!store.canOrganize).help("中断した録音を復旧").accessibilityLabel("中断した録音を復旧")
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
        Image(systemName: "mic.fill").font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary).help("入力デバイス").accessibilityLabel("入力デバイス")
        ChoiceMenu(
          title: "入力デバイス", selection: $store.preferences.inputID,
          choices: [("システムのマイク", UInt32?.none)]
            + store.inputDevices.map { ($0.name, Optional($0.id)) }
            + (store.preferences.inputUID != nil
              && !store.inputDevices.contains { $0.id == store.preferences.inputID }
              ? [("選択したマイクは未接続です", store.preferences.inputID)] : [])
        )
        .disabled(store.isCapturing)
      }.frame(width: narrow ? 176 : 188, alignment: .leading)
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: "chart.bar.fill").font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary).help("入力レベル").accessibilityLabel("入力レベル")
        LevelMeter(level: store.level).frame(height: 32)
      }.frame(maxWidth: 249, alignment: .leading)
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: "headphones").font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary).help("モニター").accessibilityLabel("モニター")
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
      .disabled(
        store.transportBusy
          || (!store.isCapturing && (!store.canOrganize || store.libraryFilter == .trash)))
      Button {
        Task {
          if store.isCapturing { await store.pauseOrResume() } else { await store.togglePlayback() }
        }
      } label: {
        Image(
          systemName: store.isCapturing
            ? (store.phase == .paused ? "play.fill" : "pause.fill")
            : (store.isPlaying ? "pause.fill" : "play.fill")
        )
        .font(.system(size: 18, weight: .semibold)).frame(width: 48, height: 48)
        .background(Theme.control, in: Circle()).overlay(
          Circle().stroke(Theme.border, lineWidth: 1))
      }
      .buttonStyle(.plain).help(store.isCapturing ? "一時停止・再開（Space）" : "再生・一時停止（⌘P）")
      .accessibilityLabel(store.isCapturing ? "一時停止または再開" : "再生または一時停止")
      .disabled(store.transportBusy || (!store.isCapturing && !store.canPlay))
      VStack(alignment: .leading, spacing: 6) {
        Text(AudioTime.string(store.isCapturing ? store.elapsed : store.playbackPosition)).font(
          .system(size: 28, weight: .regular, design: .monospaced)
        ).monospacedDigit()
        Text(store.isPlaying ? "再生中…" : store.phase.label).foregroundStyle(.secondary)
        if !store.isCapturing, store.selected != nil {
          Text("/ " + AudioTime.string(store.playbackDuration)).font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct LevelMeter: View {
  let level: Float
  var label = "入力レベル"
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
    }.accessibilityLabel(label).accessibilityValue("\(Int(level * 100))パーセント")
  }
}

struct PlaybackControls: View {
  @Bindable var store: RecordingStore
  @State private var scrubbing = false
  @State private var scrubTime = 0.0

  var body: some View {
    VStack(spacing: 10) {
      Slider(
        value: Binding(
          get: { scrubbing ? scrubTime : store.playbackPosition },
          set: { value in
            scrubTime = value
            if !scrubbing { store.seekPlayback(to: value) }
          }),
        in: 0...max(0.001, store.playbackDuration),
        onEditingChanged: { editing in
          if editing {
            scrubTime = store.playbackPosition
          } else {
            store.seekPlayback(to: scrubTime)
          }
          scrubbing = editing
        }
      ).tint(.coral).accessibilityLabel("再生位置")
        .accessibilityValue(AudioTime.string(store.playbackPosition))
        .disabled(!store.canPlay)
      HStack(spacing: 16) {
        Button {
          store.skipPlayback(seconds: -15)
        } label: {
          Image(systemName: "gobackward.15").font(.system(size: 28, weight: .medium))
            .frame(width: 40, height: 40).contentShape(.interaction, Rectangle())
        }.help("15秒戻る（⌘←）").accessibilityLabel("15秒戻る")
        Button {
          store.stopPlayback()
        } label: {
          Image(systemName: "stop.fill").font(.system(size: 20, weight: .medium))
            .frame(width: 40, height: 40).contentShape(.interaction, Rectangle())
        }.help("再生を停止して先頭へ戻す").accessibilityLabel("再生を停止して先頭へ戻す")
        Button {
          store.skipPlayback(seconds: 15)
        } label: {
          Image(systemName: "goforward.15").font(.system(size: 28, weight: .medium))
            .frame(width: 40, height: 40).contentShape(.interaction, Rectangle())
        }.help("15秒進む（⌘→）").accessibilityLabel("15秒進む")
      }.buttonStyle(.borderless).disabled(!store.canPlay)
        .frame(maxWidth: .infinity, alignment: .center)
      HStack(spacing: 12) {
        Image(systemName: "speaker.wave.2").font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary).help("再生レベル").accessibilityLabel("再生レベル")
        LevelMeter(level: store.playbackLevel, label: "再生レベル").frame(width: 110, height: 18)
      }.frame(maxWidth: .infinity, alignment: .center)
    }.frame(maxWidth: 560)
  }
}
