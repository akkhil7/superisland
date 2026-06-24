# SuperIsland Supabase backend

Deploy is automated by `.github/workflows/supabase-deploy.yml` on pushes to
`main` under `supabase/**`.

## One-time setup
- Repo secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`,
  `SUPABASE_DB_PASSWORD` (the last is needed so `supabase db push` runs
  non-interactively in CI — without it the job hangs on a password prompt).
- Function secrets: `supabase secrets set ANTHROPIC_API_KEY=… DAILY_CALL_CAP=200`.
- Auth providers (Supabase dashboard → Authentication → Providers): Google,
  Azure, Apple. Add redirect `superisland://auth-callback` to the URL allowlist.
- Fill `BackendConfig.supabaseURL` / `anonKey` in the app (already set to the
  live project `dnybgtyvqflisttbhoqw`).

This project always deploys against the **cloud** Supabase project — never local
Docker. The `classify` function pins `verify_jwt = false` in `config.toml` (it
does its own JWT validation), so CI's `functions deploy` keeps the handler
authoritative.
