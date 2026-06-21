import Combine
import Foundation

@MainActor
public final class DimmerController: ObservableObject {
    @Published public private(set) var isDimmed = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var statusMessage = "Ready"
    @Published public private(set) var lastError: String?
    @Published public private(set) var externalDisplayCount = 0

    private let settingsProvider: () -> DimmerSettings
    private let internalBrightness: InternalBrightnessManaging
    private let externalBrightness: ExternalBrightnessManaging
    private let snapshotStore: SnapshotPersisting

    private var activeSnapshot: BrightnessSnapshot?
    private var lastDimAttemptAt = Date.distantPast

    public init(
        settingsProvider: @escaping () -> DimmerSettings,
        internalBrightness: InternalBrightnessManaging,
        externalBrightness: ExternalBrightnessManaging,
        snapshotStore: SnapshotPersisting
    ) {
        self.settingsProvider = settingsProvider
        self.internalBrightness = internalBrightness
        self.externalBrightness = externalBrightness
        self.snapshotStore = snapshotStore

        if let snapshot = try? snapshotStore.load() {
            activeSnapshot = snapshot
            isDimmed = true
            statusMessage = "Saved dim snapshot found"
        }
    }

    public func handleIdleTime(_ idleTime: TimeInterval, applyHardware: Bool = true) {
        let settings = settingsProvider()

        guard settings.isEnabled else {
            if isDimmed {
                restoreNow(reason: "disabled", applyHardware: applyHardware)
            }
            return
        }

        if idleTime >= TimeInterval(settings.idleTimeoutSeconds), !isDimmed {
            dimNow(applyHardware: applyHardware)
        } else if idleTime < 1, isDimmed {
            restoreNow(reason: "activity", applyHardware: applyHardware)
        }
    }

    public func handleUserActivity(applyHardware: Bool = true) {
        guard isDimmed else {
            return
        }

        restoreNow(reason: "activity", applyHardware: applyHardware)
    }

    @discardableResult
    public func refreshExternalDisplays() -> [ExternalDisplayReference] {
        do {
            let displays = try externalBrightness.discoverDisplays()
            externalDisplayCount = displays.count
            if displays.isEmpty {
                statusMessage = "No DDC external displays found"
            } else {
                statusMessage = "Found \(displays.count) DDC display\(displays.count == 1 ? "" : "s")"
            }
            lastError = nil
            return displays
        } catch {
            externalDisplayCount = 0
            report(error)
            return []
        }
    }

    public func setStatus(_ message: String, error: String? = nil) {
        statusMessage = message
        lastError = error
    }

    public func restorePersistedSnapshotIfNeeded() {
        guard let snapshot = activeSnapshot else {
            return
        }

        restore(snapshot, reason: "saved snapshot")
    }

    public func dimNow(applyHardware: Bool = true) {
        guard !isBusy else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastDimAttemptAt) > 2 else {
            return
        }
        lastDimAttemptAt = now

        let settings = settingsProvider()
        guard settings.isEnabled else {
            return
        }

        isBusy = true
        defer {
            isBusy = false
        }

        do {
            var snapshotErrors: [Error] = []

            let internalSnapshot: [InternalDisplaySnapshot]
            do {
                internalSnapshot = try internalBrightness.currentSnapshot()
            } catch {
                snapshotErrors.append(error)
                internalSnapshot = []
            }

            let externalDisplays: [ExternalDisplayReference]
            do {
                externalDisplays = try externalBrightness.discoverDisplays()
            } catch {
                snapshotErrors.append(error)
                externalDisplays = []
            }

            let externalSnapshot: [ExternalDisplaySnapshot]
            do {
                externalSnapshot = try externalBrightness.currentSnapshot(for: externalDisplays)
            } catch {
                snapshotErrors.append(error)
                externalSnapshot = []
            }

            let snapshot = BrightnessSnapshot(
                internalDisplays: internalSnapshot,
                externalDisplays: externalSnapshot
            )

            guard !snapshot.isEmpty else {
                statusMessage = "No displays available to dim"
                lastError = snapshotErrors.first.map {
                    ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription
                }
                return
            }

            try snapshotStore.save(snapshot)
            activeSnapshot = snapshot

            if applyHardware, !internalSnapshot.isEmpty {
                try internalBrightness.setBrightness(percent: settings.dimPercent)
            }

            if applyHardware, !externalDisplays.isEmpty {
                try? externalBrightness.setBrightness(percent: settings.dimPercent, for: externalDisplays)
            }

            isDimmed = true
            externalDisplayCount = externalDisplays.count
            statusMessage = "Dimmed to \(settings.dimPercent)%"
            lastError = nil
        } catch {
            report(error)
        }
    }

    public func restoreNow(reason: String = "manual", applyHardware: Bool = true) {
        guard let snapshot = activeSnapshot ?? (try? snapshotStore.load()) else {
            isDimmed = false
            return
        }

        restore(snapshot, reason: reason, applyHardware: applyHardware)
    }

    private func restore(_ snapshot: BrightnessSnapshot, reason: String, applyHardware: Bool = true) {
        guard !isBusy else {
            return
        }

        isBusy = true
        defer {
            isBusy = false
        }

        var errors: [Error] = []

        if applyHardware {
            do {
                try internalBrightness.restore(snapshot.internalDisplays)
            } catch {
                errors.append(error)
            }

            do {
                let settings = settingsProvider()
                let externalDisplays = snapshot.externalDisplays.map { externalSnapshot in
                    guard let savedPercent = settings.externalBrightnessByDisplay[
                        externalSnapshot.display.brightnessPreferenceKey
                    ] else {
                        return externalSnapshot
                    }

                    return ExternalDisplaySnapshot(
                        display: externalSnapshot.display,
                        luminance: savedPercent
                    )
                }

                try externalBrightness.restore(externalDisplays)
            } catch {
                errors.append(error)
            }
        }

        try? snapshotStore.clear()
        activeSnapshot = nil
        isDimmed = false

        if let firstError = errors.first {
            report(firstError)
            statusMessage = "Restored with warnings"
        } else {
            statusMessage = "Restored from \(reason)"
            lastError = nil
        }
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        statusMessage = "Needs attention"
    }
}
