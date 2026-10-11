import Cocoa
import FlutterMacOS
import Sparkle

/// In-place updates with Sparkle 2 (M9-03), the way DevVault does it
/// (its ADR-0007): Sparkle runs only when the person chooses Check for
/// Updates…, then fetches the appcast, checks the EdDSA signature and the
/// Developer ID team, asks, and restarts Relay.
///
/// Channel `relay/updater`: `isAvailable` → Bool, `check` → nil.
final class AppUpdater: NSObject {
  private let channel: FlutterMethodChannel
  private var controller: SPUStandardUpdaterController?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "relay/updater", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  /// Whether this build can update itself: a feed and the public half of
  /// the update key (Configs/AppInfo.xcconfig). Unset until Relay has a
  /// public release home (open decision 4).
  static var isConfigured: Bool {
    let info = Bundle.main.infoDictionary ?? [:]
    let feed = (info["SUFeedURL"] as? String) ?? ""
    let key = (info["SUPublicEDKey"] as? String) ?? ""
    return feed.hasPrefix("https://") && !key.isEmpty
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(AppUpdater.isConfigured)
    case "check":
      guard AppUpdater.isConfigured else {
        result(FlutterError(code: "unavailable", message: "This build can't update itself.", details: nil))
        return
      }
      let c = controller ?? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
      controller = c
      c.checkForUpdates(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
