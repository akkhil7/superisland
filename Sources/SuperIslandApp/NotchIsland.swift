import AppKit
import SwiftUI
import Combine
import SuperIslandCore

/// Content view for the island window. The window is large and mostly
/// transparent; this routes clicks through everywhere except the island's
/// current bounds, so the desktop/apps underneath stay interactive.
final class IslandContainerView: NSView {
    /// The island's interactive rect, in this view's coordinates.
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate system; the content view
        // fills the window from (0,0), so it matches window coordinates.
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// A borderless, always-on-top, non-activating panel centered on the physical
/// notch. The window is a fixed size and stays put; the island animates inside
/// it (so expansion is one smooth SwiftUI spring, with no window-frame jumps).
@MainActor
final class NotchIslandController {
    private let panel: NSPanel
    private let container: IslandContainerView
    private let hostingView: NSHostingView<AnyView>
    private unowned let controller: AppController
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var hoverCollapseWork: DispatchWorkItem?

    init(controller: AppController) {
        self.controller = controller
        container = IslandContainerView()

        let w = NotchMetrics.windowWidth
        let h = NotchMetrics.windowHeight

        let root = IslandView(onSize: { [weak container] size in
            // Island sits at the top of the window; mark that rect interactive.
            guard let container else { return }
            container.interactiveRect = CGRect(
                x: (w - size.width) / 2, y: h - size.height,
                width: size.width, height: size.height
            )
        })
        .environmentObject(controller)
        .environmentObject(controller.store)
        .environmentObject(controller.settings)

        hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hostingView.autoresizingMask = [.width, .height]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // shadow is drawn by the SwiftUI shape instead
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // CRITICAL: the panel's frame is a large mostly-transparent rect. With
        // `ignoresMouseEvents = false` macOS delivers EVERY click in the frame
        // to this window (per-pixel transparency pass-through is disabled once
        // the property is set), and `hitTest -> nil` only drops the event — it
        // does NOT forward it to the window underneath. That swallowed all
        // clicks in a 320×600 band at the top-center of the screen. So the
        // panel ignores mouse events by default, and a mouse-move monitor
        // (below) enables them only while the cursor is over the island.
        panel.ignoresMouseEvents = true

        container.frame = NSRect(x: 0, y: 0, width: w, height: h)
        container.addSubview(hostingView)
        // Seed an interactive rect covering the collapsed bar until the first
        // size report arrives.
        container.interactiveRect = CGRect(
            x: (w - NotchMetrics.barWidth) / 2, y: h - NotchMetrics.height,
            width: NotchMetrics.barWidth, height: NotchMetrics.height
        )
        panel.contentView = container
    }

    func show() {
        position()
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
        installMouseTrackingMonitors()
    }

    /// Hide the island entirely and tear down its event monitors. Used when the
    /// user is signed out — the app is locked, so nothing should be on screen.
    func hide() {
        controller.islandExpanded = false
        panel.orderOut(nil)
        for monitor in [clickMonitor, localClickMonitor, mouseMoveMonitor, localMouseMoveMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        clickMonitor = nil
        localClickMonitor = nil
        mouseMoveMonitor = nil
        localMouseMoveMonitor = nil
    }

    /// The island's current bounds in screen coordinates.
    private var islandScreenRect: CGRect {
        let r = container.interactiveRect
        let f = panel.frame
        return CGRect(x: f.minX + r.minX, y: f.minY + r.minY, width: r.width, height: r.height)
    }

    /// Accept mouse events only while the cursor is over the island; the rest
    /// of the (invisible) panel stays click-through.
    private func installMouseTrackingMonitors() {
        guard mouseMoveMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateMouseInteractivity() }
            }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateMouseInteractivity() }
            }
            return event
        }
    }

    private func updateMouseInteractivity() {
        let inside = islandScreenRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        guard controller.settings.islandExpandOnHover else { return }
        if inside {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            if !controller.islandExpanded {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    controller.islandExpanded = true
                }
            }
        } else if controller.islandExpanded, hoverCollapseWork == nil {
            // Debounced collapse: brief excursions off the island don't slam
            // it shut.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverCollapseWork = nil
                    guard self.controller.settings.islandExpandOnHover,
                        !self.islandScreenRect.contains(NSEvent.mouseLocation)
                    else { return }
                    self.collapseIfExpanded()
                }
            }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// Collapse the expanded island when the user clicks anywhere outside it.
    /// Two monitors are needed: a global one for clicks in other apps (our
    /// click-through window never sees those), and a local one for clicks in
    /// SuperIsland's own windows (e.g. the menu-bar dropdown).
    private func installOutsideClickMonitors() {
        guard clickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.collapseIfExpanded() }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let window = event.window
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Clicks on the island itself land in our panel (inside the
                    // interactive rect); anything else collapses it.
                    if window !== self.panel { self.collapseIfExpanded() }
                }
            }
            return event
        }
    }

    private func collapseIfExpanded() {
        guard controller.islandExpanded else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            controller.islandExpanded = false
        }
    }

    deinit {
        for m in [clickMonitor, localClickMonitor, mouseMoveMonitor, localMouseMoveMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        // Top-center; the window's top edge sits at the screen's top edge so the
        // island lands over the notch and grows downward inside the window.
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
