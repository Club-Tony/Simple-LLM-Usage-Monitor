import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { powershellExePath } from "./token-cache.mjs";

// The Settings window's -Providers choices through Get-LLMUsageSnapshot.ps1 (release plan D5).
const here = path.dirname(fileURLToPath(import.meta.url));
const bridge = path.join(here, "Get-LLMUsageSnapshot.ps1");
const skip = process.platform !== "win32" ? "Windows PowerShell only" : false;

function runPowerShell(args, timeout = 90000) {
  return new Promise(resolve => {
    execFile(powershellExePath(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ...args],
      { encoding: "utf8", timeout, windowsHide: true },
      (error, stdout, stderr) => resolve({ code: error ? (error.code ?? 1) : 0, stdout: String(stdout), stderr: String(stderr) }));
  });
}

function readKeyValues(file) {
  return Object.fromEntries(readFileSync(file, "utf8").split(/\r?\n/).filter(line => line.includes("="))
    .map(line => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]));
}

test("the bridge stays ASCII (Windows PowerShell 5.1 reads a BOM-less file as ANSI)", () => {
  for (const file of ["Get-LLMUsageSnapshot.ps1", "Test-BridgeProviders.ps1"]) {
    const bytes = readFileSync(path.join(here, file));
    assert.equal(bytes.findIndex(byte => byte > 0x7f), -1, `${file} has a non-ASCII byte`);
  }
});

test("-Providers is cleaned, fails closed, and puts Off rows in the failure snapshot", { skip }, async () => {
  const { code, stdout, stderr } = await runPowerShell([path.join(here, "Test-BridgeProviders.ps1")]);
  const lines = stdout.split(/\r?\n/).filter(Boolean);
  assert.deepEqual(lines.filter(line => line.startsWith("FAIL")), [], stdout + stderr);
  assert.equal(code, 0, stdout + stderr);
  // Every Check in the script reported ok: none was skipped by an early exit.
  const expected = (readFileSync(path.join(here, "Test-BridgeProviders.ps1"), "utf8").match(/^\s*Check '/gm) || []).length;
  assert.ok(expected >= 28, `only ${expected} checks found`);
  assert.equal(lines.filter(line => line.startsWith("ok ")).length, expected, stdout + stderr);
});

// End to end with every provider off: the bridge hands --providers to the real scraper, which then
// reads no login, builds no cookie context and makes no request, so this runs offline.
test("bridge -> scraper with every provider off: three off statuses, overall ok, logged", { skip }, async () => {
  const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-bridge-providers-test-"));
  try {
    const outFile = path.join(scratch, "out.txt");
    const statusFile = path.join(scratch, "status.txt");
    const { code, stdout, stderr } = await runPowerShell([bridge, "-Mode", "Snapshot", "-OutFile", outFile, "-StatusFile", statusFile,
      "-DataDir", scratch, "-Providers", "codex=off claude=off grok=off"]);
    assert.equal(code, 0, stdout + stderr);
    assert.ok(existsSync(outFile), "snapshot written");
    const snapshot = readKeyValues(outFile);
    for (const provider of ["codex", "claude", "grok"]) {
      assert.equal(snapshot[`${provider}_status`], "off", provider);
      assert.equal(snapshot[`${provider}_source`], "", provider);
    }
    assert.equal(snapshot.codex_line_1, "Daily: Off");
    assert.equal(snapshot.grok_line_1, "Weekly: Off");
    assert.deepEqual(Object.keys(snapshot).filter(key => key.endsWith("_status")).sort(), ["claude_status", "codex_status", "grok_status", "overall_status"]);
    assert.equal(snapshot.claude_profile, "");
    assert.equal(snapshot.overall_status, "ok");
    assert.equal(Object.keys(snapshot).filter(key => key.startsWith("addon_")).length, 0, "no add-on keys without -AddonModule");
    assert.equal(readFileSync(statusFile, "utf8").trim(), "ok");
    const log = readFileSync(path.join(scratch, "snapshot.log"), "utf8");
    assert.match(log, /Providers: codex=off,claude=off,grok=off/);
    // Nothing was cached: no request, so no token or discovery cache file.
    assert.equal(existsSync(path.join(scratch, "llm-usage-token-cache.dpapi")), false);
    assert.equal(existsSync(path.join(scratch, "llm-usage-discovery-cache.json")), false);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

// The add-on end to end: a fixture module in a scratch folder writes a marker file when it is
// imported, so each run proves whether the module was loaded. Every built-in provider is off, so
// these runs are offline too.
const ADDON_FIXTURE = `import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
writeFileSync(fileURLToPath(new URL("./imported.marker", import.meta.url)), "imported");
export default {
  id: "fixture", label: "Fixture", lineLabels: ["Pro", "Flash"], sourceTag: "fix",
  link: "https://example.com/usage", signInHint: "", settingsWarning: "",
  async run() {
    return { status: "ok", lines: ["Pro: 55% remaining", "Flash: 10% remaining"], resetTexts: ["", ""] };
  }
};
`;

async function runBridgeWithAddon(scratch, providers, addonModule) {
  const outFile = path.join(scratch, "out.txt");
  rmSync(outFile, { force: true });
  rmSync(path.join(scratch, "imported.marker"), { force: true });
  const { code, stdout, stderr } = await runPowerShell([bridge, "-Mode", "Snapshot", "-OutFile", outFile,
    "-StatusFile", path.join(scratch, "status.txt"), "-DataDir", scratch, "-Providers", providers, "-AddonModule", addonModule]);
  assert.equal(code, 0, stdout + stderr);
  return {
    snapshot: readKeyValues(outFile),
    imported: existsSync(path.join(scratch, "imported.marker")),
    log: readFileSync(path.join(scratch, "snapshot.log"), "utf8")
  };
}

test("bridge -> scraper with an add-on: rows when on, no import when off or garbled, path never logged", { skip }, async () => {
  const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-bridge-addon-test-"));
  try {
    const modulePath = path.join(scratch, "fixture-addon.mjs");
    writeFileSync(modulePath, ADDON_FIXTURE, "utf8");
    const builtInOff = "codex=off,claude=off,grok=off";

    const on = await runBridgeWithAddon(scratch, builtInOff, modulePath);
    assert.equal(on.imported, true);
    assert.equal(on.snapshot.addon_status, "ok");
    assert.equal(on.snapshot.addon_source, "fix");
    assert.equal(on.snapshot.addon_label, "Fixture");
    assert.equal(on.snapshot.addon_line_1, "Pro: 55% remaining");
    assert.equal(on.snapshot.overall_status, "ok");
    assert.match(on.log, /Add-on: set/);
    assert.ok(!on.log.includes("fixture-addon"), "the module path is not logged");

    const off = await runBridgeWithAddon(scratch, `${builtInOff},addon=off`, modulePath);
    assert.equal(off.imported, false, "an add-on switched off is never imported");
    assert.equal(off.snapshot.addon_status, "off");
    assert.equal(off.snapshot.addon_line_1, "Off");

    const garbled = await runBridgeWithAddon(scratch, "codex=auto;calc", modulePath);
    assert.equal(garbled.imported, false, "a garbled -Providers turns the add-on off too");
    assert.equal(garbled.snapshot.addon_status, "off");
    assert.equal(garbled.snapshot.codex_status, "off");

    const rejected = await runBridgeWithAddon(scratch, builtInOff, "fixture-addon.mjs");
    assert.equal(rejected.imported, false);
    assert.equal(rejected.snapshot.addon_status, "error");
    assert.match(rejected.snapshot.error, /Add-on: path rejected/);
    assert.match(rejected.log, /Add-on: rejected/);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
