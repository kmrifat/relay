import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
