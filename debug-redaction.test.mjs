import test from "node:test";
import assert from "node:assert/strict";
import { debugJsonPreview, formatDebugLog, isSensitiveDebugKey, jsonKeyPaths, redactDebugString, redactForDebug } from "./debug-redaction.mjs";

// All values below are invented test fixtures.
const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJlLWZpeHR1cmU"; // gitleaks:allow (test fixture)
const sessionKey = "sk-ant-sid01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_fixture";
const home = "C:\\Users\\fixture-user";

test("redactDebugString masks emails, JWTs and JWT fragments, session keys and UUIDs", () => {
  const line = `label j.doe+test@example.com token ${jwt} part eyJzdWIiOiJ0ZXN0In0 key ${sessionKey} `
    + "org 3f2504e0-4f89-41d3-9a0c-0305e82c3301 v7 01890a5d-ac96-774b-bcce-b302099a8057";
  const out = redactDebugString(line, { homeDir: home });
  assert.ok(!out.includes("@"), out);
  assert.ok(!out.includes("eyJ"), out);
  assert.ok(!out.includes("sk-ant"), out);
  assert.ok(!/[0-9a-f]{8}-[0-9a-f]{4}-/i.test(out), out);
  assert.match(out, /<email>.*<jwt>.*<jwt>.*<session-key>.*<uuid>.*<uuid>/);
});

test("redactDebugString masks long hex or base64 runs but keeps ordinary words and numbers", () => {
  const hex = Buffer.from("grok billing payload fixture, long enough to dump").toString("hex");
  const out = redactDebugString(`hex=${hex} seven_day_opus remaining 42% HTTP 200`, { homeDir: home });
  assert.ok(!out.includes(hex.slice(0, 16)), out);
  assert.match(out, /hex=<redacted> seven_day_opus remaining 42% HTTP 200/);
});

test("redactDebugString replaces the home folder in plain, forward-slash and JSON-escaped paths", () => {
  const plain = redactDebugString(`EBUSY copyfile '${home}\\AppData\\Local\\Temp\\x\\cookies.sqlite'`, { homeDir: home });
  const forward = redactDebugString("C:/Users/fixture-user/AppData/Roaming", { homeDir: home });
  const escaped = redactDebugString(JSON.stringify({ path: `${home}\\Documents` }), { homeDir: home });
  for (const out of [plain, forward, escaped]) {
    assert.ok(!out.toLowerCase().includes("fixture-user"), out);
    assert.ok(out.includes("~"), out);
  }
});

test("redactForDebug masks values under sensitive keys and keeps the shape", () => {
  const body = {
    uuid: "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
    name: "Fixture Person's Organization",
    billing_type: "stripe_subscription",
    members: [{ email_address: "someone@example.com", display_name: "Fixture Person", role: "admin" }],
    session: { access_token: jwt },
    five_hour: { utilization: 12.5, resets_at: "2026-10-25T19:00:00Z" }
  };
  const out = redactForDebug(body, { homeDir: home });
  assert.equal(out.uuid, "<redacted>");
  assert.equal(out.name, "<redacted>");
  assert.equal(out.members[0].email_address, "<redacted>");
  assert.equal(out.members[0].display_name, "<redacted>");
  assert.equal(out.session, "<redacted>");
  assert.equal(out.members[0].role, "admin");
  assert.equal(out.billing_type, "stripe_subscription");
  assert.deepEqual(out.five_hour, body.five_hour);
  assert.ok(isSensitiveDebugKey("sessionKey"));
  assert.ok(isSensitiveDebugKey("Authorization"));
  assert.ok(!isSensitiveDebugKey("model_name"));
});

test("debugJsonPreview redacts before truncating, so a cut never exposes part of a value", () => {
  const preview = debugJsonPreview({ note: `contact j.doe@example.com ${jwt}`, filler: "x".repeat(10) }, 30, { homeDir: home });
  assert.ok(!preview.includes("j.doe"), preview);
  assert.ok(!preview.includes("eyJ"), preview);
  assert.ok(preview.endsWith("..."), preview);
});

test("formatDebugLog flattens newlines and redacts every line", () => {
  const text = formatDebugLog([`[claude] response: ${jwt}\r\nsecond`, `[codex] user someone@example.com`], { homeDir: home });
  const lines = text.trimEnd().split("\n");
  assert.equal(lines.length, 2);
  assert.equal(lines[0], "[claude] response: <jwt> second");
  assert.equal(lines[1], "[codex] user <email>");
});

test("jsonKeyPaths shows a body's shape with no values, masks odd keys and caps its output", () => {
  const body = {
    config: { productUsage: [{ product: "PRODUCT_GROK_BUILD", usagePercent: 7 }], currentPeriod: { end: "2026-11-01T00:00:00Z" } },
    "fixture.person42@example.com": { secret: "sk-ant-sid01-FIXTURE" },
    empty: {},
    list: [1, 2]
  };
  const paths = jsonKeyPaths(body);
  assert.deepEqual(paths, [
    "config.productUsage[].product:string",
    "config.productUsage[].usagePercent:number",
    "config.currentPeriod.end:string",
    "<key>.secret:string",
    "empty:{}",
    "list:array<number>"
  ]);
  const text = paths.join(" ");
  for (const value of ["PRODUCT_GROK_BUILD", "2026-11-01", "example.com", "sk-ant", "7"]) assert.ok(!text.includes(value), value);
  const wide = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`k${i}`, i]));
  assert.equal(jsonKeyPaths(wide, { maxPaths: 10 }).length, 10);
  assert.deepEqual(jsonKeyPaths({ a: { b: { c: { d: 1 } } } }, { maxDepth: 2 }), ["a.b:object"]);
});
