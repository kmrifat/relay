import Cocoa
import FlutterMacOS

/// Relay in the menu bar (M9-02): how many agents run, what waits on you,
/// pause new work, open, quit. Flutter feeds it over `relay/system`:
///   status {running, waiting, paused, items: [{id, title}]}
///   keepInMenuBar {on}   keep running in the menu bar when the window closes
/// Menu choices come back as `menu {action, taskId?}`.
final class StatusMenu: NSObject, NSMenuDelegate {
  static let shared = StatusMenu()
  private var item: NSStatusItem?
  private var channel: FlutterMethodChannel?
  private var running = 0, waiting = 0
  private var paused = false
  private var items: [(String, String)] = []

  /// Keep the app (and its menu bar item) when the last window closes.
  var keepInMenuBar: Bool {
    get { UserDefaults.standard.object(forKey: "keepInMenuBar") as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: "keepInMenuBar")
      newValue ? show() : hide()
    }
  }

  func attach(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "relay/system", binaryMessenger: messenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "status":
        self.running = args["running"] as? Int ?? 0
        self.waiting = args["waiting"] as? Int ?? 0
        self.paused = args["paused"] as? Bool ?? false
        self.items = (args["items"] as? [[String: Any]] ?? []).compactMap {
          guard let id = $0["id"] as? String, let title = $0["title"] as? String else { return nil }
          return (id, title)
        }
        self.refresh()
        result(nil)
      case "keepInMenuBar":
        self.keepInMenuBar = args["on"] as? Bool ?? true
        result(nil)
      case "loginItem":
        result(LoginItem.status())
      case "setLoginItem":
        do {
          result(try LoginItem.set(args["on"] as? Bool ?? false))
        } catch {
          result(FlutterError(code: "loginItem", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if keepInMenuBar { show() }
  }

  private func show() {
    guard item == nil else { return }
    let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    menu.delegate = self
    it.menu = menu
    item = it
    refresh()
  }

  private func hide() {
    if let it = item { NSStatusBar.system.removeStatusItem(it) }
    item = nil
  }

  private func refresh() {
    guard let button = item?.button else { return }
    let image = NSImage(systemSymbolName: paused ? "pause.circle" : "checklist", accessibilityDescription: "Relay")
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageLeading
    // A number only when something needs the person; no animation.
    button.title = waiting > 0 ? " \(waiting)" : ""
    button.toolTip = "Relay · \(running) running · \(waiting) waiting on you"
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let head = NSMenuItem(title: "\(running) agent\(running == 1 ? "" : "s") running · \(waiting) waiting on you", action: nil, keyEquivalent: "")
    head.isEnabled = false
    menu.addItem(head)
    for (id, title) in items.prefix(6) {
      let mi = NSMenuItem(title: title, action: #selector(openTask(_:)), keyEquivalent: "")
      mi.target = self
      mi.representedObject = id
      menu.addItem(mi)
    }
    menu.addItem(.separator())
    add(menu, paused ? "Resume new work" : "Pause new work", #selector(togglePause))
    add(menu, "Open Relay", #selector(openApp), key: "o")
    menu.addItem(.separator())
    add(menu, "Quit Relay", #selector(quit), key: "q")
  }

  private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
    mi.target = self
    menu.addItem(mi)
  }

  @objc private func openTask(_ sender: NSMenuItem) {
    openApp()
    channel?.invokeMethod("menu", arguments: ["action": "openTask", "taskId": sender.representedObject as? String ?? ""])
  }

  @objc private func togglePause() {
    channel?.invokeMethod("menu", arguments: ["action": paused ? "resume" : "pause"])
  }

  @objc func openApp() {
    NSApp.activate(ignoringOtherApps: true)
    for w in NSApp.windows where w is MainFlutterWindow {
      w.makeKeyAndOrderFront(nil)
    }
  }

  /// Quits the window app; relayd keeps running (agents finish their work).
  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
