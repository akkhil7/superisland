import AppKit
import Carbon.HIToolbox
import Foundation
import SuperIslandCore

/// App-wide diagnostic logger (internal tooling). Holds a live ring buffer for
/// the in-app viewer and appends every line to a per-launch-identified file at
/// `~/.config/superisland/diagnostics.log`. Nothing leaves the machine.
@MainActor
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    @Published private(set) var buffer = DiagnosticRingBuffer(capacity: 1000)

    /// Short id identifying this app run, stamped on every entry + file header.
    let launchID: String

    static let fileURL = ShellIntegration.configDir.appendingPathComponent("diagnostics.log")
    private let queue = DispatchQueue(label: "com.superisland.diagnostics")

    private init() {
        launchID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let header = DiagnosticFormat.launchHeader(
            launchID: launchID, version: version, build: build, date: Date())
        appendToFile("\n\(header)")
        log(.app, "launch — v\(version) (build \(build))")
    }

    func log(_ category: DiagnosticCategory, _ message: String) {
        let entry = DiagnosticEntry(
            date: Date(), launchID: launchID, category: category, message: message)
        buffer.append(entry)
        appendToFile(DiagnosticFormat.line(entry))
    }

    func clear() { buffer.clear() }

    private func appendToFile(_ line: String) {
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(
                at: ShellIntegration.configDir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: Self.fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        }
    }
}

/// Convenience for call sites. Main-actor isolated like the logger.
@MainActor func dlog(_ category: DiagnosticCategory, _ message: String) {
    DiagnosticLogger.shared.log(category, message)
}

/// Fixed internal chord (⌃⌥⌘L) that toggles diagnostics mode. Uses NSEvent
/// monitors so it never collides with the Carbon-registered drop hotkey.
@MainActor
final class DiagnosticsHotkey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onTrigger: (() -> Void)?
    private var lastAt = Date.distantPast
    private let matcher = HotkeyMatcher(
        keyCode: Int(kVK_ANSI_L), modifiers: Int(controlKey | optionKey | cmdKey))

    func install(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        var mods = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.control) { mods |= controlKey }
        guard matcher.matches(eventKeyCode: Int(event.keyCode), eventModifiers: mods) else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastAt) > 0.35 else { return }
        lastAt = now
        onTrigger?()
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
