import test, { after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createTokenCache, dpapiProtect, dpapiUnprotect, removeLegacyPlaintextCache } from "./token-cache.mjs";

// DPAPI exists only on Windows; these tests spawn Protect-CacheValue.ps1 for real.
const skip = process.platform !== "win32" ? "DPAPI is Windows-only" : false;
const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-token-cache-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const secret = "eyJhbGciOiJub25lIn0.eyJleHAiOjk5OTk5OTk5OTl9.probe-signature-" + "é"; // gitleaks:allow (test fixture)

test("DPAPI round trip returns the plaintext and the ciphertext does not contain it", { skip }, async () => {
  const blob = await dpapiProtect(secret);
  assert.match(blob, /^[A-Za-z0-9+/]+={0,2}$/);
  assert.ok(!blob.includes(Buffer.from(secret, "utf8").toString("base64")));
  assert.ok(!Buffer.from(blob, "base64").toString("latin1").includes("probe-signature"));
  assert.equal(await dpapiUnprotect(blob), secret);
});

test("a tampered DPAPI blob is rejected", { skip }, async () => {
  const blob = await dpapiProtect(secret);
  const bytes = Buffer.from(blob, "base64");
  bytes[bytes.length - 8] ^= 0xff;
  await assert.rejects(dpapiUnprotect(bytes.toString("base64")));
});

test("token cache persists encrypted, reloads, expires and drops", { skip }, async () => {
  const file = path.join(scratch, "LLMUsageMonitor", "llm-usage-token-cache.dpapi");
  const first = createTokenCache(file);
  assert.equal(await first.get("codex:token:(default)"), null);
  await first.set("codex:token:(default)", { token: secret }, Date.now() + 60_000);
  await first.set("example:short:token", { token: "already-expired" }, Date.now() + 1);
  await new Promise(resolve => setTimeout(resolve, 10));
  await first.flush();

  assert.ok(existsSync(file));
  const onDisk = readFileSync(file, "utf8");
  assert.ok(!onDisk.includes("probe-signature"));
  assert.ok(!onDisk.includes("codex:token"));

  const second = createTokenCache(file);
  assert.deepEqual(await second.get("codex:token:(default)"), { token: secret });
  assert.equal(await second.get("example:short:token"), null, "expired entries are pruned or ignored");

  await second.drop("codex:token:(default)");
  await second.flush();
  assert.ok(!existsSync(file), "an emptied cache removes its file");
});

test("an unreadable cache file degrades to a miss", { skip }, async () => {
  const file = path.join(scratch, "corrupt.dpapi");
  writeFileSync(file, "bm90LWEtZHBhcGktYmxvYg==", "utf8");
  const logged = [];
  const cache = createTokenCache(file, { log: message => logged.push(message) });
  assert.equal(await cache.get("codex:token:(default)"), null);
  assert.equal(logged.length, 1);
  assert.match(logged[0], /token cache unreadable/);
});

test("legacy plaintext cache is removed with its temp leftovers only", () => {
  const dir = mkdtempSync(path.join(scratch, "legacy-"));
  const legacy = path.join(dir, "llm-usage-discovery-cache.json");
  writeFileSync(legacy, "{}", "utf8");
  writeFileSync(`${legacy}.1234.tmp`, "{}", "utf8");
  writeFileSync(path.join(dir, "unrelated.json"), "{}", "utf8");
  assert.equal(removeLegacyPlaintextCache(dir), 2);
  assert.ok(!existsSync(legacy));
  assert.ok(existsSync(path.join(dir, "unrelated.json")));
  assert.equal(removeLegacyPlaintextCache(dir), 0);
});
