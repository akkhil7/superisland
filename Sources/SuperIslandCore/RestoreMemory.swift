import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func distance(to other: NormalizedRect) -> Double {
        abs(x - other.x)
            + abs(y - other.y)
            + abs(width - other.width)
            + abs(height - other.height)
    }
}

public enum RestoreAnchorSource: String, Codable, Sendable {
    case accessibility
    case ocr
}

public struct RestoreAnchor: Codable, Equatable, Sendable {
    public var id: String
    public var source: RestoreAnchorSource
    public var role: String
    public var label: String
    public var frame: NormalizedRect
    public var isSelected: Bool

    public init(
        id: String,
        source: RestoreAnchorSource,
        role: String,
        label: String,
        frame: NormalizedRect,
        isSelected: Bool
    ) {
        self.id = id
        self.source = source
        self.role = role
        self.label = label
        self.frame = frame
        self.isSelected = isSelected
    }
}

public struct RestoreMemory: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var appName: String
    public var bundleID: String
    public var windowTitle: String
    public var screenshotFilename: String?
    public var anchors: [RestoreAnchor]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        appName: String,
        bundleID: String,
        windowTitle: String,
        screenshotFilename: String?,
        anchors: [RestoreAnchor]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.screenshotFilename = screenshotFilename
        self.anchors = anchors
    }
}

public struct RestoreSuggestion: Codable, Equatable, Sendable {
    public var rememberedAnchorID: String
    public var targetAnchorID: String
    public var confidence: Double
    public var frame: NormalizedRect

    public init(
        rememberedAnchorID: String,
        targetAnchorID: String,
        confidence: Double,
        frame: NormalizedRect
    ) {
        self.rememberedAnchorID = rememberedAnchorID
        self.targetAnchorID = targetAnchorID
        self.confidence = confidence
        self.frame = frame
    }
}

public enum RestoreMatcher {
    public static func suggest(
        remembered: [RestoreAnchor],
        current: [RestoreAnchor],
        minimumConfidence: Double = 0.85
    ) -> RestoreSuggestion? {
        var candidates: [(remembered: RestoreAnchor, current: RestoreAnchor, score: Double)] = []

        for old in remembered where isUseful(old) {
            for new in current where isUseful(new) {
                let score = score(remembered: old, current: new)
                if score >= minimumConfidence {
                    candidates.append((old, new, score))
                }
            }
        }

        let sorted = candidates.sorted { $0.score > $1.score }
        guard let best = sorted.first else { return nil }
        if sorted.count > 1, let second = sorted.dropFirst().first,
           best.score - second.score < 0.05 {
            return nil
        }
        return RestoreSuggestion(
            rememberedAnchorID: best.remembered.id,
            targetAnchorID: best.current.id,
            confidence: best.score,
            frame: best.current.frame
        )
    }

    private static func isUseful(_ anchor: RestoreAnchor) -> Bool {
        !anchor.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func score(remembered: RestoreAnchor, current: RestoreAnchor) -> Double {
        let oldLabel = normalized(remembered.label)
        let newLabel = normalized(current.label)
        guard !oldLabel.isEmpty, !newLabel.isEmpty else { return 0 }

        var score = 0.0
        if oldLabel == newLabel {
            score += 0.45
        } else if oldLabel.contains(newLabel) || newLabel.contains(oldLabel) {
            score += 0.25
        } else {
            return 0
        }

        if remembered.role == current.role { score += 0.20 }
        if remembered.source == current.source { score += 0.05 }
        if remembered.isSelected { score += 0.10 }

        let frameDistance = remembered.frame.distance(to: current.frame)
        score += max(0, 0.20 * (1 - min(frameDistance / 0.20, 1)))

        return min(score, 1.0)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

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
}
