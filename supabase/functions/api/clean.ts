// What the web page may ask the Mac to do, cleaned before it is queued. The Mac checks links again before opening them.
// Kept in its own file so tests can run it without Supabase.

export const ID = /^[A-Za-z0-9_-]{1,64}$/;
export const SHOT_PATH = /^s\/[A-Za-z0-9_-]{1,64}\/[0-9]{1,3}\.jpg$/;
export const MAX_SHOTS = 30;

const text = (v: unknown, n: number) => (typeof v === "string" ? v.trim().slice(0, n) : undefined);

function isPrivateHost(host: string): boolean {
  const h = host.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
  if (h === "localhost" || /\.(localhost|local|internal|lan|home\.arpa)$/.test(h) || (!h.includes(".") && !h.includes(":"))) return true;
  const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (m) {
    const [a, b] = [+m[1], +m[2]];
    return a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  }
  return h === "::1" || h === "::" || /^f[cd]/.test(h) || /^fe[89ab]/.test(h);
}

export function cleanURL(v: unknown): string | null {
  if (typeof v !== "string" || v.length > 2000) return null;
  let u: URL;
  try { u = new URL(v.trim()); } catch { return null; }
  if ((u.protocol !== "http:" && u.protocol !== "https:") || isPrivateHost(u.hostname)) return null;
  return u.href;
}

// deno-lint-ignore no-explicit-any
export function cleanPatch(p: any): Record<string, unknown> | null {
  if (typeof p !== "object" || p === null || typeof p.id !== "string" || !ID.test(p.id)) return null;
  switch (p.op) {
    case "add": {
      const at = typeof p.createdAt === "string" && !Number.isNaN(Date.parse(p.createdAt)) ? p.createdAt : new Date().toISOString();
      if (p.kind === "link") {
        const url = cleanURL(p.url);
        return url ? { op: "add", id: p.id, kind: "link", url, createdAt: at } : null;
      }
      if (p.kind === "shots") {
        const shots = p.shots;
        if (!Array.isArray(shots) || !shots.length || shots.length > MAX_SHOTS) return null;
        const wanted = `s/${p.id}/`;
        if (!shots.every((s: unknown) => typeof s === "string" && SHOT_PATH.test(s) && s.startsWith(wanted))) return null;
        return { op: "add", id: p.id, kind: "shots", shots, createdAt: at };
      }
      return null;
    }
    case "update": {
      const c: Record<string, unknown> = { op: "update", id: p.id, title: text(p.title, 200), topic: text(p.topic, 40), note: text(p.note, 2000) };
      for (const k of Object.keys(c)) if (c[k] === undefined) delete c[k];
      return Object.keys(c).length > 2 ? c : null;
    }
    case "delete":
    case "retry":
      return { op: p.op, id: p.id };
  }
  return null;
}

// The fields of a news item the page may see. Anything else from the Mac is dropped, so no local path reaches the cloud.
const STATUS = ["pending", "processing", "saved", "incomplete", "failed"];
// deno-lint-ignore no-explicit-any
export function cleanNews(c: any): { id: string; data: Record<string, unknown> } | null {
  if (typeof c !== "object" || c === null || typeof c.id !== "string" || !ID.test(c.id) || !STATUS.includes(c.status)) return null;
  const shots = Array.isArray(c.shots) ? c.shots.filter((s: unknown) => typeof s === "string" && SHOT_PATH.test(s)).slice(0, MAX_SHOTS) : [];
  return {
    id: c.id,
    data: {
      id: c.id, kind: c.kind === "shots" ? "shots" : "link", status: c.status, url: text(c.url, 2000) ?? "", title: text(c.title, 200) ?? "",
      source: text(c.source, 120) ?? "", publishedAt: text(c.publishedAt, 40) ?? "", topic: text(c.topic, 40) ?? "", note: text(c.note, 2000) ?? "",
      reason: text(c.reason, 300) ?? "", fullPage: c.fullPage === true, videoMissing: c.videoMissing === true, shots,
      createdAt: text(c.createdAt, 40) ?? "", updatedAt: text(c.updatedAt, 40) ?? "",
    },
  };
}
