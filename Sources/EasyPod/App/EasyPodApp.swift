import AppKit
import SwiftUI

@main struct EasyPodApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store = RecordingStore()

  var body: some Scene {
    WindowGroup("EasyPod") {
      ContentView(store: store)
        .onAppear { delegate.store = store }
    }
    .defaultSize(width: 1280, height: 900)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新しい録音") { store.newRecording() }
          .keyboardShortcut("n").disabled(store.isCapturing || store.exporting)
      }
      CommandMenu("録音") {
        Button(store.isCapturing ? "録音を停止" : "録音を開始") {
          Task { if store.isCapturing { await store.stop() } else { await store.start() } }
        }
        .keyboardShortcut("r").disabled(store.transportBusy || store.exporting)
        Button("一時停止・再開") { Task { await store.pauseOrResume() } }
          .keyboardShortcut(" ", modifiers: []).disabled(!store.isCapturing || store.transportBusy)
        Button("再生・停止") { Task { await store.togglePlayback() } }
          .keyboardShortcut("p").disabled(store.isCapturing || store.selected == nil)
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
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store else { return .terminateNow }
    if store.isCapturing || store.exporting {
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
