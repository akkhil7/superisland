import Foundation

/// Decides whether two window targets refer to the SAME tracked thing, so at most
/// one drop is ever created for it — across every integration (Chrome tab,
/// Terminal/iTerm session, editor file, Claude/Codex conversation, plain window).
///
/// Pure and UI-free so it can be unit-tested and shared.
public enum DropIdentity {
    public static func sameTarget(_ a: WindowTarget, _ b: WindowTarget) -> Bool {
        // A non-nil `contentURL` is a unique per-conversation/route key (Electron
        // SPAs, Codex/Claude sessions). It is what lets several tasks share one
        // window while staying distinct, so it takes priority on BOTH sides: two
        // targets with content URLs are the same iff the URLs match, and a target
        // that has one is never the same as one that doesn't.
        if let ua = a.contentURL, let ub = b.contentURL { return ua == ub }
        if (a.contentURL == nil) != (b.contentURL == nil) { return false }

        // Neither has a content URL — compare by locator identity.
        switch (a.locator, b.locator) {
        case let (.chrome(wa, _, _, ta, ua, _, _, _), .chrome(wb, _, _, tb, ub, _, _, _)):
            // The extension tabID is reliable only when windowID != nil (it marks
            // an extension-id-space id; otherwise it's an AppleScript id from a
            // different space). Fall back to the exact URL.
            if wa != nil, wb != nil, let ta, let tb { return ta == tb }
            if let ua, let ub, !ua.isEmpty { return ua == ub }
            return false
        case let (.shell(ta), .shell(tb)):
            return ta == tb
        case let (.terminal(_, _, ta), .terminal(_, _, tb)):
            return ta != nil && ta == tb
        case let (.iterm(sa), .iterm(sb)):
            return sa != nil && sa == sb
        case let (.editor(pa, fa, wsa), .editor(pb, fb, wsb)):
            if let pa, let pb { return pa == pb }  // absolute path is exact
            return fa != nil && fa == fb && wsa == wsb  // else file + workspace
        case (.generic, .generic):
            // No finer key (no route/tab anchor): the same CG window is the same
            // target. A window with distinct in-app tabs carries a contentURL
            // (handled above) or a contextAnchor (kept distinct here).
            return a.windowID == b.windowID && a.contextAnchor == b.contextAnchor
        default:
            return false
        }
    }
}
