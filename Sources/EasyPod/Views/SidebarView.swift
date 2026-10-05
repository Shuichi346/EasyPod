import SwiftUI

struct SidebarView: View {
  @Bindable var store: RecordingStore
  @State private var folderPrompt = false
  @State private var folderName = ""
  @State private var renamingFolder: UUID?

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        Button {
          renamingFolder = nil
          folderName = ""
          folderPrompt = true
        } label: {
          Image(systemName: "folder.badge.plus").font(.system(size: 20, weight: .medium))
            .frame(width: 36, height: 36).contentShape(.interaction, Rectangle())
        }
        .help("フォルダーを作成").accessibilityLabel("フォルダーを作成")
        Button {
          store.newRecording()
        } label: {
          Image(systemName: "plus").font(.system(size: 20, weight: .medium))
            .frame(width: 36, height: 36).contentShape(.interaction, Rectangle())
        }
        .help("新しい録音（⌘N）").accessibilityLabel("新しい録音")
        Picker(
          "フォルダー",
          selection: Binding(
            get: { store.libraryFilter }, set: { store.setLibraryFilter($0) }
          )
        ) {
          Text("すべての録音").tag(RecordingLibraryFilter.all)
          Text("未分類").tag(RecordingLibraryFilter.unfiled)
          ForEach(store.folders) { folder in
            Text(folder.name).tag(RecordingLibraryFilter.folder(folder.id))
          }
          Text("ごみ箱（\(store.trashedSessions.count)）").tag(RecordingLibraryFilter.trash)
        }.labelsHidden().font(.system(size: 12)).frame(maxWidth: .infinity)
          .accessibilityLabel("録音のフォルダー").help("録音のフォルダーを選択")
          .contextMenu {
            if case .folder(let id) = store.libraryFilter {
              Button("名前を変更") {
                renamingFolder = id
                folderName = store.folders.first { $0.id == id }?.name ?? ""
                folderPrompt = true
              }
              Button("フォルダーを削除") { store.deleteFolder(id) }
            }
          }
      }.buttonStyle(.borderless).disabled(!store.canOrganize)
        .padding(.horizontal, 14).padding(.top, 20)
      List(
        selection: Binding(
          get: { store.selectedIDs }, set: { store.setLibrarySelection($0) }
        )
      ) {
        ForEach(store.visibleSessions) { session in
          HStack(spacing: 12) {
            Image(
              systemName: session.status == .interrupted ? "exclamationmark.triangle" : "waveform"
            )
            .font(.title2)
            .foregroundStyle(store.selectedID == session.id ? Color.coral : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
              Text(session.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
              Text(
                session.createdAt.formatted(.dateTime.month().day()) + " · "
                  + AudioTime.string(session.duration)
              )
              .font(.system(size: 12)).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 8).tag(session.id)
            .contextMenu {
              if store.libraryFilter == .trash {
                Button("録音を戻す") { store.restoreRecording(session.id) }
              } else {
                Menu("フォルダーへ移動") {
                  Button("未分類") { store.moveRecording(session.id, to: nil) }
                  ForEach(store.folders) { folder in
                    Button(folder.name) { store.moveRecording(session.id, to: folder.id) }
                  }
                }
                Button("ごみ箱へ移動") { store.requestTrashRecording(session.id) }
              }
            }
        }
      }.listStyle(.sidebar).disabled(!store.canOrganize)
        .help("⌘クリックまたはShiftクリックで複数の録音を選択できます")
        .overlay {
          if store.visibleSessions.isEmpty {
            Text(store.libraryFilter == .trash ? "ごみ箱は空です" : "このフォルダーに録音はありません")
              .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
          }
        }
        .alert("録音を削除しますか？", isPresented: $store.showTrashConfirmation) {
          Button("キャンセル", role: .cancel) { store.cancelTrashRequest() }
          Button("削除", role: .destructive) { store.confirmRequestedTrash() }
        } message: {
          Text(store.trashConfirmationMessage)
        }
      if let id = store.selectedID {
        HStack {
          if store.libraryFilter == .trash {
            Button {
              store.restoreRecording(id)
            } label: {
              Image(systemName: "arrow.uturn.backward").font(.system(size: 20, weight: .medium))
                .frame(width: 36, height: 36).contentShape(.interaction, Rectangle())
            }.help("録音を戻す").accessibilityLabel("ごみ箱の録音を戻す")
          } else {
            Menu {
              Button("未分類") { store.moveRecording(id, to: nil) }
              ForEach(store.folders) { folder in
                Button(folder.name) { store.moveRecording(id, to: folder.id) }
              }
            } label: {
              Image(systemName: "folder").font(.system(size: 20, weight: .medium))
                .frame(width: 36, height: 36).contentShape(.interaction, Rectangle())
            }
            .help("録音をフォルダーへ移動").accessibilityLabel("録音をフォルダーへ移動")
            Spacer()
            Button {
              store.requestTrashSelection()
            } label: {
              Image(systemName: "trash").font(.system(size: 20, weight: .medium))
                .frame(width: 36, height: 36).contentShape(.interaction, Rectangle())
            }.disabled(!store.canTrashSelection)
              .help("選択した\(store.selectedIDs.count)件をごみ箱へ移動（戻せます）")
              .accessibilityLabel("選択した録音をごみ箱へ移動")
          }
        }.buttonStyle(.borderless).disabled(!store.canOrganize)
          .padding(.horizontal, 16).padding(.bottom, 12)
      }
    }
    .alert(renamingFolder == nil ? "フォルダーを作成" : "フォルダーの名前", isPresented: $folderPrompt) {
      TextField("名前", text: $folderName)
      Button("キャンセル", role: .cancel) {}
      Button("保存") {
        if let id = renamingFolder {
          store.renameFolder(id, to: folderName)
        } else {
          store.createFolder(named: folderName)
        }
      }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("フォルダーを削除しても録音は未分類に残ります。")
    }
  }
}
