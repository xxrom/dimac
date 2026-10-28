import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private weak var model: AppModel?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

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
        // Drop the window on close so its SettingsView stops observing the model while hidden.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let closeObserver = self.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                self.closeObserver = nil
                self.window = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
