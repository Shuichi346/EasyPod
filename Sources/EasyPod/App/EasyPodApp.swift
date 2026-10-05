import AppKit
import SwiftUI

@main struct EasyPodApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store = RecordingStore(loadSessions: !MicrophoneRouteVerification.isRequested)

  var body: some Scene {
    WindowGroup("EasyPod") {
      if MicrophoneRouteVerification.isRequested {
        EmptyView()
      } else {
        ContentView(store: store)
          .onAppear { delegate.store = store }
      }
    }
    .defaultSize(width: 1280, height: 900)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新しい録音") { store.newRecording() }
          .keyboardShortcut("n").disabled(!store.canOrganize)
      }
      CommandMenu("録音") {
        Button(store.isCapturing ? "録音を停止" : "録音を開始") {
          Task { if store.isCapturing { await store.stop() } else { await store.start() } }
        }
        .keyboardShortcut("r").disabled(
          store.transportBusy || store.exporting || store.refining || store.libraryFilter == .trash)
        Button("一時停止・再開") { Task { await store.pauseOrResume() } }
          .keyboardShortcut(" ", modifiers: []).disabled(!store.isCapturing || store.transportBusy)
        Button("再生・一時停止") { Task { await store.togglePlayback() } }
          .keyboardShortcut("p").disabled(!store.canPlay)
        Button("15秒戻る") { store.skipPlayback(seconds: -15) }
          .keyboardShortcut(.leftArrow).disabled(!store.canPlay)
        Button("15秒進む") { store.skipPlayback(seconds: 15) }
          .keyboardShortcut(.rightArrow).disabled(!store.canPlay)
        Button("清書") { store.refineTranscript() }.disabled(!store.canRefine)
        Button("ごみ箱へ移動") {
          store.requestTrashSelection()
        }.keyboardShortcut(.delete, modifiers: .command).disabled(!store.canTrashSelection)
        Divider()
        Button("書き出す…") { store.showExportSheet = true }
          .keyboardShortcut("e").disabled(!store.canExport)
      }
    }
    Settings { SettingsView(store: store) }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var store: RecordingStore?
  func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
      if MicrophoneRouteVerification.isRequested {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
          await MicrophoneRouteVerification.run()
          NSApp.terminate(nil)
        }
        return
      }
    #endif
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    if store.isCapturing || store.transportBusy || store.exporting || store.refining {
      Task {
        await store.prepareForTermination()
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
    store.stopPlayback()
    store.saveEffects()
    return .terminateNow
  }
}
