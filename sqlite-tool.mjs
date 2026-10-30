// sqlite3.exe, which usage-scraper.mjs uses to read Firefox's cookie database.
//
// The tool ships beside the scripts (sqlite3.exe, SQLite 3.47.2; version and hash in
// the README). Only when it is missing does ensureSqlite3() fetch the matching official
// sqlite-tools zip, and it installs sqlite3.exe only after the zip's SHA3-256 matches the hash
// sqlite.org published for that file:
//   - URL and hash are pinned below. A non-2xx response, an empty or oversized body, a hash
//     mismatch or any extraction problem installs nothing, and the temp folder is always removed.
//   - Extraction runs Windows' own tar.exe (bsdtar) with an argument array: no shell and no
//     command string. bsdtar refuses absolute and ".." member paths unless told otherwise.
//   - The exe is copied to a temp name beside the destination and renamed into place, so a
//     half-written sqlite3.exe can never be picked up by a concurrent snapshot.
// Switching to Node's built-in node:sqlite would drop the binary altogether (an installer-phase option).

import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const SQLITE_TOOLS_ZIP = Object.freeze({
  url: "https://www.sqlite.org/2024/sqlite-tools-win-x64-3470200.zip",
  version: "3.47.2",
  // As published on https://www.sqlite.org/download.html while 3.47.2 was the current release
  // (6.09 MiB; read from archived copies of that page dated 2024-12-14 and 2025-01-03).
  algorithm: "sha3-256",
  digest: "7e88369b0d37e188ccd2f840e871f6be8a03dd86a8441730136e7814e4794850",
  maxBytes: 16 * 1024 * 1024
});

export function digestHex(buffer, algorithm) {
  return createHash(algorithm).update(buffer).digest("hex");
}

export function tarExePath(env = process.env) {
  return path.join(env.SystemRoot || "C:\\Windows", "System32", "tar.exe");
}

export async function extractWithTar(zipPath, destDir) {
  await execFileAsync(tarExePath(), ["-xf", zipPath, "-C", destDir], { timeout: 30000, windowsHide: true });
}

async function findFileByName(dir, name) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isFile() && entry.name.toLowerCase() === name.toLowerCase()) return full;
    if (entry.isDirectory()) {
      const found = await findFileByName(full, name);
      if (found) return found;
    }
  }
  return "";
}

// Resolves { installed, reason }; never throws. reason is "present", "downloaded" or why nothing
// was installed (for the debug log). fetchImpl, pin, extract and tempRoot are injectable for tests.
export async function ensureSqlite3(dest, {
  fetchImpl = globalThis.fetch,
  pin = SQLITE_TOOLS_ZIP,
  extract = extractWithTar,
  tempRoot = os.tmpdir(),
  platform = process.platform,
  timeoutMs = 60000
} = {}) {
  if (existsSync(dest)) return { installed: false, reason: "present" };
  if (platform !== "win32") return { installed: false, reason: "not-windows" };

  let workDir = "";
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const resp = await fetchImpl(pin.url, { signal: controller.signal, redirect: "follow" });
    if (!resp || !resp.ok) {
      return { installed: false, reason: `http-${resp?.status ?? "error"}` };
    }
    const declared = Number(resp.headers?.get?.("content-length"));
    if (Number.isFinite(declared) && declared > pin.maxBytes) {
      return { installed: false, reason: "too-large" };
    }
    const body = Buffer.from(await resp.arrayBuffer());
    if (body.length === 0 || body.length > pin.maxBytes) {
      return { installed: false, reason: body.length === 0 ? "empty" : "too-large" };
    }
    if (digestHex(body, pin.algorithm) !== String(pin.digest).toLowerCase()) {
      return { installed: false, reason: "hash-mismatch" };
    }

    workDir = await fs.mkdtemp(path.join(tempRoot, "llm-usage-sqlite-"));
    const zipPath = path.join(workDir, "sqlite-tools.zip");
    const extractDir = path.join(workDir, "x");
    await fs.mkdir(extractDir);
    await fs.writeFile(zipPath, body);
    await extract(zipPath, extractDir);

    const exe = await findFileByName(extractDir, "sqlite3.exe");
    if (!exe) return { installed: false, reason: "not-in-zip" };
    const staged = `${dest}.${process.pid}.tmp`;
    try {
      await fs.copyFile(exe, staged);
      await fs.rename(staged, dest);
    } catch (e) {
      await fs.rm(staged, { force: true }).catch(() => {});
      throw e;
    }
    return { installed: true, reason: "downloaded" };
  } catch (e) {
    return { installed: false, reason: e?.code ?? e?.name ?? "error" };
  } finally {
    clearTimeout(timer);
    if (workDir) await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}
