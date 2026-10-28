import AppKit
import Combine
import CoreGraphics
import DimacCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore

    @Published private(set) var legacyAgentDetected = LegacyAgentDetector.isDetected
    @Published private(set) var loginItemStatus = LoginItemController.statusDescription
    @Published private(set) var idleTimeText = "0s"
    @Published private(set) var connectedExternalDisplayRows: [ConnectedDisplayRow] = []
    @Published private(set) var displayControlRows: [DisplayControlRow] = []
    @Published private(set) var ddcDisplayCount = 0

    private let idleReader = IOKitIdleTimeReader()
    private let externalBrightness: ExternalBrightnessManaging
    private let displayDiscovery: ConnectedDisplayDiscovery
    private let displayProvider: (() -> [ConnectedDisplayRow])?
    private let diagnostics: DiagnosticLogger
    private lazy var internalBrightness = makeInternalBrightnessController()
    private lazy var brightnessControls: CurrentBrightnessManaging = CurrentBrightnessController(
        internalBrightness: internalBrightness, externalBrightness: externalBrightness
    )
    lazy var dimmer: DimmerController = makeDimmer()
    private lazy var statusItemController = StatusItemController(model: self)
    private lazy var settingsWindowController = SettingsWindowController(model: self)
    private var inputWakeMonitor: InputWakeMonitor?
    private var idleTimer: Timer?
    private var visibleSettingsViews = 0
    private static let maximumIdleCheckInterval: TimeInterval = 60
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore? = nil,
        dimmer: DimmerController? = nil,
        startAutomatically: Bool = true,
        brightnessControls: CurrentBrightnessManaging? = nil,
        displayProvider: (() -> [ConnectedDisplayRow])? = nil,
        diagnostics: DiagnosticLogger = .shared
    ) {
        self.displayProvider = displayProvider
        self.diagnostics = diagnostics
        let settings = settings ?? SettingsStore()
        self.settings = settings

        let externalController = M1DDCBrightnessController(
            executablePathProvider: { settings.m1ddcPath }
        )
        self.externalBrightness = externalController
        self.displayDiscovery = ConnectedDisplayDiscovery(
            brightnessPathProvider: { settings.brightnessPath }
        )

        if let dimmer {
            self.dimmer = dimmer
        }
        if let brightnessControls {
            self.brightnessControls = brightnessControls
        }
        if startAutomatically {
            diagnostics.isEnabled = settings.diagnosticLoggingEnabled
            diagnostics.record("app.started", [
                "executable": Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "unknown",
                "bundle": Bundle.main.bundlePath,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "diagnosticBuild": Bundle.main.object(forInfoDictionaryKey: "DimacDiagnosticBuild") as? String ?? "unlabelled",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "brightnessPath": settings.brightnessPath, "m1ddcPath": settings.m1ddcPath,
                "logPath": diagnostics.fileURL.path,
                "runningInstances": NSRunningApplication.runningApplications(withBundleIdentifier: "com.dimac.app").map {
                    ["pid": $0.processIdentifier, "executable": $0.executableURL?.path ?? "unknown"] as [String: Any]
                }
            ])
            AppRuntime.model = self
            setUp()
        }
    }

    private func setUp() {
        NSApp.setActivationPolicy(.accessory)
        loginItemStatus = LoginItemController.statusDescription
        settings.launchAtLogin = LoginItemController.isEnabled

        statusItemController.setVisible(!settings.hideMenuBarIcon)
        startIdleTimer()
        startInputWakeMonitor()
        observeSystemNotifications()

        dimmer.restorePersistedSnapshotIfNeeded()
        refreshExternalDisplays()
    }

    func dimNow() {
        dimmer.dimNow()
    }

    func restoreNow() {
        dimmer.restoreNow(reason: "manual")
    }

    /// - Parameter recoveryReason: set for system display events (reconnect, wake) so the saved normal
    ///   brightness is re-sent once the monitor is ready; `nil` for plain UI refreshes.
    func refreshExternalDisplays(recoveryReason: String? = nil) {
        diagnostics.record("app.displays.refreshStarted", ["recoveryReason": recoveryReason as Any? ?? NSNull()])
        let connectedDisplays = displayProvider?() ?? displayDiscovery.displays()
        connectedExternalDisplayRows = connectedDisplays.filter(\.isExternal)
        let ddcDisplays = dimmer.refreshExternalDisplays()
        if let recoveryReason, !ddcDisplays.isEmpty {
            dimmer.scheduleExternalBrightnessRecovery(reason: recoveryReason, displays: ddcDisplays)
        }

        syncDisplayControlRows(
            from: connectedDisplays,
            ddcDisplays: ddcDisplays
        )
        refreshCurrentBrightness()
        ddcDisplayCount = matchedExternalDDCDisplayCount(in: displayControlRows)

        if !(dimmer.isDimmed && dimmer.lastError != nil), let status = Self.externalDisplayStatus(
            connectedCount: connectedExternalDisplayRows.count,
            ddcCount: ddcDisplayCount
        ) {
            dimmer.setStatus(status)
        }
        diagnostics.record("app.displays.refreshed", ["rows": diagnosticRows])
    }

    var externalDisplaySummary: String {
        let connected = connectedExternalDisplayRows.count
        let ddc = ddcDisplayCount

        if connected == 0 {
            return "\(max(0, dimmer.externalDisplayCount))"
        }

        if ddc == 0 {
            return "\(connected), no DDC"
        }

        if ddc == connected {
            return "\(connected)"
        }

        return "\(connected), \(ddc) DDC"
    }

    func setDimPercent(_ percent: Int) {
        diagnostics.record("settings.allDimChanged", ["percent": percent])
        settings.setDimPercent(percent)
        for index in displayControlRows.indices {
            displayControlRows[index].dimPercent = settings.dimPercent
        }
    }

    func setDisplayDimPercent(_ percent: Int, for rowID: String) {
        diagnostics.record("settings.displayDimChanged", ["rowID": rowID, "percent": percent])
        guard let rowIndex = displayControlRows.firstIndex(where: { $0.id == rowID }) else {
            return
        }
        let row = displayControlRows[rowIndex]
        let preference = settings.setDisplayDimPercent(
            percent, key: row.preferenceKey, displayName: row.name
        )
        displayControlRows[rowIndex].dimPercent = preference.dimPercent
    }

    func refreshCurrentBrightness() {
        for index in displayControlRows.indices {
            let row = displayControlRows[index]
            if case .ddc(let display) = row.mode {
                displayControlRows[index].requestedPercent = dimmer.lastKnownExternalBrightness(for: display)
            }
            do {
                let current = row.isControllable ? try brightnessControls.read(row) : nil
                displayControlRows[index].currentPercent = current
                if case .ddc(let display) = row.mode, let current {
                    dimmer.observeExternalBrightnessReading(current, for: display)
                    displayControlRows[index].requestedPercent = dimmer.lastKnownExternalBrightness(for: display)
                }
            } catch {
                displayControlRows[index].currentPercent = nil
                diagnostics.record("ui.currentReadFailed", ["rowID": row.id, "error": error.localizedDescription])
            }
        }
        diagnostics.record("ui.brightnessRefreshed", ["rows": diagnosticRows])
    }

    func setCurrentBrightness(_ percent: Int, for rowID: String) {
        guard let index = displayControlRows.firstIndex(where: { $0.id == rowID }),
              displayControlRows[index].isControllable else { return }
        let row = displayControlRows[index]
        diagnostics.record("ui.brightnessRequested", ["rowID": rowID, "requested": percent, "rowsBefore": diagnosticRows])
        if dimmer.isDimmed {
            dimmer.restoreNow(reason: "brightness adjustment")
            let hasPendingRestore: Bool
            switch row.mode {
            case .ddc(let display):
                hasPendingRestore = dimmer.hasPendingRestore(for: display)
            case .brightnessCLI:
                let displayID = UInt32(row.preferenceKey.replacingOccurrences(of: "display:", with: ""))
                hasPendingRestore = displayID.map { dimmer.hasPendingRestore(forInternalDisplayID: $0) } ?? dimmer.isDimmed
            case .unsupported:
                return
            }
            guard !hasPendingRestore else {
                diagnostics.record("ui.brightnessBlocked", ["rowID": rowID, "reason": "selected display restore pending"])
                refreshCurrentBrightness()
                return
            }
        }
        do {
            try brightnessControls.set(percent, for: row)
            displayControlRows[index].requestedPercent = min(100, max(0, percent))
            displayControlRows[index].currentPercent = try? brightnessControls.read(row)
            if case .ddc(let display) = row.mode {
                // A zero readback is what unresponsive DDC monitors report; keep the requested level instead.
                let readback = displayControlRows[index].currentPercent.flatMap { $0 > 0 ? $0 : nil }
                dimmer.recordManualExternalBrightness(readback ?? percent, for: display)
            }
            diagnostics.record("ui.brightnessWriteAccepted", ["rowID": rowID, "requested": percent, "rowsAfter": diagnosticRows])
            dimmer.setStatus(displayControlRows[index].currentPercent == nil
                ? "Brightness sent; monitor does not report its level"
                : "Brightness adjusted")
        } catch {
            displayControlRows[index].currentPercent = try? brightnessControls.read(row)
            dimmer.setStatus("Brightness adjustment failed", error: error.localizedDescription)
            diagnostics.record("ui.brightnessWriteFailed", ["rowID": rowID, "requested": percent, "error": error.localizedDescription])
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            settings.launchAtLogin = LoginItemController.isEnabled
            loginItemStatus = LoginItemController.statusDescription
            dimmer.setStatus(enabled ? "Launch at login enabled" : "Launch at login disabled")
        } catch {
            settings.launchAtLogin = LoginItemController.isEnabled
            loginItemStatus = LoginItemController.statusDescription
            dimmer.setStatus("Login item failed", error: error.localizedDescription)
        }
    }

    /// Turning logging off also deletes existing logs, so nothing is kept once an issue is resolved.
    func setDiagnosticLogging(_ enabled: Bool) {
        settings.diagnosticLoggingEnabled = enabled
        if enabled {
            diagnostics.isEnabled = true
            diagnostics.record("diagnostics.enabled", ["logPath": diagnostics.fileURL.path])
            refreshExternalDisplays()
        } else {
            diagnostics.isEnabled = false
            diagnostics.deleteLogFiles()
        }
    }

    func setHideMenuBarIcon(_ hidden: Bool) {
        settings.hideMenuBarIcon = hidden

        if hidden {
            showSettingsWindow()
        }

        statusItemController.setVisible(!hidden)
    }

    func showSettingsWindow() {
        diagnostics.record("ui.settingsOpened")
        settingsWindowController.show()
    }

    func handleReopen() {
        if settings.hideMenuBarIcon {
            showSettingsWindow()
        } else {
            statusItemController.showPopover()
        }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        checkIdleTime()
    }

    /// Polls every second only while dimmed, retrying, or showing the UI; otherwise sleeps until the
    /// timeout could next elapse, since idle time cannot grow faster than the wall clock.
    private func checkIdleTime() {
        let idleTime = idleReader.idleTime()
        if visibleSettingsViews > 0 {
            let text = Self.formatIdleTime(idleTime)
            if text != idleTimeText { idleTimeText = text }
        }
        dimmer.handleIdleTime(idleTime)

        var interval: TimeInterval = 1
        if visibleSettingsViews == 0, !dimmer.needsFrequentIdleChecks {
            let remaining = settings.isEnabled ? TimeInterval(settings.idleTimeoutSeconds) - idleTime : .infinity
            interval = min(max(remaining, 1), Self.maximumIdleCheckInterval)
        }
        scheduleIdleCheck(after: interval)
    }

    private func scheduleIdleCheck(after interval: TimeInterval) {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkIdleTime() }
        }
        timer.tolerance = min(interval * 0.1, 1)
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func settingsViewDidAppear() {
        visibleSettingsViews += 1
        startIdleTimer()
    }

    func settingsViewDidDisappear() {
        visibleSettingsViews = max(0, visibleSettingsViews - 1)
    }

    private func startInputWakeMonitor() {
        inputWakeMonitor?.stop()
        guard EventListeningPermission.isTrusted else {
            inputWakeMonitor = nil
            diagnostics.record("input.monitorUnavailable", ["reason": "permission not granted", "idlePolling": true])
            return
        }

        // The tap's run loop source is on the main run loop, so this runs on the main actor; skipping the
        // Task hop matters because mouse moves arrive at display refresh rate.
        let monitor = InputWakeMonitor { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dimmer.isDimmed else { return }
                self.dimmer.handleUserActivity()
                self.startIdleTimer()
            }
        }

        if monitor.start() {
            inputWakeMonitor = monitor
            diagnostics.record("input.monitorStarted")
        } else {
            inputWakeMonitor = nil
            diagnostics.record("input.monitorUnavailable", ["reason": "event tap failed", "idlePolling": true])
        }
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observe(center.publisher(for: NSApplication.willTerminateNotification)) { model in
            model.diagnostics.record("system.appTerminating")
            model.dimmer.restoreNow(reason: "app quit")
        }
        observe(workspaceCenter.publisher(for: NSWorkspace.willSleepNotification)) { model in
            model.diagnostics.record("system.willSleep")
            model.dimmer.restoreNow(reason: "sleep")
        }
        observe(center.publisher(for: NSApplication.didChangeScreenParametersNotification)) { model in
            model.diagnostics.record("system.displaysChanged")
            model.refreshExternalDisplays(recoveryReason: "displays changed")
        }
        observe(workspaceCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { model in
            model.diagnostics.record("system.screensDidSleep")
        }
        observe(workspaceCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { model in
            model.diagnostics.record("system.screensDidWake")
            model.refreshExternalDisplays(recoveryReason: "screens wake")
        }
        observe(workspaceCenter.publisher(for: NSWorkspace.didWakeNotification)) { model in
            model.diagnostics.record("system.didWake")
            model.startInputWakeMonitor()
            model.dimmer.restoreNow(reason: "wake")
            model.refreshExternalDisplays(recoveryReason: "wake")
        }
    }

    private func syncDisplayControlRows(
        from displays: [ConnectedDisplayRow],
        ddcDisplays: [ExternalDisplayReference]
    ) {
        let ddcContext = makeDDCMatchContext(for: displays, ddcDisplays: ddcDisplays)

        displayControlRows = displays.map { display in
            let mode = resolveDisplayControlMode(
                for: display,
                context: ddcContext
            )
            let preferenceKey = "display:\(display.id)"
            let preference = settings.seedDisplayControl(
                key: preferenceKey,
                displayName: display.name,
                defaultDimPercent: settings.dimPercent
            )

            return DisplayControlRow(
                id: preferenceKey,
                preferenceKey: preferenceKey,
                name: display.name,
                resolution: display.resolution,
                isExternal: display.isExternal,
                dimPercent: preference.dimPercent,
                mode: mode
            )
        }
    }

    private func matchedExternalDDCDisplayCount(in rows: [DisplayControlRow]) -> Int {
        rows.reduce(into: 0) { count, row in
            guard row.isExternal else {
                return
            }

            guard case .ddc = row.mode else {
                return
            }

            count += 1
        }
    }

    private func makeDDCMatchContext(
        for displays: [ConnectedDisplayRow],
        ddcDisplays: [ExternalDisplayReference]
    ) -> DDCMatchContext {
        DDCMatchContext(
            displaysByName: Dictionary(
                grouping: ddcDisplays.filter { !$0.isPlaceholderDisplayName },
                by: { Self.normalizedDisplayName($0.name) }
            ).compactMapValues { matches in
                guard matches.count == 1,
                      displays.filter({ $0.isExternal && Self.normalizedDisplayName($0.name) == Self.normalizedDisplayName(matches[0].name) }).count == 1 else {
                    return nil
                }
                return matches[0]
            }
        )
    }

    private func resolveDisplayControlMode(
        for display: ConnectedDisplayRow,
        context: DDCMatchContext
    ) -> DisplayControlMode {
        if display.isExternal,
           let ddcDisplay = context.displaysByName[Self.normalizedDisplayName(display.name)] {
            return .ddc(ddcDisplay)
        }

        guard display.index != nil else {
            return .unsupported
        }

        if display.canReadHardwareBrightness || display.isBuiltIn {
            return .brightnessCLI
        }

        return .unsupported
    }

    private static func formatIdleTime(_ idleTime: TimeInterval) -> String {
        let seconds = max(0, Int(idleTime.rounded()))
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            return "\(minutes)m \(remainder)s"
        }

        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func noDDCStatus(for count: Int) -> String {
        "\(count) external display\(count == 1 ? "" : "s"), no DDC control"
    }

    private static func externalDisplayStatus(connectedCount: Int, ddcCount: Int) -> String? {
        guard connectedCount > 0 else {
            return nil
        }

        if ddcCount == 0 {
            return noDDCStatus(for: connectedCount)
        }

        if ddcCount == connectedCount {
            return "Found \(ddcCount) DDC display\(ddcCount == 1 ? "" : "s")"
        }

        return "\(ddcCount) of \(connectedCount) external displays support DDC"
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func makeDimmer() -> DimmerController {
        DimmerController(
            settingsProvider: { [unowned self] in
                var result = self.settings.currentSettings(externalBrightnessByDisplay: [:])
                for row in self.displayControlRows {
                    switch row.mode {
                    case .ddc(let display):
                        result.externalDimPercentByDisplay[display.brightnessPreferenceKey] = row.dimPercent
                        if let displayID = UInt32(row.preferenceKey.replacingOccurrences(of: "display:", with: "")) {
                            result.excludedInternalDisplayIDs.insert(displayID)
                        }
                    case .brightnessCLI:
                        if let displayID = UInt32(row.preferenceKey.replacingOccurrences(of: "display:", with: "")) {
                            result.internalDimPercentByDisplay[displayID] = row.dimPercent
                        }
                    case .unsupported:
                        break
                    }
                }
                return result
            },
            internalBrightness: internalBrightness,
            externalBrightness: externalBrightness,
            snapshotStore: FileSnapshotStore(diagnostics: diagnostics),
            diagnostics: diagnostics,
            levelStore: UserDefaultsExternalLevelStore(defaults: settings.defaults)
        )
    }

    private func makeInternalBrightnessController() -> InternalBrightnessManaging {
        let settings = self.settings
        do {
            return FallbackInternalBrightnessController(
                primary: try DisplayServicesBrightnessController(),
                fallback: BrightnessCLIBrightnessController(
                    executablePathProvider: { settings.brightnessPath }
                )
            )
        } catch {
            return BrightnessCLIBrightnessController(
                executablePathProvider: { settings.brightnessPath }
            )
        }
    }

    private func observe<PublisherType: Publisher>(
        _ publisher: PublisherType,
        action: @escaping @MainActor (AppModel) -> Void
    ) where PublisherType.Output == Notification, PublisherType.Failure == Never {
        publisher
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
            }
            .store(in: &cancellables)
    }

    private var diagnosticRows: [[String: Any]] {
        displayControlRows.map { row in
            var fields: [String: Any] = [
                "rowID": row.id, "name": row.name, "mode": row.controlDescription,
                "isExternal": row.isExternal, "dimPercent": row.dimPercent,
                "currentPercent": row.currentPercent as Any? ?? NSNull(),
                "requestedPercent": row.requestedPercent as Any? ?? NSNull()
            ]
            if case .ddc(let display) = row.mode { fields["ddcDisplay"] = DiagnosticLogger.encoded(display) }
            return fields
        }
    }
}

enum DisplayControlMode: Equatable {
    case brightnessCLI
    case ddc(ExternalDisplayReference)
    case unsupported
}

struct DisplayControlRow: Identifiable, Equatable {
    let id: String
    let preferenceKey: String
    let name: String
    let resolution: String
    let isExternal: Bool
    var dimPercent: Int
    var currentPercent: Int? = nil
    var requestedPercent: Int? = nil
    let mode: DisplayControlMode

    var controlDescription: String {
        switch mode {
        case .brightnessCLI:
            return "Hardware"
        case .ddc:
            return "DDC"
        case .unsupported:
            return "Unavailable"
        }
    }

    var isControllable: Bool {
        mode != .unsupported
    }
}

private struct DDCMatchContext {
    let displaysByName: [String: ExternalDisplayReference]
}

private extension ExternalDisplayReference {
    var isPlaceholderDisplayName: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let selector else {
            return normalized.isEmpty || normalized == "default external display"
        }

        return normalized.isEmpty || normalized == "display \(selector)"
    }
}
