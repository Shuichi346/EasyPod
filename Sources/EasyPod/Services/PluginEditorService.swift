import AVFoundation
import AppKit
import CoreAudioKit

@MainActor
final class PluginEditorService: NSObject, NSWindowDelegate {
  private var windows: [UUID: NSWindow] = [:]
  private var retainedUnits: [UUID: AVAudioUnit] = [:]

  isolated deinit {
    for (id, window) in windows {
      window.delegate = nil
      (retainedUnits[id]?.auAudioUnit as? EPVST3AudioUnit)?.closeEditor()
      window.contentViewController = nil
      window.contentView = nil
      window.close()
    }
  }

  func show(id: UUID, title: String, unit: AVAudioUnit) {
    if let window = windows[id] {
      window.makeKeyAndOrderFront(nil)
      return
    }
    retainedUnits[id] = unit
    if let adapter = unit.auAudioUnit as? EPVST3AudioUnit, let view = adapter.makeEditorView() {
      present(id: id, title: title, view: view)
      return
    }
    unit.auAudioUnit.requestViewController { [weak self] controller in
      Task { @MainActor in
        guard let self, self.windows[id] == nil, self.retainedUnits[id] != nil else { return }
        if let controller {
          let window = self.makeWindow(id: id, title: title, size: controller.view.frame.size)
          window.contentViewController = controller
          window.makeKeyAndOrderFront(nil)
        } else {
          self.present(id: id, title: title, view: self.genericView(unit: unit))
        }
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let id = windows.first(where: { $0.value === window })?.key
    else { return }
    (retainedUnits[id]?.auAudioUnit as? EPVST3AudioUnit)?.closeEditor()
    window.contentViewController = nil
    window.contentView = nil
    windows[id] = nil
    retainedUnits[id] = nil
  }

  private func makeWindow(id: UUID, title: String, size: NSSize) -> NSWindow {
    let size = NSSize(width: max(400, size.width), height: max(250, size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    windows[id] = window
    return window
  }

  private func present(id: UUID, title: String, view: NSView) {
    let window = makeWindow(id: id, title: title, size: view.frame.size)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
  }

  private func genericView(unit: AVAudioUnit) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    let parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
    if parameters.isEmpty {
      stack.addArrangedSubview(NSTextField(labelWithString: "このプラグインには編集可能なパラメータがありません。"))
    }
    for parameter in parameters {
      let row = NSStackView()
      row.orientation = .horizontal
      row.spacing = 12
      let name = NSTextField(labelWithString: parameter.displayName)
      name.widthAnchor.constraint(equalToConstant: 190).isActive = true
      let slider = ParameterSlider(parameter: parameter)
      slider.widthAnchor.constraint(equalToConstant: 250).isActive = true
      row.addArrangedSubview(name)
      row.addArrangedSubview(slider)
      stack.addArrangedSubview(row)
    }
    let scroll = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 510, height: min(600, max(250, parameters.count * 38 + 36))))
    scroll.hasVerticalScroller = true
    scroll.documentView = stack
    stack.frame = NSRect(x: 0, y: 0, width: 510, height: max(250, parameters.count * 38 + 36))
    return scroll
  }
}

@MainActor
private final class ParameterSlider: NSSlider {
  private let parameter: AUParameter

  init(parameter: AUParameter) {
    self.parameter = parameter
    super.init(frame: .zero)
    minValue = Double(parameter.minValue)
    maxValue = Double(parameter.maxValue)
    doubleValue = Double(parameter.value)
    isEnabled = parameter.flags.contains(.flag_IsWritable)
    target = self
    action = #selector(changeValue)
    setAccessibilityLabel(parameter.displayName)
    if parameter.unit == .boolean {
      numberOfTickMarks = 2
      allowsTickMarkValuesOnly = true
    }
  }

  required init?(coder: NSCoder) { nil }

  @objc private func changeValue() {
    parameter.setValue(Float(doubleValue), originator: nil)
    toolTip = parameter.string(fromValue: nil)
  }
}
