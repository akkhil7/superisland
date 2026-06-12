import AppKit
import SwiftUI
import KlipCore

/// Borderless rounded window: Esc closes, background drags. Borderless
/// windows refuse key status by default — override, or buttons won't click.
final class OnboardingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: OnboardingPanel?
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    /// First launch only (UserDefaults flag).
    func showIfNeeded() {
        let completed = UserDefaults.standard.bool(forKey: OnboardingFlow.completedDefaultsKey)
        guard OnboardingFlow.shouldShowOnLaunch(hasCompleted: completed) else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = OnboardingView(onFinish: { [weak self] in self?.finish() })
            .environmentObject(controller)
            .environmentObject(controller.permissions)
            .environmentObject(controller.settings)
            .environmentObject(controller.shellIntegration)
            .environmentObject(controller.claudeIntegration)
            .environmentObject(controller.chromeIntegration)
            .environmentObject(controller.codexIntegration)

        let hosting = NSHostingView(rootView: AnyView(
            root
                .frame(width: 760, height: 560)   // NSHostingView resizes borderless windows to intrinsic size — pin it
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        ))

        let panel = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // Keep the tour visible while the user grants permissions in System
        // Settings etc. — an accessory app's normal-level window gets buried
        // the moment focus leaves, and with no Dock icon it feels lost.
        panel.level = .floating
        panel.delegate = self
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    private func finish() {
        markCompleted()
        window?.close()
        controller.welcomePulse()
    }

    func windowWillClose(_ notification: Notification) {
        markCompleted()   // closing = done; no nagging on next launch
        window = nil
    }

    private func markCompleted() {
        UserDefaults.standard.set(true, forKey: OnboardingFlow.completedDefaultsKey)
    }
}
