import SwiftUI
import AppKit
import Carbon.HIToolbox
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

/// Bright status tints used on the island.
enum IslandTint {
    static let working = Color(red: 0.16, green: 0.55, blue: 1.0)   // bright blue
    static let attention = Color(red: 1.0, green: 0.55, blue: 0.0)  // orange
    static let done = Color(red: 0.20, green: 0.85, blue: 0.40)     // green

    static func tint(_ s: KlipStatus) -> Color {
        switch s {
        case .needsAttention: return attention
        case .done: return done
        default: return working
        }
    }
}

/// Apple's notch silhouette: flush top edge, **concave** (inverted) fillets at
/// the top outer corners that blend into the menu bar, and **convex** rounded
/// bottom corners. Used for the island so it reads as a real extended notch.
struct NotchShape: Shape {
    // Tuned to Apple's notch proportions for the 32pt notch height.
    var bottomRadius: CGFloat = 11
    var topRadius: CGFloat = 8   // the inverted top-corner radius

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let tr = min(topRadius, h / 2)
        let br = min(bottomRadius, (h - tr) / 1, w / 2 - tr)

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        // Top-left inverted corner (concave) curling down into the notch.
        p.addQuadCurve(to: CGPoint(x: tr, y: tr), control: CGPoint(x: tr, y: 0))
        p.addLine(to: CGPoint(x: tr, y: h - br))
        // Bottom-left convex corner.
        p.addQuadCurve(to: CGPoint(x: tr + br, y: h), control: CGPoint(x: tr, y: h))
        p.addLine(to: CGPoint(x: w - tr - br, y: h))
        // Bottom-right convex corner.
        p.addQuadCurve(to: CGPoint(x: w - tr, y: h - br), control: CGPoint(x: w - tr, y: h))
        p.addLine(to: CGPoint(x: w - tr, y: tr))
        // Top-right inverted corner (concave).
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - tr, y: 0))
        p.closeSubpath()
        return p
    }
}

/// Physical notch geometry of the main display, so the island can wrap it.
enum NotchMetrics {
    static var width: CGFloat {
        guard let s = NSScreen.main else { return 200 }
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return max(120, r.minX - l.maxX)
        }
        return 200   // no notch: a stylized central gap
    }
    static var height: CGFloat {
        let inset = NSScreen.main?.safeAreaInsets.top ?? 0
        return inset > 4 ? inset : 32
    }
    /// Width of each side flanking the notch.
    static let sideWidth: CGFloat = 52
    static var barWidth: CGFloat { sideWidth * 2 + width }

    /// The fixed host window is larger than the island and mostly transparent;
    /// the island animates within it (so the window never resizes → no jump).
    static var windowWidth: CGFloat { max(barWidth, 320) }
    static let windowHeight: CGFloat = 600
}

/// A glowing count badge shown on one side of the notch.
struct CountBadge: View {
    let count: Int
    let color: Color
    let glow: Bool

    @State private var glowOn = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 19, height: 19)
            .background(Circle().fill(color.opacity(count == 0 ? 0.25 : 1)))
            .shadow(color: (glow && count > 0) ? color : .clear, radius: glowOn ? 8 : 2)
            .onAppear {
                guard glow else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    glowOn = true
                }
            }
    }
}

/// One klip row in the expanded list.
struct KlipRow: View {
    let klip: Klip
    let onClick: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: StatusStyle.symbol(klip.status))
                .foregroundStyle(IslandTint.tint(klip.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(klip.label)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text(klip.history.last?.reason ?? klip.status.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 4)

            // Dismiss — 30×30 tap target with visible circle background.
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.13)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 284)
        .background(RoundedRectangle(cornerRadius: 10).fill(IslandTint.tint(klip.status).opacity(0.18)))
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
    }
}

/// The notch island: collapsed, it extends the notch with an in-progress count
/// on the left and a needs-you count on the right. Click to expand it
/// vertically into the full klip list.
struct IslandView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: KlipStore

    /// Reports the island's current size so the host can route clicks through
    /// the transparent area around it.
    var onSize: (CGSize) -> Void = { _ in }

    private var inProgress: [Klip] {
        store.klips.filter { $0.status == .working || $0.status == .unknown }
    }
    private var needsAttention: [Klip] { store.klips.filter { $0.status == .needsAttention } }
    private var done: [Klip] { store.klips.filter { $0.status == .done } }
    private var needsYou: [Klip] { needsAttention + done }

    /// Right-side color: orange if anything needs attention, else green if
    /// anything is done, else a neutral done-green.
    private var rightColor: Color {
        !needsAttention.isEmpty ? IslandTint.attention : IslandTint.done
    }

    private var contentWidth: CGFloat {
        controller.islandExpanded ? max(NotchMetrics.barWidth, 300) : NotchMetrics.barWidth
    }

    var body: some View {
        // The island lives at the top of a larger, fixed, mostly-transparent
        // window. It expands within that window so the window never resizes.
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(width: NotchMetrics.windowWidth, height: NotchMetrics.windowHeight, alignment: .top)
    }

    private var island: some View {
        VStack(spacing: 0) {
            collapsedBar
            if controller.islandExpanded { expandedList }
        }
        .frame(width: contentWidth)
        .background(NotchShape().fill(.black))
        .clipShape(NotchShape())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    // Collapsed: count ······ notch gap ······ count, pushed to the extremes.
    private var collapsedBar: some View {
        HStack(spacing: 0) {
            // The shape's straight side sits `topRadius` (8) in from the frame
            // edge, so a 4px gap from the visible border = 8 + 4 = 12.
            CountBadge(count: inProgress.count, color: IslandTint.working, glow: false)
                .padding(.leading, 12)
            Spacer(minLength: NotchMetrics.width)
            CountBadge(count: needsYou.count, color: rightColor, glow: !needsAttention.isEmpty)
                .padding(.trailing, 12)
        }
        .frame(width: contentWidth, height: NotchMetrics.height)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                controller.islandExpanded.toggle()
            }
        }
        .help("Click to expand")
    }

    private var expandedList: some View {
        VStack(spacing: 0) {
            Divider().overlay(.white.opacity(0.12))

            if store.klips.isEmpty {
                Text("No klips yet — focus a window and press ⌥⌘K")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 5) {
                        ForEach(needsYou + inProgress) { klip in
                            KlipRow(klip: klip,
                                    onClick: { controller.refocus(klip) },
                                    onDismiss: { controller.dismiss(klip) })
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 400)
            }

            Divider().overlay(.white.opacity(0.08))

            HStack {
                Button { controller.dropKlip() } label: {
                    Label("Drop (⌥⌘K)", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .transition(.opacity)
    }
}

// MARK: - Settings opener

/// Opens the Settings window and brings it to front. SettingsLink doesn't work
/// reliably in accessory (LSUIElement) apps — the window hides behind everything.
/// Using openSettings + activate fixes that.
struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
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
                OpenSettingsButton()
                Button("Welcome Tour…") { controller.showOnboarding() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Key recorder

/// Inline shortcut badge that enters recording mode on click and captures the
/// next valid key+modifier combination typed by the user.
struct KeyRecorderField: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                Text(isRecording ? "Type shortcut…" : hotkeyLabel(keyCode: keyCode, modifiers: modifiers))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isRecording ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .fixedSize()
            .onTapGesture { isRecording = true }

            Button(isRecording ? "Cancel" : "Reset") {
                if isRecording {
                    isRecording = false
                } else {
                    keyCode = Settings.defaultKeyCode
                    modifiers = Settings.defaultModifiers
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .background(
            KeyCaptureField(isActive: isRecording) { code, mods in
                let shortcut = HotkeyShortcutPolicy.normalized(
                    keyCode: code,
                    modifiers: mods,
                    defaultKeyCode: Settings.defaultKeyCode,
                    defaultModifiers: Settings.defaultModifiers
                )
                keyCode = shortcut.keyCode
                modifiers = shortcut.modifiers
                isRecording = false
            }
            .frame(width: 0, height: 0)
        )
    }
}

// MARK: - Key capture NSView bridge

/// Zero-size transparent view that intercepts key events when `isActive`.
struct KeyCaptureField: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (Int, Int) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        KeyCaptureNSView(onCapture: onCapture)
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        DispatchQueue.main.async {
            if isActive {
                nsView.window?.makeFirstResponder(nsView)
            } else if nsView.window?.firstResponder === nsView {
                nsView.window?.makeFirstResponder(nil)
            }
        }
    }
}

final class KeyCaptureNSView: NSView {
    var onCapture: (Int, Int) -> Void

    init(onCapture: @escaping (Int, Int) -> Void) {
        self.onCapture = onCapture
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = carbonMods(from: event.modifierFlags)
        guard mods != 0, event.keyCode != 53 /* Esc */ else { return }
        onCapture(Int(event.keyCode), mods)
    }

    // Intercept command shortcuts (⌘W, ⌘Q, etc.) while recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = carbonMods(from: event.modifierFlags)
        guard mods != 0, event.keyCode != 53 else { return false }
        onCapture(Int(event.keyCode), mods)
        return true
    }

    private func carbonMods(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option)  { m |= optionKey }
        if flags.contains(.shift)   { m |= shiftKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }
}

// MARK: - Hotkey display helpers

private func hotkeyLabel(keyCode: Int, modifiers: Int) -> String {
    var s = ""
    if modifiers & controlKey != 0 { s += "⌃" }
    if modifiers & optionKey  != 0 { s += "⌥" }
    if modifiers & shiftKey   != 0 { s += "⇧" }
    if modifiers & cmdKey     != 0 { s += "⌘" }
    s += keyCodeName(keyCode)
    return s
}

func keyCodeName(_ code: Int) -> String {
    let map: [Int: String] = [
        0:"A",  1:"S",  2:"D",  3:"F",  4:"H",  5:"G",  6:"Z",  7:"X",
        8:"C",  9:"V",  11:"B", 12:"Q", 13:"W", 14:"E", 15:"R",
        16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5",
        24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]",
        31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"↩",
        37:"L", 38:"J", 39:"ʼ", 40:"K", 41:";", 42:"\\",
        43:",",44:"/", 45:"N", 46:"M", 47:".",
        48:"⇥", 49:"Space", 51:"⌫", 53:"⎋",
        96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",
        103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",
    ]
    return map[code] ?? "?"
}
