// A local stand-in for https://in.apparent.fyi, for the example app and manual checks. Never the real intake.
//   node sdk/swift/scripts/fake-intake.mjs [port] [--out batches.jsonl]
// Accepts POST /i the way server/ingest.ts reads it, prints each event, and answers like the server does.
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const args = process.argv.slice(2);
const port = Number(args.find((a) => /^\d+$/.test(a)) ?? 8787);
const outIdx = args.indexOf("--out");
const out = outIdx >= 0 ? args[outIdx + 1] : null;
const seen = new Set();

createServer((req, res) => {
  const reply = (status, body) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
  if (req.method === "GET" && req.url === "/health") return reply(200, { ok: true, service: "fake-intake" });
  if (req.method !== "POST" || req.url !== "/i") return reply(404, { error: "not found" });
  let raw = "";
  req.on("data", (c) => { raw += c; });
  req.on("end", () => {
    let body;
    try { body = JSON.parse(raw); } catch { return reply(400, { error: "bad json" }); }
    if (!body.a || !body.k) return reply(401, { error: "unauthorized" });
    const d = body.d ?? {};
    let accepted = 0, duplicates = 0, skipped = 0;
    for (const e of Array.isArray(body.e) ? body.e : []) {
      const anon = e.a ?? d.anon;
      if (!e.n || !anon) { skipped++; continue; }
      const id = e.i ?? `${anon}:${e.t}:${e.n}`;
      if (seen.has(id)) { duplicates++; continue; }
      seen.add(id);
      accepted++;
      const user = e.u !== undefined ? e.u : d.user;
      console.log(`${body.a} ${e.n} anon=${anon} user=${user ?? "-"} ${e.p ? JSON.stringify(e.p) : ""}`);
    }
    if (out) appendFileSync(out, JSON.stringify(body) + "\n");
    reply(200, { ok: true, accepted, duplicates, skipped });
  });
}).listen(port, "127.0.0.1", () => console.log(`fake intake on http://127.0.0.1:${port}/i`));
