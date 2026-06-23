import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreImage

/// A point-in-time read of a window: its accessibility text and (optionally) a
/// downscaled screenshot. Feeds the change detector, prefilter, and classifier.
struct Snapshot {
    var axText: String
    var screenshotPNG: Data?

    /// Cheap content hash used by the ChangeDetector. Based on text when we
    /// have meaningful text, otherwise on the screenshot bytes.
    var contentHash: Int {
        if axText.count >= 8 { return axText.hashValue }
        if let png = screenshotPNG { return png.count.hashValue ^ png.prefix(512).hashValue }
        return axText.hashValue
    }
}

enum CaptureService {
    /// Max characters of AX text we keep / send.
    static let maxTextLength = 6000

    /// Produce a snapshot for a drop's window. `wantsScreenshot` controls
    /// whether we pay for a ScreenCaptureKit grab (text-first, screenshot when
    /// text is thin or a verdict is being formed).
    /// - Parameter allowScreenshot: master gate. When false we never capture a
    ///   screenshot or run OCR — used for the privacy-friendly text-only mode,
    ///   which lets the app run without the Screen Recording permission.
    static func snapshot(
        pid: pid_t,
        windowID: CGWindowID,
        axWindow: AXUIElement?,
        wantsScreenshot: Bool,
        allowScreenshot: Bool = true
    ) async -> Snapshot {
        var text = axWindow.map { axText(of: $0) } ?? ""

        // Electron apps expose an empty AX tree until AXManualAccessibility is
        // set on them. If the first walk found (almost) nothing, opt in and
        // retry once — this is what makes Claude Desktop, Slack, etc. readable.
        if text.count < 40 {
            AX.enableManualAccessibility(pid: pid)
            if let axWindow { text = axText(of: axWindow) }
        }

        var png: Data?
        // Only ever touch ScreenCaptureKit when screenshots are allowed AND the
        // permission is already granted — calling it while unauthorized is what
        // produces a repeating permission prompt.
        if allowScreenshot, CGPreflightScreenCaptureAccess(), wantsScreenshot || text.count < 40 {
            png = try? await screenshot(windowID: windowID)
        }

        return Snapshot(axText: String(text.prefix(maxTextLength)), screenshotPNG: png)
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

    // MARK: - Screenshot (ScreenCaptureKit)

    enum CaptureError: Error { case windowNotFound, noImage }

    static func screenshot(windowID: CGWindowID) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // Downscale: cap the long edge ~1200px to keep tokens/cost down.
        let scale = min(1.0, 1200.0 / max(scWindow.frame.width, scWindow.frame.height))
        config.width = max(1, Int(scWindow.frame.width * scale))
        config.height = max(1, Int(scWindow.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false  // SuperIsland only ever needs a still image.

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        guard let data = pngData(from: cgImage) else { throw CaptureError.noImage }
        return data
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
