// DPAPI-protected token cache for usage-scraper.mjs.
//
// Bearer tokens (the Codex session token, and whatever a host's add-on caches through its
// ctx.cache) used to sit in a plaintext JSON file in %TEMP%. They now live in one
// file in the per-user data folder (see usage-scraper.mjs), encrypted with Windows DPAPI
// (CurrentUser scope) through Protect-CacheValue.ps1 - Node has no DPAPI binding of its own.
//
// Spawn budget per scraper run: at most one -Unprotect, made lazily the first time a token
// is asked for and only when the file exists (every provider in the run shares it), and at
// most one -Protect, from flush() at the end of the run, only when an entry changed.
//
// Every failure degrades to a cache miss, so the run re-discovers the token exactly as it
// would with no cache. Plaintext never reaches disk: when protection fails nothing is
// written. Diagnostics carry error codes only, never error messages, because a JSON parse
// error quotes the text it choked on.

import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
export const dpapiHelperPath = path.join(moduleDir, "Protect-CacheValue.ps1");

export function powershellExePath() {
  const psExe = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  return existsSync(psExe) ? psExe : "powershell.exe";
}

// Runs a stable .ps1 with -File (never an inline -Command) without blocking the event loop.
// Resolves trimmed stdout; rejects on a nonzero exit, a timeout or a spawn failure.
export function runPowerShellFile(scriptPath, args = [], { input = "", timeoutMs = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = execFile(powershellExePath(),
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, ...args],
      { encoding: "utf8", timeout: timeoutMs, windowsHide: true, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(String(stdout).trim());
      });
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

function errorCode(e) {
  return e?.code ?? e?.name ?? "error";
}

export async function dpapiProtect(plaintext, options = {}) {
  const input = Buffer.from(String(plaintext), "utf8").toString("base64");
  const out = await runPowerShellFile(dpapiHelperPath, ["-Protect"], { ...options, input });
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(out)) {
    throw new Error("DPAPI helper returned no ciphertext");
  }
  return out;
}

export async function dpapiUnprotect(ciphertext, options = {}) {
  const out = await runPowerShellFile(dpapiHelperPath, ["-Unprotect"], { ...options, input: String(ciphertext) });
  return Buffer.from(out, "base64").toString("utf8");
}

// One cache instance per scraper run. filePath "" disables persistence (memory only).
export function createTokenCache(filePath, { log } = {}) {
  let loading = null;
  let dirty = false;
  const note = message => {
    try {
      if (log) log(message);
    } catch {}
  };

  async function readEntries() {
    if (!filePath || !existsSync(filePath)) return {};
    try {
      const blob = readFileSync(filePath, "utf8").trim();
      if (!blob) return {};
      const parsed = JSON.parse(await dpapiUnprotect(blob));
      return (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : {};
    } catch (e) {
      note(`token cache unreadable -> treated as empty (${errorCode(e)})`);
      return {};
    }
  }

  function load() {
    if (!loading) loading = readEntries();
    return loading;
  }

  return {
    async get(key) {
      const entry = (await load())[key];
      if (!entry || typeof entry !== "object") return null;
      if (!Number.isFinite(entry.expiresAt) || Date.now() >= entry.expiresAt) return null;
      return entry.value ?? null;
    },

    async set(key, value, expiresAt) {
      if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) return;
      const entries = await load();
      entries[key] = { value, expiresAt };
      dirty = true;
    },

    async drop(key) {
      const entries = await load();
      if (!(key in entries)) return;
      delete entries[key];
      dirty = true;
    },

    // Persists changes made during this run. Never throws.
    async flush() {
      if (!dirty || !loading || !filePath) return;
      dirty = false;
      try {
        const entries = await loading;
        const now = Date.now();
        for (const key of Object.keys(entries)) {
          if (!Number.isFinite(entries[key]?.expiresAt) || entries[key].expiresAt <= now) delete entries[key];
        }
        if (Object.keys(entries).length === 0) {
          rmSync(filePath, { force: true });
          return;
        }
        const blob = await dpapiProtect(JSON.stringify(entries));
        mkdirSync(path.dirname(filePath), { recursive: true });
        const tmp = `${filePath}.${process.pid}.tmp`;
        writeFileSync(tmp, blob, "utf8");
        renameSync(tmp, filePath);
      } catch (e) {
        note(`token cache not saved (${errorCode(e)})`);
      }
    }
  };
}

// Migration: the pre-DPAPI cache held bearer tokens and an OAuth client secret in plaintext.
// Deletes it when found, plus any temp file an interrupted writer left beside it. Costs one
// existsSync per run once it is gone (no directory scan of %TEMP%). Never throws.
export function removeLegacyPlaintextCache(directory, baseName = "llm-usage-discovery-cache.json") {
  let removed = 0;
  try {
    if (!directory || !existsSync(path.join(directory, baseName))) return 0;
    for (const name of readdirSync(directory)) {
      if (name === baseName || (name.startsWith(`${baseName}.`) && name.endsWith(".tmp"))) {
        try {
          rmSync(path.join(directory, name), { force: true });
          removed += 1;
        } catch {}
      }
    }
  } catch {}
  return removed;
}
