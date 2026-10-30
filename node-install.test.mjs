import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { powershellExePath } from "./token-cache.mjs";

// Runs Test-NodeInstall.ps1, the offline test of Get-LLMUsageSnapshot.ps1's Node.js zip fallback
// (fake dist folder, no network, no winget, no PATH or real data-folder changes).
const here = path.dirname(fileURLToPath(import.meta.url));
const skip = process.platform !== "win32" ? "Windows PowerShell only" : false;

function runPowerShellTest(scratch) {
  return new Promise(resolve => {
    execFile(powershellExePath(),
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path.join(here, "Test-NodeInstall.ps1"), "-Scratch", scratch],
      { encoding: "utf8", timeout: 90000, windowsHide: true },
      (error, stdout, stderr) => resolve({ code: error ? (error.code ?? 1) : 0, stdout: String(stdout), stderr: String(stderr) }));
  });
}

test("Node.js zip fallback verifies SHASUMS256, installs into the data folder, deletes nothing and leaves PATH alone", { skip }, async () => {
  const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-node-install-test-"));
  try {
    const { code, stdout, stderr } = await runPowerShellTest(scratch);
    const lines = stdout.split(/\r?\n/).filter(Boolean);
    const failed = lines.filter(line => line.startsWith("FAIL"));
    assert.deepEqual(failed, [], stdout + stderr);
    assert.equal(code, 0, stdout + stderr);
    assert.ok(lines.filter(line => line.startsWith("ok ")).length >= 17, stdout + stderr);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
