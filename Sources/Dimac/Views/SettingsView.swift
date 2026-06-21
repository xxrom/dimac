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
            settingRow("Dim level", systemImage: "sun.min") {
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
                in: 1...100,
                onEditingChanged: { editing in
                    if !editing {
                        model.applyDisplayControlsForCurrentState()
                    }
                }
            )
            .padding(.leading, 26)
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

            Toggle("Hide menu bar icon", isOn: $settings.hideMenuBarIcon)
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

                    statusRow(
                        title: "External",
                        value: model.externalDisplaySummary,
                        systemImage: "display",
                        tint: model.connectedExternalDisplayRows.isEmpty ? .secondary : .green
                    )

                    displayControls
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

                    if let error = dimmer.lastError {
                        errorRow(error)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private var displayControls: some View {
        VStack(spacing: 7) {
            settingRow("Displays", systemImage: "sun.max") {
                Button {
                    model.refreshExternalDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh displays")
            }

            if !model.displayControlRows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(model.displayControlRows) { row in
                        displayControlRow(row)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }

    private func displayControlRow(_ row: DisplayControlRow) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if !row.resolution.isEmpty {
                            Text(row.resolution)
                        }

                        Text(row.controlDescription)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(row.isExternal ? "External" : "Built-in")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            displaySlider(
                title: "Bright",
                value: row.normalPercent,
                setValue: { model.setDisplayPercent($0, for: row.id, kind: .normal) }
            )
            .disabled(!row.isControllable)

            cappedDisplaySlider(
                title: "Dim",
                value: row.dimPercent,
                allowedUpperBound: row.normalPercent,
                setValue: { model.setDisplayPercent($0, for: row.id, kind: .dim) }
            )
            .disabled(!row.isControllable)
        }
    }

    private func displaySlider(
        title: String,
        value: Int,
        setValue: @escaping (Int) -> Void
    ) -> some View {
        sliderRow(title: title, value: value) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { setValue(Int($0.rounded())) }
                ),
                in: 1...100,
                onEditingChanged: { editing in
                    if !editing {
                        model.applyDisplayControlsForCurrentState()
                    }
                }
            )
            .tint(systemAccentColor)
        }
    }

    private func cappedDisplaySlider(
        title: String,
        value: Int,
        allowedUpperBound: Int,
        setValue: @escaping (Int) -> Void
    ) -> some View {
        sliderRow(title: title, value: value) {
            CappedDisplaySlider(
                value: Binding(
                    get: { value },
                    set: { setValue($0) }
                ),
                allowedUpperBound: allowedUpperBound,
                accentColor: systemAccentColor
            ) { editing in
                if !editing {
                    model.applyDisplayControlsForCurrentState()
                }
            }
        }
    }

    private func sliderRow<Track: View>(
        title: String,
        value: Int,
        @ViewBuilder track: () -> Track
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            track()

            Text("\(value)%")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var systemAccentColor: Color {
        Color(nsColor: .controlAccentColor)
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

private struct CappedDisplaySlider: View {
    @Binding var value: Int

    let allowedUpperBound: Int
    let accentColor: Color
    let onEditingChanged: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false

    private let minimumValue = 1
    private let maximumValue = 100
    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let allowedValue = max(minimumValue, min(allowedUpperBound, maximumValue))
            let currentValue = max(minimumValue, min(value, allowedValue))
            let allowedProgress = progress(for: allowedValue)
            let currentProgress = progress(for: currentValue)
            let width = max(geometry.size.width, 1)
            let allowedWidth = width * allowedProgress
            let currentWidth = width * currentProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(accentColor.opacity(0.26))
                    .frame(width: allowedWidth, height: trackHeight)

                Capsule()
                    .fill(accentColor)
                    .frame(width: currentWidth, height: trackHeight)

                if allowedValue < maximumValue {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: max(0, width - allowedWidth), height: trackHeight)
                        .offset(x: allowedWidth)

                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 2, height: thumbSize - 2)
                        .offset(x: max(0, min(width - 2, allowedWidth - 1)))
                }

                Circle()
                    .fill(accentColor)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: max(0, min(width - thumbSize, currentWidth - (thumbSize / 2))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else {
                            return
                        }

                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }

                        updateValue(for: gesture.location.x, width: width, allowedUpperBound: allowedValue)
                    }
                    .onEnded { gesture in
                        guard isEnabled else {
                            return
                        }

                        updateValue(for: gesture.location.x, width: width, allowedUpperBound: allowedValue)
                        if isDragging {
                            isDragging = false
                            onEditingChanged(false)
                        }
                    }
            )
        }
        .frame(height: thumbSize)
        .opacity(isEnabled ? 1 : 0.55)
        .help("Dim cannot exceed the current Bright level.")
        .accessibilityValue("\(value)%")
    }

    private func updateValue(for locationX: CGFloat, width: CGFloat, allowedUpperBound: Int) {
        let clampedX = min(max(0, locationX), width)
        let progress = width > 0 ? clampedX / width : 0
        let rawValue = Int((Double(progress) * Double(maximumValue - minimumValue)).rounded()) + minimumValue
        value = min(allowedUpperBound, max(minimumValue, rawValue))
    }

    private func progress(for value: Int) -> CGFloat {
        let normalizedValue = max(minimumValue, min(value, maximumValue))
        return CGFloat(normalizedValue - minimumValue) / CGFloat(maximumValue - minimumValue)
    }
}
