// supabase/functions/classify/handler.ts
export interface Deps {
  cap: number;
  modelAllowlist: string[];
  maxBodyBytes: number;
  getUserId: (jwt: string) => Promise<string | null>;
  incrementQuota: (userId: string, cap: number) => Promise<{ allowed: boolean; used: number }>;
  anthropicFetch: (body: string) => Promise<Response>;
}

const json = (status: number, obj: unknown, extra: HeadersInit = {}) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", ...extra },
  });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return json(401, { error: "missing_token" });

  const userId = await deps.getUserId(jwt);
  if (!userId) return json(401, { error: "invalid_token" });

  const raw = await req.text();
  if (raw.length > deps.maxBodyBytes) return json(413, { error: "payload_too_large" });

  let parsed: { model?: string };
  try { parsed = JSON.parse(raw); } catch { return json(400, { error: "invalid_json" }); }
  if (!parsed.model || !deps.modelAllowlist.includes(parsed.model)) {
    return json(400, { error: "model_not_allowed" });
  }

  const { allowed, used } = await deps.incrementQuota(userId, deps.cap);
  const quotaHeaders = { "x-quota-used": String(used), "x-quota-cap": String(deps.cap) };
  if (!allowed) return json(429, { error: "quota_exceeded", used, cap: deps.cap }, quotaHeaders);

  const upstream = await deps.anthropicFetch(raw);
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": "application/json", ...quotaHeaders },
  });
}
