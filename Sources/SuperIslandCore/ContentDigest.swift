import Foundation

/// Change-detection hash for a window's accessibility text that ignores
/// cosmetically volatile substrings — relative timestamps ("2 minutes ago"),
/// wall-clock times, and whitespace runs.
///
/// Why: the monitor re-samples a *settled* drop (done / needsAttention) often
/// so it can notice the user resuming, and only re-runs the AI classifier when
/// the content hash changed. If the raw text hashed differently every time
/// "2 minutes ago" ticked to "3 minutes ago", a finished conversation would be
/// re-classified — and flip-flop between done and needsAttention — every few
/// seconds. Normalizing those volatile tokens away keeps a settled window
/// stable while a genuine new message (the user's reply) still changes the hash.
///
/// Pure and UI-free so it can be unit-tested. The hash is `String.hashValue`,
/// which is per-process seeded — fine for comparing within one run, but it must
/// never be persisted or compared across launches.
public enum ContentDigest {
    public static func hash(_ text: String) -> Int {
        normalize(text).hashValue
    }

    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        for (pattern, replacement) in replacements {
            s = s.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let replacements: [(String, String)] = [
        // "<n> <unit> ago" (2 minutes ago, 45s ago, 3 hrs ago, …) and "just now".
        (#"\b\d+\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|month|months|y|yr|yrs|year|years)\s+ago\b"#, " "),
        (#"\bjust now\b"#, " "),
        // Wall-clock times: 10:42, 10:42:07, 10:42 pm.
        (#"\b\d{1,2}:\d{2}(:\d{2})?\s*([ap]m)?\b"#, " "),
        // Collapse any whitespace run (incl. newlines) to a single space — done
        // last so the removals above don't leave double spaces that defeat the
        // comparison.
        (#"\s+"#, " "),
    ]
}
