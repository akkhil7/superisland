// providers.js — single source of truth for the SuperIsland Chrome bridge.
//
// Two jobs:
//   1. The ALLOWLIST. SuperIsland only ever observes these AI-prompting web apps;
//      every other domain is rejected (content script never injects, webRequest
//      never delivers, the background guard drops it, and the Swift side
//      re-checks). PAGE_HOSTS are the document/tab origins; FETCH_HOSTS are the
//      cross-origin generation/infra endpoints those pages call.
//   2. The DETECTOR TABLE. Per provider, how to tell a *generation* request apart
//      from telemetry/preview/auth/poll noise, so background.js can derive
//      working/done from request lifecycles instead of scraping prose.
//
// Generation is decided in priority order:
//   a. isExcluded()           -> never generation (telemetry, preview, auth, polls)
//   b. genPathRe match        -> fast-path WORKING (credible per-provider path)
//   c. content-type event-stream (background.js, characteristic rule)
//   d. promoteLongPost: a POST that stays open past STREAM_OPEN_MS — only for
//      providers whose stream is NOT text/event-stream and whose path we cannot
//      pin (bolt's text/plain data-stream, v0's opaque route).

// ---- Allowlist: document/tab origins (gate content script + tab.url) ---------
export const PAGE_HOSTS = [
  "lovable.dev",
  "gemini.google.com",
  "chatgpt.com",
  "chat.openai.com",
  "claude.ai",
  "app.emergent.sh",
  "emergent.sh",
  "v0.app",
  "v0.dev",
  "grok.com",
  "chat.mistral.ai",
  "chat.deepseek.com",
  "www.perplexity.ai",
  "perplexity.ai",
  "bolt.new",
];

// ---- Allowlist: cross-origin hosts the pages FETCH (never a tab document) -----
// Observed via webRequest so we can classify them; some are generation
// (api.lovable.dev, api.emergent.sh), the rest are excluded infra.
export const FETCH_HOSTS = [
  "api.lovable.dev",
  "lovable-api.com",
  "api.emergent.sh",
  "auth.emergent.sh",
  "ap.emergent.sh",
  "files.emergent.sh",
  "mcp.emergent.sh",
  "assets.emergent.sh",
  "job-connect.api.emergent.sh",
];

// Exact-host set for O(1) lookups. Exact only — never substring/suffix (those
// would admit evil-lovable.dev or lovable.dev.attacker.com).
export const ALLOWED_HOSTS = new Set([...PAGE_HOSTS, ...FETCH_HOSTS]);

// chrome.webRequest url filter — one exact "https://<host>/*" per host, so Chrome
// never even delivers an event for an off-allowlist host.
export const WEBREQUEST_FILTER = {
  urls: [...PAGE_HOSTS, ...FETCH_HOSTS].map((h) => `https://${h}/*`),
};

// ---- Detector table ----------------------------------------------------------
export const PROVIDERS = [
  {
    key: "lovable",
    kind: "app-builder",
    hostSuffixes: ["lovable.dev", "lovable-api.com"],
    // POST starts the build; the long-lived SSE GET is the true working channel.
    genPathRe:
      /\/v1\/(messages(\/[0-9a-f-]{36})?\/stream|projects\/[0-9a-f-]{36}\/messages)(\?|$)/,
    endpointCredible: true,
    promoteLongPost: false,
    excludeHostSuffixes: ["lovable.app"],
    excludePathRe: /\/v1\/(workspaces\/[^/]+\/credits|.*\/(analytics|usage)|health)(\/|\?|$)/,
  },
  {
    key: "emergent",
    kind: "app-builder",
    hostSuffixes: ["emergent.sh"],
    genPathRe: /\/trajectories\/v0\/stream/,
    endpointCredible: true,
    promoteLongPost: false,
    // Only api.emergent.sh carries generation; every other emergent host is infra.
    excludeHostSuffixes: [
      "auth.emergent.sh",
      "ap.emergent.sh",
      "files.emergent.sh",
      "mcp.emergent.sh",
      "assets.emergent.sh",
      "job-connect.api.emergent.sh",
      "j.emergent.sh",
      "get.emergent.sh",
    ],
    excludePathRe:
      /\/(trajectories\/v0\/[^/]+\/history|wingman|suggestions|skills|permissions|secrets|health)(\/|\?|$)/,
  },
  {
    key: "v0",
    kind: "app-builder",
    hostSuffixes: ["v0.app", "v0.dev"],
    genPathRe: null, // private/opaque route — rely on event-stream header + long-POST
    endpointCredible: false,
    promoteLongPost: true,
    excludeHostSuffixes: ["vusercontent.net", "vercel.app", "labs.vercel.dev", "vercel-insights.com"],
    excludePathRe: /\/(_next|chat-static|_vercel|api\/auth)(\/|\?|$)/,
  },
  {
    key: "bolt",
    kind: "app-builder",
    hostSuffixes: ["bolt.new"],
    // Vercel AI-SDK data-stream: content-type is text/plain, NOT event-stream,
    // so the path hint + long-open POST carry detection, never header sniffing.
    genPathRe: /\/api\/chat(\?|$)/,
    endpointCredible: false,
    promoteLongPost: true,
    excludeHostSuffixes: ["webcontainer-api.io", "staticblitz.com", "posthog.com"],
    excludePathRe: /\/api\/(enhancer|auth)(\/|\?|$)/,
  },
  {
    key: "chatgpt",
    kind: "chat",
    hostSuffixes: ["chatgpt.com", "chat.openai.com"],
    genPathRe: /\/backend-api\/(f\/)?conversation(\?|$)/,
    endpointCredible: false, // f/ variant unconfirmed — header rule backstops it
    promoteLongPost: false,
    excludeHostSuffixes: ["featuregates.org", "ab.chatgpt.com"],
    excludePathRe:
      /\/backend-api\/(conversation\/gen_title|sentinel|moderations|me|models|conversations)(\/|\?|$)/,
  },
  {
    key: "claude",
    kind: "chat",
    hostSuffixes: ["claude.ai"],
    genPathRe:
      /\/api\/organizations\/[^/]+\/chat_conversations\/[^/]+\/(completion|retry_completion)(\?|$)/,
    endpointCredible: true,
    promoteLongPost: false,
    excludeHostSuffixes: ["statsig.anthropic.com", "sentry.io"],
    excludePathRe: /\/(_next|api\/(auth|account|bootstrap))(\/|\?|$)/,
  },
  {
    key: "gemini",
    kind: "chat",
    hostSuffixes: ["gemini.google.com"],
    // Chunked NDJSON (no event-stream header) — anchor on the stable RPC name.
    genPathRe: /BardFrontendService\/StreamGenerate/,
    endpointCredible: true,
    promoteLongPost: false,
    excludeHostSuffixes: ["clients6.google.com", "play.google.com", "gstatic.com", "accounts.google.com"],
    excludePathRe: /\/_\/BardChatUi\/data\/batchexecute/, // short non-stream RPCs
  },
  {
    key: "grok",
    kind: "chat",
    hostSuffixes: ["grok.com"],
    genPathRe: /\/rest\/app-chat\/conversations\/([^/]+\/responses|new)(\?|$)/,
    endpointCredible: true,
    promoteLongPost: false,
    excludeHostSuffixes: ["assets.grok.com"],
    excludePathRe: /\/rest\/(auth|subscriptions)(\/|\?|$)/,
  },
  {
    key: "mistral",
    kind: "chat",
    hostSuffixes: ["chat.mistral.ai"],
    genPathRe: /\/api\/chat(\/[^/]+\/stream)?(\?|$)/,
    endpointCredible: false, // /api/chat probable; resume path was refuted
    promoteLongPost: false,
    excludeHostSuffixes: ["cloudflareinsights.com", "sentry.io", "intercom.io"],
    excludePathRe: /\/api\/(trpc|code-trpc|file|billing|users)(\/|\?|$)/,
  },
  {
    key: "deepseek",
    kind: "chat",
    hostSuffixes: ["chat.deepseek.com"],
    genPathRe: /\/api\/v\d+\/chat\/completion(\/|\?|$)/, // singular, version-tolerant
    endpointCredible: true,
    promoteLongPost: false,
    excludePathRe: /\/api\/v\d+\/(chat\/create_pow_challenge|chat_session|users)(\/|\?|$)/,
  },
  {
    key: "perplexity",
    kind: "search-chat",
    hostSuffixes: ["perplexity.ai"],
    genPathRe: /\/rest\/sse\/perplexity_ask/,
    endpointCredible: true,
    promoteLongPost: false,
    excludeHostSuffixes: ["pplx-next-static-public.perplexity.ai"],
    excludePathRe: /\/(socket\.io|_next|rest\/event|api\/auth|rest\/auth)(\/|\?|$)/,
  },
];

// Per-kind timing. App-builders run for minutes with multi-second gaps between
// sequential streams (queue pauses, tool steps, build/install), so DONE must
// trail-edge debounce far longer than a chat turn.
export const TIMING = {
  "app-builder": { debounceMs: 18000, stallMs: 600000 }, // bridge ~15-20s gaps; 10min stall ceiling
  chat: { debounceMs: 2500, stallMs: 120000 },
  "search-chat": { debounceMs: 2500, stallMs: 120000 },
};

function hostMatches(host, suffixes) {
  if (!suffixes) return false;
  return suffixes.some((s) => host === s || host.endsWith("." + s));
}

/** Resolve which provider (if any) owns a hostname. */
export function providerForHost(host) {
  return PROVIDERS.find((p) => hostMatches(host, p.hostSuffixes)) || null;
}

/** Is this URL an excluded (non-generation) channel for the provider? */
export function isExcluded(provider, url) {
  if (hostMatches(url.hostname, provider.excludeHostSuffixes)) return true;
  if (provider.excludePathRe && provider.excludePathRe.test(url.pathname + url.search)) return true;
  return false;
}

/** Does this request's path match the provider's credible generation path? */
export function pathLooksLikeGeneration(provider, url) {
  return !!provider.genPathRe && provider.genPathRe.test(url.pathname + url.search);
}

/**
 * The document/tab allowlist gate: true only for an https URL whose EXACT host is
 * a known web-app page host. Parsing with URL() makes userinfo tricks
 * (https://chatgpt.com@evil.com/) resolve to hostname "evil.com" and get rejected.
 */
export function isAllowedPageURL(rawURL) {
  if (typeof rawURL !== "string" || rawURL.length === 0) return false;
  let u;
  try {
    u = new URL(rawURL);
  } catch {
    return false;
  }
  if (u.protocol !== "https:") return false;
  return PAGE_HOSTS.includes(u.hostname);
}
