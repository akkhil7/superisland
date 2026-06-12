import Foundation
import Combine
import KlipCore

/// Manages installing/uninstalling shell hooks and tracking active sessions.
/// Owned by AppController; passed as an environment object to SettingsView.
final class ShellIntegration: ObservableObject {
    @Published private(set) var isInstalled: Bool = false
    @Published private(set) var activeSessions: Int = 0

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/klip")
    static let zshScriptPath = configDir.appendingPathComponent("klip.zsh")
    static let bashScriptPath = configDir.appendingPathComponent("klip.bash")

    // Checked synchronously by adapters at klip-drop time.
    static var isScriptInstalled: Bool {
        FileManager.default.fileExists(atPath: zshScriptPath.path)
            || FileManager.default.fileExists(atPath: bashScriptPath.path)
    }

    init() { isInstalled = Self.isScriptInstalled }

    func refresh() {
        isInstalled = Self.isScriptInstalled
    }

    // MARK: - Session tracking (called by AppController on shell events)

    func sessionRegistered() { activeSessions += 1 }
    func sessionEnded() { activeSessions = max(0, activeSessions - 1) }

    // MARK: - Install / Uninstall

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        try zshScript().write(to: Self.zshScriptPath, atomically: true, encoding: .utf8)
        try bashScript().write(to: Self.bashScriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.zshScriptPath.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.bashScriptPath.path)
        appendSourceLine(to: ".zshrc", scriptPath: Self.zshScriptPath.path)
        appendSourceLine(to: ".bashrc", scriptPath: Self.bashScriptPath.path)
        appendSourceLine(to: ".bash_profile", scriptPath: Self.bashScriptPath.path)
        isInstalled = true
    }

    func uninstall() {
        removeSourceLine()
        try? FileManager.default.removeItem(at: Self.zshScriptPath)
        try? FileManager.default.removeItem(at: Self.bashScriptPath)
        isInstalled = false
        activeSessions = 0
    }

    // MARK: - Shell RC injection

    private func appendSourceLine(to rc: String, scriptPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(rc)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = ShellHookScriptBuilder.sourceBlock(scriptPath: scriptPath)
        guard !existing.contains(block) else { return }
        try? (existing + block).write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeSourceLine() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for rc in [".zshrc", ".bashrc", ".bash_profile"] {
            let url = home.appendingPathComponent(rc)
            guard var content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            content = content.replacingOccurrences(
                of: ShellHookScriptBuilder.sourceBlock(scriptPath: Self.zshScriptPath.path),
                with: ""
            )
            content = content.replacingOccurrences(
                of: ShellHookScriptBuilder.sourceBlock(scriptPath: Self.bashScriptPath.path),
                with: ""
            )
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Script content

    func zshScript() -> String { ShellHookScriptBuilder.zshScript(port: ShellServer.port) }
    func bashScript() -> String { ShellHookScriptBuilder.bashScript(port: ShellServer.port) }
}
