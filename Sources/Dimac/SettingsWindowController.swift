import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private weak var model: AppModel?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let model else {
            return
        }

        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(model)
                .environmentObject(model.dimmer)
                .environmentObject(model.settings)
        )

        let window = NSWindow(contentViewController: controller)
        window.title = "Dimac"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 330, height: 520))
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
