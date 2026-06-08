import AppKit
import ApplicationServices
import CoreGraphics

/// The OS permissions Klip needs, and helpers to check/request them and to
/// deep-link the user into the right System Settings pane.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status { case granted, denied, unknown }

    @Published var accessibility: Status = .unknown
    @Published var screenRecording: Status = .unknown

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Prompt for Accessibility — only if not already trusted. When already
    /// granted this is a no-op refresh and shows no dialog.
    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { refresh(); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
    }

    /// Prompt for Screen Recording — only if not already granted. Calling the
    /// request API while unauthorized is what surfaces the system dialog; we
    /// skip it entirely when access is already present.
    func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { refresh(); return }
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    var allGranted: Bool {
        accessibility == .granted && screenRecording == .granted
    }
}
