import Foundation

public struct PrefilterResult: Equatable, Sendable {
    /// Whether this snapshot is worth spending a Claude call on.
    public var isInteresting: Bool
    /// A cheap on-device guess at the status. Also used as the fallback status
    /// when the cloud classifier is unavailable.
    public var hint: KlipStatus
    /// Human-readable signals that fired (for the chip tooltip / debugging).
    public var signals: [String]

    public init(isInteresting: Bool, hint: KlipStatus, signals: [String]) {
        self.isInteresting = isInteresting
        self.hint = hint
        self.signals = signals
    }
}

/// Cheap, on-device first pass over a window's text. Decides whether a snapshot
/// looks interesting enough to send to Claude, and produces a best-effort
/// status guess that doubles as the offline fallback.
///
/// Pure string logic — fully unit-testable. (The Vision/OCR step that turns a
/// screenshot into text lives in the app target; its output is fed here.)
public struct Prefilter: Sendable {
    public init() {}

    /// Phrases that strongly suggest the task is waiting for the user.
    private static let attentionPatterns: [String] = [
        "[y/n]", "(y/n)", "[yes/no]", "(yes/no)", "yes/no",
        "password:", "passphrase:", "enter password",
        "press any key", "press enter", "press return",
        "do you want to", "would you like to", "are you sure",
        "continue?", "proceed?", "overwrite?", "confirm",
        "permission", "authorize", "authenticate",
        "waiting for input", "your response", "type your",
    ]

    /// Phrases that strongly suggest the task finished.
    private static let donePatterns: [String] = [
        "done.", "done!", "✓", "✔", "completed", "complete.",
        "finished", "success", "succeeded", "build succeeded",
        "passing", "all tests passed", "no errors",
        "exit code 0", "process completed", "task complete",
    ]

    /// Phrases that suggest a failure the user should look at.
    private static let errorPatterns: [String] = [
        "error", "failed", "failure", "exception", "traceback",
        "fatal", "panic", "cannot", "denied", "not found",
    ]

    public func assess(text rawText: String) -> PrefilterResult {
        let text = rawText.lowercased()
        var signals: [String] = []

        let attention = Self.attentionPatterns.filter { text.contains($0) }
        let done = Self.donePatterns.filter { text.contains($0) }
        let errors = Self.errorPatterns.filter { text.contains($0) }

        // A trailing "?" on the last non-empty line is a strong prompt signal.
        let trailingQuestion = lastNonEmptyLine(of: rawText)?
            .trimmingCharacters(in: .whitespaces)
            .hasSuffix("?") ?? false

        signals.append(contentsOf: attention.map { "attention:\($0)" })
        signals.append(contentsOf: done.map { "done:\($0)" })
        signals.append(contentsOf: errors.map { "error:\($0)" })
        if trailingQuestion { signals.append("attention:trailing-?") }

        // Priority: a pending question/prompt beats a "done" word that may just
        // be scrollback. Errors are treated as needing attention.
        let needsAttention = !attention.isEmpty || trailingQuestion
        let hint: KlipStatus
        if needsAttention {
            hint = .needsAttention
        } else if !errors.isEmpty {
            hint = .needsAttention
        } else if !done.isEmpty {
            hint = .done
        } else {
            hint = .working
        }

        let isInteresting = !signals.isEmpty
        return PrefilterResult(isInteresting: isInteresting, hint: hint, signals: signals)
    }

    private func lastNonEmptyLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
