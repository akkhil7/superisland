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

## Supabase MCP

`.mcp.json` (repo root) registers the official Supabase MCP server, scoped to
this project (`--project-ref=dnybgtyvqflisttbhoqw`), for managing the backend
from Claude. It reads `SUPABASE_ACCESS_TOKEN` from the environment — no token is
committed. To activate:

1. Create a Personal Access Token (Supabase dashboard → Account → Access Tokens)
   and export it: `export SUPABASE_ACCESS_TOKEN=sbp_…` (add to your shell
   profile). The same token is the `SUPABASE_ACCESS_TOKEN` repo secret for CI.
2. Restart/reload Claude Code and approve the new project MCP server when
   prompted.

For tighter safety, add `--read-only` to the `args` in `.mcp.json`.
