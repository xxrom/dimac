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
    private let hardwareBrightness: DisplayHardwareBrightnessController
    lazy var dimmer: DimmerController = makeDimmer()
    private lazy var statusItemController = StatusItemController(model: self)
    private lazy var settingsWindowController = SettingsWindowController(model: self)
    private var inputWakeMonitor: InputWakeMonitor?
    private var idleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var displayControlApplyTimer: Timer?

    init() {
        let settings = SettingsStore()
        self.settings = settings

        let externalController = M1DDCBrightnessController(
            executablePathProvider: { settings.m1ddcPath }
        )
        self.externalBrightness = externalController
        self.displayDiscovery = ConnectedDisplayDiscovery(
            brightnessPathProvider: { settings.brightnessPath }
        )
        self.hardwareBrightness = DisplayHardwareBrightnessController(
            brightnessPathProvider: { settings.brightnessPath }
        )

        AppRuntime.model = self
        observeSettings()
        setUp()
    }

    private func setUp() {
        NSApp.setActivationPolicy(.accessory)
        loginItemStatus = LoginItemController.statusDescription
        settings.launchAtLogin = LoginItemController.isEnabled

        applyMenuBarIconVisibility()
        startIdleTimer()
        startInputWakeMonitor()
        observeSystemNotifications()

        refreshExternalDisplays()
        dimmer.restorePersistedSnapshotIfNeeded()
        refreshExternalDisplays()
    }

    func dimNow() {
        dimmer.dimNow(applyHardware: false)
        applyDisplayControls(forDimmedState: true)
    }

    func restoreNow() {
        dimmer.restoreNow(reason: "manual", applyHardware: false)
        applyDisplayControls(forDimmedState: false)
    }

    func refreshExternalDisplays() {
        let connectedDisplays = displayDiscovery.displays()
        connectedExternalDisplayRows = connectedDisplays.filter(\.isExternal)
        let ddcDisplays = dimmer.refreshExternalDisplays()

        syncDisplayControlRows(
            from: connectedDisplays,
            ddcDisplays: ddcDisplays,
            ddcBrightnessByDisplay: loadDDCBrightnessByDisplay(for: ddcDisplays),
            useLiveValuesForSeeding: !dimmer.isDimmed
        )
        ddcDisplayCount = matchedExternalDDCDisplayCount(in: displayControlRows)

        if let status = Self.externalDisplayStatus(
            connectedCount: connectedExternalDisplayRows.count,
            ddcCount: ddcDisplayCount
        ) {
            dimmer.setStatus(status)
        }

        applyDisplayControls(forDimmedState: dimmer.isDimmed)
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
            displayControlRows[index].normalPercent = preference.normalPercent
            displayControlRows[index].dimPercent = preference.dimPercent
        }
    }

    func setDisplayPercent(_ percent: Int, for rowID: String, kind: DisplayControlValueKind) {
        guard let rowIndex = displayControlRows.firstIndex(where: { $0.id == rowID }) else {
            return
        }

        var row = displayControlRows[rowIndex]
        switch kind {
        case .normal:
            let preference = settings.setDisplayNormalPercent(
                percent,
                key: row.preferenceKey,
                displayName: row.name
            )
            row.normalPercent = preference.normalPercent
            row.dimPercent = preference.dimPercent
        case .dim:
            let preference = settings.setDisplayDimPercent(
                percent,
                key: row.preferenceKey,
                displayName: row.name
            )
            row.normalPercent = preference.normalPercent
            row.dimPercent = preference.dimPercent
        }
        displayControlRows[rowIndex] = row
    }

    func applyDisplayControlsForCurrentState() {
        scheduleDisplayControlApply(delay: 0.05)
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

    private func observeSettings() {
        settings.$hideMenuBarIcon
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyMenuBarIconVisibility()
            }
            .store(in: &cancellables)
    }

    private func applyMenuBarIconVisibility() {
        statusItemController.setVisible(!settings.hideMenuBarIcon)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let idleTime = self.idleReader.idleTime()
                self.idleTimeText = Self.formatIdleTime(idleTime)
                let wasDimmed = self.dimmer.isDimmed
                self.dimmer.handleIdleTime(idleTime, applyHardware: false)
                self.handleDimStateTransition(from: wasDimmed)
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
                let wasDimmed = self.dimmer.isDimmed
                self.dimmer.handleUserActivity(applyHardware: false)
                self.handleDimStateTransition(from: wasDimmed)
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
        ddcDisplays: [ExternalDisplayReference],
        ddcBrightnessByDisplay: [String: Int],
        useLiveValuesForSeeding: Bool
    ) {
        let ddcContext = makeDDCMatchContext(for: displays, ddcDisplays: ddcDisplays)
        var externalOffset = 0

        displayControlRows = displays.map { display in
            let mode = resolveDisplayControlMode(
                for: display,
                context: ddcContext,
                externalOffset: externalOffset
            )
            let preferenceKey = "display:\(display.id)"
            let preference = settings.seedDisplayControl(
                key: preferenceKey,
                displayName: display.name,
                currentPercent: liveBrightnessPercent(
                    for: display,
                    mode: mode,
                    ddcBrightnessByDisplay: ddcBrightnessByDisplay,
                    useLiveValuesForSeeding: useLiveValuesForSeeding
                ),
                defaultDimPercent: settings.dimPercent
            )

            if display.isExternal {
                externalOffset += 1
            }

            return DisplayControlRow(
                id: preferenceKey,
                preferenceKey: preferenceKey,
                name: display.name,
                resolution: display.resolution,
                isExternal: display.isExternal,
                normalPercent: preference.normalPercent,
                dimPercent: preference.dimPercent,
                mode: mode
            )
        }
    }

    private var externalBrightnessRestoreDefaults: [String: Int] {
        displayControlRows.reduce(into: [:]) { defaults, row in
            guard case .ddc(let display) = row.mode else {
                return
            }

            defaults[display.brightnessPreferenceKey] = row.normalPercent
        }
    }

    private func loadDDCBrightnessByDisplay(for displays: [ExternalDisplayReference]) -> [String: Int] {
        guard !displays.isEmpty else {
            return [:]
        }

        do {
            let snapshots = try externalBrightness.currentSnapshot(for: displays)
            return Dictionary(
                uniqueKeysWithValues: snapshots.map { ($0.display.brightnessPreferenceKey, $0.luminance) }
            )
        } catch {
            return [:]
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
            ).mapValues { $0[0] },
            unnamedDisplays: ddcDisplays.filter(\.isPlaceholderDisplayName),
            externalDisplayCount: displays.filter(\.isExternal).count
        )
    }

    private func resolveDisplayControlMode(
        for display: ConnectedDisplayRow,
        context: DDCMatchContext,
        externalOffset: Int
    ) -> DisplayControlMode {
        if display.isExternal,
           let ddcDisplay = context.displaysByName[Self.normalizedDisplayName(display.name)] {
            return .ddc(ddcDisplay)
        }

        if display.isExternal, context.unnamedDisplays.count == context.externalDisplayCount,
           let ddcDisplay = context.unnamedDisplays[safe: externalOffset] {
            return .ddc(ddcDisplay)
        }

        if display.isExternal, let ddcDisplay = context.unnamedDisplays[safe: externalOffset] {
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

    private func liveBrightnessPercent(
        for display: ConnectedDisplayRow,
        mode: DisplayControlMode,
        ddcBrightnessByDisplay: [String: Int],
        useLiveValuesForSeeding: Bool
    ) -> Int? {
        guard useLiveValuesForSeeding else {
            return nil
        }

        switch mode {
        case .ddc(let ddcDisplay):
            return ddcBrightnessByDisplay[ddcDisplay.brightnessPreferenceKey]
        case .brightnessCLI, .unsupported:
            return display.brightnessPercent
        }
    }

    private func applyDisplayControls(forDimmedState isDimmed: Bool) {
        displayControlApplyTimer?.invalidate()
        displayControlApplyTimer = nil
        applyDisplayControls(percent: isDimmed ? \.dimPercent : \.normalPercent)
    }

    private func handleDimStateTransition(from wasDimmed: Bool) {
        guard wasDimmed != dimmer.isDimmed else {
            return
        }

        applyDisplayControls(forDimmedState: dimmer.isDimmed)
    }

    private func scheduleDisplayControlApply(delay: TimeInterval = 0.15) {
        displayControlApplyTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyDisplayControls(forDimmedState: self.dimmer.isDimmed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayControlApplyTimer = timer
    }

    private func applyDisplayControls(percent percentKeyPath: KeyPath<DisplayControlRow, Int>) {
        for row in displayControlRows {
            applyHardwareDisplayControl(row, percent: row[keyPath: percentKeyPath])
        }
    }

    private func applyHardwareDisplayControl(_ row: DisplayControlRow, percent: Int) {
        do {
            switch row.mode {
            case .brightnessCLI(let displayIndex):
                try hardwareBrightness.setBrightness(percent: percent, displayIndex: displayIndex)
            case .ddc(let display):
                try externalBrightness.setBrightness(percent: percent, for: [display])
            case .unsupported:
                return
            }
        } catch {
            dimmer.setStatus("Display brightness failed", error: error.localizedDescription)
        }
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
                self.settings.currentSettings(
                    externalBrightnessByDisplay: self.externalBrightnessRestoreDefaults
                )
            },
            internalBrightness: makeInternalBrightnessController(),
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

enum DisplayControlValueKind {
    case normal
    case dim
}

struct DisplayControlRow: Identifiable, Equatable {
    let id: String
    let preferenceKey: String
    let name: String
    let resolution: String
    let isExternal: Bool
    var normalPercent: Int
    var dimPercent: Int
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

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct DDCMatchContext {
    let displaysByName: [String: ExternalDisplayReference]
    let unnamedDisplays: [ExternalDisplayReference]
    let externalDisplayCount: Int
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
