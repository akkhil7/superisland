import Foundation

/// Tiny helper for running AppleScript and getting a string/bool result.
///
/// Used by the Chrome/Terminal adapters to read tab/window identity and to
/// raise an exact tab. Automation (Apple Events) permission is required; a
/// failure here is non-fatal — callers fall back to generic AX behavior.
enum AppleScriptRunner {
    struct ScriptError: Error { let message: String }

    /// Run a script, returning its string result (may be empty).
    @discardableResult
    static func run(_ source: String) throws -> String {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ScriptError(message: "could not compile script")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg =
                errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
            throw ScriptError(message: msg)
        }
        return result.stringValue ?? ""
    }
}
