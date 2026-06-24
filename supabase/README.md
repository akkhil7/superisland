# SuperIsland Supabase backend

Deploy is automated by `.github/workflows/supabase-deploy.yml` on pushes to
`main` under `supabase/**`.

## One-time setup
- Repo secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`.
- Function secrets: `supabase secrets set ANTHROPIC_API_KEY=… DAILY_CALL_CAP=200`.
- Auth providers (Supabase dashboard → Authentication → Providers): Google,
  Azure, Apple. Add redirect `superisland://auth-callback` to the URL allowlist.
- Fill `BackendConfig.supabaseURL` / `anonKey` in the app.
