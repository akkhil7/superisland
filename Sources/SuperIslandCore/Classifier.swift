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
    public var status: DropStatus
    public var reason: String
    public var confidence: Double
    /// Short AI-generated label for the task (≤5 words). nil if not provided.
    public var label: String?

    public init(status: DropStatus, reason: String, confidence: Double, label: String? = nil) {
        self.status = status
        self.reason = reason
        self.confidence = confidence
        self.label = label
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
    public static let defaultModel = "claude-haiku-4-5"
    public static let apiVersion = "2023-06-01"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public static let systemPrompt = """
        You monitor a single application window on a user's Mac to tell them when a \
        long-running task needs them. Classify the window's CURRENT state into exactly one of:
        - "working": a task is actively running or producing output.
        - "needsAttention": a task ran, then stopped, and is now explicitly waiting for \
        the user — a question, confirmation, password prompt, or blocking error.
        - "done": a task finished successfully and needs nothing further.
        - "unknown": no task evidence — an empty or idle window with no preceding \
        command output, a fresh terminal, or a state you genuinely cannot read.

        CRITICAL: A bare shell prompt ($, %, >, ➜, or similar) with NO preceding command \
        output means no task was ever running — classify as "unknown", NOT "needsAttention". \
        Only classify "needsAttention" if you can see actual task output followed by a \
        question or input request. An idle shell after output means "done".

        If a screenshot is provided, read the task state from the screenshot — it is \
        the primary evidence when the window text is thin or missing. For AI-assistant \
        apps (Claude, ChatGPT, Cursor, …): a streaming/typing response or a visible \
        stop button means "working"; a completed response means "done"; a permission \
        or confirmation dialog means "needsAttention".

        For AI coding editors (Cursor, VS Code with an agent/chat panel): judge by the \
        agent panel, not the code. An agent generating, running tools, or applying edits \
        means "working". The agent asking ANYTHING of the user — approve a command, \
        accept/reject edits, answer a question, provide more information or input — \
        means "needsAttention". A finished agent response with no pending request means \
        "done". Plain code editing with no agent activity means "unknown".

        Also generate a "label": a ≤5-word title describing what the task IS (not its status). \
        Examples: "npm build", "pytest suite", "git push origin", "Claude agent", "Docker image build". \
        If there is no discernible task, use a short app description like "Terminal session".

        Respond with ONLY a JSON object, no prose, no markdown fences:
        {"status": "...", "reason": "<=12 words", "label": "<=5 words", "confidence": 0.0-1.0}
        """

    /// Focused classifier prompt for the END of a Claude Code turn. The general
    /// `systemPrompt` monitors arbitrary windows (shells, editors, screenshots)
    /// and misreads a bare assistant message — it flagged a friendly sign-off as
    /// "needsAttention". This prompt judges ONE thing: given the assistant's
    /// final message, must the user reply for it to continue? Validated against
    /// real turn-endings (sign-offs → done, questions → needsAttention, code
    /// `?` ignored).
    public static let turnEndSystemPrompt = """
        You are a status classifier for an AI coding assistant (e.g. Claude Code) \
        running in a terminal. You are given ONLY the assistant's final message to \
        the user at the end of its turn. Decide what, if anything, the user must do now.

        Output exactly one status:
        - "needsAttention": the assistant is blocked on the user. It asks a direct \
        question, requests a decision/approval/confirmation, asks for missing \
        information, or reports an error or condition the user must resolve before \
        work can continue. The user MUST reply or act for the assistant to proceed.
        - "done": the assistant has finished its turn and needs nothing to proceed. \
        Includes completed work, summaries/status reports ("all tests pass", \
        "rebuilt and relaunched"), and friendly sign-offs or idle pleasantries \
        ("let me know if you need anything", "ping me whenever", "have a great \
        one"). A polite OPTIONAL offer of future help is "done", not "needsAttention".
        - "working": the assistant says it is still actively doing something right \
        now (rare in a final message).

        Decision rule: pick "needsAttention" ONLY if the assistant cannot continue \
        without a user reply. If it could simply stop here owing nothing, pick \
        "done". If the message both reports completion AND asks a question, the \
        question wins → "needsAttention". Ignore questions that appear inside code \
        (backticks or code blocks).

        Also produce "label": a <=5-word description of the task (not its status).

        Respond with ONLY a JSON object, no prose, no markdown fences:
        {"status":"...","reason":"<=12 words","label":"<=5 words","confidence":0.0-1.0}
        """

    /// Request body for classifying a Claude turn-end message with the focused
    /// `turnEndSystemPrompt`. The message is the sole user text block.
    public static func turnEndRequestBody(message: String, model: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 256,
            "system": turnEndSystemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Assistant's final message:\n\n\(message)"]
                    ],
                ]
            ],
        ]
    }

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
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": content]
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

        let text =
            contentBlocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        guard let obj = extractJSONObject(from: text) else {
            throw ClassifierError.malformedResponse
        }

        let statusRaw = (obj["status"] as? String) ?? "unknown"
        let status = DropStatus(rawValue: statusRaw) ?? .unknown
        let reason = (obj["reason"] as? String) ?? ""
        let confidence =
            (obj["confidence"] as? Double)
            ?? (obj["confidence"] as? NSNumber)?.doubleValue
            ?? 0.0
        let label = obj["label"] as? String
        return Classification(status: status, reason: reason, confidence: confidence, label: label)
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
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
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
        return try await send(body)
    }

    /// Classify the END of a Claude Code turn from the assistant's final message
    /// alone, using the focused `turnEndSystemPrompt`.
    public func classifyTurnEndMessage(_ message: String) async throws -> Classification {
        guard let apiKey, !apiKey.isEmpty else { throw ClassifierError.missingAPIKey }
        let body = ClassifierProtocolBuilder.turnEndRequestBody(message: message, model: model)
        return try await send(body)
    }

    private func send(_ body: [String: Any]) async throws -> Classification {
        guard let apiKey, !apiKey.isEmpty else { throw ClassifierError.missingAPIKey }

        var request = URLRequest(url: ClassifierProtocolBuilder.endpoint)
        request.httpMethod = "POST"
        // Cap a single classify call: the default URLRequest timeout is 60s, so
        // one hung request would itself stall a verdict for ~a minute. A Haiku
        // classification returns in a second or two; 20s is generous headroom.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(
            ClassifierProtocolBuilder.apiVersion, forHTTPHeaderField: "anthropic-version")
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
