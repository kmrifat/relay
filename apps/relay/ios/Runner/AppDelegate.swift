import Flutter
import UIKit
import UserNotifications

/// Relay on iPhone. Besides Flutter, this wires notifications (M8-04) on
/// the `relay/notify` channel, the same one the Mac app uses:
///   register            → ask for permission, register with APNs; the
///                         token comes back as `token {token, sandbox}`
///   post {title, body, info} → a local notification
///   badge {label}       → the app icon badge
/// Tapping a notification sends `open {info}` to Flutter.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var channel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RelayNotify") else { return }
    let ch = FlutterMethodChannel(name: "relay/notify", binaryMessenger: registrar.messenger())
    channel = ch
    ch.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "register":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          guard granted else { return }
          DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
        result(nil)
      case "post":
        let content = UNMutableNotificationContent()
        content.title = args["title"] as? String ?? "Relay"
        content.body = args["body"] as? String ?? ""
        content.sound = .default
        content.userInfo = ["relay": args["info"] as? [String: Any] ?? [:]]
        let id = args["id"] as? String ?? UUID().uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        result(nil)
      case "badge":
        let n = Int(args["label"] as? String ?? "") ?? 0
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(n)
        } else {
          UIApplication.shared.applicationIconBadgeNumber = n
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    #if DEBUG
    let sandbox = true
    #else
    let sandbox = false
    #endif
    channel?.invokeMethod("token", arguments: ["token": token, "sandbox": sandbox])
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    channel?.invokeMethod("tokenError", arguments: ["error": error.localizedDescription])
  }

  // In front, the app shows things itself.
  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler(UIApplication.shared.applicationState == .active ? [] : [.banner, .sound, .badge])
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo["relay"] as? [String: Any] ?? [:]
    channel?.invokeMethod("open", arguments: ["info": info])
    completionHandler()
  }
}
