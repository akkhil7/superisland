import Foundation
import SuperIslandCore
import Network

/// Local HTTP endpoint used by the native messaging host. The Chrome extension
/// talks to `SuperIslandChromeNativeHost`; that helper forwards messages here so the
/// running menu-bar app owns tab state and command queues.
final class ChromeBridgeServer {
    static let port: UInt16 = 2931

    private var listener: NWListener?
    private let registry = ChromeBridgeStateStore.shared

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

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let data,
                  let str = String(data: data, encoding: .utf8),
                  let sep = str.range(of: "\r\n\r\n")
            else { return }

            let body = Data(str[sep.upperBound...].utf8)
            DispatchQueue.main.async { [weak self] in
                let payload = self?.handle(body: body) ?? Self.responseData(
                    ChromeBridgeHTTPResponse(ok: false, commands: nil, error: "bridge unavailable")
                )
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(header.utf8) + payload,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
    }

    private func handle(body: Data) -> Data {
        if let call = try? JSONDecoder().decode(ChromeBridgeToolCall.self, from: body) {
            return handleToolCall(call)
        }
        guard let event = try? JSONDecoder().decode(ChromeBridgeExtensionEvent.self, from: body) else {
            return Self.responseData(
                ChromeBridgeHTTPResponse(ok: false, commands: nil, error: "malformed chrome bridge message")
            )
        }

        if event.type == .commandPoll {
            return Self.responseData(
                ChromeBridgeHTTPResponse(ok: true, commands: registry.consumeCommands(), error: nil)
            )
        }

        registry.update(event: event)
        return Self.responseData(ChromeBridgeHTTPResponse(ok: true, commands: [], error: nil))
    }

    private func handleToolCall(_ call: ChromeBridgeToolCall) -> Data {
        response(registry.handleToolCall(call))
    }

    private func response(_ response: ChromeBridgeResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data(#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"encode error"}}"#.utf8)
    }

    private static func responseData(_ response: ChromeBridgeHTTPResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"error":"encode error"}"#.utf8)
    }
}
