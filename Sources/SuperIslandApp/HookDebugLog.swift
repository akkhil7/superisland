import Foundation
import os

/// Append-only diagnostic log for Claude/Codex hook delivery. Captures the raw
/// payload at the server boundary plus the routing decision (mapped status,
/// matched drop) so we can see exactly what Claude sends for a permission prompt
/// and where — if anywhere — that event is dropped before it reaches a chip.
///
/// Writes timestamped lines to `~/.config/superisland/hook-debug.log` and mirrors them
/// to the unified log (subsystem `com.superisland.hooks`). Hook events are
/// infrequent, so the file append is negligible. This is temporary
/// instrumentation — remove once the permission-prompt question is settled.
enum HookDebugLog {
    static let fileURL = ShellIntegration.configDir
        .appendingPathComponent("hook-debug.log")

    private static let osLog = Logger(subsystem: "com.superisland.hooks", category: "delivery")
    private static let queue = DispatchQueue(label: "com.superisland.hookdebug")

    static func log(_ message: String) {
        osLog.debug("\(message, privacy: .public)")
        queue.async {
            let line = "\(timestamp())  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(
                at: ShellIntegration.configDir, withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
