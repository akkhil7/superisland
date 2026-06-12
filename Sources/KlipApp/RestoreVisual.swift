import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import ImageIO
import KlipCore
import SwiftUI
@preconcurrency import Vision

struct CollectedRestoreAnchor {
    var anchor: RestoreAnchor
    var element: AXUIElement?
    var absoluteFrame: CGRect?
}

enum RestoreAnchorCollector {
    /// Labels of all currently selected navigational elements in the window —
    /// the selected in-app tab, sidebar conversation, list row, etc. This is
    /// what distinguishes two klips that share one window (apps like Claude
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
        let windowFrame = frame(of: window) ?? NSScreen.main?.frame ?? .zero
        var anchors: [CollectedRestoreAnchor] = []
        var nodeBudget = 1200
        var index = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 50, nodeBudget > 0 else { return }
            nodeBudget -= 1
            defer { index += 1 }

            let label = bestLabel(for: element)
            let role = AX.stringAttribute(element, kAXRoleAttribute as String) ?? "AXElement"
            let rect = frame(of: element)
            if let rect, !label.isEmpty, isNavigational(role: role) {
                anchors.append(
                    CollectedRestoreAnchor(
                        anchor: RestoreAnchor(
                            id: "ax-\(index)",
                            source: .accessibility,
                            role: role,
                            label: label,
                            frame: normalize(rect, in: windowFrame),
                            isSelected: boolAttribute(element, kAXSelectedAttribute as String) ?? false
                        ),
                        element: element,
                        absoluteFrame: rect
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

    static func ocrAnchors(from png: Data?) async -> [CollectedRestoreAnchor] {
        guard let png,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let anchors = observations.enumerated().compactMap { idx, observation -> CollectedRestoreAnchor? in
                    guard let text = observation.topCandidates(1).first?.string,
                          text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                    else { return nil }
                    let box = observation.boundingBox
                    return CollectedRestoreAnchor(
                        anchor: RestoreAnchor(
                            id: "ocr-\(idx)",
                            source: .ocr,
                            role: "OCRText",
                            label: text,
                            frame: KlipCore.NormalizedRect(
                                x: box.origin.x,
                                y: box.origin.y,
                                width: box.width,
                                height: box.height
                            ),
                            isSelected: false
                        ),
                        element: nil,
                        absoluteFrame: nil
                    )
                }
                continuation.resume(returning: anchors)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image)
            DispatchQueue.global(qos: .utility).async {
                try? handler.perform([request])
            }
        }
    }

    static func normalize(_ rect: CGRect, in windowFrame: CGRect) -> KlipCore.NormalizedRect {
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return KlipCore.NormalizedRect(x: 0, y: 0, width: 0, height: 0)
        }
        return KlipCore.NormalizedRect(
            x: Double((rect.minX - windowFrame.minX) / windowFrame.width),
            y: Double((rect.minY - windowFrame.minY) / windowFrame.height),
            width: Double(rect.width / windowFrame.width),
            height: Double(rect.height / windowFrame.height)
        )
    }

    static func denormalize(_ rect: KlipCore.NormalizedRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + CGFloat(rect.x) * windowFrame.width,
            y: windowFrame.minY + CGFloat(rect.y) * windowFrame.height,
            width: CGFloat(rect.width) * windowFrame.width,
            height: CGFloat(rect.height) * windowFrame.height
        )
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = AX.attribute(element, kAXPositionAttribute as String),
              let sizeValue = AX.attribute(element, kAXSizeAttribute as String)
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        let positionOK = AXValueGetValue((positionValue as! AXValue), .cgPoint, &point)
        let sizeOK = AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
        guard positionOK, sizeOK, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
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

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        AX.attribute(element, name) as? Bool
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

struct RestoreMemoryEnvelope: Codable {
    var memory: RestoreMemory
    var screenshotPNG: Data?
}

final class RestoreMemoryStore {
    private static let keyAccount = "restore-memory-key"
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("Klip", isDirectory: true)
                .appendingPathComponent("RestoreMemory", isDirectory: true)
        }
    }

    func save(memory: RestoreMemory, screenshotPNG: Data?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = RestoreMemoryEnvelope(memory: memory, screenshotPNG: screenshotPNG)
        let payload = try encoder.encode(envelope)
        let sealed = try AES.GCM.seal(payload, using: key())
        guard let combined = sealed.combined else {
            throw NSError(domain: "KlipRestoreMemory", code: -1)
        }
        try combined.write(to: url(for: memory.id), options: Data.WritingOptions.atomic)
    }

    func load(id: UUID) throws -> RestoreMemoryEnvelope {
        let data = try Data(contentsOf: url(for: id))
        let box = try AES.GCM.SealedBox(combined: data)
        let payload = try AES.GCM.open(box, using: key())
        return try decoder.decode(RestoreMemoryEnvelope.self, from: payload)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).kliprestore")
    }

    private func key() throws -> SymmetricKey {
        if let data = Keychain.data(account: Self.keyAccount), data.count == 32 {
            return SymmetricKey(data: data)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "KlipRestoreMemory", code: Int(status))
        }
        let data = Data(bytes)
        Keychain.setData(data, account: Self.keyAccount)
        return SymmetricKey(data: data)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

@MainActor
final class RestoreGuidanceManager {
    private let store: RestoreMemoryStore
    private var overlay: RestoreSuggestionOverlayController?

    init(store: RestoreMemoryStore = RestoreMemoryStore()) {
        self.store = store
    }

    func captureMemory(id: UUID, target: WindowTarget) async {
        guard IntegrationRouter.allowsVisualRestore(
            locator: target.locator,
            bundleID: target.bundleID
        ) else { return }
        guard let axWindow = WindowFinder.axWindow(pid: target.pid, windowID: target.windowID) else {
            return
        }

        let snapshot = await CaptureService.snapshot(
            pid: target.pid,
            windowID: target.windowID,
            axWindow: axWindow,
            wantsScreenshot: true,
            allowScreenshot: true
        )
        let axAnchors = RestoreAnchorCollector.collect(from: axWindow)
        let ocrAnchors = await RestoreAnchorCollector.ocrAnchors(from: snapshot.screenshotPNG)
        let memory = RestoreMemory(
            id: id,
            appName: target.appName,
            bundleID: target.bundleID,
            windowTitle: target.windowTitle,
            screenshotFilename: nil,
            anchors: (axAnchors + ocrAnchors).map(\.anchor)
        )

        try? store.save(memory: memory, screenshotPNG: snapshot.screenshotPNG)
    }

    func suggestRestore(for klip: Klip) async {
        guard let id = klip.restoreMemoryID,
              IntegrationRouter.allowsVisualRestore(
                locator: klip.target.locator,
                bundleID: klip.target.bundleID
              ),
              let envelope = try? store.load(id: id),
              let axWindow = WindowFinder.axWindow(
                pid: klip.target.pid,
                windowID: klip.target.windowID
              )
        else { return }

        let snapshot = await CaptureService.snapshot(
            pid: klip.target.pid,
            windowID: klip.target.windowID,
            axWindow: axWindow,
            wantsScreenshot: true,
            allowScreenshot: true
        )
        let axAnchors = RestoreAnchorCollector.collect(from: axWindow)
        let ocrAnchors = await RestoreAnchorCollector.ocrAnchors(from: snapshot.screenshotPNG)
        let current = axAnchors + ocrAnchors
        guard let suggestion = RestoreMatcher.suggest(
            remembered: envelope.memory.anchors,
            current: current.map(\.anchor)
        ) else { return }

        let windowFrame = RestoreAnchorCollector.frame(of: axWindow) ?? NSScreen.main?.frame ?? .zero
        guard let match = current.first(where: { $0.anchor.id == suggestion.targetAnchorID }) else {
            return
        }
        let frame = match.absoluteFrame ?? RestoreAnchorCollector.denormalize(suggestion.frame, in: windowFrame)
        // Close any previous suggestion first — dropping the reference without
        // closing leaks an undismissable panel that keeps blocking clicks.
        overlay?.dismiss()
        let controller = RestoreSuggestionOverlayController()
        controller.show(frame: frame, label: match.anchor.label) {
            if let element = match.element,
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return
            }
            Self.click(frame.center)
        }
        overlay = controller
    }

    private static func click(_ point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
final class RestoreSuggestionOverlayController {
    private var panel: NSPanel?
    private var autoDismissTask: Task<Void, Never>?

    func show(frame: CGRect, label: String, onClick: @escaping () -> Void) {
        dismiss()

        let outer = frame.insetBy(dx: -10, dy: -36)
        let panel = NSPanel(
            contentRect: outer,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RestoreSuggestionOverlayView(
            label: label,
            onClick: { [weak self] in
                onClick()
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        self.panel = panel

        // Safety net: a suggestion the user ignores must never linger as an
        // invisible click-blocker.
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.dismiss()
        }
    }

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.close()
        panel = nil
    }
}

struct RestoreSuggestionOverlayView: View {
    let label: String
    let onClick: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button("Click") { onClick() }
                    .keyboardShortcut(.defaultAction)
                Button("Dismiss") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.black.opacity(0.82))
            )
            .foregroundStyle(.white)
            .help(label)

            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 3)
                .shadow(color: Color.accentColor.opacity(0.8), radius: 8)
        }
        .padding(2)
    }
}
