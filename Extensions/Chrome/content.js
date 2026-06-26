// content.js — DEMOTED to a one-bit side channel.
//
// background.js (network) is the source of truth for working/done, and the app's
// AI classifier owns needsAttention (it reads the settled conversation). This
// script only reports the one thing the network can't see and the DOM does
// reliably: whether a Stop/▣ button is present, used to CORROBORATE working when
// the service worker missed the stream.

// A Stop/abort control replaces Send in every provider's composer while generating.
function stopButtonPresent() {
  const sel = [
    '[data-testid="stop-button"]',
    'button[aria-label*="stop generating" i]',
    'button[aria-label*="stop response" i]',
    'button[aria-label*="stop streaming" i]',
    'button[aria-label="Stop" i]',
  ].join(",");
  if (document.querySelector(sel)) return true;
  // Fallback: a button whose visible/aria label is exactly a stop verb.
  for (const b of document.querySelectorAll("button")) {
    const t = (b.getAttribute("aria-label") || b.innerText || "").trim().toLowerCase();
    if (t === "stop" || t === "stop generating" || t === "stop response") return true;
  }
  return false;
}

function collectSignal() {
  const working = stopButtonPresent();
  const text = (document.body?.innerText || "").replace(/\s+/g, " ").trim().slice(0, 600);
  return { domConfirmsWorking: working, text };
}

function report() {
  chrome.runtime
    .sendMessage({ type: "superisland_dom_signal", ...collectSignal() })
    .catch(() => {});
}

// Back-compat: background.js (and the Swift getTabStatus tool) may still pull a
// summary synchronously.
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "superisland_collect_dom") {
    const s = collectSignal();
    sendResponse({
      title: document.title || "",
      text: s.text,
      taskState: s.domConfirmsWorking ? "working" : "unknown",
    });
  }
  return true;
});

let pending = null;
const observer = new MutationObserver(() => {
  clearTimeout(pending);
  pending = setTimeout(report, 650);
});

if (document.body) {
  observer.observe(document.body, { childList: true, subtree: true, characterData: true });
}
report();
