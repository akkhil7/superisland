import AppKit

/// Plays the alert chime that accompanies a freshly-raised banner. A thin
/// wrapper over a built-in macOS system sound so the call site stays a
/// one-liner. AppKit-only, so it lives in the App layer (never in Core).
enum AlertChime {
    /// The built-in macOS sound used for the chime. "Glass" is a short, clean
    /// tone that reads as a notification without being jarring.
    static let soundName = NSSound.Name("Glass")

    /// Play the chime once. A no-op if the named sound can't be resolved (e.g.
    /// a future macOS that drops it), so a missing sound never crashes.
    static func play() {
        NSSound(named: soundName)?.play()
    }
}
