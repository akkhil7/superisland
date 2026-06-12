import XCTest
@testable import KlipCore

final class RestoreMatcherTests: XCTestCase {
    func testMatchesRememberedSelectedVisibleAnchor() {
        let remembered = RestoreAnchor(
            id: "t0-sidebar-project",
            source: .accessibility,
            role: "AXButton",
            label: "macOS task status tracking app",
            frame: NormalizedRect(x: 0.02, y: 0.22, width: 0.14, height: 0.04),
            isSelected: true
        )
        let current = RestoreAnchor(
            id: "current-sidebar-project",
            source: .accessibility,
            role: "AXButton",
            label: "macOS task status tracking app",
            frame: NormalizedRect(x: 0.025, y: 0.225, width: 0.14, height: 0.04),
            isSelected: false
        )

        let suggestion = RestoreMatcher.suggest(
            remembered: [remembered],
            current: [current]
        )

        XCTAssertEqual(suggestion?.targetAnchorID, "current-sidebar-project")
        XCTAssertGreaterThanOrEqual(suggestion?.confidence ?? 0, 0.85)
    }

    func testReturnsNilForAmbiguousDuplicateAnchors() {
        let remembered = RestoreAnchor(
            id: "t0-add",
            source: .accessibility,
            role: "AXButton",
            label: "Add",
            frame: NormalizedRect(x: 0.10, y: 0.10, width: 0.05, height: 0.03),
            isSelected: false
        )
        let current = [
            RestoreAnchor(
                id: "current-add-1",
                source: .accessibility,
                role: "AXButton",
                label: "Add",
                frame: NormalizedRect(x: 0.10, y: 0.10, width: 0.05, height: 0.03),
                isSelected: false
            ),
            RestoreAnchor(
                id: "current-add-2",
                source: .accessibility,
                role: "AXButton",
                label: "Add",
                frame: NormalizedRect(x: 0.11, y: 0.10, width: 0.05, height: 0.03),
                isSelected: false
            ),
        ]

        XCTAssertNil(RestoreMatcher.suggest(remembered: [remembered], current: current))
    }
}
