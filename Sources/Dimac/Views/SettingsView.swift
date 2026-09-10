import AppKit
import DimacCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dimmer: DimmerController
    @EnvironmentObject private var settings: SettingsStore

    @State private var timeoutInput = ""
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            VStack(spacing: 14) {
                timeoutRow
                dimLevelRow
            }
            .padding(14)

            Divider()

            displayControls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            advanced
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
        .controlSize(.small)
        .background(.ultraThinMaterial)
        .onAppear {
            timeoutInput = settings.timeoutText
            model.refreshCurrentBrightness()
        }
        .onChange(of: dimmer.isDimmed) { _ in
            model.refreshCurrentBrightness()
        }
        .onChange(of: settings.idleTimeoutSeconds) { _ in
            timeoutInput = settings.timeoutText
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dimac")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(dimmer.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Toggle("Enabled", isOn: $settings.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(settings.isEnabled ? "Disable dimming" : "Enable dimming")
        }
    }

    private var timeoutRow: some View {
        VStack(spacing: 7) {
            settingRow("Timeout", systemImage: "timer") {
                Text(settings.timeoutText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { settings.timeoutSliderValue },
                    set: { settings.setTimeoutSliderValue($0) }
                ),
                in: 0...100
            )
            .padding(.leading, 26)
        }
    }

    private var dimLevelRow: some View {
        VStack(spacing: 7) {
            settingRow("Dim all displays", systemImage: "sun.min") {
                Text("\(settings.dimPercent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { Double(settings.dimPercent) },
                    set: { model.setDimPercent(Int($0.rounded())) }
                ),
                in: 1...100
            )
            .padding(.leading, 26)

            DisclosureGroup("How dimming works") {
                Text("Restores your previous brightness when you return. Idle levels apply on the next idle cycle and never brighten a screen. Dim all displays replaces individual idle levels. If a monitor cannot report brightness, set Now once per session to enable dimming; monitor-button changes cannot be detected.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
        }
    }

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Displays · \(model.displayControlRows.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshExternalDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh displays and brightness")
            }
            .font(.system(size: 11))

            if model.displayControlRows.isEmpty {
                Text("No displays found. Try refreshing.")
                    .foregroundStyle(.secondary)
            } else if model.displayControlRows.count <= 3 {
                displayList
            } else {
                ScrollView { displayList }
                    .frame(height: 240)
            }
            if let error = dimmer.lastError {
                errorRow(error)
            }
        }
    }

    private var displayList: some View {
        VStack(spacing: 12) {
            ForEach(model.displayControlRows) { row in
                compactDisplayRow(row)
            }
        }
    }

    private func compactDisplayRow(_ row: DisplayControlRow) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(!row.isControllable ? "Unavailable" : row.currentPercent != nil ? row.controlDescription : row.requestedPercent != nil ? "Set level" : "Set first")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("\(row.name) · \(row.resolution) · \(row.controlDescription)")

            CurrentBrightnessSlider(
                percent: row.currentPercent,
                requestedPercent: row.requestedPercent,
                isControllable: row.isControllable
            ) {
                model.setCurrentBrightness($0, for: row.id)
                let updated = model.displayControlRows.first(where: { $0.id == row.id })
                return updated?.currentPercent ?? updated?.requestedPercent
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(row.name) current brightness")

            HStack(spacing: 7) {
                Text("Idle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(row.dimPercent) },
                    set: { model.setDisplayDimPercent(Int($0.rounded()), for: row.id) }
                ), in: 1...100)
                .accessibilityLabel("\(row.name) idle brightness")
                Text("\(row.dimPercent)%")
                    .monospacedDigit()
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .disabled(!row.isControllable)
        }
    }

    private var preciseTimeoutRow: some View {
        settingRow("Exact timeout", systemImage: "keyboard") {
            HStack(spacing: 6) {
                TextField("10m", text: $timeoutInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 66)
                    .onSubmit {
                        settings.setTimeoutFromText(timeoutInput)
                        timeoutInput = settings.timeoutText
                    }
                    .help("Use values like 30s, 5m, or 2h")

                Stepper(
                    "",
                    onIncrement: { settings.incrementTimeout() },
                    onDecrement: { settings.decrementTimeout() }
                )
                .labelsHidden()
                .frame(width: 24)
                .help("Adjust timeout")
            }
        }
    }

    private var launchAtLoginRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(settings.launchAtLogin ? .green : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            Spacer(minLength: 12)

            Text(model.loginItemStatus)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var hideMenuBarIconRow: some View {
        HStack(spacing: 8) {
            Image(systemName: settings.hideMenuBarIcon ? "eye.slash" : "menubar.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Toggle("Hide menu bar icon", isOn: Binding(
                get: { settings.hideMenuBarIcon },
                set: { model.setHideMenuBarIcon($0) }
            ))
            .toggleStyle(.switch)

            Spacer(minLength: 12)
        }
        .help("When hidden, open Dimac.app again to show settings.")
    }

    private var advanced: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    Text("Advanced")
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(spacing: 9) {
                    preciseTimeoutRow

                    statusRow(
                        title: "Idle",
                        value: model.idleTimeText,
                        systemImage: "clock",
                        tint: .secondary
                    )

                    launchAtLoginRow
                    hideMenuBarIconRow
                    toolPathRow(
                        title: "brightness",
                        systemImage: "sun.max",
                        path: $settings.brightnessPath,
                        refreshHelp: "Refresh display discovery"
                    )
                    toolPathRow(
                        title: "m1ddc",
                        systemImage: "display.2",
                        path: $settings.m1ddcPath,
                        refreshHelp: "Refresh external displays"
                    )
                    versionRow

                    if model.legacyAgentDetected {
                        warningRow("Old idle-dim LaunchAgent detected")
                    }

                }
                .padding(.top, 10)
            }
        }
    }

    private func toolPathRow(
        title: String,
        systemImage: String,
        path: Binding<String>,
        refreshHelp: String
    ) -> some View {
        VStack(spacing: 6) {
            settingRow(title, systemImage: systemImage) {
                Button {
                    model.refreshExternalDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(refreshHelp)
            }

            TextField("Path", text: path)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .onSubmit {
                    model.refreshExternalDisplays()
                }
                .padding(.leading, 26)
        }
    }

    private var versionRow: some View {
        settingRow("Version", systemImage: "number") {
            Text(appVersionText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildVersion = info?["CFBundleVersion"] as? String
        let version = shortVersion ?? buildVersion ?? "0.0.0"
        return "v\(version)"
    }

    private var footer: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .buttonStyle(.plain)
        .help("Quit Dimac")
    }

    private func settingRow<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            content()
        }
    }

    private func statusRow(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            statusRowContent(title: title, value: value, systemImage: systemImage, tint: tint)
        }
    }

    private func statusRowContent(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Group {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func warningRow(_ message: String) -> some View {
        Label {
            Text(message)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CurrentBrightnessSlider: View {
    let percent: Int?
    let requestedPercent: Int?
    let isControllable: Bool
    let apply: (Int) -> Int?
    @State private var draft: Double = 0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 7) {
            Text("Now")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Slider(value: $draft, in: 0...100, onEditingChanged: { editing in
                isEditing = editing
                if !editing {
                    draft = Double(apply(Int(draft.rounded())) ?? 0)
                }
            })
            .accessibilityLabel("Current brightness")
            .disabled(!isControllable)
            Text(valueLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .help("Adjust screen brightness now. Idle controls the next idle cycle.")
        .onAppear { draft = Double(percent ?? requestedPercent ?? 0) }
        .onChange(of: percent) { value in
            if !isEditing { draft = Double(value ?? requestedPercent ?? 0) }
        }
        .onChange(of: requestedPercent) { value in
            if !isEditing { draft = Double(percent ?? value ?? 0) }
        }
    }

    private var valueLabel: String {
        if isEditing || percent != nil { return "\(Int(draft.rounded()))%" }
        if let requestedPercent { return "Set \(requestedPercent)%" }
        return "—"
    }
}
