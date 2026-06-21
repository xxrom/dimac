import AppKit
import CoreGraphics
import DimacCore

@MainActor
final class SoftwareDimmingOverlayController {
    struct Target: Equatable {
        let displayID: String
        let percent: Int
    }

    private var windowsByDisplayID: [String: NSWindow] = [:]
    private var appliedTargets: [Target] = []

    var isVisible: Bool {
        !windowsByDisplayID.isEmpty
    }

    func show(dimPercent: Int) {
        let percent = DimmerSettings.clampedPercent(dimPercent)
        apply(Self.externalScreens().map { Target(displayID: $0.id, percent: percent) })
    }

    func apply(_ targets: [Target]) {
        let clampedTargets = targets
            .map { Target(displayID: $0.displayID, percent: DimmerSettings.clampedPercent($0.percent)) }
            .filter { $0.percent < 100 }

        guard !clampedTargets.isEmpty else {
            hide()
            return
        }

        if appliedTargets == clampedTargets {
            return
        }

        let targetIDs = Set(clampedTargets.map(\.displayID))
        for (displayID, window) in windowsByDisplayID where !targetIDs.contains(displayID) {
            window.orderOut(nil)
            window.close()
            windowsByDisplayID[displayID] = nil
        }

        let screensByID = Dictionary(uniqueKeysWithValues: Self.externalScreens().map { ($0.id, $0.screen) })

        for target in clampedTargets {
            guard let screen = screensByID[target.displayID] else {
                continue
            }

            let alpha = min(0.92, max(0.0, 1.0 - (CGFloat(target.percent) / 100.0)))
            let window = windowsByDisplayID[target.displayID] ?? NSWindow(
                contentRect: screen.visibleFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: false)
            window.backgroundColor = NSColor.black.withAlphaComponent(alpha)
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary
            ]
            window.orderFrontRegardless()
            windowsByDisplayID[target.displayID] = window
        }

        appliedTargets = clampedTargets
    }

    func hide() {
        for window in windowsByDisplayID.values {
            window.orderOut(nil)
            window.close()
        }
        windowsByDisplayID = [:]
        appliedTargets = []
    }

    private static func externalScreens() -> [(id: String, screen: NSScreen)] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard CGDisplayIsBuiltin(displayID) == 0 else {
                return nil
            }

            return ("\(displayID)", screen)
        }
    }
}
