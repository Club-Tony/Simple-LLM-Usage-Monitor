import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { powershellExePath } from "./token-cache.mjs";

// Runs installer\Test-Installer.ps1: two release builds, the BAT carrier and Install.bat, and the
// setup lifecycle against fixture runtimes from a fake mirror. TEMP and TMP point at scratch and
// LLMUSAGE_SETUP_TEST=1 fences setup into scratch locations: no network, no registry writes, and
// nothing in the real Start Menu, Startup, install or data folders.
const here = path.dirname(fileURLToPath(import.meta.url));
const skip = process.platform !== "win32" ? "Windows PowerShell only" : false;

function runPowerShellTest(scratch, temp) {
  return new Promise(resolve => {
    execFile(powershellExePath(),
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(here, "installer", "Test-Installer.ps1"), "-Scratch", scratch],
      {
        encoding: "utf8", timeout: 600000, windowsHide: true, maxBuffer: 16 * 1024 * 1024,
        env: { ...process.env, TEMP: temp, TMP: temp, LLMUSAGE_SETUP_TEST: "1" },
      },
      (error, stdout, stderr) => resolve({ code: error ? (error.code ?? 1) : 0, stdout: String(stdout), stderr: String(stderr) }));
  });
}

test("one-click installer: deterministic build, verified carrier, install, reinstall, repair and owned-only uninstall", { skip, timeout: 620000 }, async () => {
  const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-installer-test-"));
  const temp = path.join(scratch, "temp");
  mkdirSync(temp);
  try {
    const { code, stdout, stderr } = await runPowerShellTest(scratch, temp);
    const lines = stdout.split(/\r?\n/).filter(Boolean);
    const failed = lines.filter(line => line.startsWith("FAIL"));
    assert.deepEqual(failed, [], stdout + stderr);
    assert.equal(code, 0, stdout + stderr);
    assert.ok(lines.filter(line => line.startsWith("ok ")).length >= 80, stdout + stderr);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
