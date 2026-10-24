// Records what the Expo SDK (sdk/expo) saves and sends, as the Swift SDK's reference.
// Run from the repo root: node --import ./sdk/expo/test/setup.mjs sdk/swift/scripts/make-expo-fixture.ts
import { writeFileSync } from "node:fs";
import { ApparentClient, type Storage } from "../../expo/src/index.ts";

const map = new Map<string, string>();
const storage: Storage = { getItem: async (k) => map.get(k) ?? null, setItem: async (k, v) => { map.set(k, v); } };
let captured: { saved: unknown; body: unknown } | null = null;
globalThis.fetch = (async (_url: string, init: { body: string }) => {
  // What is on disk while the batch is in flight is exactly what the next launch would read.
  captured ??= { saved: JSON.parse(map.get("apparent:v2")!), body: JSON.parse(init.body) };
  return { ok: true, status: 200, headers: { get: () => null } } as unknown as Response;
}) as unknown as typeof fetch;

const c = new ApparentClient();
c.init({ apiUrl: "https://apparent.test", app: "einb", key: "write-key", storage, flushIntervalMs: 3_600_000, flushAt: 1000, captureErrors: false });
await c.ready();
c.setProperties({ language: "de", plan: "free" });
c.track("paywall_view", { source: "onboarding", price: 4.99, count: 3, trial: true, coupon: null });
c.screen("practice/[topic]", { path: "/practice/recht" });
c.screen("exam");
c.identify("user-1");
c.track("purchase", { product: "pro_lifetime" });
c.reset();
c.track("after_logout");
c.captureError(new TypeError("Cannot read property 'score' of undefined"), { how: "boundary" });
await c.flush();
await c.shutdown();
const out = new URL("../Tests/ApparentTests/Fixtures/expo-batch.json", import.meta.url);
// No local paths in the committed file.
const root = new URL("../../../", import.meta.url).href;
writeFileSync(out, JSON.stringify(captured, null, 2).replaceAll(root, "file:///repo/") + "\n");
console.log("wrote", out.pathname);
