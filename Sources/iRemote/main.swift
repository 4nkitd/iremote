import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        let controller = PanelController(model: model)
        self.controller = controller
        if model.pairing != nil || ProcessInfo.processInfo.environment["IREMOTE_OPEN"] != nil {
            controller.open()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
