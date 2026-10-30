// Copies of Firefox's cookie database for usage-scraper.mjs, kept to as few as possible.
//
// Firefox keeps cookies.sqlite locked while it runs, so the scraper reads a private copy. Each
// copy is a full cookie database, so a snapshot (every 15-60 s) makes as few as it can:
//   - one copy per profile per snapshot, shared by every query on that profile
//     (createCookieDbCopies): Codex, Grok and the Claude sign-in check all read one copy of
//     the default profile
//   - which profiles hold a live Claude session is cached per profile, keyed by the
//     size and mtime of cookies.sqlite and cookies.sqlite-wal (resolveSessionExpiries): a
//     profile whose files have not changed is not copied again just to re-check it
//   - cookies.sqlite-wal is copied too, before the main file, so a sign-in Firefox has not
//     checkpointed yet is still seen (the old copies missed it until Firefox checkpointed)
//   - every copy lives in its own %TEMP%\llm-usage-cookies-* folder that is removed when the
//     snapshot ends; sweepStaleTempDirs() clears folders a killed run left behind
// Cookie values never leave memory; the cache holds profile names, file stats and expiry times.

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readdirSync, rmSync, statSync } from "node:fs";
import path from "node:path";

export const COOKIE_COPY_PREFIX = "llm-usage-cookies-";
// Current prefix, the pre-B5 listing prefix, and sqlite-tool.mjs's download folder.
export const STALE_TEMP_PREFIXES = Object.freeze([COOKIE_COPY_PREFIX, "llm-usage-cookie-count-", "llm-usage-sqlite-"]);
export const STALE_TEMP_AGE_MS = 10 * 60 * 1000;

function statOrNull(file) {
  try {
    return statSync(file);
  } catch {
    return null;
  }
}

// "" when the profile has no cookies.sqlite. Any write by Firefox changes the main file or its
// WAL, so an unchanged fingerprint means an unchanged cookie jar.
export function cookieDbFingerprint(profileDir) {
  const main = statOrNull(path.join(profileDir, "cookies.sqlite"));
  if (!main) return "";
  const wal = statOrNull(path.join(profileDir, "cookies.sqlite-wal"));
  return `${main.size}:${Math.trunc(main.mtimeMs)}|${wal ? `${wal.size}:${Math.trunc(wal.mtimeMs)}` : "-"}`;
}

// Returns { tmpDir, tmpDb } or null; never throws. The WAL is copied first: if Firefox
// checkpoints between the two copies, the older WAL frames replay onto pages that already hold
// them, whereas a newer WAL over an older main file could describe pages the copy never received.
export function copyCookieDb(profileDir, tempRoot) {
  const cookiesDb = path.join(profileDir, "cookies.sqlite");
  if (!existsSync(cookiesDb)) return null;
  let tmpDir;
  try {
    tmpDir = mkdtempSync(path.join(tempRoot, COOKIE_COPY_PREFIX));
  } catch {
    return null;
  }
  const tmpDb = path.join(tmpDir, "cookies.sqlite");
  try {
    const wal = `${cookiesDb}-wal`;
    if (existsSync(wal)) {
      try { copyFileSync(wal, `${tmpDb}-wal`); } catch {}
    }
    copyFileSync(cookiesDb, tmpDb);
    return { tmpDir, tmpDb };
  } catch {
    try { rmSync(tmpDir, { recursive: true, force: true }); } catch {}
    return null;
  }
}

// One copy per profile for the life of a snapshot. count is the number of copies made.
export function createCookieDbCopies(tempRoot, { copy = copyCookieDb } = {}) {
  const copies = new Map();
  let count = 0;
  return {
    get(profileDir) {
      const key = path.resolve(profileDir).toLowerCase();
      if (!copies.has(key)) {
        const made = copy(profileDir, tempRoot);
        if (made) count += 1;
        copies.set(key, made);
      }
      return copies.get(key);
    },
    get count() {
      return count;
    },
    dispose() {
      for (const made of copies.values()) {
        if (made) {
          try { rmSync(made.tmpDir, { recursive: true, force: true }); } catch {}
        }
      }
      copies.clear();
    }
  };
}

function sqlString(text) {
  return `'${String(text).replaceAll("'", "''")}'`;
}

// WHERE clause matching a cookie host to any of the hostnames or their subdomains.
export function buildCookieHostConditions(hostnames) {
  return hostnames
    .map(h => `host LIKE ${sqlString(`%.${h}`)} OR host = ${sqlString(h)}`)
    .join(" OR ");
}

// Latest expiry in unix seconds of the named session cookies (any cookie when no names are
// given) for the hostnames; 0 when there is none. Firefox stores expiry in seconds on older
// builds and milliseconds on newer ones.
export function sessionExpiryQuery(hostnames, sessionNames = []) {
  const nameCondition = sessionNames.length > 0
    ? ` AND name IN (${sessionNames.map(sqlString).join(", ")})`
    : "";
  return "SELECT COALESCE(MAX(CASE WHEN expiry > 99999999999 THEN expiry / 1000 ELSE expiry END), 0)"
    + ` FROM moz_cookies WHERE (${buildCookieHostConditions(hostnames)})${nameCondition};`;
}

// Runs sessionExpiryQuery on a database copy. null when there is no copy or the query fails.
export function querySessionExpiry(sqliteBin, dbCopy, hostnames, sessionNames = []) {
  if (!dbCopy || !sqliteBin || !existsSync(sqliteBin)) return null;
  if (hostnames.length === 0) return 0;
  try {
    const raw = execFileSync(sqliteBin, [dbCopy.tmpDb, sessionExpiryQuery(hostnames, sessionNames)], {
      encoding: "utf8",
      timeout: 5000,
      windowsHide: true
    }).trim();
    const expiry = Number.parseInt(raw, 10);
    return Number.isFinite(expiry) ? expiry : null;
  } catch {
    return null;
  }
}

// profiles: [{ name, fingerprint }]; cache: { [name]: { fingerprint, sessionExpiry } } from the
// last run. queryExpiry(profile) returns the latest session-cookie expiry in unix seconds (0 =
// none), or null when the query failed (then nothing is cached for that profile and it is
// re-checked next time). Returns { expiries: Map(name -> seconds), cache, changed, queried }.
export function resolveSessionExpiries(profiles, { cache = {}, queryExpiry }) {
  const expiries = new Map();
  const nextCache = {};
  let changed = false;
  let queried = 0;
  for (const profile of profiles) {
    const hit = cache && typeof cache === "object" ? cache[profile.name] : null;
    if (profile.fingerprint && hit && hit.fingerprint === profile.fingerprint && Number.isFinite(hit.sessionExpiry)) {
      expiries.set(profile.name, hit.sessionExpiry);
      nextCache[profile.name] = hit;
      continue;
    }
    queried += 1;
    const expiry = queryExpiry(profile);
    if (Number.isFinite(expiry)) {
      expiries.set(profile.name, expiry);
      if (profile.fingerprint) nextCache[profile.name] = { fingerprint: profile.fingerprint, sessionExpiry: expiry };
    } else {
      expiries.set(profile.name, 0);
    }
    changed = true;
  }
  if (Object.keys(cache || {}).some(name => !(name in nextCache))) changed = true;
  return { expiries, cache: nextCache, changed, queried };
}

// Removes leftover copy folders older than maxAgeMs (a younger one may belong to a snapshot
// that is still running). Returns how many were removed. Never throws.
export function sweepStaleTempDirs(tempRoot, { prefixes = STALE_TEMP_PREFIXES, maxAgeMs = STALE_TEMP_AGE_MS, now = Date.now() } = {}) {
  let removed = 0;
  let names = [];
  try {
    names = readdirSync(tempRoot);
  } catch {
    return 0;
  }
  for (const name of names) {
    if (!prefixes.some(prefix => name.startsWith(prefix))) continue;
    const full = path.join(tempRoot, name);
    const stats = statOrNull(full);
    if (!stats || !stats.isDirectory() || now - stats.mtimeMs < maxAgeMs) continue;
    try {
      rmSync(full, { recursive: true, force: true });
      removed += 1;
    } catch {}
  }
  return removed;
}
