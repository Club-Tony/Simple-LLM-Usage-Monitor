import test, { after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  CLAUDE_DESKTOP_LABEL_ENV,
  claudeDesktopLabelOptedIn,
  extractClaudeAccountLabelFromOrganizations,
  maskEmailForDisplay,
  readClaudeDesktopAccountLabel
} from "./claude-account-label.mjs";

const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-claude-label-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

// A fake APPDATA holding a Claude Desktop leveldb folder with an invented address.
const appData = path.join(scratch, "AppData", "Roaming");
const leveldb = path.join(appData, "Claude", "Local Storage", "leveldb");
mkdirSync(leveldb, { recursive: true });
writeFileSync(path.join(leveldb, "000003.log"), Buffer.from("\u0000\u0001junk jane.fixture42@example.com more\u0000", "latin1"));

// Every fs call throws and is counted, so a test can prove the folder was never touched.
function trippedFs() {
  const calls = [];
  const trip = name => (...args) => { calls.push([name, ...args]); throw new Error(`fs.${name} must not be called`); };
  return { calls, fs: { existsSync: trip("existsSync"), readdirSync: trip("readdirSync"), readFileSync: trip("readFileSync"), statSync: trip("statSync") } };
}

test("the Claude Desktop scan is off unless the opt-in is exactly 1", () => {
  assert.equal(claudeDesktopLabelOptedIn({}), false);
  assert.equal(claudeDesktopLabelOptedIn({ [CLAUDE_DESKTOP_LABEL_ENV]: "" }), false);
  assert.equal(claudeDesktopLabelOptedIn({ [CLAUDE_DESKTOP_LABEL_ENV]: "0" }), false);
  assert.equal(claudeDesktopLabelOptedIn({ [CLAUDE_DESKTOP_LABEL_ENV]: "true" }), false);
  assert.equal(claudeDesktopLabelOptedIn({ [CLAUDE_DESKTOP_LABEL_ENV]: " 1 " }), true);
});

test("with the opt-in unset, no file-system call is made, even with Claude Desktop storage present", () => {
  const { calls, fs } = trippedFs();
  assert.equal(readClaudeDesktopAccountLabel({ env: { APPDATA: appData }, platform: "win32", fs }), "");
  assert.equal(readClaudeDesktopAccountLabel({ env: { APPDATA: appData, [CLAUDE_DESKTOP_LABEL_ENV]: "0" }, platform: "win32", fs }), "");
  assert.deepEqual(calls, []);
  // The real fs with the default (unset) environment of this test run reads nothing either.
  assert.equal(readClaudeDesktopAccountLabel({ env: { APPDATA: appData }, platform: "win32" }), "");
});

test("with the opt-in set, the newest storage file yields a masked label only", () => {
  const label = readClaudeDesktopAccountLabel({ env: { APPDATA: appData, [CLAUDE_DESKTOP_LABEL_ENV]: "1" }, platform: "win32" });
  assert.equal(label, "j***42@example.com");
  assert.equal(readClaudeDesktopAccountLabel({ env: { APPDATA: appData, [CLAUDE_DESKTOP_LABEL_ENV]: "1" }, platform: "linux" }), "");
  assert.equal(readClaudeDesktopAccountLabel({ env: { APPDATA: path.join(scratch, "missing"), [CLAUDE_DESKTOP_LABEL_ENV]: "1" }, platform: "win32" }), "");
});

test("org-response labels and masking are unchanged", () => {
  assert.equal(extractClaudeAccountLabelFromOrganizations([{ name: "jane.fixture42@example.com's Organization" }]), "j***42@example.com");
  assert.equal(extractClaudeAccountLabelFromOrganizations({ organizations: [{ name: "Team" }] }), "");
  assert.equal(maskEmailForDisplay("ab@Example.COM"), "a***b@example.com");
  assert.equal(maskEmailForDisplay("not an email"), "");
});
