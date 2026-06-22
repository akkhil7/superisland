import SwiftUI
import AppKit
import Carbon.HIToolbox
import SuperIslandCore

/// Visual treatment per status — the only "alert" surface (no banners/sound),
/// so colors and a subtle animation carry the signal.
enum StatusStyle {
    static func color(_ s: DropStatus) -> Color {
        switch s {
        case .working: return .blue
        case .needsAttention: return .orange
        case .done: return .green
        case .stale: return .secondary
        case .unknown: return .gray
        }
    }

    static func symbol(_ s: DropStatus) -> String {
        switch s {
        case .working: return "hourglass"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .stale: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Whether a status should pull the eye (animate) on the island.
    static func isAlerting(_ s: DropStatus) -> Bool {
        s == .needsAttention || s == .done
    }
}

// MARK: - Island chip

/// Bright status tints used on the island.
enum IslandTint {
    /// Brand purple (#7b39fc) — matches the website's working/primary color.
    static let working = Color(red: 0x7B / 255, green: 0x39 / 255, blue: 0xFC / 255)
    static let attention = Color(red: 0.95, green: 0.23, blue: 0.21)  // red
    static let done = Color(red: 0.20, green: 0.85, blue: 0.40)  // green

    /// Muted gray for states with no live signal (unknown / stale) — they must
    /// not borrow the vivid brand purple, which reads as "working".
    static let idle = Color.secondary

    static func tint(_ s: DropStatus) -> Color {
        switch s {
        case .working: return working
        case .needsAttention: return attention
        case .done: return done
        case .unknown, .stale: return idle
        }
    }
}

/// Apple's notch silhouette: flush top edge, **concave** (inverted) fillets at
/// the top outer corners that blend into the menu bar, and **convex** rounded
/// bottom corners. Used for the island so it reads as a real extended notch.
struct NotchShape: Shape {
    // Tuned to Apple's notch proportions for the 32pt notch height.
    var bottomRadius: CGFloat = 11
    var topRadius: CGFloat = 8  // the inverted top-corner radius

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
        return 200  // no notch: a stylized central gap
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

/// A counter orb shown on one side of the notch: a clean solid disc with the
/// count, wrapped in a soft outer glow that breathes when alerting.
struct CountBadge: View {
    let count: Int
    let color: Color
    let glow: Bool

    @State private var glowOn = false

    private var lit: Bool { count > 0 }

    var body: some View {
        ZStack {
            // Flat, evenly-filled disc — keeps the number fully legible. The
            // hairline ring separates the disc from a same-colored notch when
            // the colored-notch alert level tints the background.
            Circle().fill(color.opacity(lit ? 1 : 0.22))
                .overlay(Circle().stroke(.white.opacity(lit ? 0.22 : 0), lineWidth: 1))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(lit ? 1 : 0.6))
        }
        .frame(width: 20, height: 20)
        // Outer glow only: always on while lit, breathing when alerting.
        .shadow(color: lit ? color.opacity(0.95) : .clear, radius: glowOn ? 10 : 6)
        .shadow(color: lit ? color.opacity(0.5) : .clear, radius: glowOn ? 18 : 11)
        .onAppear {
            guard glow else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glowOn = true
            }
        }
    }
}

extension Drop {
    /// The origin badge shown on this drop (Claude Desktop vs Claude Code, …).
    var source: DropSource {
        DropSource.identify(
            bundleID: target.bundleID, locator: target.locator,
            contentURL: target.contentURL, label: label
        )
    }
}

/// Small badge naming a drop's origin so the same app used two ways
/// ("Claude Desktop" vs "Claude Code" in a terminal) reads differently.
struct SourcePill: View {
    let source: DropSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.icon)
                .font(.system(size: 8, weight: .semibold))
            Text(source.name)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.white.opacity(0.12)))
        .fixedSize()
    }
}

/// One drop row in the expanded list.
struct DropRow: View {
    let drop: Drop
    let onClick: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: StatusStyle.symbol(drop.status))
                .foregroundStyle(IslandTint.tint(drop.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(drop.label)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    SourcePill(source: drop.source)
                    Text(drop.history.last?.reason ?? drop.status.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
        .background(
            RoundedRectangle(cornerRadius: 10).fill(IslandTint.tint(drop.status).opacity(0.18))
        )
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
    }
}

/// The notch's fill, with a built-in pulse. Plain black when `tint` is nil;
/// when a status color is active it lays a tinted gradient over the black base
/// and throbs that tint's opacity in and out forever. The motion lives *inside*
/// the clipped notch (an opacity animation, not an outer shadow), so it renders
/// reliably on the transparent panel where a spill-out glow did not. The black
/// base keeps the count badges legible at every point in the pulse.
struct NotchPlate: View {
    let tint: Color?
    /// Toggled forever by `startPulse` to drive the throb between dim & bright.
    @State private var bright = false

    private let dimOpacity = 0.32
    private let brightOpacity = 0.85

    var body: some View {
        ZStack {
            NotchShape().fill(.black)
            if let tint {
                NotchShape()
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .opacity(bright ? brightOpacity : dimOpacity)
                // Constant soft top sheen for a little gloss.
                NotchShape()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
            }
        }
        .onAppear { startPulse() }
        .onChange(of: tint) { _, _ in startPulse() }
    }

    /// Start (or restart, on a color change) the forever throb; stops cleanly
    /// when the tint clears. Same proven approach as the `CountBadge` glow.
    private func startPulse() {
        bright = false
        guard tint != nil else { return }
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            bright = true
        }
    }
}

/// The notch island: collapsed, it extends the notch with an in-progress count
/// on the left and a needs-you count on the right. Click to expand it
/// vertically into the full drop list.
struct IslandView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: DropStore
    // Observed directly so toggling the alert level in Settings re-renders the
    // island immediately, rather than only on the next drop status change.
    @EnvironmentObject var settings: Settings

    /// Reports the island's current size so the host can route clicks through
    /// the transparent area around it.
    var onSize: (CGSize) -> Void = { _ in }

    private var inProgress: [Drop] {
        store.drops.filter { $0.status == .working || $0.status == .unknown }
    }
    private var needsAttention: [Drop] { store.drops.filter { $0.status == .needsAttention } }
    private var done: [Drop] { store.drops.filter { $0.status == .done } }
    private var needsYou: [Drop] { needsAttention + done }

    /// Right-side color: orange if anything needs attention, else green if
    /// anything is done, else a neutral done-green.
    private var rightColor: Color {
        !needsAttention.isEmpty ? IslandTint.attention : IslandTint.done
    }

    /// The status color the notch should glow with, or nil for the plain black
    /// notch. Active only at the colored-notch alert level (or louder) when
    /// something needs the user — needsAttention (red) wins over done (green).
    /// Reverts to nil while expanded so the drop list stays legible.
    private var notchTint: Color? {
        guard settings.alertLevel.showsColoredNotch,
            !controller.islandExpanded
        else { return nil }
        if !needsAttention.isEmpty { return IslandTint.attention }
        if !done.isEmpty { return IslandTint.done }
        return nil
    }

    private var contentWidth: CGFloat {
        controller.islandExpanded ? max(NotchMetrics.barWidth, 300) : NotchMetrics.barWidth
    }

    var body: some View {
        // The island lives at the top of a larger, fixed, mostly-transparent
        // window. It expands within that window so the window never resizes.
        VStack(spacing: 6) {
            island
            if let toast = controller.toast {
                ToastBar(message: toast.message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchMetrics.windowWidth, height: NotchMetrics.windowHeight, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controller.toast)
    }

    private var island: some View {
        VStack(spacing: 0) {
            collapsedBar
            if controller.islandExpanded { expandedList }
        }
        .frame(width: contentWidth)
        .background(NotchPlate(tint: notchTint))
        .clipShape(NotchShape())
        .animation(.easeInOut(duration: 0.4), value: notchTint)
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            onSize($0)
        }
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

            if store.drops.isEmpty {
                Text("No drops yet — focus a window and press ⌥⌘K")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 5) {
                        ForEach(needsYou + inProgress) { drop in
                            DropRow(
                                drop: drop,
                                onClick: { controller.refocus(drop) },
                                onDismiss: { controller.dismiss(drop) })
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 400)
            }

            Divider().overlay(.white.opacity(0.08))

            HStack {
                Button {
                    controller.createDrop()
                } label: {
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

// MARK: - Toast bar

/// A compact, non-interactive pill shown just under the notch island to relay
/// a transient message — currently the "app not supported" notice when a drop
/// is refused. Auto-dismissed by `AppController.showToast`.
struct ToastBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandTint.attention)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(.black.opacity(0.92))
        )
        .overlay(
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .help(message)
    }
}

// MARK: - Alert banner

/// Fixed width of each banner card, so the row reads as an even set of tiles.
private let alertBannerCardWidth: CGFloat = 240

/// The explicit, most-intrusive alert surface: a persistent status card shown
/// when a drop changes to a state that needs the user (only at the `.notify`
/// alert level). Cards never time out — clicking anywhere on the card jumps to
/// the drop's tab/window, which is also the only way to dismiss it. Laid out in
/// a row by `AlertBannerBar`.
struct AlertBannerView: View {
    let status: DropStatus
    let label: String
    let source: DropSource
    var onTap: () -> Void = {}

    private var tint: Color { IslandTint.tint(status) }

    private var headline: String {
        switch status {
        case .needsAttention: return "Needs you"
        case .done: return "Done"
        default: return status.rawValue.capitalized
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: StatusStyle.symbol(status))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                    SourcePill(source: source)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: alertBannerCardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // Whole card is clickable → show the pointing-hand cursor on hover.
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("\(headline): \(label) — click to open")
    }
}

/// Host content for the full-width banner panel: a horizontal row of persistent
/// banner cards spread across the top of the screen. Reports the row's size so
/// the window can route clicks through everywhere except the cards.
struct AlertBannerBar: View {
    @EnvironmentObject var controller: AppController
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(controller.alertBanners) { banner in
                    AlertBannerView(
                        status: banner.status,
                        label: banner.label,
                        source: banner.source,
                        onTap: { controller.activateBanner(id: banner.id) }
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .padding(.top, AlertBannerMetrics.topInset)
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                onSize($0)
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: AlertBannerMetrics.windowWidth,
            height: AlertBannerMetrics.windowHeight,
            alignment: .top
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: controller.alertBanners)
    }
}

/// Geometry for the full-width banner window. Spans the main screen so the row
/// can spread horizontally; banners sit just below the menu bar / notch.
enum AlertBannerMetrics {
    static var windowWidth: CGFloat { NSScreen.main?.frame.width ?? 1440 }
    static let windowHeight: CGFloat = 160
    /// Push the row clear of the menu bar / notch at the very top.
    static var topInset: CGFloat { max(NotchMetrics.height, 24) + 10 }
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
    @EnvironmentObject var store: DropStore
    @EnvironmentObject var permissions: PermissionsManager
    @EnvironmentObject var settings: Settings
    @EnvironmentObject private var updater: SoftwareUpdater

    /// Accessibility is always required; Screen Recording only when the user
    /// opted into screenshots.
    private var permissionsBlocked: Bool {
        permissions.accessibility != .granted
            || (settings.useScreenshots && permissions.screenRecording != .granted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Drops").font(.headline)
                Spacer()
                Button("New Drop (⌥⌘K)") { controller.createDrop() }
            }

            if permissionsBlocked {
                Label(
                    "Permissions needed — open Settings",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            if store.drops.isEmpty {
                Text("No drops yet. Switch to a window and press ⌥⌘K.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.drops) { drop in
                    HStack {
                        Image(systemName: StatusStyle.symbol(drop.status))
                            .foregroundStyle(StatusStyle.color(drop.status))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(drop.label).lineLimit(1)
                            Text(drop.history.last?.reason ?? drop.status.rawValue)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Go") { controller.refocus(drop) }
                        Button {
                            controller.dismiss(drop)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            HStack {
                OpenSettingsButton()
                Button("Welcome Tour…") { controller.showOnboarding() }
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
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
                    .stroke(
                        isRecording ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                Text(
                    isRecording
                        ? "Type shortcut…" : hotkeyLabel(keyCode: keyCode, modifiers: modifiers)
                )
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
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }
}

// MARK: - Hotkey display helpers

private func hotkeyLabel(keyCode: Int, modifiers: Int) -> String {
    var s = ""
    if modifiers & controlKey != 0 { s += "⌃" }
    if modifiers & optionKey != 0 { s += "⌥" }
    if modifiers & shiftKey != 0 { s += "⇧" }
    if modifiers & cmdKey != 0 { s += "⌘" }
    s += keyCodeName(keyCode)
    return s
}

func keyCodeName(_ code: Int) -> String {
    let map: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "ʼ", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
    ]
    return map[code] ?? "?"
}
