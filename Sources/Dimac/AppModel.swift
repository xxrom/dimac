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
    private lazy var internalBrightness = makeInternalBrightnessController()
    private lazy var brightnessControls: CurrentBrightnessManaging = CurrentBrightnessController(
        internalBrightness: internalBrightness, externalBrightness: externalBrightness
    )
    lazy var dimmer: DimmerController = makeDimmer()
    private lazy var statusItemController = StatusItemController(model: self)
    private lazy var settingsWindowController = SettingsWindowController(model: self)
    private var inputWakeMonitor: InputWakeMonitor?
    private var idleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore? = nil,
        dimmer: DimmerController? = nil,
        startAutomatically: Bool = true,
        brightnessControls: CurrentBrightnessManaging? = nil,
        displayProvider: (() -> [ConnectedDisplayRow])? = nil
    ) {
        self.displayProvider = displayProvider
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

    func refreshExternalDisplays() {
        let connectedDisplays = displayProvider?() ?? displayDiscovery.displays()
        connectedExternalDisplayRows = connectedDisplays.filter(\.isExternal)
        let ddcDisplays = dimmer.refreshExternalDisplays()

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
        settings.setDimPercent(percent)
        for index in displayControlRows.indices {
            let row = displayControlRows[index]
            let preference = settings.setDisplayDimPercent(
                percent,
                key: row.preferenceKey,
                displayName: row.name
            )
            displayControlRows[index].dimPercent = preference.dimPercent
        }
    }

    func setDisplayDimPercent(_ percent: Int, for rowID: String) {
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
            displayControlRows[index].currentPercent = row.isControllable
                ? try? brightnessControls.read(row) : nil
        }
    }

    func setCurrentBrightness(_ percent: Int, for rowID: String) {
        guard let index = displayControlRows.firstIndex(where: { $0.id == rowID }),
              displayControlRows[index].isControllable else { return }
        let row = displayControlRows[index]
        // Finish the idle cycle first so later activity cannot undo this explicit choice,
        // including when the chosen value equals the dim target.
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
                refreshCurrentBrightness()
                return
            }
        }
        do {
            try brightnessControls.set(percent, for: row)
            displayControlRows[index].requestedPercent = min(100, max(0, percent))
            displayControlRows[index].currentPercent = try? brightnessControls.read(row)
            if case .ddc(let display) = row.mode {
                dimmer.recordManualExternalBrightness(displayControlRows[index].currentPercent ?? percent, for: display)
            }
            dimmer.setStatus(displayControlRows[index].currentPercent == nil
                ? "Brightness sent; monitor does not report its level"
                : "Brightness adjusted")
        } catch {
            displayControlRows[index].currentPercent = try? brightnessControls.read(row)
            dimmer.setStatus("Brightness adjustment failed", error: error.localizedDescription)
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

    func setHideMenuBarIcon(_ hidden: Bool) {
        settings.hideMenuBarIcon = hidden

        if hidden {
            showSettingsWindow()
        }

        statusItemController.setVisible(!hidden)
    }

    func showSettingsWindow() {
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

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let idleTime = self.idleReader.idleTime()
                self.idleTimeText = Self.formatIdleTime(idleTime)
                self.dimmer.handleIdleTime(idleTime)
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func startInputWakeMonitor() {
        inputWakeMonitor?.stop()
        guard EventListeningPermission.isTrusted else {
            inputWakeMonitor = nil
            return
        }

        let monitor = InputWakeMonitor { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.dimmer.handleUserActivity()
            }
        }

        if monitor.start() {
            inputWakeMonitor = monitor
        } else {
            inputWakeMonitor = nil
        }
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observe(center.publisher(for: NSApplication.willTerminateNotification)) { model in
            model.dimmer.restoreNow(reason: "app quit")
        }
        observe(workspaceCenter.publisher(for: NSWorkspace.willSleepNotification)) { model in
            model.dimmer.restoreNow(reason: "sleep")
        }
        observe(center.publisher(for: NSApplication.didChangeScreenParametersNotification)) { model in
            model.refreshExternalDisplays()
        }
        observe(workspaceCenter.publisher(for: NSWorkspace.didWakeNotification)) { model in
            model.startInputWakeMonitor()
            model.dimmer.restoreNow(reason: "wake")
            model.refreshExternalDisplays()
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
                currentPercent: nil,
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

        guard let index = display.index else {
            return .unsupported
        }

        if display.canReadHardwareBrightness || display.isBuiltIn {
            return .brightnessCLI(displayIndex: index)
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
            snapshotStore: FileSnapshotStore()
        )
    }

    private func makeInternalBrightnessController() -> InternalBrightnessManaging {
        do {
            return FallbackInternalBrightnessController(
                primary: try DisplayServicesBrightnessController(),
                fallback: BrightnessCLIBrightnessController(
                    executablePathProvider: { self.settings.brightnessPath }
                )
            )
        } catch {
            return BrightnessCLIBrightnessController(
                executablePathProvider: { self.settings.brightnessPath }
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
}

enum DisplayControlMode: Equatable {
    case brightnessCLI(displayIndex: Int)
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
