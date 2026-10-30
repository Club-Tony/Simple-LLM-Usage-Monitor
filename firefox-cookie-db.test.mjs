import test, { after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  STALE_TEMP_PREFIXES,
  buildCookieHostConditions,
  cookieDbFingerprint,
  copyCookieDb,
  createCookieDbCopies,
  querySessionExpiry,
  resolveSessionExpiries,
  sweepStaleTempDirs
} from "./firefox-cookie-db.mjs";

const sqliteBin = path.join(path.dirname(fileURLToPath(import.meta.url)), "sqlite3.exe");
const needsSqlite = process.platform !== "win32" || !existsSync(sqliteBin) ? "needs the bundled sqlite3.exe" : false;
const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-cookie-db-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const nowSec = Math.floor(Date.now() / 1000);
const HOSTS = ["claude.ai"];
const SESSION = ["sessionKey"];
const SCHEMA = "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER);";
const cookieRow = (name, host, expiry) => `INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure, isHttpOnly) VALUES ('${name}', 'fixture-value', '${host}', '/', ${expiry}, 1, 1);`;

function sqlite(dbPath, sql) {
  return execFileSync(sqliteBin, [dbPath, sql], { encoding: "utf8", windowsHide: true }).trim();
}

// A fake Firefox profile folder holding a cookies.sqlite with the given rows (WAL mode, like Firefox).
function makeProfile(root, name, rows) {
  const dir = path.join(root, name);
  mkdirSync(dir, { recursive: true });
  sqlite(path.join(dir, "cookies.sqlite"), ["PRAGMA journal_mode=WAL;", SCHEMA, ...rows].join(" "));
  return { name, path: dir };
}

// The scraper's listing in miniature: fingerprint, cached expiries, one copy per profile.
function listSignedIn(profiles, cache) {
  const copyRoot = path.join(scratch, "copies");
  mkdirSync(copyRoot, { recursive: true });
  const dbCopies = createCookieDbCopies(copyRoot);
  try {
    const candidates = profiles.map(p => ({ ...p, fingerprint: cookieDbFingerprint(p.path) }));
    const resolved = resolveSessionExpiries(candidates, {
      cache,
      queryExpiry: profile => querySessionExpiry(sqliteBin, dbCopies.get(profile.path), HOSTS, SESSION)
    });
    const signedIn = candidates.filter(p => (resolved.expiries.get(p.name) ?? 0) > nowSec).map(p => p.name);
    return { ...resolved, signedIn, copies: dbCopies.count };
  } finally {
    dbCopies.dispose();
  }
}

test("host conditions match the host and its subdomains and escape quotes", () => {
  assert.equal(buildCookieHostConditions(["claude.ai"]), "host LIKE '%.claude.ai' OR host = 'claude.ai'");
  assert.equal(buildCookieHostConditions(["o'x.com"]), "host LIKE '%.o''x.com' OR host = 'o''x.com'");
});

test("resolveSessionExpiries re-reads only profiles whose cookie files changed", () => {
  const calls = [];
  const queryExpiry = profile => { calls.push(profile.name); return profile.name === "broken" ? null : 1000; };
  const first = resolveSessionExpiries(
    [{ name: "a", fingerprint: "1" }, { name: "b", fingerprint: "2" }, { name: "broken", fingerprint: "3" }],
    { cache: {}, queryExpiry });
  assert.deepEqual(calls, ["a", "b", "broken"]);
  assert.equal(first.changed, true);
  assert.deepEqual(Object.keys(first.cache), ["a", "b"]);   // a failed query is not cached
  assert.equal(first.expiries.get("broken"), 0);

  calls.length = 0;
  const second = resolveSessionExpiries(
    [{ name: "a", fingerprint: "1" }, { name: "b", fingerprint: "2-changed" }],
    { cache: first.cache, queryExpiry });
  assert.deepEqual(calls, ["b"]);
  assert.equal(second.queried, 1);
  assert.equal(second.changed, true);

  calls.length = 0;
  const third = resolveSessionExpiries([{ name: "a", fingerprint: "1" }], { cache: second.cache, queryExpiry });
  assert.deepEqual(calls, []);
  assert.equal(third.changed, true);                          // b disappeared from the cache
  assert.deepEqual(Object.keys(third.cache), ["a"]);
  const fourth = resolveSessionExpiries([{ name: "a", fingerprint: "1" }], { cache: third.cache, queryExpiry });
  assert.equal(fourth.changed, false);
});

test("a snapshot copies each profile once and removes every copy", () => {
  const made = [];
  const copies = createCookieDbCopies(scratch, {
    copy: dir => {
      made.push(dir);
      if (dir.includes("missing")) return null;
      const tmpDir = mkdtempSync(path.join(scratch, "fake-copy-"));
      return { tmpDir, tmpDb: path.join(tmpDir, "cookies.sqlite") };
    }
  });
  const a = copies.get(path.join(scratch, "Profile-A"));
  assert.equal(copies.get(path.join(scratch, "profile-a")), a);
  assert.equal(copies.get(path.join(scratch, "missing")), null);
  assert.equal(copies.get(path.join(scratch, "missing")), null);
  assert.equal(made.length, 2);
  assert.equal(copies.count, 1);
  assert.ok(existsSync(a.tmpDir));
  copies.dispose();
  assert.equal(existsSync(a.tmpDir), false);
});

test("stale copy folders are swept, a live one and unrelated entries are kept", () => {
  const root = mkdtempSync(path.join(scratch, "sweep-"));
  for (const prefix of STALE_TEMP_PREFIXES) mkdirSync(path.join(root, `${prefix}abc123`));
  mkdirSync(path.join(root, "unrelated-folder"));
  writeFileSync(path.join(root, `${STALE_TEMP_PREFIXES[0]}a-file`), "not a folder");
  assert.equal(sweepStaleTempDirs(root), 0);                  // all just made: could be a live snapshot
  const later = Date.now() + 11 * 60 * 1000;
  assert.equal(sweepStaleTempDirs(root, { now: later }), STALE_TEMP_PREFIXES.length);
  assert.deepEqual(readdirSync(root).sort(), [`${STALE_TEMP_PREFIXES[0]}a-file`, "unrelated-folder"]);
  assert.equal(sweepStaleTempDirs(path.join(root, "does-not-exist")), 0);
});

test("the signed-in list matches the old rule and survives a sign-in in one profile", { skip: needsSqlite }, () => {
  const root = mkdtempSync(path.join(scratch, "profiles-"));
  const profiles = [
    makeProfile(root, "a.seconds", [cookieRow("sessionKey", ".claude.ai", nowSec + 86400)]),
    makeProfile(root, "b.millis", [cookieRow("sessionKey", "claude.ai", (nowSec + 86400) * 1000)]),
    makeProfile(root, "c.expired", [cookieRow("sessionKey", ".claude.ai", nowSec - 60)]),
    makeProfile(root, "d.other", [cookieRow("sessionKey", ".example.com", nowSec + 86400), cookieRow("lastActiveOrg", ".claude.ai", nowSec + 86400)])
  ];

  const cold = listSignedIn(profiles, {});
  assert.deepEqual(cold.signedIn, ["a.seconds", "b.millis"]);
  assert.equal(cold.copies, 4);

  const steady = listSignedIn(profiles, cold.cache);
  assert.deepEqual(steady.signedIn, ["a.seconds", "b.millis"]);
  assert.equal(steady.queried, 0);
  assert.equal(steady.copies, 0);

  sqlite(path.join(profiles[2].path, "cookies.sqlite"), cookieRow("sessionKey", ".claude.ai", nowSec + 3600));
  const afterSignIn = listSignedIn(profiles, steady.cache);
  assert.deepEqual(afterSignIn.signedIn, ["a.seconds", "b.millis", "c.expired"]);
  assert.equal(afterSignIn.queried, 1);
  assert.equal(afterSignIn.copies, 1);
  assert.deepEqual(readdirSync(path.join(scratch, "copies")), []);
});

test("a missing temp folder means no copy, not an exception", { skip: needsSqlite }, () => {
  const root = mkdtempSync(path.join(scratch, "no-temp-"));
  const profile = makeProfile(root, "p", [cookieRow("sessionKey", ".claude.ai", nowSec + 60)]);
  assert.equal(copyCookieDb(profile.path, path.join(root, "missing-temp")), null);
  assert.equal(copyCookieDb(path.join(root, "no-such-profile"), root), null);
});

test("a sign-in still in cookies.sqlite-wal is seen through the copy", { skip: needsSqlite }, async () => {
  const root = mkdtempSync(path.join(scratch, "wal-"));
  const profile = makeProfile(root, "w.default", [cookieRow("other", ".claude.ai", nowSec + 86400)]);
  const db = path.join(profile.path, "cookies.sqlite");

  // Keep a writer open with checkpoints off, as a running Firefox would, so the new row lives
  // only in the WAL file.
  const writer = spawn(sqliteBin, [db], { stdio: ["pipe", "ignore", "ignore"], windowsHide: true });
  const exited = new Promise(resolve => writer.on("exit", resolve));
  try {
    writer.stdin.write(`PRAGMA wal_autocheckpoint=0;\n${cookieRow("sessionKey", ".claude.ai", nowSec + 86400)}\n`);
    const walPath = `${db}-wal`;
    for (let i = 0; i < 100 && !(existsSync(walPath) && statSync(walPath).size > 0); i += 1) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.ok(existsSync(walPath) && statSync(walPath).size > 0, "writer never produced a WAL");

    const copy = copyCookieDb(profile.path, root);
    try {
      assert.ok(existsSync(`${copy.tmpDb}-wal`));
      assert.ok(querySessionExpiry(sqliteBin, copy, HOSTS, SESSION) > nowSec);
    } finally {
      rmSync(copy.tmpDir, { recursive: true, force: true });
    }

    // The old way, main file only, misses it.
    const mainOnly = mkdtempSync(path.join(root, "main-only-"));
    copyFileSync(db, path.join(mainOnly, "cookies.sqlite"));
    assert.equal(querySessionExpiry(sqliteBin, { tmpDir: mainOnly, tmpDb: path.join(mainOnly, "cookies.sqlite") }, HOSTS, SESSION), 0);
  } finally {
    writer.stdin.end();
    await exited;
  }
});
