import Cocoa
import FlutterMacOS
import ServiceManagement

/// Starts relayd at login (M9-02) with the LaunchAgent bundled at
/// Contents/Library/LaunchAgents/com.binarycastle.relay.daemon.plist, so
/// queued and overnight work runs without opening Relay.
///
/// Channel `relay/system`: `loginItem` → status, `setLoginItem {on}` → status.
/// Status is enabled, off, needsApproval (System Settings → Login Items) or
/// unsupported (macOS 12).
enum LoginItem {
  static let plist = "com.binarycastle.relay.daemon.plist"

  static func status() -> String {
    guard #available(macOS 13.0, *) else { return "unsupported" }
    switch SMAppService.agent(plistName: plist).status {
    case .enabled: return "enabled"
    case .requiresApproval: return "needsApproval"
    case .notFound: return "notFound"
    default: return "off"
    }
  }

  static func set(_ on: Bool) throws -> String {
    guard #available(macOS 13.0, *) else { return "unsupported" }
    let service = SMAppService.agent(plistName: plist)
    if on {
      try service.register()
      if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    } else {
      try service.unregister()
    }
    return status()
  }
}
