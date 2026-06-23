import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
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

    func showPopover() {
        installIfNeeded()

        guard let button = statusItem?.button else {
            model?.showSettingsWindow()
            return
        }

        let popover = makePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        startMonitoringOutsideEvents()
    }

    private func installIfNeeded() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Dimac"

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

    private func closePopover() {
        stopMonitoringOutsideEvents()
        popover?.performClose(nil)
        popover = nil
    }

    private func startMonitoringOutsideEvents() {
        stopMonitoringOutsideEvents()
        outsideEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
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
        popover.contentSize = NSSize(width: 330, height: 520)

        if let model {
            popover.contentViewController = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(model)
                    .environmentObject(model.dimmer)
                    .environmentObject(model.settings)
            )
        }

        return popover
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopMonitoringOutsideEvents()
        popover = nil
    }
}
