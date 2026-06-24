# SuperIsland — Membership & Hosted Claude Proxy

Date: 2026-06-24
Status: Approved design, pending implementation plan

## Problem

Today every SuperIsland install calls `api.anthropic.com` directly using an
Anthropic API key stored in that Mac's login Keychain ("distributed externally
for the shipped product"). That means the key ships to users' machines and there
is no notion of identity, access control, or per-user cost control.

We want to:

1. Add **membership / sign-in** via OAuth (Google, Microsoft/Outlook, Apple).
2. Run a **server** so any signed-in user can use the app against **the owner's
   single Anthropic API key**, which never leaves the server.
3. Bound cost with a **per-user quota**.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Membership model | **Free now, billing later** — build auth + proxy + quota; design so billing can bolt on without rework. No payment in this scope. |
| Backend platform | **Supabase all-in** — Auth + Postgres + Edge Functions. |
| Access & quota | **Anyone who signs in**, with a **per-user daily call cap** enforced server-side. |
| BYO key | **Hosted only** — the per-machine Anthropic key is retired; everyone goes through the proxy after signing in. |
| Gating | **Hard wall** — sign-in is required to use the app at all. Signed-out users cannot drop, monitor, or classify. |
| OAuth in the app | **One uniform PKCE web flow** via `ASWebAuthenticationSession` for all three providers (including Apple), avoiding the native Sign-in-with-Apple entitlement on a Developer-ID build. |
| Deploy | **Supabase deploy added to CI/CD.** |

## Architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────────────┐
│  SuperIsland.app (macOS)     │         │  Supabase project                     │
│                              │         │                                       │
│  AuthService                 │  OAuth  │  Auth (Google / Azure / Apple)        │
│   └ ASWebAuthenticationSession ───────▶│   → issues JWT (access + refresh)     │
│   └ session in Keychain      │         │                                       │
│                              │         │  Postgres                             │
│  ClaudeClassifier (proxy mode)│ Bearer │   profiles, usage_daily               │
│   builds Anthropic payload   │  JWT    │   check_and_increment_quota()         │
│   POST /functions/v1/classify├────────▶│                                       │
│                              │         │  Edge Function: classify              │
│                              │         │   1. verify JWT → user                │
│                              │  verbatim    2. quota check → 429 if over       │
│                              │◀────────│   3. forward to api.anthropic.com      │
│  parse() → Classification    │  resp   │      with ANTHROPIC_API_KEY secret    │
└─────────────────────────────┘         │   4. return Anthropic response as-is  │
                                         └───────────────────────────────────────┘
```

The Edge Function is a **thin authenticated pass-through**. All prompt logic
(`ClassifierProtocolBuilder.systemPrompt`, `turnEndSystemPrompt`, request body
shapes) stays in the client, so the server never duplicates or drifts from the
prompts. The client's only behavioral change is **endpoint + auth header**.

## Server (Supabase)

### Auth
Enable three providers in Supabase Auth, each pointed at the app's redirect:

- **Google** — OAuth client (Web application type).
- **Azure** — App registration (covers Microsoft / Outlook accounts).
- **Apple** — Services ID + key, used through Supabase's hosted OAuth (web flow),
  not the native capability.

Redirect URL allowlist includes `superisland://auth-callback`.

### Database schema (migrations)

```sql
-- profiles: one row per user, created on signup
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

-- trigger: insert a profile row when a new auth user is created
create function public.handle_new_user() returns trigger ...;
create trigger on_auth_user_created after insert on auth.users ...;

-- usage_daily: per-user per-UTC-day call counter
create table public.usage_daily (
  user_id uuid references auth.users(id) on delete cascade,
  day date not null,
  count int not null default 0,
  primary key (user_id, day)
);

-- atomic check-and-increment against a configurable daily cap.
-- Returns the new count and whether the call is allowed.
create function public.check_and_increment_quota(p_cap int)
  returns table(allowed boolean, used int)
  language plpgsql security definer ...;
```

- **RLS**: enabled on both tables; a user may read only their own rows. Writes to
  `usage_daily` happen only via the `security definer` function.
- **Daily cap**: a single configurable integer (env/secret for the Edge
  Function, e.g. `DAILY_CALL_CAP`, default e.g. 200). Easy to raise per the
  app's real call volume.

### Edge Function `classify`
TypeScript/Deno. Pseudocode:

```ts
serve(async (req) => {
  const jwt = bearer(req);                          // 401 if missing
  const user = await verifyUser(jwt);               // 401 if invalid
  const { allowed, used } = await rpc('check_and_increment_quota', { p_cap: CAP });
  if (!allowed) return json(429, { error: 'quota_exceeded', used, cap: CAP });

  const upstream = await fetch(ANTHROPIC_ENDPOINT, {
    method: 'POST',
    headers: {
      'x-api-key': ANTHROPIC_API_KEY,               // server secret
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: await req.text(),                          // client-built payload, forwarded as-is
  });
  return new Response(upstream.body, {               // verbatim passthrough
    status: upstream.status,
    headers: { 'content-type': 'application/json',
               'x-quota-used': String(used), 'x-quota-cap': String(CAP) },
  });
});
```

- **Secrets**: `ANTHROPIC_API_KEY`, `DAILY_CALL_CAP`. Set via `supabase secrets set`.
- **Hardening**: reject oversized bodies; restrict forwarded model list to an
  allowlist (so a tampered client can't request an arbitrary expensive model);
  optional `max_tokens` ceiling.

### Public vs secret config
- **Public, embedded in the app**: Supabase project URL, anon (publishable) key,
  Edge Function path. These are designed to be public.
- **Secret, server-only**: `ANTHROPIC_API_KEY`, `DAILY_CALL_CAP`. Never shipped.

## Client (macOS app)

### `AuthService` (new, `SuperIslandApp` target)
- Starts a provider sign-in with `ASWebAuthenticationSession`, opening
  `https://<proj>.supabase.co/auth/v1/authorize?provider=<google|azure|apple>&redirect_to=superisland://auth-callback`,
  using **PKCE** (code verifier/challenge).
- On the `superisland://auth-callback?code=…` redirect, exchanges the code for a
  Supabase session (`POST /auth/v1/token?grant_type=pkce`).
- Persists the session (`access_token`, `refresh_token`, `expires_at`) in
  Keychain (reuse `Keychain.setData(_:account:)`, account `supabase-session`).
- Refreshes the access token before expiry (`grant_type=refresh_token`); on
  refresh failure, transitions to signed-out and prompts re-auth.
- Publishes auth state (`signedOut`, `signedIn(email)`) for the UI.

### URL scheme
- Info.plist `CFBundleURLTypes` registers scheme `superisland`.
- App handles the incoming URL (`onOpenURL` / `kAEGetURL`) and routes it to
  `AuthService` to complete the PKCE exchange.

### Classifier seam
`ClaudeClassifier` gains a **proxy mode**:

- New initializer carrying `(proxyURL, bearerToken)` instead of `apiKey`.
- In `send(_:)`, when in proxy mode: POST to `proxyURL` with
  `Authorization: Bearer <jwt>` and **no** `x-api-key` / `anthropic-version`
  (the server adds those). Body and `parse()` unchanged.
- Map `429` → a new `ClassifierError.quotaExceeded` so the UI can show a clear
  "daily limit reached" message instead of a generic failure.
- The 3 call sites (`AppController.swift:911`, `ClaudeIntegration.swift:183`,
  `Monitor.swift:182`) obtain the bearer token from `AuthService` rather than
  `settings.apiKey()`.

### Hard wall (gating)
- At launch, if there is no valid session, the app is in a **locked** state:
  - The menu-bar surface shows a **Sign in** call to action only.
  - Dropping (hotkey, Services, menu, notch) is refused with a "Sign in to use
    SuperIsland" toast.
  - Monitoring / classification do not run.
- Onboarding gains a **required Sign-in step** before any other step can complete.
- Once signed in, the full app unlocks. If the session later becomes invalid and
  cannot refresh (e.g. revoked), the app returns to the locked state and surfaces
  re-sign-in. Cached drops remain visible but inert until re-auth.

### Settings
- New **Account** section: signed-in email, remaining quota for the day
  (`x-quota-used` / `x-quota-cap`), and **Sign out**.
- Retire the `anthropic-api-key` Keychain path (`Settings.apiKey()` and its call
  sites are removed/replaced by the auth token path).

## Distribution / CI-CD

- **App build**: no new secrets — only the public Supabase URL + anon key are
  embedded. CI's secret-free gate is unaffected.
- **Supabase deploy** (new): a workflow (or job) that, on the relevant trigger,
  runs `supabase db push` (migrations) and `supabase functions deploy classify`,
  authenticated with a `SUPABASE_ACCESS_TOKEN` + project ref repo secret.
  `ANTHROPIC_API_KEY` / `DAILY_CALL_CAP` are set as Supabase function secrets
  (out of band or via the deploy job from repo secrets).

## One-time owner setup (prerequisites, documented for the plan)

1. Create the Supabase project; record URL + anon key.
2. Register OAuth apps: Google client, Azure app registration, Apple Services ID;
   wire each into Supabase Auth; add `superisland://auth-callback` to redirects.
3. `supabase secrets set ANTHROPIC_API_KEY=… DAILY_CALL_CAP=…`.
4. Add repo secrets for the deploy job (`SUPABASE_ACCESS_TOKEN`, project ref).

## Testing

Pure logic lands in `SuperIslandCore` and is unit-tested:

- **Callback parsing**: extract `code`/`error` from a `superisland://auth-callback` URL.
- **Session model**: expiry math, "needs refresh" decision, decode of the token
  response JSON.
- **Quota handling**: map `429` body/headers to `ClassifierError.quotaExceeded`
  and parse `x-quota-used` / `x-quota-cap`.
- **Proxy request building**: proxy-mode request has Bearer auth, no `x-api-key`,
  correct URL and body.

`ASWebAuthenticationSession`, Keychain, and live networking stay thin and are
verified manually (the environment cannot complete a real OAuth round-trip
headless).

Server: the Edge Function gets a minimal Deno test for the auth-missing (401),
over-quota (429), and happy-path (forward) branches with Anthropic mocked.

## Out of scope (future)

- Billing / paid tiers (schema and quota are shaped to allow it later).
- Native Sign-in-with-Apple (requires the `applesignin` entitlement + provisioning).
- Per-user model selection or org/team accounts.
- Streaming responses through the proxy (classification is single-shot).

## Key files touched

- New server: `supabase/migrations/*.sql`, `supabase/functions/classify/index.ts`,
  `supabase/config.toml`.
- New client: `Sources/SuperIslandApp/AuthService.swift`,
  `Sources/SuperIslandCore/AuthSession.swift` (+ callback/quota parsing),
  Account UI in Settings, Sign-in onboarding step.
- Modified: `Sources/SuperIslandCore/Classifier.swift` (proxy mode +
  `quotaExceeded`), `AppController.swift`, `ClaudeIntegration.swift`,
  `Monitor.swift` (token instead of `apiKey()`), `Settings.swift` (Account, drop
  `apiKey()`), `Info.plist` (URL scheme), `.github/workflows/` (Supabase deploy),
  `docs/architecture-*.md`.
