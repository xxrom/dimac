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
    private var appliedDimSnapshot: BrightnessSnapshot?
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
            if snapshot.appliedInternalDisplays != nil || snapshot.appliedExternalDisplays != nil {
                appliedDimSnapshot = BrightnessSnapshot(
                    internalDisplays: snapshot.appliedInternalDisplays ?? [],
                    externalDisplays: snapshot.appliedExternalDisplays ?? []
                )
            }
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
        guard !isBusy, !isDimmed else {
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
                internalSnapshot = try internalBrightness.currentSnapshot().filter {
                    !settings.excludedInternalDisplayIDs.contains($0.displayID)
                }
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
                let captured = try externalBrightness.currentSnapshot(for: externalDisplays)
                let capturedByKey = Dictionary(grouping: captured) {
                    $0.display.brightnessPreferenceKey
                }
                let discoveredByKey = Dictionary(grouping: externalDisplays, by: \.brightnessPreferenceKey)
                externalSnapshot = captured.filter { snapshot in
                    let key = snapshot.display.brightnessPreferenceKey
                    return capturedByKey[key]?.count == 1
                        && discoveredByKey[key]?.count == 1
                        && key.hasPrefix("name:")
                }
                if externalSnapshot.count != captured.count {
                    snapshotErrors.append(
                        BrightnessError.readFailed("an external display with an ambiguous identity")
                    )
                }
            } catch {
                snapshotErrors.append(error)
                externalSnapshot = []
            }

            guard !internalSnapshot.isEmpty || !externalSnapshot.isEmpty else {
                statusMessage = "No displays available to dim"
                lastError = snapshotErrors.first.map {
                    ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription
                }
                return
            }

            let internalDimSnapshot = internalSnapshot.map { display in
                let percent = settings.internalDimPercentByDisplay[display.displayID] ?? settings.dimPercent
                return InternalDisplaySnapshot(
                    displayID: display.displayID,
                    brightness: min(display.brightness, Float(percent) / 100)
                )
            }

            let externalDimSnapshot = externalSnapshot.map { display in
                let percent = settings.externalDimPercentByDisplay[
                    display.display.brightnessPreferenceKey
                ] ?? settings.dimPercent
                return ExternalDisplaySnapshot(
                    display: display.display,
                    luminance: min(display.luminance, percent)
                )
            }

            let snapshot = BrightnessSnapshot(
                internalDisplays: internalSnapshot,
                externalDisplays: externalSnapshot,
                appliedInternalDisplays: applyHardware ? internalDimSnapshot : nil,
                appliedExternalDisplays: applyHardware ? externalDimSnapshot : nil
            )
            try snapshotStore.save(snapshot)
            activeSnapshot = snapshot

            var writeErrors: [Error] = []
            if applyHardware, !internalDimSnapshot.isEmpty {
                do {
                    try internalBrightness.restore(internalDimSnapshot)
                } catch {
                    writeErrors.append(error)
                }
            }

            if applyHardware, !externalDimSnapshot.isEmpty {
                do {
                    try externalBrightness.restore(externalDimSnapshot)
                } catch {
                    writeErrors.append(error)
                }
            }

            appliedDimSnapshot = applyHardware
                ? BrightnessSnapshot(
                    internalDisplays: internalDimSnapshot,
                    externalDisplays: externalDimSnapshot
                )
                : nil
            isDimmed = true
            externalDisplayCount = externalDisplays.count
            let errors = snapshotErrors + writeErrors
            if let firstError = errors.first {
                report(firstError)
                statusMessage = "Dimmed with warnings"
            } else {
                statusMessage = "Dimmed"
                lastError = nil
            }
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
        var failedInternal: [InternalDisplaySnapshot] = []
        var failedExternal: [ExternalDisplaySnapshot] = []

        if applyHardware {
            let resolution = externalSnapshotsResolvedAgainstConnectedDisplays(
                snapshot.externalDisplays
            )
            errors.append(contentsOf: resolution.errors)
            failedExternal = resolution.pending
            let resolvedSnapshot = BrightnessSnapshot(
                internalDisplays: snapshot.internalDisplays,
                externalDisplays: resolution.resolved
            )
            let snapshotsToRestore = snapshotsUnchangedSinceDim(in: resolvedSnapshot)
            for internalSnapshot in snapshotsToRestore.internalDisplays {
                do {
                    try internalBrightness.restore([internalSnapshot])
                } catch {
                    errors.append(error)
                    failedInternal.append(internalSnapshot)
                }
            }

            for externalSnapshot in snapshotsToRestore.externalDisplays {
                do {
                    try externalBrightness.restore([externalSnapshot])
                } catch {
                    errors.append(error)
                    failedExternal.append(externalSnapshot)
                }
            }
        }

        if let firstError = errors.first {
            let remaining = BrightnessSnapshot(
                internalDisplays: failedInternal,
                externalDisplays: failedExternal,
                appliedInternalDisplays: appliedDimSnapshot?.internalDisplays.filter { applied in
                    failedInternal.contains { $0.displayID == applied.displayID }
                },
                appliedExternalDisplays: appliedDimSnapshot?.externalDisplays.filter { applied in
                    failedExternal.contains {
                        $0.display.brightnessPreferenceKey == applied.display.brightnessPreferenceKey
                    }
                },
                createdAt: snapshot.createdAt,
                appVersion: snapshot.appVersion
            )
            if !remaining.isEmpty {
                activeSnapshot = remaining
                try? snapshotStore.save(remaining)
            }
            report(firstError)
            statusMessage = "Restore failed; will retry"
        } else {
            do {
                try snapshotStore.clear()
            } catch {
                report(error)
                statusMessage = "Restored, but snapshot cleanup failed"
                return
            }
            activeSnapshot = nil
            appliedDimSnapshot = nil
            isDimmed = false
            statusMessage = "Restored from \(reason)"
            lastError = nil
        }
    }

    private func externalSnapshotsResolvedAgainstConnectedDisplays(
        _ snapshots: [ExternalDisplaySnapshot]
    ) -> (
        resolved: [ExternalDisplaySnapshot],
        pending: [ExternalDisplaySnapshot],
        errors: [Error]
    ) {
        guard !snapshots.isEmpty else {
            return ([], [], [])
        }

        let connected: [ExternalDisplayReference]
        do {
            connected = try externalBrightness.discoverDisplays()
        } catch {
            return ([], snapshots, [error])
        }
        let connectedByKey = Dictionary(grouping: connected, by: \.brightnessPreferenceKey)
        let savedByKey = Dictionary(grouping: snapshots) {
            $0.display.brightnessPreferenceKey
        }

        var resolved: [ExternalDisplaySnapshot] = []
        var pending: [ExternalDisplaySnapshot] = []
        var errors: [Error] = []
        for saved in snapshots {
            let key = saved.display.brightnessPreferenceKey
            guard savedByKey[key]?.count == 1,
                  let matches = connectedByKey[key], matches.count == 1,
                  let connectedDisplay = matches.first else {
                pending.append(saved)
                errors.append(BrightnessError.readFailed("saved external display \(saved.display.name)"))
                continue
            }
            resolved.append(ExternalDisplaySnapshot(display: connectedDisplay, luminance: saved.luminance))
        }
        return (resolved, pending, errors)
    }

    private func snapshotsUnchangedSinceDim(in original: BrightnessSnapshot) -> BrightnessSnapshot {
        guard let appliedDimSnapshot else {
            return original
        }

        var currentInternalByID: [UInt32: Float] = [:]
        if let current = try? internalBrightness.currentSnapshot() {
            currentInternalByID = Dictionary(
                uniqueKeysWithValues: current.map { ($0.displayID, $0.brightness) }
            )
        }
        let appliedInternalByID = Dictionary(
            uniqueKeysWithValues: appliedDimSnapshot.internalDisplays.map { ($0.displayID, $0.brightness) }
        )
        let internalDisplays = original.internalDisplays.filter { display in
            guard let applied = appliedInternalByID[display.displayID],
                  let current = currentInternalByID[display.displayID] else {
                return true
            }
            return abs(current - applied) < 0.005
        }

        let originalExternalDisplays = original.externalDisplays.map(\.display)
        let currentExternal = try? externalBrightness.currentSnapshot(for: originalExternalDisplays)
        let currentExternalByID = (currentExternal ?? []).reduce(into: [String: Int]()) {
            $0[$1.display.brightnessPreferenceKey] = $1.luminance
        }
        let appliedExternalByID = appliedDimSnapshot.externalDisplays.reduce(
            into: [String: Int]()
        ) {
            $0[$1.display.brightnessPreferenceKey] = $1.luminance
        }
        let externalDisplays = original.externalDisplays.filter { display in
            let key = display.display.brightnessPreferenceKey
            guard let applied = appliedExternalByID[key],
                  let current = currentExternalByID[key] else {
                return true
            }
            return current == applied
        }

        return BrightnessSnapshot(
            internalDisplays: internalDisplays,
            externalDisplays: externalDisplays,
            createdAt: original.createdAt,
            appVersion: original.appVersion
        )
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        statusMessage = "Needs attention"
    }
}
