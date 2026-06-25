import AppKit
import SwiftUI
import SuperIslandCore

/// Hosts the diagnostics log viewer in a standard window. Reused across opens.
@MainActor
final class LogsWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: LogsView().environmentObject(DiagnosticLogger.shared))
        let w = NSWindow(contentViewController: hosting)
        w.title = "SuperIsland Diagnostics"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 760, height: 480))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
}

/// Read-only diagnostics viewer: category filter, live auto-scroll, copy/clear.
struct LogsView: View {
    @EnvironmentObject var logger: DiagnosticLogger
    @State private var filter: DiagnosticCategory?

    private var entries: [DiagnosticEntry] { logger.buffer.filtered(filter) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    Text("All").tag(DiagnosticCategory?.none)
                    ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                        Text(category.rawValue.capitalized).tag(DiagnosticCategory?.some(category))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                Spacer()
                Text("launch \(logger.launchID) · \(entries.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy") { copyAll() }
                Button("Clear") { logger.clear() }
                Button("Reveal Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLogger.fileURL])
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            Text(DiagnosticFormat.line(entry))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: entry.category))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.indices.last {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private func copyAll() {
        let text = entries.map { DiagnosticFormat.line($0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func color(for category: DiagnosticCategory) -> Color {
        switch category {
        case .error: return .red
        case .auth: return .purple
        case .proxy: return .blue
        case .monitor: return .teal
        case .hooks: return .orange
        case .app: return .secondary
        }
    }
}
