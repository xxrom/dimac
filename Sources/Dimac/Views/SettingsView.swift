import AppKit
import DimacCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dimmer: DimmerController
    @EnvironmentObject private var settings: SettingsStore

    @State private var timeoutInput = ""
    @State private var showAdvanced = false
    @State private var showHelp = false

    private static let displayTints: [Color] = [.blue, .teal, .purple, .pink, .mint]

    var body: some View {
        GlassGroup {
            VStack(spacing: 8) {
                header
                scheduleCard
                displayControls
                advancedToggle
                if showAdvanced {
                    advancedCards
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
            .padding(10)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12))
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

    // MARK: - Main

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(settings.isEnabled ? Color.indigo : Color.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Dimac")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    if let error = dimmer.lastError {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .help(error)
                            .accessibilityLabel("Error: \(error)")
                    }
                    Text(dimmer.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("How dimming works")
            .accessibilityLabel("How dimming works")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                Text("Now is your live brightness. Idle applies after the timeout and never brightens a display. Activity restores the previous level. Idle all replaces individual idle levels. If a display cannot report brightness, set Now once; changes made with monitor buttons cannot be detected.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260)
                    .padding(12)
            }

            Toggle("Enabled", isOn: $settings.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(settings.isEnabled ? "Disable dimming" : "Enable dimming")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var scheduleCard: some View {
        card(title: "All displays", tint: .indigo) {
            CapsuleSlider(
                value: Binding(
                    get: { settings.timeoutSliderValue },
                    set: { settings.setTimeoutSliderValue($0) }
                ),
                range: 0...100,
                systemImage: "timer",
                title: "Dim after",
                valueText: settings.timeoutText,
                tint: .indigo,
                accessibilityLabel: "Idle timeout"
            )
            CapsuleSlider(
                value: Binding(
                    get: { Double(settings.dimPercent) },
                    set: { model.setDimPercent(Int($0.rounded())) }
                ),
                range: 1...100,
                systemImage: "moon.fill",
                title: "Idle all",
                valueText: "\(settings.dimPercent)%",
                tint: .purple,
                accessibilityLabel: "Idle brightness for all displays"
            )
            .help("Replaces every display's idle level")
        }
    }

    @ViewBuilder
    private var displayControls: some View {
        if model.displayControlRows.isEmpty {
            card(title: "Displays", tint: .gray) {
                Text("No displays found. Try refreshing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }
        } else if model.displayControlRows.count <= 3 {
            displayList
        } else {
            ScrollView { displayList }
                .frame(height: 300)
        }
    }

    private var displayList: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.displayControlRows.enumerated()), id: \.element.id) { index, row in
                displayCard(row, tint: Self.displayTints[index % Self.displayTints.count])
            }
        }
    }

    private func displayCard(_ row: DisplayControlRow, tint: Color) -> some View {
        card(
            title: row.name,
            tint: tint,
            chip: !row.isControllable ? "Unavailable" : row.currentPercent != nil ? row.controlDescription : row.requestedPercent != nil ? "Set level" : "Set first",
            help: "\(row.name) · \(row.resolution) · \(row.controlDescription)"
        ) {
            CurrentBrightnessSlider(
                displayName: row.name,
                percent: row.currentPercent,
                requestedPercent: row.requestedPercent,
                isControllable: row.isControllable
            ) {
                model.setCurrentBrightness($0, for: row.id)
                let updated = model.displayControlRows.first(where: { $0.id == row.id })
                return updated?.currentPercent ?? updated?.requestedPercent
            }

            CapsuleSlider(
                value: Binding(
                    get: { Double(row.dimPercent) },
                    set: { model.setDisplayDimPercent(Int($0.rounded()), for: row.id) }
                ),
                range: 1...100,
                systemImage: "moon.fill",
                title: "Idle",
                valueText: "\(row.dimPercent)%",
                tint: tint,
                isEnabled: row.isControllable,
                accessibilityLabel: "\(row.name) idle brightness"
            )
            .help("Brightness applied after the timeout. Never brightens a display.")
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                showAdvanced.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    .frame(width: 14)
                Text("Advanced")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if !showAdvanced, dimmer.lastError != nil || model.legacyAgentDetected {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(dimmer.lastError != nil ? Color.red : Color.orange)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(tint: .gray, cornerRadius: 14)
        .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
    }

    // MARK: - Advanced

    private var advancedCards: some View {
        VStack(spacing: 8) {
            card(title: "Timing", tint: .orange, systemImage: "clock", compact: true) {
                row("Exact timeout") {
                    TextField("10m", text: $timeoutInput)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 11, design: .monospaced))
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
                    .help("Adjust timeout")
                }
                row("Idle for") {
                    Text(model.idleTimeText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            card(title: "System", tint: .green, systemImage: "gearshape", compact: true) {
                row("Launch at login") {
                    Text(model.loginItemStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Toggle("Launch at login", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                row("Hide menu bar icon") {
                    Toggle("Hide menu bar icon", isOn: Binding(
                        get: { settings.hideMenuBarIcon },
                        set: { model.setHideMenuBarIcon($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .help("When hidden, open Dimac.app again to show settings.")
            }

            card(title: "Tools", tint: .cyan, systemImage: "wrench.and.screwdriver", compact: true) {
                toolPathRow("brightness", path: $settings.brightnessPath)
                toolPathRow("m1ddc", path: $settings.m1ddcPath)
            }

            card(title: "Info", tint: .pink, systemImage: "info.circle", compact: true) {
                if let error = dimmer.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.legacyAgentDetected {
                    Label("Old idle-dim LaunchAgent detected", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                }
                row("Diagnostics log") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLogger.shared.fileURL])
                    }
                    .buttonStyle(.borderless)
                    .help(DiagnosticLogger.shared.fileURL.path)
                }
                row("Version") {
                    Text(appVersionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func toolPathRow(_ title: String, path: Binding<String>) -> some View {
        row(title) {
            TextField("Path", text: path)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: 200)
                .onSubmit { model.refreshExternalDisplays() }
                .help("Press Return to refresh displays")
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
        HStack(spacing: 8) {
            Button {
                model.refreshExternalDisplays()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r")
            .help("Refresh displays and brightness (⌘R)")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("q")
            .help("Quit Dimac (⌘Q)")
        }
        .controlSize(.regular)
        .glassButtons()
    }

    // MARK: - Building blocks

    private func card<Content: View>(
        title: String,
        tint: Color,
        systemImage: String? = nil,
        chip: String? = nil,
        help: String? = nil,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let chip {
                    Text(chip)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: Capsule())
                }
            }
            .help(help ?? title)

            content()
                .controlSize(compact ? .small : .regular)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 8 : 10)
        .glassCard(tint: tint, strength: compact ? 0.06 : 0.12)
    }

    private func row<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Sliders

/// Full-width, line-height capsule slider in the style of Control Center.
private struct CapsuleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let systemImage: String
    let title: String
    let valueText: String
    let tint: Color
    var isEnabled = true
    let accessibilityLabel: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var isHovering = false

    private let height: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.55), tint.opacity(0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: height + (width - height) * fraction)
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text(title)
                    Spacer(minLength: 4)
                    Text(valueText)
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(isDragging ? 0.4 : isHovering ? 0.25 : 0.1)))
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let usable = max(width - height, 1)
                        let position = min(max((gesture.location.x - height / 2) / usable, 0), 1)
                        value = range.lowerBound + position * span
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = (range.upperBound - range.lowerBound) / 20
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}

private struct CurrentBrightnessSlider: View {
    let displayName: String
    let percent: Int?
    let requestedPercent: Int?
    let isControllable: Bool
    let apply: (Int) -> Int?
    @State private var draft: Double = 0
    @State private var isEditing = false

    var body: some View {
        CapsuleSlider(
            value: $draft,
            range: 0...100,
            systemImage: "sun.max.fill",
            title: "Now",
            valueText: valueLabel,
            tint: .orange,
            isEnabled: isControllable,
            accessibilityLabel: "\(displayName) current brightness",
            onEditingChanged: { editing in
                isEditing = editing
                if !editing {
                    draft = Double(apply(Int(draft.rounded())) ?? 0)
                }
            }
        )
        .help("Now changes brightness immediately. Idle applies after the timeout.")
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
        return isControllable ? "Drag to set" : "—"
    }
}

// MARK: - Glass

/// Groups glass cards so they blend and morph together on macOS 26+.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard(tint: Color, strength: Double = 0.12, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint.opacity(strength)), in: shape)
        } else {
            self.background(tint.opacity(strength * 0.8), in: shape)
                .background(.thinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    func glassButtons() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
