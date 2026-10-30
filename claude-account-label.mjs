// Masked Claude account label ("j***42@example.com") for the popup's account display.
//
// Source 1 (always): the first email-like string in the /api/organizations response.
// Source 2 (opt-in): Claude Desktop's own storage. When the org response carries no email, the
// scraper can scan %APPDATA%\Claude\Local Storage\leveldb\*.ldb|*.log (files up to 20 MB) for the
// first email-like string. That reads another app's private storage and can pick up the wrong
// address, so it is off unless the environment sets LLM_USAGE_CLAUDE_DESKTOP_LABEL=1 (a host can
// do that with EnvSet above its #Include). With the opt-in unset, nothing here touches that folder.
// Only the masked form ever leaves this module.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

export const CLAUDE_DESKTOP_LABEL_ENV = "LLM_USAGE_CLAUDE_DESKTOP_LABEL";
const MAX_STORAGE_FILE_BYTES = 20 * 1024 * 1024;
const realFs = { existsSync, readdirSync, readFileSync, statSync };

export function claudeDesktopLabelOptedIn(env = process.env) {
  return String(env?.[CLAUDE_DESKTOP_LABEL_ENV] ?? "").trim() === "1";
}

export function findFirstEmail(value) {
  if (typeof value === "string") {
    const match = value.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i);
    return match ? match[0] : "";
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findFirstEmail(item);
      if (found) return found;
    }
    return "";
  }

  if (value && typeof value === "object") {
    for (const child of Object.values(value)) {
      const found = findFirstEmail(child);
      if (found) return found;
    }
  }

  return "";
}

export function maskEmailForDisplay(email) {
  if (!email) {
    return "";
  }

  const match = String(email).trim().match(/^([^@\s]+)@([^@\s]+)$/);
  if (!match) {
    return "";
  }

  const local = match[1];
  const domain = match[2].toLowerCase();
  const head = local.slice(0, 1);
  const tail = local.length > 3 ? local.slice(-2) : local.length > 1 ? local.slice(-1) : "";
  return `${head}***${tail}@${domain}`;
}

export function extractClaudeAccountLabelFromOrganizations(data) {
  const list = Array.isArray(data) ? data : (data?.organizations ?? []);
  const primaryOrg = list[0] || data;
  const email = findFirstEmail(primaryOrg) || findFirstEmail(data);
  return maskEmailForDisplay(email);
}

// Opt-in fallback; see the header. env, platform and fs are injectable for tests.
export function readClaudeDesktopAccountLabel({ env = process.env, platform = process.platform, fs = realFs } = {}) {
  if (!claudeDesktopLabelOptedIn(env)) {
    return "";
  }
  try {
    if (platform !== "win32" || !env.APPDATA) {
      return "";
    }

    const storageDir = path.join(env.APPDATA, "Claude", "Local Storage", "leveldb");
    if (!fs.existsSync(storageDir)) {
      return "";
    }

    const files = fs.readdirSync(storageDir)
      .filter(name => /\.(ldb|log)$/i.test(name))
      .map(name => {
        const filePath = path.join(storageDir, name);
        const stats = fs.statSync(filePath);
        return { filePath, mtimeMs: stats.mtimeMs, size: stats.size };
      })
      .filter(file => file.size > 0 && file.size <= MAX_STORAGE_FILE_BYTES)
      .sort((a, b) => b.mtimeMs - a.mtimeMs);

    for (const file of files) {
      const text = fs.readFileSync(file.filePath).toString("latin1");
      const label = maskEmailForDisplay(findFirstEmail(text));
      if (label) {
        return label;
      }
    }
  } catch {}

  return "";
}
