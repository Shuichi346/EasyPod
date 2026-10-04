import SwiftUI

struct QualityControls: View {
  @Binding var settings: RecordingSettings
  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text(settings.format == .wav ? "ビット深度" : "AAC ビットレート").font(
          .system(size: 12, weight: .medium)
        ).foregroundStyle(.secondary)
        if settings.format == .wav {
          ChoiceMenu(
            title: "ビット深度", selection: $settings.bitDepth,
            choices: [("16 bit", 16), ("24 bit", 24), ("32 bit float", 32)])
        } else {
          ChoiceMenu(
            title: "AAC ビットレート", selection: $settings.bitrate,
            choices: [96_000, 128_000, 192_000, 256_000].map { ("\($0 / 1000) kbps", $0) })
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Divider().frame(height: 48)
      VStack(alignment: .leading, spacing: 6) {
        Text("サンプルレート").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        ChoiceMenu(
          title: "サンプルレート", selection: $settings.sampleRate,
          choices: [("44.1 kHz", 44_100.0), ("48 kHz", 48_000.0)])
      }.frame(maxWidth: .infinity, alignment: .leading)
      Divider().frame(height: 48)
      VStack(alignment: .leading, spacing: 6) {
        Text("形式").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        ChoiceSegments(
          title: "形式", selection: $settings.format,
          choices: ExportFormat.allCases.map { ($0.label, $0) })
      }.frame(maxWidth: .infinity, alignment: .leading)
      Divider().frame(height: 48)
      VStack(alignment: .leading, spacing: 6) {
        Text("チャンネル").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        ChoiceSegments(
          title: "チャンネル", selection: $settings.channels,
          choices: [("モノラル", 1), ("ステレオ", 2)])
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.fixedSize(horizontal: false, vertical: true)
  }
}

struct ChoiceMenu<Value: Hashable>: View {
  var title: String
  @Binding var selection: Value
  var choices: [(String, Value)]

  var body: some View {
    Menu {
      ForEach(choices.indices, id: \.self) { index in
        Button {
          selection = choices[index].1
        } label: {
          HStack {
            Text(choices[index].0)
            if selection == choices[index].1 { Image(systemName: "checkmark") }
          }
        }
      }
    } label: {
      HStack {
        Text(choices.first { $0.1 == selection }?.0 ?? "").lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 8)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }.padding(.horizontal, 12).frame(height: 32).frame(maxWidth: .infinity)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
      .frame(maxWidth: .infinity)
      .accessibilityLabel(title).accessibilityValue(choices.first { $0.1 == selection }?.0 ?? "")
  }
}

struct ChoiceSegments<Value: Hashable>: View {
  var title: String
  @Binding var selection: Value
  var choices: [(String, Value)]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(choices.indices, id: \.self) { index in
        let selected = choices[index].1 == selection
        Button {
          selection = choices[index].1
        } label: {
          Text(choices[index].0).font(.system(size: 13, weight: selected ? .medium : .regular))
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(
              selected ? Theme.control : Color.clear,
              in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay {
              if selected {
                RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1)
              }
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
      }
    }.padding(2).frame(height: 32)
      .background(Theme.track, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
      .accessibilityElement(children: .contain).accessibilityLabel(title)
  }
}
