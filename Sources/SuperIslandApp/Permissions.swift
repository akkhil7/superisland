import AppKit
import ApplicationServices

/// The OS permissions SuperIsland needs, and helpers to check/request them and to
/// deep-link the user into the right System Settings pane.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status { case granted, denied, unknown }

    @Published var accessibility: Status = .unknown

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    /// Prompt for Accessibility — only if not already trusted. When already
    /// granted this is a no-op refresh and shows no dialog.
    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { refresh(); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
    }

    /// Clear SuperIsland's own TCC entry for a service and re-prompt. This is the fix
    /// for a *stale grant*: when the app's code signature changes (rebuild with
    /// a different identity), System Settings still shows the toggle as ON but
    /// the OS no longer honors it — and re-toggling does nothing. Resetting the
    /// entry makes macOS treat the app as never-asked, so a fresh, working
    /// prompt appears.
    func resetStaleGrant(service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, bundleID]
        try? p.run()
        p.waitUntilExit()

        switch service {
        case "Accessibility": requestAccessibility()
        default: break
        }
        refresh()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    var allGranted: Bool {
        accessibility == .granted
    }
}
