// Tests for the add-on provider hook (release plan phase 7, "Phase 7 decisions"). Every value here
// is invented; the fixture modules are written to a scratch folder and removed afterwards.
import test, { after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  ADDON_LINK_PATTERN,
  ADDON_OUTPUT_KEYS,
  addonLoadFailureFields,
  addonOffFields,
  addonOutputFields,
  buildAddonContext,
  checkAddonPath,
  cleanAddonText,
  loadAddon,
  runAddon,
  validateAddonModule
} from "./addon-provider.mjs";

const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-addon-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const SECRET = "FIXTURE-addon-secret-0000000000000000000000000000";

function definition(overrides = {}) {
  return {
    id: "example",
    label: "Example",
    lineLabels: ["Pro", "Flash"],
    sourceTag: "api",
    link: "https://example.com/usage",
    signInHint: "Example sign-in required. Run example login, then Refresh.",
    settingsWarning: "Unofficial: check the provider's terms.",
    async run() {
      return { status: "ok", lines: ["Pro: 70% remaining", "Flash: 40% remaining"], resetTexts: ["resets 11/1 3pm", ""], note: "", loginRequired: false };
    },
    ...overrides
  };
}

function validMeta(overrides) {
  const checked = validateAddonModule({ default: definition(overrides) });
  assert.equal(checked.ok, true, checked.reason);
  return checked.meta;
}

function writeFixture(name, source) {
  const filePath = path.join(scratch, name);
  writeFileSync(filePath, source, "utf8");
  return filePath;
}

const FIXTURE_SOURCE = `export default {
  id: "fixture",
  label: "Fixture",
  lineLabels: ["Pro", "Flash"],
  sourceTag: "fix",
  link: "",
  signInHint: "",
  settingsWarning: "",
  async run(ctx) {
    return { status: "ok", lines: ["Pro: 55% remaining", "Flash: 10% remaining"], resetTexts: ["", ""] };
  }
};
`;

test("checkAddonPath accepts only an absolute drive path to an existing .mjs file", () => {
  const good = writeFixture("good.mjs", FIXTURE_SOURCE);
  assert.deepEqual(checkAddonPath(good), { ok: true, path: good });

  assert.equal(checkAddonPath(undefined).reason, "no path");
  assert.equal(checkAddonPath("").reason, "no path");
  assert.equal(checkAddonPath("true").reason, "no path");
  assert.equal(checkAddonPath("addon.mjs").reason, "path rejected");
  assert.equal(checkAddonPath(".\\addon.mjs").reason, "path rejected");
  assert.equal(checkAddonPath("\\\\server\\share\\addon.mjs").reason, "path rejected");
  assert.equal(checkAddonPath("C:\\addons\\addon.js").reason, "path rejected");
  assert.equal(checkAddonPath("C:\\addons\\add\"on.mjs").reason, "path rejected");
  assert.equal(checkAddonPath("C:\\addons\\..\\addon.mjs").reason, "path rejected");
  assert.equal(checkAddonPath("C:/addons/addon.mjs").reason, "path rejected");
  assert.equal(checkAddonPath(`C:\\${"a".repeat(260)}.mjs`).reason, "path too long");
  assert.equal(checkAddonPath(path.join(scratch, "missing.mjs")).reason, "file not found");
  assert.equal(checkAddonPath(scratch + "\\folder.mjs", { exists: () => true, stat: () => ({ isFile: () => false }) }).reason, "file not found");
});

test("validateAddonModule enforces every metadata limit", () => {
  assert.equal(validateAddonModule({}).ok, false);
  assert.equal(validateAddonModule({ default: 5 }).ok, false);
  const reasonFor = overrides => validateAddonModule({ default: definition(overrides) }).reason;
  assert.equal(reasonFor({ id: "Bad Id" }), "invalid module (id)");
  assert.equal(reasonFor({ label: "TooLongX" }), "invalid module (label)");
  assert.equal(reasonFor({ label: "" }), "invalid module (label)");
  assert.equal(reasonFor({ label: "a\nb" }), "invalid module (label)");
  assert.equal(reasonFor({ lineLabels: ["Pro"] }), "invalid module (lineLabels)");
  assert.equal(reasonFor({ lineLabels: ["Pro", "Flashes"] }), "invalid module (lineLabels)");
  assert.equal(reasonFor({ sourceTag: "API" }), "invalid module (sourceTag)");
  assert.equal(reasonFor({ sourceTag: "toolongtag" }), "invalid module (sourceTag)");
  assert.equal(reasonFor({ signInHint: "x".repeat(121) }), "invalid module (signInHint)");
  assert.equal(reasonFor({ settingsWarning: 7 }), "invalid module (settingsWarning)");
  assert.equal(reasonFor({ run: "not a function" }), "invalid module (run)");

  const meta = validMeta({ link: "", signInHint: undefined, settingsWarning: "two\nlines" });
  assert.equal(meta.link, "");
  assert.equal(meta.signInHint, "");
  assert.equal(meta.settingsWarning, "two lines");
  assert.ok(Object.isFrozen(meta));
});

test("the link pattern allows a plain https URL and nothing that could become a command", () => {
  for (const ok of ["https://example.com", "https://example.com/", "https://sub.example.com/a/b-c_d.e~f"]) {
    assert.ok(ADDON_LINK_PATTERN.test(ok), ok);
  }
  for (const bad of [
    "http://example.com",
    "https://example.com/?q=1",
    "https://example.com/#x",
    "https://example.com:8443/",
    "https://example.com/%20",
    "https://example.com/a b",
    "https://example.com/\"&calc",
    "https://user@example.com/",
    "file:///C:/Windows/System32/calc.exe",
    "cmd.exe /c calc"
  ]) {
    assert.equal(ADDON_LINK_PATTERN.test(bad), false, bad);
    assert.equal(validateAddonModule({ default: definition({ link: bad }) }).reason, "invalid module (link)", bad);
  }
});

test("loadAddon imports a valid fixture and reports failures without the path", async () => {
  const good = writeFixture("load-good.mjs", FIXTURE_SOURCE);
  const loaded = await loadAddon(good);
  assert.equal(loaded.ok, true, loaded.reason);
  assert.equal(loaded.meta.label, "Fixture");

  const broken = writeFixture("load-broken.mjs", "export default {\n");
  const failed = await loadAddon(broken);
  assert.equal(failed.ok, false);
  assert.match(failed.reason, /^import failed \([A-Za-z0-9_.-]+\)$/);
  assert.ok(!failed.reason.includes(scratch) && !failed.reason.includes(os.userInfo().username));

  const invalid = writeFixture("load-invalid.mjs", "export default { id: 'x' };\n");
  assert.equal((await loadAddon(invalid)).reason, "invalid module (label)");

  const rejected = await loadAddon("relative.mjs", { importFn: () => { throw new Error("must not import"); } });
  assert.equal(rejected.reason, "path rejected");
});

test("a module is never imported when its path fails the check", async () => {
  const marker = path.join(scratch, "import-marker.txt");
  const fixture = writeFixture("side-effect.js", `import { writeFileSync } from "node:fs"; writeFileSync(${JSON.stringify(marker)}, "imported"); export default {};\n`);
  const loaded = await loadAddon(fixture);
  assert.equal(loaded.reason, "path rejected");
  assert.equal(existsSync(marker), false);
});

test("buildAddonContext namespaces cache keys and passes log lines through cleaned", async () => {
  const meta = validMeta();
  const tokenStore = new Map();
  const discoveryStore = new Map();
  const logged = [];
  const ctx = buildAddonContext(meta, {
    tokenCache: {
      get: async key => tokenStore.get(key) ?? null,
      set: async (key, value) => { tokenStore.set(key, value); },
      drop: async key => { tokenStore.delete(key); }
    },
    discoveryGet: key => discoveryStore.get(key) ?? null,
    discoverySet: (key, value) => { discoveryStore.set(key, value); },
    log: line => logged.push(line),
    timeoutMs: 1234
  });
  await ctx.cache.set("token", { token: SECRET }, Date.now() + 1000);
  assert.deepEqual([...tokenStore.keys()], ["addon:example:token"]);
  assert.deepEqual(await ctx.cache.get("token"), { token: SECRET });
  assert.equal(await ctx.cache.get("codex:token:(default)"), null, "an add-on cannot read the monitor's own keys");
  await ctx.cache.drop("token");
  assert.equal(tokenStore.size, 0);
  ctx.discovery.set("tier", { state: "paid" }, Date.now() + 1000);
  assert.deepEqual([...discoveryStore.keys()], ["addon:example:tier"]);
  ctx.log("line one\r\nline two");
  assert.deepEqual(logged, ["line one line two"]);
  assert.equal(ctx.timeoutMs, 1234);
  assert.ok(Object.isFrozen(ctx) && Object.isFrozen(ctx.cache));
});

test("runAddon normalises results and turns throws, timeouts and junk into error rows", async () => {
  const ok = await runAddon(validMeta(), {});
  assert.equal(ok.status, "ok");
  assert.deepEqual(ok.lines, ["Pro: 70% remaining", "Flash: 40% remaining"]);
  assert.deepEqual(ok.resetTexts, ["resets 11/1 3pm", ""]);

  const junk = await runAddon(validMeta({ run: async () => ({ status: "hacked", lines: ["a\nb=c", 42], note: "x".repeat(500) }) }), {});
  assert.equal(junk.status, "error");
  assert.deepEqual(junk.lines, ["a b=c", "42"]);
  assert.equal(junk.note.length, 200);

  const empty = await runAddon(validMeta({ run: async () => null }), {});
  assert.equal(empty.status, "error");
  assert.deepEqual(empty.lines, ["Pro: unavailable", "Flash: unavailable"]);

  const thrown = await runAddon(validMeta({ run: async () => { throw Object.assign(new Error(`token ${SECRET}`), { code: "EBOOM" }); } }), {});
  assert.equal(thrown.status, "error");
  assert.equal(thrown.note, "Example: add-on failed (EBOOM)");
  assert.ok(!JSON.stringify(thrown).includes(SECRET));

  const aborted = await runAddon(validMeta({ run: async () => { throw Object.assign(new Error("aborted"), { name: "AbortError" }); } }), {});
  assert.equal(aborted.note, "Example: request timed out");

  const slow = await runAddon(validMeta({ run: () => new Promise(() => {}) }), {}, { timeoutMs: 20 });
  assert.equal(slow.status, "error");
  assert.equal(slow.note, "Example: request timed out");

  const signIn = await runAddon(validMeta({ run: async () => ({ status: "login_required", lines: [], note: "sign in" }) }), {});
  assert.equal(signIn.loginRequired, true);
  assert.deepEqual(signIn.lines, ["Pro: unavailable", "Flash: unavailable"]);
});

test("addonOutputFields writes every add-on key and tags only a usable result", () => {
  const meta = validMeta();
  const fields = addonOutputFields(meta, { status: "ok", lines: ["Pro: 70% remaining", "Flash: 40% remaining"], resetTexts: ["resets 11/1 3pm", ""] });
  assert.deepEqual(Object.keys(fields), [...ADDON_OUTPUT_KEYS]);
  assert.equal(fields.addon_source, "api");
  assert.equal(fields.addon_label, "Example");
  assert.equal(fields.addon_link, "https://example.com/usage");
  assert.equal(addonOutputFields(meta, { status: "error", lines: ["Pro: unavailable", "Flash: unavailable"] }).addon_source, "");

  const off = addonOffFields();
  assert.deepEqual(Object.keys(off), [...ADDON_OUTPUT_KEYS]);
  assert.equal(off.addon_status, "off");

  const failed = addonLoadFailureFields("import failed (ERR_X)");
  assert.equal(failed.addon_status, "error");
  assert.equal(failed.note, "Add-on: import failed (ERR_X)");
  for (const key of ADDON_OUTPUT_KEYS) assert.ok(key in failed, key);
});

test("cleanAddonText strips control characters and caps the length", () => {
  assert.equal(cleanAddonText("a\u0000b\tc\r\nd"), "a b c d");
  assert.equal(cleanAddonText("x".repeat(200), 10), "x".repeat(10));
  assert.equal(cleanAddonText(undefined), "");
});
