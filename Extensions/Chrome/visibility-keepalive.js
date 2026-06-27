// visibility-keepalive.js — runs in the page's MAIN world at document_start.
//
// Web AI apps (Gemini confirmed, ChatGPT, and the builder apps) PAUSE their own
// generation stream when the tab is hidden — they gate on the Page Visibility
// API. That's why a backgrounded turn "only streams when you come back," and why
// SuperIsland could never see it finish. This shim makes the allowlisted provider
// tabs always report visible/focused, so the site keeps streaming in the
// background and the turn runs to completion unattended.
//
// MUST run in the MAIN world (Object.defineProperty on document only affects the
// realm it runs in — the isolated content-script world is invisible to the page)
// and at document_start (before the app caches document.hidden or attaches its
// visibilitychange listeners). It is intentionally self-contained: MAIN-world
// scripts have no chrome.* APIs. Network detection stays in the service worker.
(() => {
  // Defense-in-depth host gate (the manifest match list is the primary scope).
  const ALLOW = new Set([
    "lovable.dev", "gemini.google.com", "chatgpt.com", "chat.openai.com",
    "claude.ai", "app.emergent.sh", "emergent.sh", "v0.app", "v0.dev",
    "grok.com", "chat.mistral.ai", "chat.deepseek.com", "www.perplexity.ai",
    "perplexity.ai", "bolt.new",
  ]);
  if (!ALLOW.has(location.hostname)) return;

  const def = (obj, prop, value) => {
    try {
      Object.defineProperty(obj, prop, { get: () => value, configurable: true });
    } catch (_) {}
  };

  // Always visible / always focused.
  def(document, "hidden", false);
  def(document, "visibilityState", "visible");
  def(document, "webkitHidden", false);
  def(document, "webkitVisibilityState", "visible");
  try {
    document.hasFocus = () => true;
  } catch (_) {}

  // Swallow the events the app uses to pause itself, in the CAPTURE phase so we
  // run before the app's own (later-registered) listeners. We deliberately leave
  // focus / pagehide / freeze / resume alone — navigation and the bfcache depend
  // on them, and faking them risks corrupting page lifecycle.
  const swallow = (e) => e.stopImmediatePropagation();
  for (const ev of ["visibilitychange", "webkitvisibilitychange", "blur"]) {
    window.addEventListener(ev, swallow, true);
    document.addEventListener(ev, swallow, true);
  }
})();
