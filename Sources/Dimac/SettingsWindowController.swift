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
        // Size the window to SettingsView (fixed width, ideal height) and follow it when
        // Advanced opens or closes, so nothing is clipped.
        controller.sizingOptions = [.preferredContentSize, .minSize, .maxSize]

        let window = NSWindow(contentViewController: controller)
        window.title = "Dimac"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(controller.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        model.setSettingsPresentation(.window, visible: true)
        // Drop the window on close so its SettingsView stops observing the model while hidden.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let closeObserver = self.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                self.closeObserver = nil
                self.window = nil
                self.model?.setSettingsPresentation(.window, visible: false)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
