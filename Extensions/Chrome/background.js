// background.js — network-first status detector for the SuperIsland Chrome bridge.
//
// Source of truth for working/done is now chrome.webRequest (observational,
// MV3-legal — no webRequestBlocking, no body reads): a per-tab state machine
// derives status from generation request lifecycles against the provider
// allowlist. content.js is demoted to a two-bit side channel (needsAttention +
// a Stop-button "really working" confirmation).
import {
  WEBREQUEST_FILTER,
  providerForHost,
  isExcluded,
  pathLooksLikeGeneration,
  isAllowedPageURL,
  TIMING,
} from "./providers.js";

const NATIVE_HOST = "com.superisland.chrome_bridge";

// --- tuning knobs -----------------------------------------------------------
const WORKING_GRACE_MS = 2000; // stay WORKING this long after last gen activity
const STREAM_OPEN_MS = 1200; // a watched POST open longer than this is a stream
const TICK_MS = 1000; // state-machine + command-poll cadence

// Flip to false to silence. Logs land in the service-worker console
// (chrome://extensions → SuperIsland → "service worker").
const DEBUG = false;
function dbg(...a) {
  if (DEBUG) console.log("[SI]", ...a);
}

// ---------------------------------------------------------------------------
// Native messaging (transport unchanged)
// ---------------------------------------------------------------------------
let nativePort = null;
const documentIds = new Map();

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      setTimeout(connectNative, 1500);
    });
  } catch {
    nativePort = null;
  }
}

function postNative(message) {
  if (!nativePort) return;
  try {
    nativePort.postMessage(message);
  } catch {
    nativePort = null;
  }
}

// ---------------------------------------------------------------------------
// Per-tab network detector state
// ---------------------------------------------------------------------------
// tabNet: tabId -> { provider, inflight:Map<requestId,{startedAt,isGen,watch}>,
//                    lastGenActivity, lastGenEndedAt, statusNet }
const tabNet = new Map();
// DOM signal from content.js: tabId -> { domStatus, domConfirmsWorking, text, at }
const tabDom = new Map();

function netFor(tabId) {
  let s = tabNet.get(tabId);
  if (!s) {
    s = {
      provider: null,
      inflight: new Map(),
      lastGenActivity: 0,
      lastGenEndedAt: 0,
      statusNet: "unknown",
    };
    tabNet.set(tabId, s);
  }
  return s;
}

function markGenStart(tabId, provider, requestId) {
  const s = netFor(tabId);
  s.provider = provider;
  const entry = s.inflight.get(requestId) || { startedAt: Date.now(), watch: false };
  const wasGen = entry.isGen;
  entry.isGen = true;
  s.inflight.set(requestId, entry);
  s.lastGenActivity = Date.now();
  if (!wasGen) dbg("gen-start", provider.key, "tab", tabId, "req", requestId);
}

function markRequestEnd(tabId, requestId) {
  const s = tabNet.get(tabId);
  if (!s) return;
  const entry = s.inflight.get(requestId);
  s.inflight.delete(requestId);
  if (entry?.isGen) {
    s.lastGenActivity = Date.now();
    s.lastGenEndedAt = Date.now();
    dbg("gen-end", s.provider?.key, "tab", tabId, "req", requestId);
  }
}

// ---------------------------------------------------------------------------
// webRequest observers (observational only — no blocking, MV3-legal)
// ---------------------------------------------------------------------------
function classify(details) {
  let url;
  try {
    url = new URL(details.url);
  } catch {
    return null;
  }
  const provider = providerForHost(url.hostname);
  if (!provider) return null;
  if (isExcluded(provider, url)) return { provider, isGen: false, watch: false };
  if (pathLooksLikeGeneration(provider, url)) return { provider, isGen: true, watch: false };
  // Characteristic candidate: a POST we should watch for a long-open stream —
  // only for providers whose stream is not text/event-stream and whose path is
  // not pinnable (bolt text/plain, v0 opaque route).
  if (details.method === "POST" && provider.promoteLongPost) {
    return { provider, isGen: false, watch: true };
  }
  return { provider, isGen: false, watch: false };
}

chrome.webRequest.onBeforeRequest.addListener((details) => {
  if (details.tabId < 0) return;
  const c = classify(details);
  // Log every POST to a provider host with its decision — the fastest way to see
  // whether a generation request (e.g. Gemini StreamGenerate) is being matched.
  if (c?.provider && details.method === "POST") {
    let path = "";
    try {
      path = new URL(details.url).pathname.slice(0, 90);
    } catch {}
    dbg("POST", c.provider.key, c.isGen ? "→GEN" : c.watch ? "→watch" : "→ignored", path);
  }
  if (!c || (!c.isGen && !c.watch)) return;
  const s = netFor(details.tabId);
  s.provider = c.provider;
  s.inflight.set(details.requestId, {
    startedAt: Date.now(),
    isGen: !!c.isGen,
    watch: !!c.watch,
  });
  if (c.isGen) {
    markGenStart(details.tabId, c.provider, details.requestId);
    captureTabState(details.tabId); // emit WORKING now — don't wait for the tick
  }
}, WEBREQUEST_FILTER);

// content-type: text/event-stream => generation (characteristic rule). Catches
// any SSE turn even when the path is unknown (v0) or the f/ variant drifted.
chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0) return;
    const ct =
      (details.responseHeaders || []).find((h) => h.name.toLowerCase() === "content-type")?.value ||
      "";
    if (!/text\/event-stream/i.test(ct)) return;
    const c = classify(details);
    if (c?.provider && !isExcludedDetails(c.provider, details)) {
      markGenStart(details.tabId, c.provider, details.requestId);
      captureTabState(details.tabId);
    }
  },
  WEBREQUEST_FILTER,
  ["responseHeaders"]
);

function isExcludedDetails(provider, details) {
  try {
    return isExcluded(provider, new URL(details.url));
  } catch {
    return true;
  }
}

function onRequestDone(details) {
  if (details.tabId < 0) return;
  const wasGen = tabNet.get(details.tabId)?.inflight.get(details.requestId)?.isGen;
  markRequestEnd(details.tabId, details.requestId);
  // The completion event wakes the SW even when the tab is backgrounded; emit so
  // the trailing-debounce DONE is anchored from here (the tick finishes it).
  if (wasGen) captureTabState(details.tabId);
}
chrome.webRequest.onCompleted.addListener(onRequestDone, WEBREQUEST_FILTER);
chrome.webRequest.onErrorOccurred.addListener(onRequestDone, WEBREQUEST_FILTER);

// ---------------------------------------------------------------------------
// State machine — runs every tick and on every signal
// ---------------------------------------------------------------------------
function recomputeNet(tabId, now) {
  const s = tabNet.get(tabId);
  if (!s || !s.provider) return "unknown";
  const { debounceMs, stallMs } = TIMING[s.provider.kind] || TIMING.chat;

  // Promote a long-open watched POST to a generation stream (bolt text/plain,
  // v0 RSC server-action — never carries a text/event-stream header).
  for (const [reqId, e] of s.inflight) {
    if (!e.isGen && e.watch && now - e.startedAt > STREAM_OPEN_MS) {
      markGenStart(tabId, s.provider, reqId);
    }
  }

  const genEntries = [...s.inflight.values()].filter((e) => e.isGen);
  const anyGenInflight = genEntries.length > 0;

  // Stall watchdog: a stream open longer than stallMs with no completion is
  // treated as hung -> allow DONE rather than pin WORKING forever.
  const oldestGen = genEntries.reduce((min, e) => Math.min(min, e.startedAt), Infinity);
  const stalled = oldestGen !== Infinity && now - oldestGen > stallMs;

  if (anyGenInflight && !stalled) {
    s.statusNet = "working";
  } else if (now - s.lastGenActivity < WORKING_GRACE_MS) {
    s.statusNet = "working";
  } else if (s.lastGenEndedAt && now - s.lastGenEndedAt < debounceMs && !stalled) {
    // Trailing-edge debounce: bridge multi-call agentic gaps before DONE.
    s.statusNet = "working";
  } else if (s.lastGenEndedAt) {
    s.statusNet = "done";
    if (stalled) s.inflight.clear(); // drop the hung request so we don't re-stall
  } else {
    s.statusNet = "unknown";
  }
  return s.statusNet;
}

// Precedence: needsAttention > working > done > unknown.
function mergeStatus(net, dom) {
  if (dom?.domStatus === "needsAttention") return "needsAttention";
  if (net === "working") return "working";
  if (dom?.domConfirmsWorking) return "working"; // Stop button up but we missed the stream
  if (net === "done") return "done";
  if (dom?.domStatus === "done") return "done";
  return "unknown";
}

// ---------------------------------------------------------------------------
// Emit tab state to the native host
// ---------------------------------------------------------------------------
async function captureTabState(tabId) {
  if (!tabId || tabId === chrome.tabs.TAB_ID_NONE) return;

  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return;
  }

  // DEFENSE IN DEPTH: ignore any tab whose URL is not an allowlisted page host.
  if (!isAllowedPageURL(tab.url)) {
    documentIds.delete(tabId);
    tabNet.delete(tabId);
    tabDom.delete(tabId);
    return;
  }

  const now = Date.now();
  const net = recomputeNet(tabId, now);
  const dom = tabDom.get(tabId);
  const status = mergeStatus(net, dom);
  const provider = tabNet.get(tabId)?.provider?.key || null;
  dbg(
    "emit tab", tab.id, "status=" + status, "(net=" + net + ")",
    "provider=" + (provider || "-"),
    "dom=" + (dom?.domStatus || "-") + (dom?.domConfirmsWorking ? "+stop" : "")
  );

  postNative({
    type: "tab_state",
    tab: {
      tabId: tab.id,
      windowId: tab.windowId,
      index: tab.index,
      url: tab.url || "",
      title: tab.title || "",
      documentId: documentIds.get(tab.id) || null,
      status,
      statusSource: provider ? "network" : "dom",
    },
    domSummary: {
      title: tab.title || "",
      text: dom?.text || "",
      taskState: status,
    },
  });
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------
async function handleNativeMessage(message) {
  const commands = Array.isArray(message?.commands) ? message.commands : [];
  for (const command of commands) {
    if (command.type !== "refocus_tab" || typeof command.tabId !== "number") continue;
    try {
      if (typeof command.windowId === "number") {
        await chrome.windows.update(command.windowId, { focused: true });
      }
      await chrome.tabs.update(command.tabId, { active: true });
    } catch {
      // The native app falls back to AppleScript/AX when the tab is gone.
    }
  }
}

chrome.tabs.onActivated.addListener(({ tabId }) => captureTabState(tabId));

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!isAllowedPageURL(tab?.url)) return;
  if (changeInfo.status === "complete" || changeInfo.title || changeInfo.url) {
    captureTabState(tabId);
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  if (tab?.id) captureTabState(tab.id);
});

chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0 && details.documentId) {
    documentIds.set(details.tabId, details.documentId);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabNet.delete(tabId);
  tabDom.delete(tabId);
  documentIds.delete(tabId);
});

// content.js now reports needsAttention + a working confirmation, never prose.
chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "superisland_dom_signal" || !sender.tab?.id) return;
  // sender.url is set by Chrome from the real frame origin and cannot be spoofed
  // by page JS — reject anything not on the allowlist.
  if (!isAllowedPageURL(sender.url)) return;
  tabDom.set(sender.tab.id, {
    domStatus: message.domStatus || "unknown",
    domConfirmsWorking: !!message.domConfirmsWorking,
    text: message.text || "",
    at: Date.now(),
  });
  captureTabState(sender.tab.id);
});

// Tick: drive the state machine for tabs with active/recent generation and poll
// the native host for queued commands.
setInterval(() => {
  postNative({ type: "command_poll" });
  const now = Date.now();
  for (const [tabId, s] of tabNet) {
    if (!s.provider) continue;
    const before = s.statusNet;
    recomputeNet(tabId, now);
    const debounceMs = TIMING[s.provider.kind]?.debounceMs || 2500;
    const inWindow =
      s.inflight.size > 0 ||
      now - s.lastGenActivity < WORKING_GRACE_MS + 1000 ||
      (s.lastGenEndedAt && now - s.lastGenEndedAt < debounceMs + 1500);
    if (before !== s.statusNet || inWindow) captureTabState(tabId);
  }
}, TICK_MS);

connectNative();
