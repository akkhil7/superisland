import Foundation

/// Buckets a collection of drops by lifecycle state — the source of truth for
/// the island's two counter orbs. Keeping this in Core (rather than inline in
/// the SwiftUI view) makes the orb counts unit-testable and pins the invariant
/// that the right orb counts *only* tasks waiting on the user.
extension Collection where Element == Drop {
    /// Left counter orb: drops still doing work (`working` / `unknown`). Settled
    /// (`done` / `needsAttention`) and `stale` drops are not in progress.
    public var inProgress: [Drop] {
        filter { $0.status == .working || $0.status == .unknown }
    }

    /// Right counter orb: drops explicitly waiting on the user (`needsAttention`
    /// only). Completed (`done`) drops are deliberately *not* counted here.
    public var needsAttention: [Drop] {
        filter { $0.status == .needsAttention }
    }

    /// Completed drops (`done`) — surfaced in the expanded list, never in the
    /// right orb's count.
    public var done: [Drop] {
        filter { $0.status == .done }
    }

    /// Everything resting that you might still act on: needs-attention followed
    /// by done. Backs the expanded list and the right orb's *tint*, not its
    /// count.
    public var needsYou: [Drop] {
        needsAttention + done
    }
}
