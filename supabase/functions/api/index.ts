// 拾闻: one endpoint for the web page and the Mac app. Every request carries the passcode in `x-passcode`.
// Secret (set with `supabase secrets set`): APP_PASSCODE.
import { createClient } from "npm:@supabase/supabase-js@2.45.0";
import { cleanNews, cleanPatch, ID, MAX_SHOTS, SHOT_PATH } from "./clean.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "content-type, x-passcode",
  "access-control-allow-methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

// Compares fixed-length hashes, so the time taken says nothing about the passcode; 20 wrong ones in 10 minutes lock it.
async function checkPasscode(given: string) {
  const since = new Date(Date.now() - 10 * 60_000).toISOString();
  const { count } = await db.from("auth_failures").select("*", { count: "exact", head: true }).gte("at", since);
  if ((count ?? 0) >= 20) throw new HttpError(429, "尝试次数太多，请 10 分钟后再试");
  const expected = Deno.env.get("APP_PASSCODE") ?? "";
  const a = await sha256(given), b = await sha256(expected);
  let diff = expected.length === 0 ? 1 : 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  if (diff !== 0) {
    await db.from("auth_failures").insert({});
    throw new HttpError(401, "口令不对");
  }
}

// The Mac holds a long poll (mac_wait) open while awake; anything older means it is asleep, quit or offline.
const MAC_FRESH_MS = 75_000;

async function macState() {
  const { data } = await db.from("mac_status").select("seen_at, state").eq("id", 1).maybeSingle();
  const seen = data ? Date.parse(data.seen_at) : 0;
  return { online: !!data && data.state === "online" && Date.now() - seen < MAC_FRESH_MS, state: data?.state ?? "unknown", seenAt: data?.seen_at ?? null };
}

async function pendingEdits() {
  const { data, error } = await db.from("news_edits").select("id, patch").eq("done", false).order("id").limit(200);
  if (error) throw new HttpError(500, error.message);
  return data ?? [];
}

const shotPaths = (paths: unknown, max: number): paths is string[] =>
  Array.isArray(paths) && paths.length <= max && paths.every((p) => typeof p === "string" && SHOT_PATH.test(p));

async function signed(paths: string[]) {
  if (!paths.length) return {};
  const { data, error } = await db.storage.from("shots").createSignedUrls(paths, 3600);
  if (error) throw new HttpError(500, error.message);
  const urls: Record<string, string> = {};
  for (const d of data ?? []) if (d.path && d.signedUrl) urls[d.path] = d.signedUrl;
  return urls;
}

async function removeShots(id: string) {
  const { data } = await db.storage.from("shots").list(`s/${id}`, { limit: 200 });
  const paths = (data ?? []).map((f) => `s/${id}/${f.name}`);
  if (paths.length) await db.storage.from("shots").remove(paths);
}

type Handler = (body: any, signal: AbortSignal) => Promise<unknown>;
const actions: Record<string, Handler> = {
  // Web: checks the passcode (done before every action).
  async ping() {
    return { ok: true };
  },

  // Web: every item as the Mac last reported it, the requests it has not taken in yet, and whether it is online.
  async news_get() {
    const rows: unknown[] = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await db.from("news").select("data").order("id").range(from, from + 999);
      if (error) throw new HttpError(500, error.message);
      rows.push(...(data ?? []).map((r) => r.data));
      if ((data ?? []).length < 1000) break;
    }
    const [edits, mac] = await Promise.all([pendingEdits(), macState()]);
    return { newsItems: rows, pending: edits.map((e) => e.patch), mac };
  },

  // Web: queues a request for the Mac.
  async news_edit({ patch }) {
    const clean = cleanPatch(patch);
    if (!clean) throw new HttpError(400, "参数不对");
    const { error } = await db.from("news_edits").insert({ patch: clean });
    if (error) throw new HttpError(500, error.message);
    return { ok: true, patch: clean, mac: await macState() };
  },

  // Web and Mac: one screenshot as a base64 JPEG.
  async shot_upload({ path, jpeg }) {
    if (typeof path !== "string" || !SHOT_PATH.test(path) || typeof jpeg !== "string" || jpeg.length > 8_000_000) throw new HttpError(400, "参数不对");
    const bytes = Uint8Array.from(atob(jpeg), (c) => c.charCodeAt(0));
    const { error } = await db.storage.from("shots").upload(path, bytes, { contentType: "image/jpeg", upsert: true });
    if (error) throw new HttpError(500, error.message);
    return { ok: true };
  },

  // Web and Mac: signed links (an hour) to screenshots.
  async shot_urls({ paths }) {
    if (!shotPaths(paths, MAX_SHOTS * 4)) throw new HttpError(400, "参数不对");
    return { urls: await signed(paths) };
  },

  async mac_status() {
    return await macState();
  },

  // Mac: reports items after any change. Only the fields in cleanNews are kept.
  async news_push({ newsItems }) {
    if (!Array.isArray(newsItems) || newsItems.length > 500) throw new HttpError(400, "参数不对");
    const rows = newsItems.map(cleanNews);
    if (rows.some((r) => !r)) throw new HttpError(400, "参数不对");
    if (rows.length) {
      const now = new Date().toISOString();
      const { error } = await db.from("news").upsert(rows.map((r) => ({ id: r!.id, data: r!.data, updated_at: now })));
      if (error) throw new HttpError(500, error.message);
    }
    return { ok: true };
  },

  // Mac: items deleted anywhere; removes them and their screenshots from the cloud. PDFs on the Mac are not touched.
  async news_delete({ ids }) {
    if (!Array.isArray(ids) || ids.length > 200 || !ids.every((i) => typeof i === "string" && ID.test(i))) throw new HttpError(400, "参数不对");
    for (const id of ids) await removeShots(id);
    if (ids.length) {
      const { error } = await db.from("news").delete().in("id", ids);
      if (error) throw new HttpError(500, error.message);
    }
    return { ok: true };
  },

  // Mac: requests not taken in yet.
  async edits_pull() {
    return { edits: await pendingEdits() };
  },

  // Mac: the requests it has applied.
  async edits_done({ ids }) {
    if (!Array.isArray(ids) || ids.length > 200 || !ids.every((n) => Number.isSafeInteger(n))) throw new HttpError(400, "参数不对");
    if (ids.length) {
      const { error } = await db.from("news_edits").update({ done: true }).in("id", ids);
      if (error) throw new HttpError(500, error.message);
    }
    return { ok: true };
  },

  // Mac: a long poll. Marks the Mac as online, then waits (up to ~45 s) until the web page has queued something.
  async mac_wait(_body, signal) {
    const beat = () => db.from("mac_status").upsert({ id: 1, seen_at: new Date().toISOString(), state: "online" });
    await beat();
    const until = Date.now() + 45_000;
    let beaten = Date.now();
    while (!signal.aborted) {
      const { count, error } = await db.from("news_edits").select("id", { count: "exact", head: true }).eq("done", false);
      if (error) throw new HttpError(500, error.message);
      if ((count ?? 0) > 0) return { web: true };
      if (Date.now() >= until) break;
      if (Date.now() - beaten > 20_000) { await beat(); beaten = Date.now(); }
      await new Promise((r) => setTimeout(r, 2500));
    }
    await beat();
    return { web: false };
  },

  // Mac: going to sleep or quitting, so the page can say so.
  async mac_bye({ state }) {
    if (!["sleeping", "quit"].includes(state)) throw new HttpError(400, "参数不对");
    const { error } = await db.from("mac_status").upsert({ id: 1, seen_at: new Date().toISOString(), state });
    if (error) throw new HttpError(500, error.message);
    return { ok: true };
  },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  try {
    if (req.method !== "POST") throw new HttpError(405, "POST only");
    await checkPasscode(req.headers.get("x-passcode") ?? "");
    const body = await req.json();
    const handler = actions[body?.action];
    if (!handler) throw new HttpError(400, "未知操作");
    return reply(await handler(body, req.signal));
  } catch (e) {
    if (e instanceof HttpError) return reply({ error: e.message }, e.status);
    console.error(e);
    return reply({ error: "服务器出错了" }, 500);
  }
});
