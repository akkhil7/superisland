// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Klip",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, testable logic. No SwiftUI/AppKit imports so tests stay fast and clean.
        .target(
            name: "KlipCore"
        ),
        // The macOS menu-bar agent: UI + OS integration (AppKit, SwiftUI,
        // ScreenCaptureKit, Vision, Accessibility, AppleScript).
        // Uses the Swift 5 language mode: the AppKit/Carbon/AX integration is
        // inherently main-thread, callback-heavy, and full of non-Sendable OS
        // types, so strict Swift 6 concurrency adds churn without safety here.
        .executableTarget(
            name: "KlipApp",
            dependencies: ["KlipCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KlipCoreTests",
            dependencies: ["KlipCore"]
        ),
    ]
)
