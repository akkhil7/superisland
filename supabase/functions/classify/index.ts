// supabase/functions/classify/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handle, type Deps } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const CAP = Number(Deno.env.get("DAILY_CALL_CAP") ?? "200");

const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

const deps: Deps = {
  cap: CAP,
  modelAllowlist: ["claude-haiku-4-5", "claude-opus-4-8"],
  maxBodyBytes: 200_000,
  getUserId: async (jwt) => {
    const client = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data } = await client.auth.getUser();
    return data.user?.id ?? null;
  },
  incrementQuota: async (userId, cap) => {
    const { data, error } = await admin.rpc("check_and_increment_quota", {
      p_user: userId, p_cap: cap,
    });
    if (error || !data?.[0]) return { allowed: false, used: cap };
    return { allowed: data[0].allowed, used: data[0].used };
  },
  anthropicFetch: (body) =>
    fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body,
    }),
};

serve((req) => handle(req, deps));
