import SwiftUI
import KlipCore

/// Visual treatment per status — the only "alert" surface (no banners/sound),
/// so colors and a subtle animation carry the signal.
enum StatusStyle {
    static func color(_ s: KlipStatus) -> Color {
        switch s {
        case .working: return .blue
        case .needsAttention: return .orange
        case .done: return .green
        case .stale: return .secondary
        case .unknown: return .gray
        }
    }

    static func symbol(_ s: KlipStatus) -> String {
        switch s {
        case .working: return "hourglass"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .stale: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Whether a status should pull the eye (animate) on the island.
    static func isAlerting(_ s: KlipStatus) -> Bool {
        s == .needsAttention || s == .done
    }
}

// MARK: - Island chip

/// A single klip pill on the notch island. Recolors and pulses when it flips to
/// needs-attention/done. Click to refocus the exact window/tab.
struct KlipChip: View {
    let klip: Klip
    let onClick: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                Image(systemName: StatusStyle.symbol(klip.status))
                Text(klip.label)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(
                Capsule().fill(StatusStyle.color(klip.status).opacity(0.9))
            )
            .scaleEffect(pulse ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .help(klip.history.last?.reason ?? klip.status.rawValue)
        .onChange(of: klip.status) { _, newValue in
            guard StatusStyle.isAlerting(newValue) else { return }
            withAnimation(.easeInOut(duration: 0.4).repeatCount(5, autoreverses: true)) {
                pulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { pulse = false }
        }
    }
}

/// The notch island content: a row of chips plus a drop button.
struct IslandView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: KlipStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                controller.dropKlip()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Drop a klip on the current window (⌥⌘K)")

            if store.klips.isEmpty {
                Text("No klips")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(store.klips) { klip in
                    KlipChip(klip: klip) { controller.refocus(klip) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.black))
        .fixedSize()
    }
}

// MARK: - Menu bar dropdown

struct MenuBarContent: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: KlipStore
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var settings: Settings

    /// Accessibility is always required; Screen Recording only when the user
    /// opted into screenshots.
    private var permissionsBlocked: Bool {
        permissions.accessibility != .granted
            || (settings.useScreenshots && permissions.screenRecording != .granted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Klips").font(.headline)
                Spacer()
                Button("Drop Klip (⌥⌘K)") { controller.dropKlip() }
            }

            if permissionsBlocked {
                Label("Permissions needed — open Settings", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            if store.klips.isEmpty {
                Text("No klips yet. Switch to a window and press ⌥⌘K.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.klips) { klip in
                    HStack {
                        Image(systemName: StatusStyle.symbol(klip.status))
                            .foregroundStyle(StatusStyle.color(klip.status))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(klip.label).lineLimit(1)
                            Text(klip.history.last?.reason ?? klip.status.rawValue)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Go") { controller.refocus(klip) }
                        Button {
                            controller.dismiss(klip)
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var controller: AppController

    @State private var apiKeyField: String = ""

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField("Anthropic API key", text: $apiKeyField)
                HStack {
                    Button("Save Key") {
                        settings.setAPIKey(apiKeyField)
                        apiKeyField = ""
                    }
                    if settings.hasAPIKey {
                        Label("Key saved", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.caption)
                    }
                }
                Picker("Model", selection: $settings.model) {
                    ForEach(Settings.availableModels, id: \.self) { Text($0).tag($0) }
                }
            }

            Section("Monitoring") {
                Toggle("Capture screenshots (needs Screen Recording)", isOn: $settings.useScreenshots)
                Text("Off = text-only. Klip reads window text and never needs Screen Recording. Turn on for better accuracy on graphical windows.")
                    .font(.caption2).foregroundStyle(.secondary)
                sliderRow("Poll every", value: $settings.pollInterval, range: 2...30, unit: "s")
                sliderRow("Settle after", value: $settings.settleInterval, range: 2...30, unit: "s")
                sliderRow("Fallback check", value: $settings.fallbackInterval, range: 60...600, unit: "s")
                Button("Apply intervals") { controller.monitor.resetDetectors(); controller.monitor.start() }
            }

            Section("Permissions") {
                permissionRow("Accessibility", granted: permissions.accessibility == .granted) {
                    permissions.requestAccessibility(); permissions.openAccessibilitySettings()
                }
                permissionRow("Screen Recording", granted: permissions.screenRecording == .granted) {
                    permissions.requestScreenRecording(); permissions.openScreenRecordingSettings()
                }
                Button("Open Automation settings") { permissions.openAutomationSettings() }
                Button("Re-check") { permissions.refresh() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
        .onAppear { permissions.refresh() }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))\(unit)").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            if !granted { Button("Grant", action: action) }
        }
    }
}
