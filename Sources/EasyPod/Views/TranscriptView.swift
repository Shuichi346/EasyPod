import AppKit
import SwiftUI

struct TranscriptView: View {
  @Bindable var store: RecordingStore
  private var segments: [TranscriptSegment] {
    store.isCapturing ? store.transcription.segments : store.selected?.transcript ?? []
  }
  private var recognitionStatus: String {
    if store.isCapturing { return store.transcription.status }
    return store.selected?.transcriptionStatus
      ?? (store.preferences.transcriptionEnabled ? "Nemotron 3.5 · ローカル" : "文字起こし オフ")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("文字起こし").font(.system(size: 15, weight: .semibold))
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            segments.map(\.text).joined(separator: "\n\n"), forType: .string)
        } label: {
          Image(systemName: "doc.on.doc").frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless).disabled(segments.isEmpty).help("文字起こしをコピー")
        .accessibilityLabel("文字起こしをコピー")
      }
      HStack(spacing: 7) {
        Circle().fill(
          recognitionStatus.hasPrefix("文字起こし:")
            ? Color.orange
            : store.preferences.transcriptionEnabled ? Color.green : Color.secondary
        ).frame(
          width: 8, height: 8)
        Text(recognitionStatus).font(.system(size: 12)).foregroundStyle(.secondary)
          .lineLimit(3).help(recognitionStatus)
      }.padding(.horizontal, 12).padding(.vertical, 8).background(
        Theme.track, in: RoundedRectangle(cornerRadius: 6))
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if segments.isEmpty {
              Text(
                store.selected == nil
                  ? "録音を始めると、ここに文字起こしが表示されます。音声はこのMacだけで処理されます。"
                  : "この録音の文字起こしはありません。音声はこのMacだけで処理されます。"
              )
              .foregroundStyle(.secondary).font(.system(size: 15)).lineSpacing(5)
            }
            ForEach(segments) { segment in
              VStack(alignment: .leading, spacing: 7) {
                Text("\(AudioTime.string(segment.start)) – \(AudioTime.string(segment.end))")
                  .font(.caption.monospaced()).foregroundStyle(.secondary)
                  .accessibilityLabel(
                    "\(AudioTime.string(segment.start))から\(AudioTime.string(segment.end))まで"
                  )
                Text(segment.text).font(.system(size: 16)).lineSpacing(5)
                  .foregroundStyle(segment.isFinal ? Color.primary : Color.secondary)
                  .textSelection(.enabled)
              }.id(segment.id)
            }
            Color.clear.frame(height: 1).id("end")
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: segments) { proxy.scrollTo("end", anchor: .bottom) }
      }
    }.padding(.horizontal, 20).padding(.vertical, 14).frame(maxHeight: .infinity, alignment: .top)
  }
}
