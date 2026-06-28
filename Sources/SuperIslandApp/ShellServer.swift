import Foundation
import SuperIslandCore
import Network

// MARK: - Event type

struct ShellEvent: Decodable {
    let event: String  // "register" | "start" | "done"
    let tty: String  // /dev/ttys003
    let cmd: String?
    let exitCode: Int?
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case event, tty, cmd
        case exitCode = "exit_code"
        case duration
    }
}

// MARK: - Server

/// Minimal TCP/HTTP server on localhost:2929 that receives shell hook events
/// from superisland.zsh / superisland.bash.  All public methods must be called on the main queue.
final class ShellServer {
    static let port: UInt16 = 2929

    private var listener: NWListener?

    /// TTYs whose shell sessions have registered with SuperIsland (sent "register" event).
    private(set) var registeredTTYs: Set<String> = []

    /// Called on the main queue whenever a well-formed shell event arrives.
    var onEvent: ((ShellEvent) -> Void)?

    /// Called on the main queue for Claude Code hook events (POST /claude).
    var onClaudeEvent: ((ClaudeHookEvent) -> Void)?

    /// Called on the main queue for Codex hook events (POST /codex) — same
    /// payload shape as Claude hooks.
    var onCodexEvent: ((ClaudeHookEvent) -> Void)?

    /// Called on the main queue for Cursor agent hook events (POST /cursor).
    var onCursorEvent: ((CursorHookEvent) -> Void)?

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: Self.port),
            let l = try? NWListener(using: params, on: p)
        else { return }

        l.newConnectionHandler = { [weak self] conn in
            DispatchQueue.main.async { self?.accept(conn) }
        }
        l.start(queue: .global(qos: .utility))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func isRegistered(tty: String) -> Bool { registeredTTYs.contains(tty) }

    // MARK: - Connection handling (main queue)

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        // One read covers our payloads: shell events are <300 bytes; Claude
        // hook events (incl. prompt text) stay well under this cap.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, _, _ in
            guard let data, !data.isEmpty,
                let str = String(data: data, encoding: .utf8),
                let sep = str.range(of: "\r\n\r\n")
            else { return }

            // Request line: "POST /shell HTTP/1.1" — route on the path.
            let path =
                str.prefix(while: { $0 != "\r" })
                .components(separatedBy: " ")
                .dropFirst().first ?? "/"
            let body = String(str[sep.upperBound...])
            DispatchQueue.main.async { [weak self] in
                self?.dispatch(path: String(path), body: body)
            }

            let resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            connection.send(
                content: resp.data(using: .utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func dispatch(path: String, body: String) {
        guard let data = body.data(using: .utf8) else { return }
        // Hook scripts report the agent's controlling TTY as a query param —
        // the join between a CLI agent session and a terminal drop.
        let hookTTY = HookRequestQuery.normalizeTTY(
            HookRequestQuery.value(of: "tty", inPath: path)
        )
        if path.hasPrefix("/claude") {
            HookDebugLog.log("RAW /claude tty=\(hookTTY ?? "-") body=\(body)")
            if var event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: data) {
                event.tty = hookTTY
                onClaudeEvent?(event)
            } else {
                HookDebugLog.log("  → DECODE FAILED for /claude payload")
            }
            return
        }
        if path.hasPrefix("/codex") {
            if var event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: data) {
                event.tty = hookTTY
                onCodexEvent?(event)
            }
            return
        }
        if path.hasPrefix("/cursor") {
            HookDebugLog.log("RAW /cursor tty=\(hookTTY ?? "-") body=\(body)")
            if var event = try? JSONDecoder().decode(CursorHookEvent.self, from: data) {
                event.tty = hookTTY
                onCursorEvent?(event)
            } else {
                HookDebugLog.log("  → DECODE FAILED for /cursor payload")
            }
            return
        }
        guard let event = try? JSONDecoder().decode(ShellEvent.self, from: data) else { return }
        if event.event == "register" { registeredTTYs.insert(event.tty) }
        onEvent?(event)
    }
}
