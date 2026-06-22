import Foundation

public struct ChromeBridgeCommand: Codable, Equatable, Sendable {
    public var type: String
    public var tabID: Int
    public var windowID: Int?

    public init(type: String, tabID: Int, windowID: Int?) {
        self.type = type
        self.tabID = tabID
        self.windowID = windowID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case tabID = "tabId"
        case windowID = "windowId"
    }
}

public struct ChromeBridgeHTTPResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var commands: [ChromeBridgeCommand]?
    public var error: String?

    public init(ok: Bool, commands: [ChromeBridgeCommand]? = nil, error: String? = nil) {
        self.ok = ok
        self.commands = commands
        self.error = error
    }
}

public final class ChromeBridgeStateStore: @unchecked Sendable {
    public static let shared = ChromeBridgeStateStore()

    public private(set) var tabs: [Int: ChromeTabState] = [:]
    public private(set) var domSummaries: [Int: ChromeDOMSummary] = [:]
    public private(set) var lastSeenAt: Date?

    private var pendingCommands: [ChromeBridgeCommand] = []
    private var lastActiveTabID: Int?

    public init() {}

    public var isConnected: Bool { isConnected(now: Date()) }

    public func isConnected(now: Date) -> Bool {
        lastSeenAt.map { now.timeIntervalSince($0) < 10 } ?? false
    }

    public func update(event: ChromeBridgeExtensionEvent, now: Date = Date()) {
        lastSeenAt = now
        guard let tab = event.tab else { return }
        tabs[tab.tabID] = tab
        lastActiveTabID = tab.tabID
        if let summary = event.domSummary {
            domSummaries[tab.tabID] = summary
        }
    }

    public func bestActiveTab(matchingTitle title: String) -> ChromeTabState? {
        // The last tab the extension reported can be stale (events lag behind
        // fast tab switches) — only trust it when it agrees with the window
        // title the drop was dropped on.
        if let id = lastActiveTabID, let tab = tabs[id],
           title.isEmpty || titleMatches(tab, windowTitle: title) {
            return tab
        }
        guard !title.isEmpty else { return tabs.values.first }
        return tabs.values.first { titleMatches($0, windowTitle: title) }
    }

    /// Find a tab by exact URL, else by title containment. Used to enrich an
    /// AppleScript-captured tab with the extension's ids (the two live in
    /// DIFFERENT id spaces — AppleScript tab ids never equal extension ids).
    public func tab(matchingURL url: String?, orTitle title: String?) -> ChromeTabState? {
        if let url, !url.isEmpty,
           let hit = tabs.values.first(where: { $0.url == url }) {
            return hit
        }
        if let title, !title.isEmpty {
            return tabs.values.first { titleMatches($0, windowTitle: title) }
        }
        return nil
    }

    private func titleMatches(_ tab: ChromeTabState, windowTitle: String) -> Bool {
        guard let t = tab.title, !t.isEmpty else { return false }
        return windowTitle.contains(t) || t.contains(windowTitle)
    }

    public func enqueueRefocus(tabID: Int, windowID: Int?) {
        pendingCommands.append(
            ChromeBridgeCommand(type: "refocus_tab", tabID: tabID, windowID: windowID)
        )
    }

    public func consumeCommands() -> [ChromeBridgeCommand] {
        let commands = pendingCommands
        pendingCommands.removeAll()
        return commands
    }

    public func handleToolCall(_ call: ChromeBridgeToolCall) -> ChromeBridgeResponse {
        switch call.tool {
        case .listTabs:
            let values = tabs.values.sorted { $0.tabID < $1.tabID }.map { tab in
                JSONValue.object([
                    "tabId": .number(Double(tab.tabID)),
                    "windowId": .number(Double(tab.windowID)),
                    "index": .number(Double(tab.index)),
                    "url": tab.url.map(JSONValue.string) ?? .null,
                    "title": tab.title.map(JSONValue.string) ?? .null,
                    "documentId": tab.documentID.map(JSONValue.string) ?? .null,
                ])
            }
            return .success(id: call.id, result: ["tabs": .array(values)])

        case .captureActiveTabState:
            guard let tab = bestActiveTab(matchingTitle: "") else {
                return .failure(id: call.id, code: -32004, message: "No active tab")
            }
            return .success(id: call.id, result: [
                "tabId": .number(Double(tab.tabID)),
                "windowId": .number(Double(tab.windowID)),
                "url": tab.url.map(JSONValue.string) ?? .null,
                "title": tab.title.map(JSONValue.string) ?? .null,
                "documentId": tab.documentID.map(JSONValue.string) ?? .null,
            ])

        case .captureTabDOMSummary, .getTabStatus:
            guard let tabID = call.arguments["tabId"]?.intValue,
                  let summary = domSummaries[tabID]
            else {
                return .failure(id: call.id, code: -32004, message: "No DOM summary")
            }
            return .success(id: call.id, result: [
                "title": summary.title.map(JSONValue.string) ?? .null,
                "text": summary.text.map(JSONValue.string) ?? .null,
                "taskState": summary.taskState.map { .string($0.rawValue) } ?? .null,
            ])

        case .refocusTab:
            guard let tabID = call.arguments["tabId"]?.intValue else {
                return .failure(id: call.id, code: -32602, message: "tabId is required")
            }
            enqueueRefocus(tabID: tabID, windowID: call.arguments["windowId"]?.intValue)
            return .success(id: call.id, result: ["queued": .bool(true)])

        case .observeTabTask:
            return .success(id: call.id, result: ["observing": .bool(true)])
        }
    }
}
