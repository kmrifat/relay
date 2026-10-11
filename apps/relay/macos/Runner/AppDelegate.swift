import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// With the menu bar item on, closing the window keeps Relay running
  /// there (idle: no timers, no animation); otherwise it quits. relayd runs
  /// on either way.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !StatusMenu.shared.keepInMenuBar
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { StatusMenu.shared.openApp() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
