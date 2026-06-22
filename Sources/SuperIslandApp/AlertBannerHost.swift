import AppKit
import SwiftUI

/// A borderless, always-on-top, non-activating panel spanning the full width of
/// the main screen, hosting the row of persistent status banners. Mirrors
/// `NotchIslandController`'s click-through strategy: the panel is a large,
/// mostly-transparent rect that ignores mouse events by default, and a
/// mouse-move monitor enables interaction only while the cursor is over the
/// banner row (so the menu bar and apps underneath stay clickable everywhere
/// else).
@MainActor
final class AlertBannerHostController {
    private let panel: NSPanel
    private let container: IslandContainerView
    private let hostingView: NSHostingView<AnyView>
    private unowned let controller: AppController
    private var mouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?

    init(controller: AppController) {
        self.controller = controller
        container = IslandContainerView()

        let w = AlertBannerMetrics.windowWidth
        let h = AlertBannerMetrics.windowHeight

        let root = AlertBannerBar(onSize: { [weak container] size in
            guard let container else { return }
            // Centered row, anchored `topInset` below the top of the window.
            container.interactiveRect = size.width <= 0
                ? .zero
                : CGRect(
                    x: (w - size.width) / 2,
                    y: h - AlertBannerMetrics.topInset - size.height,
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
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // See NotchIslandController for why this must default to ignoring mouse
        // events (a transparent full-width band would otherwise swallow every
        // click along the top of the screen, including the menu bar).
        panel.ignoresMouseEvents = true

        container.frame = NSRect(x: 0, y: 0, width: w, height: h)
        container.interactiveRect = .zero   // nothing interactive until a banner shows
        container.addSubview(hostingView)
        panel.contentView = container
    }

    func show() {
        position()
        panel.orderFrontRegardless()
        installMouseTrackingMonitors()
    }

    /// The banner row's bounds in screen coordinates (empty when no banners).
    private var rowScreenRect: CGRect {
        let r = container.interactiveRect
        guard r.width > 0 else { return .zero }
        let f = panel.frame
        return CGRect(x: f.minX + r.minX, y: f.minY + r.minY, width: r.width, height: r.height)
    }

    private func installMouseTrackingMonitors() {
        guard mouseMoveMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateInteractivity() }
            }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateInteractivity() }
            }
            return event
        }
    }

    private func updateInteractivity() {
        let inside = rowScreenRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    deinit {
        for m in [mouseMoveMonitor, localMouseMoveMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
    }
}
