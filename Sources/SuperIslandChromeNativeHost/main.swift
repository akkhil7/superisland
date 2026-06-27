import Foundation
import SuperIslandCore

let bridgeURL = URL(string: "http://127.0.0.1:2931/chrome")!

func readNativeMessage() -> Data? {
    let header = FileHandle.standardInput.readData(ofLength: 4)
    guard header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { ptr -> UInt32 in
        ptr.load(as: UInt32.self)
    }
    guard length > 0, length < 1024 * 1024 * 4 else { return nil }
    let body = FileHandle.standardInput.readData(ofLength: Int(length))
    return body.count == Int(length) ? body : nil
}

func writeNativeMessage(_ data: Data) {
    var length = UInt32(data.count)
    let header = Data(bytes: &length, count: 4)
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

func forwardToSuperIsland(_ body: Data) -> Data {
    var request = URLRequest(url: bridgeURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let semaphore = DispatchSemaphore(value: 0)
    var output: Data?
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        output = data
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 2)
    return output ?? Data(#"{"ok":false,"error":"SuperIsland app is not reachable"}"#.utf8)
}

/// True when `body` is a tab event for a non-allowlisted host. `command_poll`
/// and tool-call traffic carry no foreign URL and pass through untouched. This is
/// a cheap early drop that saves a localhost round-trip; the app's bridge server
/// re-checks and is the authoritative boundary.
func hasDisallowedHost(_ body: Data) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let tab = obj["tab"] as? [String: Any]
    else { return false }  // not a tab event we inspect
    return !ChromeHostAllowlist.isAllowed(urlString: tab["url"] as? String)
}

while let message = readNativeMessage() {
    if hasDisallowedHost(message) {
        writeNativeMessage(Data(#"{"ok":false,"error":"rejected: host not allowlisted"}"#.utf8))
        continue
    }
    writeNativeMessage(forwardToSuperIsland(message))
}
