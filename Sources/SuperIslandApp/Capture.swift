import AppKit
import ApplicationServices
import SuperIslandCore

/// A point-in-time read of a window: its accessibility text.
/// Feeds the change detector, prefilter, and classifier.
struct Snapshot {
    var axText: String

    /// Cheap content hash used by the ChangeDetector. Normalized so cosmetic
    /// churn (relative timestamps, wall-clock times, whitespace) doesn't read
    /// as a content change — otherwise a *settled* drop, re-sampled often,
    /// would re-classify and flip-flop every few seconds. See `ContentDigest`.
    var contentHash: Int {
        ContentDigest.hash(axText)
    }
}

enum CaptureService {
    /// Max characters of AX text we keep / send.
    static let maxTextLength = 6000

    /// Produce a snapshot for a drop's window (AX text only).
    static func snapshot(
        pid: pid_t,
        windowID: CGWindowID,
        axWindow: AXUIElement?
    ) async -> Snapshot {
        var text = axWindow.map { axText(of: $0) } ?? ""

        // Electron apps expose an empty AX tree until AXManualAccessibility is
        // set on them. If the first walk found (almost) nothing, opt in and
        // retry once — this is what makes Claude Desktop, Slack, etc. readable.
        if text.count < 40 {
            AX.enableManualAccessibility(pid: pid)
            if let axWindow { text = axText(of: axWindow) }
        }

        return Snapshot(axText: String(text.prefix(maxTextLength)))
    }

    // MARK: - Accessibility text

    /// Walk the window's AX subtree collecting visible text. Bounded in depth,
    /// node count, and total length to stay cheap.
    static func axText(of window: AXUIElement) -> String {
        var pieces: [String] = []
        var seen = Set<String>()
        var nodeBudget = 4000

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 60, nodeBudget > 0 else { return }
            nodeBudget -= 1

            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = AX.stringAttribute(element, attr as String) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 2, !seen.contains(trimmed) {
                        seen.insert(trimmed)
                        pieces.append(trimmed)
                    }
                }
            }
            for child in AX.elementsAttribute(element, kAXChildrenAttribute as String) {
                visit(child, depth: depth + 1)
            }
        }

        visit(window, depth: 0)
        return pieces.joined(separator: "\n")
    }
}
