import SwiftUI

struct EffectRackView: View {
  @Bindable var store: RecordingStore
  @Binding var showPicker: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("エフェクト").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
      HStack(spacing: 16) {
        ChoiceSegments(
          title: "エフェクトのタイミング", selection: $store.preferences.settings.effectTiming,
          choices: EffectTiming.allCases.map { ($0.label, $0) }
        )
        .frame(width: 200).disabled(store.isCapturing)
        Button {
          showPicker = true
        } label: {
          Label("VST3 / AU を追加", systemImage: "plus.circle").frame(minHeight: 28)
        }
        .buttonStyle(.borderless).disabled(!store.canEditChain)
      }
      if !store.effects.isEmpty {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(Array(store.effects.enumerated()), id: \.element.id) { index, slot in
              HStack(spacing: 6) {
                Button {
                  store.bypass(slot.id)
                } label: {
                  Image(systemName: "power").frame(width: 28, height: 28)
                }
                .foregroundStyle(slot.bypassed ? Color.secondary : Color.coral)
                .help("バイパス切り替え")
                .accessibilityLabel(
                  slot.bypassed
                    ? "\(slot.plugin.name)を有効にする" : "\(slot.plugin.name)をバイパスする"
                )
                .accessibilityValue(slot.bypassed ? "バイパス中" : "有効")
                Text(slot.plugin.name).lineLimit(1)
                Text(slot.plugin.format.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                  Task { await store.editEffect(slot.id) }
                } label: {
                  Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28)
                }
                .help("エフェクトの編集").accessibilityLabel("\(slot.plugin.name)のエディター")
                Button {
                  Task { await store.moveEffect(slot.id, delta: -1) }
                } label: {
                  Image(systemName: "chevron.up").frame(width: 28, height: 28)
                }
                .disabled(index == 0 || !store.canEditChain).help("上に移動").accessibilityLabel("上に移動")
                Button {
                  Task { await store.moveEffect(slot.id, delta: 1) }
                } label: {
                  Image(systemName: "chevron.down").frame(width: 28, height: 28)
                }
                .disabled(index == store.effects.count - 1 || !store.canEditChain).help("下に移動")
                .accessibilityLabel("下に移動")
                Button {
                  Task { await store.removeEffect(slot.id) }
                } label: {
                  Image(systemName: "minus.circle").frame(width: 28, height: 28)
                }
                .disabled(!store.canEditChain).help("エフェクトを外す").accessibilityLabel(
                  "\(slot.plugin.name)を外す")
              }.buttonStyle(.borderless).padding(.vertical, 9)
              Divider()
            }
          }
        }.frame(maxHeight: 110)
      }
    }
  }
}

struct PluginPickerView: View {
  @Bindable var store: RecordingStore
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("エフェクトを追加").font(.title2.bold())
        Spacer()
        Button("再スキャン") { Task { await store.discoverPlugins(force: true) } }.disabled(
          store.scanning)
      }
      TextField("名前やメーカーで検索", text: $search).textFieldStyle(.roundedBorder)
      if store.scanning { ProgressView("AU / VST3 を確認中…") }
      List(
        store.plugins.filter {
          search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
            || $0.manufacturer.localizedCaseInsensitiveContains(search)
        }
      ) { plugin in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(plugin.name)
            Text(plugin.unavailableReason ?? "\(plugin.manufacturer) · \(plugin.format.rawValue)")
              .font(.caption).foregroundStyle(
                plugin.unavailableReason == nil ? Color.secondary : Color.orange)
          }.accessibilityElement(children: .combine)
          Spacer()
          Button("追加") {
            Task {
              await store.addEffect(plugin)
              dismiss()
            }
          }.buttonStyle(.bordered).disabled(plugin.unavailableReason != nil)
            .accessibilityLabel("\(plugin.name)（\(plugin.format.rawValue)）を追加")
        }.padding(.vertical, 4)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(plugin.name)（\(plugin.format.rawValue)）")
      }
      HStack {
        Spacer()
        Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(width: 620, height: 500)
      .task { await store.discoverPlugins() }
  }
}
