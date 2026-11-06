import { assertEquals } from "jsr:@std/assert@1";
import { cleanNews, cleanPatch, cleanURL } from "./clean.ts";

Deno.test("links: only public http(s)", () => {
  for (const bad of ["file:///etc/hosts", "javascript:alert(1)", "ftp://a.com/x", "http://localhost/", "http://127.0.0.1/", "http://10.0.0.1/", "http://192.168.1.1/",
    "http://172.16.0.1/", "http://169.254.169.254/", "http://[::1]/", "http://printer.local/", "http://intranet/", "", 3, null]) {
    assertEquals(cleanURL(bad), null, String(bad));
  }
  assertEquals(cleanURL(" https://mp.weixin.qq.com/s/x "), "https://mp.weixin.qq.com/s/x");
});

Deno.test("add link", () => {
  assertEquals(cleanPatch({ op: "add", id: "a1", kind: "link", url: "https://a.com/x", createdAt: "2026-11-04T00:00:00Z", extra: 1 }),
    { op: "add", id: "a1", kind: "link", url: "https://a.com/x", createdAt: "2026-11-04T00:00:00Z" });
  assertEquals(cleanPatch({ op: "add", id: "a1", kind: "link", url: "http://192.168.1.1/" }), null);
  assertEquals(cleanPatch({ op: "add", id: "../x", kind: "link", url: "https://a.com/" }), null);
});

Deno.test("add screenshots: paths must belong to the item", () => {
  assertEquals(cleanPatch({ op: "add", id: "a1", kind: "shots", shots: ["s/a1/0.jpg"], createdAt: "2026-11-04T00:00:00Z" })?.shots, ["s/a1/0.jpg"]);
  assertEquals(cleanPatch({ op: "add", id: "a1", kind: "shots", shots: ["s/other/0.jpg"] }), null);
  assertEquals(cleanPatch({ op: "add", id: "a1", kind: "shots", shots: ["s/a1/../../x.jpg"] }), null);
  assertEquals(cleanPatch({ op: "add", id: "a1", kind: "shots", shots: [] }), null);
});

Deno.test("update, delete, retry", () => {
  assertEquals(cleanPatch({ op: "update", id: "a", topic: " 投资 ", status: "saved" }), { op: "update", id: "a", topic: "投资" });
  assertEquals(cleanPatch({ op: "update", id: "a" }), null);
  assertEquals(cleanPatch({ op: "delete", id: "a", path: "/x" }), { op: "delete", id: "a" });
  assertEquals(cleanPatch({ op: "retry", id: "a" }), { op: "retry", id: "a" });
  assertEquals(cleanPatch({ op: "wipe", id: "a" }), null);
});

Deno.test("what reaches the cloud leaves out local details", () => {
  const r = cleanNews({ id: "a", status: "saved", title: "t", desktopFile: "/Users/x/Desktop/新闻/a.pdf", pdf: "/x", shots: ["s/a/0.jpg", "/etc/passwd"] });
  assertEquals(r?.data.shots, ["s/a/0.jpg"]);
  assertEquals("desktopFile" in r!.data, false);
  assertEquals(JSON.stringify(r).includes("/Users"), false);
  assertEquals(cleanNews({ id: "a", status: "gone" }), null);
});
