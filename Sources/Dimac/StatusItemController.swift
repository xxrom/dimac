import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    /// The popover the user is interacting with. At most one is tracked or on screen.
    private var popover: NSPopover?
    /// A popover fading out after `closePopover()`; it is closed at once if a new one opens.
    private var closingPopover: NSPopover?
    private var outsideEventMonitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool {
        statusItem != nil
    }

    func setVisible(_ visible: Bool) {
        if visible {
            installIfNeeded()
        } else {
            remove()
        }
    }

    /// Shows the popover, or the settings window if the status item cannot anchor one
    /// (no button, or hidden from the menu bar by the system or the user).
    func showPopover() {
        installIfNeeded()

        guard let statusItem, statusItem.isVisible, let button = statusItem.button else {
            model?.showSettingsWindow()
            return
        }

        // Reuse a popover that is already open instead of stacking a second one.
        if let current = self.popover, current.isShown {
            activate(current)
            return
        }

        // Drop any popover still fading out, or one that closed without telling us.
        finishClosingPopover()
        if let stale = self.popover {
            self.popover = nil
            discard(stale)
        }

        let newPopover = makePopover()
        self.popover = newPopover
        NSApp.activate(ignoringOtherApps: true)
        newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        activate(newPopover)
        startMonitoringOutsideEvents()
        model?.setSettingsPresentation(.popover, visible: true)
    }

    private func activate(_ popover: NSPopover) {
        NSApp.activate(ignoringOtherApps: true)
        // Make the popover key so its text fields receive typing and Edit menu shortcuts.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func installIfNeeded() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        // No tooltip: macOS draws the menu bar item out of process, so the mouse-exit that should
        // dismiss it can be lost (always with an auto-hiding menu bar), stranding it on screen.
        item.button?.setAccessibilityLabel("Dimac")

        if let image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Dimac") {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            let configuredImage = image.withSymbolConfiguration(configuration) ?? image
            configuredImage.isTemplate = true
            item.button?.image = configuredImage
            item.button?.imagePosition = .imageOnly
        } else {
            item.button?.title = "Dimac"
        }

        statusItem = item
    }

    private func remove() {
        closePopover()
        finishClosingPopover()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            closePopover()
            return
        }

        showPopover()
    }

    /// Starts the close fade. The old popover stays referenced until it has closed so the fade
    /// can be cut short if the user opens a new popover meanwhile.
    private func closePopover() {
        stopMonitoringOutsideEvents()
        guard let popover else {
            return
        }
        self.popover = nil
        model?.setSettingsPresentation(.popover, visible: false)
        finishClosingPopover()
        closingPopover = popover
        popover.performClose(nil)
    }

    /// Closes a fading popover immediately.
    private func finishClosingPopover() {
        guard let closing = closingPopover else {
            return
        }
        closingPopover = nil
        discard(closing)
    }

    private func discard(_ popover: NSPopover) {
        popover.animates = false
        if popover.isShown {
            popover.close()
        }
    }

    private func startMonitoringOutsideEvents() {
        stopMonitoringOutsideEvents()
        // Clicks only: key presses must never close the popover while the user types in it.
        outsideEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func stopMonitoringOutsideEvents() {
        if let outsideEventMonitor {
            NSEvent.removeMonitor(outsideEventMonitor)
        }
        outsideEventMonitor = nil
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 340, height: 480)

        if let model {
            let controller = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(model)
                    .environmentObject(model.dimmer)
                    .environmentObject(model.settings)
            )
            controller.sizingOptions = .preferredContentSize
            popover.contentViewController = controller
        }

        return popover
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        guard let shown = notification.object as? NSPopover, shown === popover else {
            return
        }
        // Resize instantly when Advanced opens or closes; keep the open/close fade.
        shown.animates = false
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover,
              closing === popover || closing === closingPopover else {
            return
        }
        closing.animates = true
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover else {
            return
        }
        if closed === closingPopover {
            closingPopover = nil
        }
        // A stale popover's close must not tear down the one now on screen.
        guard closed === popover else {
            return
        }
        popover = nil
        stopMonitoringOutsideEvents()
        model?.setSettingsPresentation(.popover, visible: false)
    }
}
