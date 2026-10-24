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
    private let now: () -> Date
    private let diagnostics: DiagnosticLogger

    private var manualExternalLevels: [String: Int] = [:]

    public func recordManualExternalBrightness(_ percent: Int, for display: ExternalDisplayReference) {
        manualExternalLevels[display.recoveryKey] = min(100, max(0, percent))
        trace("manual.externalBaseline", ["display": DiagnosticLogger.encoded(display), "percent": percent])
    }

    public func lastKnownExternalBrightness(for display: ExternalDisplayReference) -> Int? {
        manualExternalLevels[display.recoveryKey]
    }

    private var activeSnapshot: BrightnessSnapshot?
    private var appliedDimSnapshot: BrightnessSnapshot?
    private var lastDimAttemptAt = Date.distantPast
    private var lastRestoreAttemptAt = Date.distantPast
    private var restoreRequested = false
    private var lastIdleLogAt = Date.distantPast

    public init(
        settingsProvider: @escaping () -> DimmerSettings,
        internalBrightness: InternalBrightnessManaging,
        externalBrightness: ExternalBrightnessManaging,
        snapshotStore: SnapshotPersisting,
        now: @escaping () -> Date = Date.init,
        diagnostics: DiagnosticLogger = .shared
    ) {
        self.settingsProvider = settingsProvider
        self.internalBrightness = internalBrightness
        self.externalBrightness = externalBrightness
        self.snapshotStore = snapshotStore
        self.now = now
        self.diagnostics = diagnostics

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
        trace("dimmer.initialized")
    }

    public func handleIdleTime(_ idleTime: TimeInterval, applyHardware: Bool = true) {
        let settings = settingsProvider()
        if now().timeIntervalSince(lastIdleLogAt) >= 10 || (idleTime < 1 && isDimmed && !restoreRequested) {
            lastIdleLogAt = now()
            trace("idle.observed", ["idleSeconds": idleTime, "settings": DiagnosticLogger.encoded(settings)])
        }

        if restoreRequested, now().timeIntervalSince(lastRestoreAttemptAt) >= 5 {
            restoreNow(reason: "retry", applyHardware: applyHardware)
            if !isDimmed { return }
        }

        guard settings.isEnabled else {
            if isDimmed {
                handleUserActivity(applyHardware: applyHardware)
            }
            return
        }

        if idleTime >= TimeInterval(settings.idleTimeoutSeconds), !isDimmed || restoreRequested {
            dimNow(applyHardware: applyHardware)
        } else if idleTime < 1, isDimmed {
            handleUserActivity(applyHardware: applyHardware)
        }
    }

    public func handleUserActivity(applyHardware: Bool = true) {
        guard isDimmed else {
            return
        }

        if !restoreRequested || now().timeIntervalSince(lastRestoreAttemptAt) >= 5 {
            restoreNow(reason: "activity", applyHardware: applyHardware)
        }
    }

    @discardableResult
    public func refreshExternalDisplays() -> [ExternalDisplayReference] {
        do {
            let displays = try externalBrightness.discoverDisplays()
            trace("displays.discovered", ["displays": DiagnosticLogger.encoded(displays)])
            let connected = Dictionary(grouping: displays, by: \.recoveryKey)
            manualExternalLevels = manualExternalLevels.filter {
                connected[$0.key]?.count == 1 || ($0.key.hasPrefix("uuid:") && connected[$0.key] == nil)
            }
            externalDisplayCount = displays.count
            if restoreRequested {
                restoreNow(reason: "display reconnect")
            } else if !isDimmed {
                statusMessage = displays.isEmpty
                    ? "No DDC external displays found"
                    : "Found \(displays.count) DDC display\(displays.count == 1 ? "" : "s")"
                lastError = nil
            }
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
        trace("status.changed", ["message": message, "error": error ?? ""])
    }

    public func restorePersistedSnapshotIfNeeded() {
        guard let snapshot = activeSnapshot else {
            return
        }

        restore(snapshot, reason: "saved snapshot")
    }

    public func hasPendingRestore(for display: ExternalDisplayReference) -> Bool {
        activeSnapshot?.externalDisplays.contains {
            display.matchesRecoveryIdentity(of: $0.display)
        } ?? false
    }

    public func hasPendingRestore(forInternalDisplayID displayID: UInt32) -> Bool {
        activeSnapshot?.internalDisplays.contains { $0.displayID == displayID } ?? false
    }

    public func dimNow(applyHardware: Bool = true) {
        guard !isBusy, !isDimmed || restoreRequested else {
            return
        }

        let attemptTime = now()
        guard attemptTime.timeIntervalSince(lastDimAttemptAt) > 2 else {
            return
        }
        lastDimAttemptAt = attemptTime

        let settings = settingsProvider()
        guard settings.isEnabled else {
            return
        }
        trace("dim.started", ["settings": DiagnosticLogger.encoded(settings), "applyHardware": applyHardware])

        isBusy = true
        defer {
            isBusy = false
        }

        do {
            var snapshotErrors: [Error] = []
            let pending = restoreRequested ? activeSnapshot : nil

            let internalSnapshot: [InternalDisplaySnapshot]
            do {
                internalSnapshot = try internalBrightness.currentSnapshot().filter { display in
                    !settings.excludedInternalDisplayIDs.contains(display.displayID)
                        && !(pending?.internalDisplays.contains(where: { $0.displayID == display.displayID }) ?? false)
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

            let discoveredByKey = Dictionary(grouping: externalDisplays, by: \.recoveryKey)
            manualExternalLevels = manualExternalLevels.filter {
                discoveredByKey[$0.key]?.count == 1 || ($0.key.hasPrefix("uuid:") && discoveredByKey[$0.key] == nil)
            }
            var externalSnapshot: [ExternalDisplaySnapshot] = []
            for display in externalDisplays {
                if pending?.externalDisplays.contains(where: { display.matchesRecoveryIdentity(of: $0.display) }) == true {
                    trace("dim.external.skipped", ["display": DiagnosticLogger.encoded(display), "reason": "pending restore retained"])
                    continue
                }
                let key = display.recoveryKey
                guard display.hasReliableIdentity, discoveredByKey[key]?.count == 1,
                      externalDisplays.filter({ $0.matchesRecoveryIdentity(of: display) }).count == 1 else {
                    trace("dim.external.skipped", ["display": DiagnosticLogger.encoded(display), "reason": "ambiguous identity"])
                    snapshotErrors.append(BrightnessError.readFailed("an external display with an ambiguous identity"))
                    continue
                }
                do {
                    let captured = try externalBrightness.currentSnapshot(for: [display])
                    guard captured.count == 1, let value = captured.first,
                          value.display.recoveryKey == key else {
                        throw BrightnessError.readFailed(display.name)
                    }
                    externalSnapshot.append(value)
                    trace("dim.external.captured", ["reading": DiagnosticLogger.encoded(value), "source": "live read"])
                    if manualExternalLevels[key] != nil { manualExternalLevels[key] = value.luminance }
                } catch {
                    if let level = manualExternalLevels[key] {
                        externalSnapshot.append(ExternalDisplaySnapshot(display: display, luminance: level))
                        trace("dim.external.captured", ["display": DiagnosticLogger.encoded(display), "percent": level,
                                                       "source": "manual fallback", "readError": error.localizedDescription])
                    } else {
                        trace("dim.external.skipped", ["display": DiagnosticLogger.encoded(display),
                                                     "reason": "no baseline", "error": error.localizedDescription])
                        snapshotErrors.append(error)
                    }
                }
            }

            guard !internalSnapshot.isEmpty || !externalSnapshot.isEmpty else {
                if pending != nil { return }
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

            var snapshot = BrightnessSnapshot(
                internalDisplays: (pending?.internalDisplays ?? []) + internalSnapshot,
                externalDisplays: (pending?.externalDisplays ?? []) + externalSnapshot,
                appliedInternalDisplays: applyHardware ? (pending?.appliedInternalDisplays ?? []) + internalDimSnapshot : nil,
                appliedExternalDisplays: applyHardware ? pending?.appliedExternalDisplays ?? [] : nil
            )
            trace("dim.snapshotPrepared", ["snapshot": DiagnosticLogger.encoded(snapshot),
                                           "externalTargets": DiagnosticLogger.encoded(externalDimSnapshot)])
            try snapshotStore.save(snapshot)
            activeSnapshot = snapshot

            var writeErrors: [Error] = []
            if applyHardware, !internalDimSnapshot.isEmpty {
                do {
                    try internalBrightness.restore(internalDimSnapshot)
                    trace("dim.internal.sent", ["targets": DiagnosticLogger.encoded(internalDimSnapshot)])
                } catch {
                    writeErrors.append(error)
                }
            }

            if applyHardware {
                for target in externalDimSnapshot {
                    do {
                        try externalBrightness.restore([target])
                        trace("dim.external.sent", ["target": DiagnosticLogger.encoded(target)])
                        do {
                            let readings = try externalBrightness.currentSnapshot(for: [target.display])
                            let accepted = readings.count == 1 && readings.first?.display.recoveryKey == target.display.recoveryKey
                                && (readings.first?.luminance ?? 101) <= target.luminance
                            trace("dim.external.readback", ["target": DiagnosticLogger.encoded(target),
                                                            "readings": DiagnosticLogger.encoded(readings), "accepted": accepted])
                            if accepted, let reading = readings.first {
                                snapshot.appliedExternalDisplays?.append(reading)
                            }
                        } catch {
                            trace("dim.external.readbackFailed", ["target": DiagnosticLogger.encoded(target), "error": error.localizedDescription])
                        }
                    } catch {
                        trace("dim.external.writeFailed", ["target": DiagnosticLogger.encoded(target), "error": error.localizedDescription])
                        writeErrors.append(error)
                    }
                }
            }

            appliedDimSnapshot = applyHardware
                ? BrightnessSnapshot(
                    internalDisplays: snapshot.appliedInternalDisplays ?? [],
                    externalDisplays: snapshot.appliedExternalDisplays ?? []
                )
                : nil
            activeSnapshot = snapshot
            isDimmed = true
            restoreRequested = false
            do {
                try snapshotStore.save(snapshot)
            } catch {
                writeErrors.append(error)
            }
            externalDisplayCount = externalDisplays.count
            let errors = snapshotErrors + writeErrors
            if let firstError = errors.first {
                report(firstError)
                statusMessage = "Dimmed with warnings"
            } else {
                statusMessage = "Dimmed"
                lastError = nil
            }
            trace("dim.finished", ["status": statusMessage])
        } catch {
            report(error)
        }
    }

    public func restoreNow(reason: String = "manual", applyHardware: Bool = true) {
        trace("restore.requested", ["reason": reason, "applyHardware": applyHardware])
        guard let snapshot = activeSnapshot ?? (try? snapshotStore.load()) else {
            isDimmed = false
            trace("restore.noSnapshot", ["reason": reason])
            return
        }

        restore(snapshot, reason: reason, applyHardware: applyHardware)
    }

    private func restore(_ snapshot: BrightnessSnapshot, reason: String, applyHardware: Bool = true) {
        guard !isBusy else {
            return
        }

        isBusy = true
        restoreRequested = true
        lastRestoreAttemptAt = now()
        trace("restore.started", ["reason": reason])
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
                    trace("restore.internal.sent", ["target": DiagnosticLogger.encoded(internalSnapshot)])
                } catch {
                    errors.append(error)
                    failedInternal.append(internalSnapshot)
                }
            }

            for externalSnapshot in snapshotsToRestore.externalDisplays {
                do {
                    try externalBrightness.restore([externalSnapshot])
                    manualExternalLevels[externalSnapshot.display.recoveryKey] = externalSnapshot.luminance
                    trace("restore.external.sent", ["target": DiagnosticLogger.encoded(externalSnapshot)])
                } catch {
                    trace("restore.external.writeFailed", ["target": DiagnosticLogger.encoded(externalSnapshot), "error": error.localizedDescription])
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
                        $0.display.matchesRecoveryIdentity(of: applied.display)
                    }
                },
                createdAt: snapshot.createdAt,
                appVersion: snapshot.appVersion
            )
            if !remaining.isEmpty {
                activeSnapshot = remaining
                do {
                    try snapshotStore.save(remaining)
                } catch {
                    report(error)
                    statusMessage = "Restore pending; snapshot update failed"
                    return
                }
            }
            report(firstError)
            statusMessage = "Restore failed; will retry"
            trace("restore.pending", ["error": firstError.localizedDescription])
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
            restoreRequested = false
            statusMessage = "Restored from \(reason)"
            lastError = nil
            trace("restore.finished", ["reason": reason])
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
        let savedByKey = Dictionary(grouping: snapshots) {
            $0.display.recoveryKey
        }

        var resolved: [ExternalDisplaySnapshot] = []
        var pending: [ExternalDisplaySnapshot] = []
        var errors: [Error] = []
        for saved in snapshots {
            let key = saved.display.recoveryKey
            let matches = connected.filter { $0.matchesRecoveryIdentity(of: saved.display) }
            trace("restore.external.identity", ["saved": DiagnosticLogger.encoded(saved),
                                                "matches": DiagnosticLogger.encoded(matches),
                                                "savedIdentityCount": savedByKey[key]?.count ?? 0])
            guard savedByKey[key]?.count == 1,
                  matches.count == 1,
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
        trace("restore.internal.comparison", ["original": DiagnosticLogger.encoded(original.internalDisplays),
                                              "current": DiagnosticLogger.encoded(currentInternalByID),
                                              "selected": DiagnosticLogger.encoded(internalDisplays)])

        let originalExternalDisplays = original.externalDisplays.map(\.display)
        let currentExternal = try? externalBrightness.currentSnapshot(for: originalExternalDisplays)
        let currentExternalByID = (currentExternal ?? []).reduce(into: [String: Int]()) {
            $0[$1.display.recoveryKey] = $1.luminance
        }
        let externalDisplays = original.externalDisplays.filter { display in
            let key = display.display.recoveryKey
            let appliedMatches = appliedDimSnapshot.externalDisplays.filter {
                display.display.matchesRecoveryIdentity(of: $0.display)
            }
            guard appliedMatches.count == 1, let applied = appliedMatches.first?.luminance,
                  let current = currentExternalByID[key] else {
                trace("restore.external.decision", ["original": DiagnosticLogger.encoded(display),
                    "appliedMatches": DiagnosticLogger.encoded(appliedMatches), "current": currentExternalByID[key] as Any? ?? NSNull(),
                    "decision": "restore", "reason": "unverified current or applied level"])
                return true
            }
            if current != applied { manualExternalLevels[key] = current }
            trace("restore.external.decision", ["original": DiagnosticLogger.encoded(display),
                "applied": applied, "current": current, "decision": current == applied ? "restore" : "preserve changed reading"])
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
        trace("error", ["message": message])
    }

    private func trace(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["isDimmed"] = isDimmed
        entry["restoreRequested"] = restoreRequested
        entry["activeSnapshot"] = activeSnapshot.map { DiagnosticLogger.encoded($0) } ?? NSNull()
        entry["appliedDimSnapshot"] = appliedDimSnapshot.map { DiagnosticLogger.encoded($0) } ?? NSNull()
        entry["manualExternalLevels"] = manualExternalLevels
        diagnostics.record(event, entry)
    }
}
