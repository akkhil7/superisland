import AppKit
import SwiftUI
import Combine
import KlipCore

/// A borderless, always-on-top, non-activating panel rendered around the notch
/// area showing the klip chips. Non-activating so clicking a chip or the drop
/// button doesn't make Klip the frontmost app (keeps drop-target tracking sane).
@MainActor
final class NotchIslandController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private var cancellable: AnyCancellable?

    init(controller: AppController) {
        let root = IslandView()
            .environmentObject(controller)
            .environmentObject(controller.store)

        hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.contentView = hostingView

        // Re-fit and reposition whenever the klip list changes.
        cancellable = controller.store.$klips
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
    }

    func show() {
        panel.orderFrontRegardless()
        reposition()
    }

    private func reposition() {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = NSSize(width: max(120, fitting.width), height: max(28, fitting.height))
        panel.setContentSize(size)

        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        // Flush to the very top of the screen (over the notch row).
        let y = frame.maxY - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
