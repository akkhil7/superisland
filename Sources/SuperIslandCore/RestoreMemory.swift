import Foundation

public enum RestoreMatcher {
    /// Loose equality for UI labels: tolerant of casing, whitespace, and the
    /// truncation apps apply to long tab titles ("My conversation ab…").
    /// Used to recognize a drop's in-app tab among the currently selected
    /// elements of its window.
    public static func labelsMatch(_ a: String, _ b: String) -> Bool {
        var na = normalized(a).replacingOccurrences(of: "…", with: "")
        var nb = normalized(b).replacingOccurrences(of: "…", with: "")
        na = na.trimmingCharacters(in: .whitespaces)
        nb = nb.trimmingCharacters(in: .whitespaces)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if na.contains(nb) || nb.contains(na) { return true }
        // Both truncated differently: a long shared prefix is decisive.
        return na.commonPrefix(with: nb).count >= 16
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}
