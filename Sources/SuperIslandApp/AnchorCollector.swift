import AppKit
import ApplicationServices
import SuperIslandCore

/// A lightweight capture of a navigational AX element, used to identify
/// which in-app tab/conversation is currently selected.
struct CollectedAnchorInfo {
    var role: String
    var label: String
    var isSelected: Bool
}

/// A collected navigational element with its AX element reference.
/// The `.anchor` property provides label/role/isSelected;
/// `.element` is the raw AXUIElement for performing actions (e.g. press).
struct CollectedRestoreAnchor {
    var anchor: CollectedAnchorInfo
    var element: AXUIElement?
}

enum RestoreAnchorCollector {
    /// Labels of all currently selected navigational elements in the window —
    /// the selected in-app tab, sidebar conversation, list row, etc. This is
    /// what distinguishes two drops that share one window (apps like Claude
    /// Desktop or Codex with internal tab mechanisms).
    static func selectedLabels(from window: AXUIElement) -> [String] {
        collect(from: window)
            .filter { $0.anchor.isSelected && !$0.anchor.label.isEmpty }
            .map(\.anchor.label)
    }

    /// The single best "which tab am I on" label: prefers real tab controls
    /// over selected rows/cells, since rows can be selected incidentally.
    static func selectedContextAnchor(from window: AXUIElement) -> String? {
        let selected = collect(from: window)
            .filter { $0.anchor.isSelected && !$0.anchor.label.isEmpty }
        let tabRoles: Set<String> = [
            kAXRadioButtonRole as String, kAXTabGroupRole as String, "AXTab",
        ]
        if let tab = selected.first(where: { tabRoles.contains($0.anchor.role) }) {
            return tab.anchor.label
        }
        return selected.first?.anchor.label
    }

    static func collect(from window: AXUIElement) -> [CollectedRestoreAnchor] {
        var anchors: [CollectedRestoreAnchor] = []
        var nodeBudget = 1200

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 50, nodeBudget > 0 else { return }
            nodeBudget -= 1

            let label = bestLabel(for: element)
            let role = AX.stringAttribute(element, kAXRoleAttribute as String) ?? "AXElement"
            if !label.isEmpty, isNavigational(role: role) {
                let selected =
                    AX.attribute(element, kAXSelectedAttribute as String) as? Bool ?? false
                anchors.append(
                    CollectedRestoreAnchor(
                        anchor: CollectedAnchorInfo(role: role, label: label, isSelected: selected),
                        element: element
                    )
                )
            }

            for child in AX.elementsAttribute(element, kAXChildrenAttribute as String) {
                visit(child, depth: depth + 1)
            }
        }

        visit(window, depth: 0)
        return anchors
    }

    private static func bestLabel(for element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let s = AX.stringAttribute(element, attr as String) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func isNavigational(role: String) -> Bool {
        let roles: Set<String> = [
            kAXButtonRole as String,
            kAXRadioButtonRole as String,
            kAXCheckBoxRole as String,
            kAXTabGroupRole as String,
            kAXStaticTextRole,
            "AXRow",
            "AXCell",
            "AXLink",
            "AXMenuItem",
        ]
        return roles.contains(role)
    }
}
