import Foundation

/// Public Supabase configuration. The anon key and project URL are designed to
/// be shipped in clients; no secret lives here.
enum BackendConfig {
    static let supabaseURL = URL(string: "https://dnybgtyvqflisttbhoqw.supabase.co")!
    static let anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRueWJndHl2cWZsaXN0dGJob3F3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzMTQ1ODYsImV4cCI6MjA5Nzg5MDU4Nn0.u-9RLPsOfxyyWd_09z2T6luHgjHBek_LK3zgCkAHGgI"
    /// OAuth redirect target. A hosted success page (not the raw custom scheme)
    /// so the browser tab lands somewhere sensible; the page then deep-links the
    /// code into the app via `superisland://auth-callback`.
    static let redirectURI = "https://akkhil7.github.io/superisland/auth-callback.html"
    static var classifyURL: URL { supabaseURL.appendingPathComponent("functions/v1/classify") }
    static var tokenURL: URL { supabaseURL.appendingPathComponent("auth/v1/token") }
}
