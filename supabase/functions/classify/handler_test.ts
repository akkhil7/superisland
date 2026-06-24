// supabase/functions/classify/handler_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handle, type Deps } from "./handler.ts";

const baseDeps = (over: Partial<Deps> = {}): Deps => ({
  cap: 200,
  modelAllowlist: ["claude-haiku-4-5", "claude-opus-4-8"],
  maxBodyBytes: 200_000,
  getUserId: async () => "user-1",
  incrementQuota: async () => ({ allowed: true, used: 5 }),
  anthropicFetch: async () =>
    new Response(JSON.stringify({ content: [{ type: "text", text: "{}" }] }), { status: 200 }),
  ...over,
});

const req = (body: unknown, auth = "Bearer jwt") =>
  new Request("https://x/functions/v1/classify", {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("401 when no bearer token", async () => {
  const res = await handle(req({ model: "claude-haiku-4-5" }, ""), baseDeps());
  assertEquals(res.status, 401);
});

Deno.test("401 when token does not resolve to a user", async () => {
  const res = await handle(req({ model: "claude-haiku-4-5" }),
    baseDeps({ getUserId: async () => null }));
  assertEquals(res.status, 401);
});

Deno.test("400 when model not in allowlist", async () => {
  const res = await handle(req({ model: "gpt-4" }), baseDeps());
  assertEquals(res.status, 400);
});

Deno.test("429 with quota headers when over cap", async () => {
  const res = await handle(req({ model: "claude-haiku-4-5" }),
    baseDeps({ incrementQuota: async () => ({ allowed: false, used: 200 }) }));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("x-quota-used"), "200");
  assertEquals(res.headers.get("x-quota-cap"), "200");
});

Deno.test("200 forwards to anthropic and sets quota headers", async () => {
  let forwarded = false;
  const res = await handle(req({ model: "claude-haiku-4-5" }),
    baseDeps({
      anthropicFetch: async () => {
        forwarded = true;
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    }));
  assertEquals(res.status, 200);
  assertEquals(forwarded, true);
  assertEquals(res.headers.get("x-quota-used"), "5");
});
