import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var updater: AppUpdater?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Unified look (design T01): the sidebar runs up under the traffic
    // lights and the toolbar is drawn by Flutter.
    self.title = "Relay"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = false
    self.setContentSize(NSSize(width: 1440, height: 900))
    self.contentMinSize = NSSize(width: 1100, height: 680)
    self.center()
    self.setFrameAutosaveName("RelayMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    Notifications.shared.attach(flutterViewController.engine.binaryMessenger)
    StatusMenu.shared.attach(flutterViewController.engine.binaryMessenger)
    updater = AppUpdater(messenger: flutterViewController.engine.binaryMessenger)
    // Closing the window hides it; Relay stays in the menu bar (M9-02).
    self.isReleasedWhenClosed = false

    super.awakeFromNib()
  }
}

/// System notifications and the Dock badge for relayd's `notify` events
/// (M7-04), over the `relay/notify` channel:
///   post {id, title, body, info}   → a notification; banners only while
///                                    Relay is in the background
///   badge {label}                  → the Dock badge ("" clears it)
/// A click sends `open {info}` back to Flutter and brings Relay forward.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifications()
  private var channel: FlutterMethodChannel?
  private var asked = false

  func attach(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "relay/notify", binaryMessenger: messenger)
    channel = ch
    UNUserNotificationCenter.current().delegate = self
    ch.setMethodCallHandler { [weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "post":
        self?.post(args)
        result(nil)
      case "badge":
        NSApp.dockTile.badgeLabel = (args["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func post(_ args: [String: Any]) {
    let center = UNUserNotificationCenter.current()
    let send = {
      let content = UNMutableNotificationContent()
      content.title = args["title"] as? String ?? "Relay"
      content.body = args["body"] as? String ?? ""
      content.sound = .default
      content.userInfo = args["info"] as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? UUID().uuidString
      center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    if asked {
      send()
      return
    }
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      self.asked = true
      if granted { send() }
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // While Relay is in front the app shows it itself.
    completionHandler(NSApp.isActive ? [] : [.banner, .sound])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    NSApp.activate(ignoringOtherApps: true)
    channel?.invokeMethod("open", arguments: ["info": response.notification.request.content.userInfo])
    completionHandler()
  }
}
