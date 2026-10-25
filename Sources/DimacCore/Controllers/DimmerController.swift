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
    private let levelStore: ExternalLevelPersisting?
    private let scheduler: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let recoveryDelays: [TimeInterval]

    /// The user's normal (undimmed) brightness per display. UUID-keyed values are persisted so they
    /// survive reconnects and restarts; hardware readings never replace them while a display is recovering.
    private var manualExternalLevels: [String: Int] = [:] {
        didSet {
            guard let levelStore else { return }
            let persisted = manualExternalLevels.filter { $0.key.hasPrefix("uuid:") }
            if persisted != oldValue.filter({ $0.key.hasPrefix("uuid:") }) {
                levelStore.saveLevels(persisted)
            }
        }
    }

    /// Recovery keys seen by the last discovery; `nil` until the first discovery after launch.
    private var knownExternalKeys: Set<String>?
    /// Until these dates, hardware readings for a display are treated as untrustworthy (reconnect/wake).
    private var untrustedReadingsUntil: [String: Date] = [:]
    /// Displays whose readback disagreed with the level just written; their readings are ignored as baselines.
    private var unreliableReadbackKeys: Set<String> = []
    /// Displays that reconnected or woke while dimmed; they must receive the saved level on restore.
    private var reconnectedWhileDimmed: Set<String> = []
    private var recoveryGeneration = 0

    nonisolated public static let externalRecoveryDelays: [TimeInterval] = [2, 5, 10, 20, 40]
    private static let untrustedReadingWindow: TimeInterval = 120
    private static let recoveryRestoreReasons: Set<String> = ["wake", "display reconnect", "retry", "saved snapshot"]

    nonisolated public static func mainQueueScheduler(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in work() }
        }
    }

    public func recordManualExternalBrightness(_ percent: Int, for display: ExternalDisplayReference) {
        manualExternalLevels[display.recoveryKey] = min(100, max(0, percent))
        untrustedReadingsUntil[display.recoveryKey] = nil
        trace("manual.externalBaseline", ["display": DiagnosticLogger.encoded(display), "percent": percent])
    }

    /// Lets the UI report a live reading. It only becomes the saved level when it is trustworthy.
    public func observeExternalBrightnessReading(_ percent: Int, for display: ExternalDisplayReference) {
        let key = display.recoveryKey
        guard !isDimmed, !restoreRequested, display.hasReliableIdentity,
              isTrustedReading(percent, for: key), manualExternalLevels[key] != percent else {
            return
        }
        manualExternalLevels[key] = percent
        trace("observed.externalBaseline", ["display": DiagnosticLogger.encoded(display), "percent": percent])
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
        diagnostics: DiagnosticLogger = .shared,
        levelStore: ExternalLevelPersisting? = nil,
        recoveryDelays: [TimeInterval] = DimmerController.externalRecoveryDelays,
        scheduler: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = DimmerController.mainQueueScheduler
    ) {
        self.settingsProvider = settingsProvider
        self.internalBrightness = internalBrightness
        self.externalBrightness = externalBrightness
        self.snapshotStore = snapshotStore
        self.now = now
        self.diagnostics = diagnostics
        self.levelStore = levelStore
        self.recoveryDelays = recoveryDelays
        self.scheduler = scheduler
        manualExternalLevels = (levelStore?.loadLevels() ?? [:]).filter { $0.key.hasPrefix("uuid:") }

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
            let appeared = displays.filter { !(knownExternalKeys?.contains($0.recoveryKey) ?? false) }
            if !appeared.isEmpty {
                trace("displays.appeared", ["displays": DiagnosticLogger.encoded(appeared),
                                            "firstDiscovery": knownExternalKeys == nil])
                distrustReadings(for: appeared)
            }
            knownExternalKeys = Set(displays.map(\.recoveryKey))
            defer {
                if !appeared.isEmpty {
                    scheduleExternalBrightnessRecovery(reason: "display appeared", displays: appeared)
                }
            }
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
                    if let level = manualExternalLevels[key], !canTrustReadings(for: key) {
                        externalSnapshot.append(ExternalDisplaySnapshot(display: display, luminance: level))
                        trace("dim.external.captured", ["display": DiagnosticLogger.encoded(display), "percent": level,
                                                       "source": "saved level", "reason": "display readings untrusted"])
                        continue
                    }
                    let captured = try externalBrightness.currentSnapshot(for: [display])
                    guard captured.count == 1, let value = captured.first,
                          value.display.recoveryKey == key else {
                        throw BrightnessError.readFailed(display.name)
                    }
                    guard isTrustedReading(value.luminance, for: key) else {
                        trace("dim.external.readingRejected", ["reading": DiagnosticLogger.encoded(value),
                                                              "reason": "implausible or untrusted reading"])
                        if let level = manualExternalLevels[key] {
                            externalSnapshot.append(ExternalDisplaySnapshot(display: display, luminance: level))
                            trace("dim.external.captured", ["display": DiagnosticLogger.encoded(display), "percent": level,
                                                           "source": "saved level", "reason": "live reading rejected"])
                        } else {
                            trace("dim.external.skipped", ["display": DiagnosticLogger.encoded(display),
                                                         "reason": "no baseline; reading is not a usable brightness"])
                        }
                        continue
                    }
                    externalSnapshot.append(value)
                    trace("dim.external.captured", ["reading": DiagnosticLogger.encoded(value), "source": "live read"])
                    manualExternalLevels[key] = value.luminance
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
        var restoredExternal: [ExternalDisplayReference] = []

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

            for original in snapshotsToRestore.externalDisplays {
                var externalSnapshot = original
                let key = original.display.recoveryKey
                if original.luminance == 0, let saved = manualExternalLevels[key], saved > 0 {
                    externalSnapshot.luminance = saved
                    trace("restore.external.substituted", ["original": DiagnosticLogger.encoded(original), "saved": saved,
                                                          "reason": "captured baseline was an implausible zero reading"])
                }
                do {
                    try externalBrightness.restore([externalSnapshot])
                    if externalSnapshot.luminance > 0 { manualExternalLevels[key] = externalSnapshot.luminance }
                    restoredExternal.append(externalSnapshot.display)
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

        // A display that just reconnected or woke may accept the DDC write before it is ready and keep
        // its power-on brightness, so re-send and verify the saved level a few times.
        let needsVerification = restoredExternal.filter {
            Self.recoveryRestoreReasons.contains(reason) || reconnectedWhileDimmed.contains($0.recoveryKey)
        }
        if !isDimmed, !needsVerification.isEmpty {
            reconnectedWhileDimmed.removeAll()
            scheduleExternalBrightnessRecovery(reason: "after \(reason) restore", displays: needsVerification)
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
            if reconnectedWhileDimmed.contains(key) || !canTrustReadings(for: key) {
                trace("restore.external.decision", ["original": DiagnosticLogger.encoded(display),
                    "current": currentExternalByID[key] as Any? ?? NSNull(), "decision": "restore",
                    "reason": "display reconnected or woke while dimmed; its reading is not a user change"])
                return true
            }
            guard appliedMatches.count == 1, let applied = appliedMatches.first?.luminance,
                  let current = currentExternalByID[key] else {
                trace("restore.external.decision", ["original": DiagnosticLogger.encoded(display),
                    "appliedMatches": DiagnosticLogger.encoded(appliedMatches), "current": currentExternalByID[key] as Any? ?? NSNull(),
                    "decision": "restore", "reason": "unverified current or applied level"])
                return true
            }
            if current != applied, current == 0 {
                trace("restore.external.decision", ["original": DiagnosticLogger.encoded(display),
                    "applied": applied, "current": current, "decision": "restore", "reason": "implausible zero reading"])
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

    /// Re-sends the saved normal brightness to external displays after a reconnect or wake, then reads it
    /// back. Monitors often accept DDC writes before they are ready, or power on at a default level, so
    /// attempts are repeated with increasing delays until the readback matches or the attempts run out.
    public func scheduleExternalBrightnessRecovery(reason: String, displays: [ExternalDisplayReference]? = nil) {
        let candidates = displays ?? ((try? externalBrightness.discoverDisplays()) ?? [])
        distrustReadings(for: candidates)
        if isDimmed {
            reconnectedWhileDimmed.formUnion(candidates.map(\.recoveryKey))
            trace("recovery.deferred", ["reason": reason, "displays": DiagnosticLogger.encoded(candidates),
                                        "detail": "dimmed; the saved level is sent on restore"])
            return
        }
        let keys = Set(candidates.filter { manualExternalLevels[$0.recoveryKey] != nil }.map(\.recoveryKey))
        guard !keys.isEmpty, !recoveryDelays.isEmpty else {
            trace("recovery.skipped", ["reason": reason, "displays": DiagnosticLogger.encoded(candidates),
                                       "detail": "no saved level for these displays"])
            return
        }
        recoveryGeneration += 1
        trace("recovery.scheduled", ["reason": reason, "keys": keys.sorted(), "delays": recoveryDelays,
                                     "generation": recoveryGeneration])
        scheduleRecoveryAttempt(0, keys: keys, generation: recoveryGeneration, reason: reason)
    }

    private func scheduleRecoveryAttempt(_ attempt: Int, keys: Set<String>, generation: Int, reason: String) {
        scheduler(recoveryDelays[attempt]) { [weak self] in
            self?.runRecoveryAttempt(attempt, keys: keys, generation: generation, reason: reason)
        }
    }

    private func runRecoveryAttempt(_ attempt: Int, keys: Set<String>, generation: Int, reason: String) {
        guard generation == recoveryGeneration else { return }
        guard !isDimmed else {
            reconnectedWhileDimmed.formUnion(keys)
            trace("recovery.deferred", ["reason": reason, "attempt": attempt + 1, "keys": keys.sorted(),
                                        "detail": "dimmed before recovery finished"])
            return
        }
        if isBusy {
            if attempt + 1 < recoveryDelays.count {
                scheduleRecoveryAttempt(attempt + 1, keys: keys, generation: generation, reason: reason)
            }
            return
        }

        let connected = (try? externalBrightness.discoverDisplays()) ?? []
        var pending = Set<String>()
        for key in keys.sorted() {
            let matches = connected.filter { $0.recoveryKey == key }
            guard let level = manualExternalLevels[key] else { continue }
            guard matches.count == 1, let display = matches.first else {
                pending.insert(key)
                trace("recovery.attempt", ["reason": reason, "attempt": attempt + 1, "key": key,
                                           "result": "display not connected"])
                continue
            }
            let target = ExternalDisplaySnapshot(display: display, luminance: level)
            do {
                try externalBrightness.restore([target])
            } catch {
                pending.insert(key)
                trace("recovery.attempt", ["reason": reason, "attempt": attempt + 1, "target": DiagnosticLogger.encoded(target),
                                           "result": "write failed", "error": error.localizedDescription])
                continue
            }
            let readback = (try? externalBrightness.currentSnapshot(for: [display]))?.first { $0.display.recoveryKey == key }
            if let readback, readback.luminance == level {
                unreliableReadbackKeys.remove(key)
                untrustedReadingsUntil[key] = nil
                trace("recovery.attempt", ["reason": reason, "attempt": attempt + 1, "target": DiagnosticLogger.encoded(target),
                                           "readback": readback.luminance, "result": "verified"])
            } else {
                if readback != nil { unreliableReadbackKeys.insert(key) }
                pending.insert(key)
                trace("recovery.attempt", ["reason": reason, "attempt": attempt + 1, "target": DiagnosticLogger.encoded(target),
                                           "readback": readback.map { $0.luminance as Any } ?? NSNull(),
                                           "result": readback == nil ? "sent; readback unavailable" : "sent; readback mismatch"])
            }
        }

        if !pending.isEmpty, attempt + 1 < recoveryDelays.count {
            scheduleRecoveryAttempt(attempt + 1, keys: pending, generation: generation, reason: reason)
        } else {
            trace("recovery.finished", ["reason": reason, "attempts": attempt + 1, "unverified": pending.sorted()])
        }
    }

    private func distrustReadings(for displays: [ExternalDisplayReference]) {
        let until = now().addingTimeInterval(Self.untrustedReadingWindow)
        for display in displays {
            untrustedReadingsUntil[display.recoveryKey] = until
        }
    }

    private func canTrustReadings(for key: String) -> Bool {
        !unreliableReadbackKeys.contains(key) && (untrustedReadingsUntil[key] ?? .distantPast) <= now()
    }

    /// Zero is what m1ddc reports for displays that do not really answer DDC (seen right after a monitor
    /// wakes and for the built-in panel), so it is never accepted as a normal level. Other readings are
    /// rejected while the display is recovering, but only when a saved level exists to use instead.
    private func isTrustedReading(_ percent: Int, for key: String) -> Bool {
        percent > 0 && (canTrustReadings(for: key) || manualExternalLevels[key] == nil)
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
