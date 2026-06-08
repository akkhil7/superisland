import Foundation

/// Input to the cloud classifier: the window's text and (optionally) a
/// screenshot, plus light metadata to ground the model.
public struct ClassificationInput: Sendable {
    public var appName: String
    public var windowTitle: String
    public var axText: String
    /// Downscaled PNG screenshot, when text alone is insufficient.
    public var screenshotPNG: Data?

    public init(appName: String, windowTitle: String, axText: String, screenshotPNG: Data? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.axText = axText
        self.screenshotPNG = screenshotPNG
    }
}

/// The classifier's verdict.
public struct Classification: Equatable, Sendable {
    public var status: KlipStatus
    public var reason: String
    public var confidence: Double

    public init(status: KlipStatus, reason: String, confidence: Double) {
        self.status = status
        self.reason = reason
        self.confidence = confidence
    }
}

public enum ClassifierError: Error, Equatable {
    case missingAPIKey
    case http(status: Int, body: String)
    case malformedResponse
    case transport(String)
}

/// Builds the Anthropic Messages API request and parses the response.
///
/// Both halves are pure functions so they can be unit-tested without a
/// network call. `ClaudeClassifier` wraps them with `URLSession`.
public enum ClassifierProtocolBuilder {
    /// Default model. Per Anthropic guidance we default to the latest Opus;
    /// the app exposes this in Settings so the user can pick a cheaper model
    /// (e.g. `claude-haiku-4-5`) for high-frequency checks.
    public static let defaultModel = "claude-opus-4-8"
    public static let apiVersion = "2023-06-01"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public static let systemPrompt = """
    You monitor a single application window on a user's Mac to tell them when a \
    long-running task needs them. Classify the window's CURRENT state into exactly one of:
    - "working": the task is still running / producing output / mid-progress.
    - "needsAttention": the task has stopped and is waiting for the user — a prompt, \
    a question, a confirmation, a password/input field, or a blocking error the user must resolve.
    - "done": the task has finished successfully and needs nothing further.
    - "unknown": you genuinely cannot tell.

    Judge only the latest visible state, not scrollback history. A shell sitting at an \
    idle prompt after output usually means "done". A visible question or input request \
    means "needsAttention".

    Respond with ONLY a JSON object, no prose, no markdown fences:
    {"status": "...", "reason": "<=12 words", "confidence": 0.0-1.0}
    """

    /// Build the JSON request body. `screenshotBase64` is the base64 of a PNG, if any.
    public static func requestBody(
        for input: ClassificationInput,
        model: String,
        screenshotBase64: String?
    ) -> [String: Any] {
        var content: [[String: Any]] = []

        if let b64 = screenshotBase64 {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": b64,
                ],
            ])
        }

        let header = "App: \(input.appName)\nWindow: \(input.windowTitle)"
        let text = """
        \(header)

        Window text (may be truncated):
        \(input.axText)
        """
        content.append(["type": "text", "text": text])

        return [
            "model": model,
            "max_tokens": 200,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": content],
            ],
        ]
    }

    /// Parse the Anthropic Messages API success body into a `Classification`.
    /// Tolerant of the model wrapping JSON in prose or code fences.
    public static func parse(responseData: Data) throws -> Classification {
        guard
            let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let contentBlocks = root["content"] as? [[String: Any]]
        else { throw ClassifierError.malformedResponse }

        let text = contentBlocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        guard let obj = extractJSONObject(from: text) else {
            throw ClassifierError.malformedResponse
        }

        let statusRaw = (obj["status"] as? String) ?? "unknown"
        let status = KlipStatus(rawValue: statusRaw) ?? .unknown
        let reason = (obj["reason"] as? String) ?? ""
        let confidence = (obj["confidence"] as? Double)
            ?? (obj["confidence"] as? NSNumber)?.doubleValue
            ?? 0.0
        return Classification(status: status, reason: reason, confidence: confidence)
    }

    /// Find the first balanced `{...}` JSON object in arbitrary text and decode it.
    static func extractJSONObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let c = text[idx]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    let slice = String(text[start...idx])
                    if let data = slice.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return obj
                    }
                    return nil
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

/// Live classifier that talks to the Anthropic API over HTTPS.
public struct ClaudeClassifier: Sendable {
    public var apiKey: String?
    public var model: String

    public init(apiKey: String?, model: String = ClassifierProtocolBuilder.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    public func classify(_ input: ClassificationInput) async throws -> Classification {
        guard let apiKey, !apiKey.isEmpty else { throw ClassifierError.missingAPIKey }

        let b64 = input.screenshotPNG?.base64EncodedString()
        let body = ClassifierProtocolBuilder.requestBody(
            for: input, model: model, screenshotBase64: b64
        )

        var request = URLRequest(url: ClassifierProtocolBuilder.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClassifierProtocolBuilder.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClassifierError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClassifierError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClassifierError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try ClassifierProtocolBuilder.parse(responseData: data)
    }
}
