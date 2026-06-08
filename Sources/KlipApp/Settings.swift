import Foundation
import Combine
import KlipCore

/// User-tunable settings, backed by UserDefaults (and Keychain for the API key).
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    /// Seconds the window must be quiet before we evaluate.
    @Published var settleInterval: Double {
        didSet { defaults.set(settleInterval, forKey: Keys.settle) }
    }
    /// Seconds between cheap polls of each klipped window.
    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Keys.poll) }
    }
    /// Long fallback interval that forces an evaluation.
    @Published var fallbackInterval: Double {
        didSet { defaults.set(fallbackInterval, forKey: Keys.fallback) }
    }
    /// Whether to capture window screenshots (needs Screen Recording). Off by
    /// default so Klip runs text-only — no Screen Recording permission, no
    /// prompts — unless the user opts in for better classification accuracy.
    @Published var useScreenshots: Bool {
        didSet { defaults.set(useScreenshots, forKey: Keys.useScreenshots) }
    }
    /// Whether an API key is present (mirrors Keychain; for UI display).
    @Published var hasAPIKey: Bool

    enum Keys {
        static let model = "model"
        static let settle = "settleInterval"
        static let poll = "pollInterval"
        static let fallback = "fallbackInterval"
        static let useScreenshots = "useScreenshots"
    }

    init() {
        model = defaults.string(forKey: Keys.model) ?? ClassifierProtocolBuilder.defaultModel
        settleInterval = defaults.object(forKey: Keys.settle) as? Double ?? 6
        pollInterval = defaults.object(forKey: Keys.poll) as? Double ?? 5
        fallbackInterval = defaults.object(forKey: Keys.fallback) as? Double ?? 180
        useScreenshots = defaults.object(forKey: Keys.useScreenshots) as? Bool ?? false
        hasAPIKey = (Keychain.apiKey()?.isEmpty == false)
    }

    func setAPIKey(_ key: String) {
        Keychain.setAPIKey(key)
        hasAPIKey = !key.isEmpty
    }

    func apiKey() -> String? { Keychain.apiKey() }

    /// Available models for the picker. Opus is the accurate default; Haiku is
    /// the cheap/fast option for frequent checks.
    static let availableModels = [
        "claude-opus-4-8",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
    ]
}
