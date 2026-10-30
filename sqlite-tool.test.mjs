import test, { after } from "node:test";
import assert from "node:assert/strict";
import { getHashes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { crc32 } from "node:zlib";
import { SQLITE_TOOLS_ZIP, digestHex, ensureSqlite3, extractWithTar } from "./sqlite-tool.mjs";

// No network: every test hands ensureSqlite3 a fake fetch.
const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-sqlite-tool-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));
const windowsOnly = process.platform !== "win32" ? "uses Windows tar.exe" : false;

// A fresh temp root and an empty install folder per case.
function newCase() {
  const dir = mkdtempSync(path.join(scratch, "case-"));
  const tempRoot = path.join(dir, "temp");
  const installDir = path.join(dir, "install");
  mkdirSync(tempRoot);
  mkdirSync(installDir);
  return { tempRoot, dest: path.join(installDir, "sqlite3.exe") };
}

function fakeFetch(body, { status = 200, contentLength } = {}) {
  const calls = [];
  const impl = async (url, options) => {
    calls.push(url);
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: name => (name.toLowerCase() === "content-length" && contentLength !== undefined ? String(contentLength) : null) },
      arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)
    };
  };
  impl.calls = calls;
  return impl;
}

// Minimal zip writer (stored, no compression) so tests can build exact archives, including
// hostile member names that tar.exe itself refuses to create.
function storedZip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const { name, data } of entries) {
    const nameBuf = Buffer.from(name, "utf8");
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x21, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, nameBuf, data);
    centrals.push(central, nameBuf);
    offset += local.length + nameBuf.length + data.length;
  }
  const centralBuf = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBuf.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, centralBuf, end]);
}

const fakeExe = Buffer.from("MZ fake sqlite3 test bytes");
const pinFor = zip => ({ ...SQLITE_TOOLS_ZIP, digest: digestHex(zip, SQLITE_TOOLS_ZIP.algorithm) });

test("the pinned download is the official 3.47.2 zip with a well-formed SHA3-256", () => {
  assert.match(SQLITE_TOOLS_ZIP.url, /^https:\/\/www\.sqlite\.org\/\d{4}\/sqlite-tools-win-x64-3470200\.zip$/);
  assert.equal(SQLITE_TOOLS_ZIP.algorithm, "sha3-256");
  assert.ok(getHashes().includes("sha3-256"));
  assert.match(SQLITE_TOOLS_ZIP.digest, /^[0-9a-f]{64}$/);
});

test("a hash mismatch writes no sqlite3.exe, never extracts and leaves no temp folder", async () => {
  const { tempRoot, dest } = newCase();
  let extracted = false;
  const zip = storedZip([{ name: "sqlite-tools/sqlite3.exe", data: fakeExe }]);
  const fetchImpl = fakeFetch(zip);   // a real zip, but not the pinned one
  const result = await ensureSqlite3(dest, { fetchImpl, tempRoot, platform: "win32", extract: async () => { extracted = true; } });
  assert.deepEqual(result, { installed: false, reason: "hash-mismatch" });
  assert.equal(fetchImpl.calls.length, 1);
  assert.equal(extracted, false);
  assert.equal(existsSync(dest), false);
  assert.deepEqual(readdirSync(path.dirname(dest)), []);
  assert.deepEqual(readdirSync(tempRoot), []);
});

test("a non-2xx response, an empty body or an oversized one installs nothing", async () => {
  for (const [fetchImpl, reason] of [
    [fakeFetch(Buffer.from("not found"), { status: 404 }), "http-404"],
    [fakeFetch(Buffer.alloc(0)), "empty"],
    [fakeFetch(Buffer.from("x"), { contentLength: SQLITE_TOOLS_ZIP.maxBytes + 1 }), "too-large"]
  ]) {
    const { tempRoot, dest } = newCase();
    const result = await ensureSqlite3(dest, { fetchImpl, tempRoot, platform: "win32", extract: async () => { throw new Error("must not extract"); } });
    assert.deepEqual(result, { installed: false, reason });
    assert.equal(existsSync(dest), false);
    assert.deepEqual(readdirSync(tempRoot), []);
  }
});

test("an existing sqlite3.exe or a non-Windows platform makes no request", async () => {
  const fetchImpl = fakeFetch(Buffer.from("unused"));
  const existing = newCase();
  writeFileSync(existing.dest, "already installed");
  assert.deepEqual(await ensureSqlite3(existing.dest, { fetchImpl, platform: "win32" }), { installed: false, reason: "present" });
  assert.equal(readFileSync(existing.dest, "utf8"), "already installed");
  const { dest } = newCase();
  assert.deepEqual(await ensureSqlite3(dest, { fetchImpl, platform: "linux" }), { installed: false, reason: "not-windows" });
  assert.equal(fetchImpl.calls.length, 0);
});

test("a zip matching the pin installs sqlite3.exe through tar.exe and cleans up", { skip: windowsOnly }, async () => {
  const { tempRoot, dest } = newCase();
  const zip = storedZip([
    { name: "sqlite-tools-win-x64-3470200/sqldiff.exe", data: Buffer.from("other tool") },
    { name: "sqlite-tools-win-x64-3470200/sqlite3.exe", data: fakeExe }
  ]);
  const result = await ensureSqlite3(dest, { fetchImpl: fakeFetch(zip), pin: pinFor(zip), tempRoot, platform: "win32" });
  assert.deepEqual(result, { installed: true, reason: "downloaded" });
  assert.deepEqual(readFileSync(dest), fakeExe);
  assert.deepEqual(readdirSync(path.dirname(dest)), ["sqlite3.exe"]);
  assert.deepEqual(readdirSync(tempRoot), []);
});

test("a member path that climbs out of the extract folder is not written there", { skip: windowsOnly }, async () => {
  const { tempRoot, dest } = newCase();
  const zip = storedZip([{ name: "../sqlite3.exe", data: fakeExe }]);
  let escaped = null;
  const extract = async (zipPath, destDir) => {
    try {
      await extractWithTar(zipPath, destDir);
    } finally {
      escaped = existsSync(path.join(destDir, "..", "sqlite3.exe"));
    }
  };
  const result = await ensureSqlite3(dest, { fetchImpl: fakeFetch(zip), pin: pinFor(zip), tempRoot, platform: "win32", extract });
  assert.equal(escaped, false);
  assert.equal(result.installed, false);
  assert.equal(existsSync(dest), false);
  assert.deepEqual(readdirSync(tempRoot), []);
});
