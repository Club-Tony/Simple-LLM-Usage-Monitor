// Tests for the per-provider Settings choices (release plan D5). Every credential here is invented.
import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_PROVIDER_PREFS,
  PROVIDERS_ARG_MAX_LENGTH,
  firefoxCookieKeys,
  formatProviderPrefs,
  isProviderEnabled,
  normalizeProviderPref,
  offResult,
  overallStatusFor,
  parseProviderPrefs,
  resolveProviderSource,
  shouldWriteClaudeProfileKeys,
  sourceOrder
} from "./provider-settings.mjs";

const NOW = Date.parse("2026-10-26T12:00:00Z");
const HOUR = 60 * 60 * 1000;
const now = () => NOW;
const SECRET = "FIXTURE-secret-token-0000000000000000000000000000";

function fakeLogin(state = "ok", { provider = "codex", cliName = "Codex CLI", expiresAtMs = NOW + 3 * HOUR } = {}) {
  const login = { provider, cliName, state, expiresAtMs, plan: "" };
  Object.defineProperty(login, "headers", { value: () => ({ Authorization: `Bearer ${SECRET}` }), enumerable: false });
  return Object.freeze(login);
}

const OK_RESULT = Object.freeze({ status: "ok", lines: ["Daily: 80% remaining", "Weekly: 60% remaining"], resetTexts: ["", ""], note: "", loginRequired: false });
const LOGIN_REQUIRED = Object.freeze({ status: "login_required", lines: ["Daily: unavailable", "Weekly: unavailable"], resetTexts: ["", ""], note: "Codex login required.", loginRequired: true });

// Spied callbacks: each records its calls; run order and return values are configurable.
function spies({ login = fakeLogin(), cli = { result: OK_RESULT }, firefox = OK_RESULT } = {}) {
  const calls = { readLogin: 0, runCli: 0, runFirefox: 0 };
  const lines = [];
  const call = value => (typeof value === "function" ? value() : value);
  return {
    calls,
    lines,
    options: {
      readLogin: () => { calls.readLogin += 1; return login; },
      runCli: async () => { calls.runCli += 1; return call(cli); },
      runFirefox: async () => { calls.runFirefox += 1; return call(firefox); },
      log: line => lines.push(line),
      now
    }
  };
}

test("parse: no argument, an empty one or a bare flag gives the defaults (every provider on)", () => {
  for (const value of [undefined, "", "true"]) {
    const parsed = parseProviderPrefs(value);
    assert.deepEqual({ ...parsed.prefs }, { ...DEFAULT_PROVIDER_PREFS });
    assert.equal(parsed.given, false);
    assert.deepEqual([...parsed.ignored], []);
  }
  assert.deepEqual({ ...DEFAULT_PROVIDER_PREFS }, { codex: "auto", claude: "auto", grok: "auto", addon: "on" });
});

test("parse: a full valid value gives exactly those choices", () => {
  const parsed = parseProviderPrefs("codex=firefox,claude=cli,grok=off,addon=off");
  assert.deepEqual({ ...parsed.prefs }, { codex: "firefox", claude: "cli", grok: "off", addon: "off" });
  assert.equal(parsed.given, true);
  assert.deepEqual([...parsed.ignored], []);
});

test("parse: upper case is accepted and lowercased", () => {
  assert.deepEqual({ ...parseProviderPrefs("CODEX=CLI,Addon=Off").prefs }, { codex: "cli", claude: "auto", grok: "auto", addon: "off" });
});

test("parse: an unknown provider is ignored and listed; the other entries still apply", () => {
  const parsed = parseProviderPrefs("cursor=off,claude=off");
  assert.equal(parsed.prefs.claude, "off");
  assert.deepEqual([...parsed.ignored], ["cursor"]);
});

test("parse: an unknown value turns that provider off (fails closed) and is listed", () => {
  const parsed = parseProviderPrefs("codex=sometimes,claude=cli");
  assert.equal(parsed.prefs.codex, "off");
  assert.equal(parsed.prefs.claude, "cli");
  assert.deepEqual([...parsed.ignored], ["codex=sometimes"]);
});

test("parse: the CLI providers do not take on (anything else: off); an unknown provider is ignored", () => {
  assert.equal(parseProviderPrefs("cursor=on").prefs.cursor, undefined);
  assert.deepEqual([...parseProviderPrefs("cursor=on").ignored], ["cursor"]);
  assert.equal(parseProviderPrefs("codex=on").prefs.codex, "off");
  assert.equal(parseProviderPrefs("grok=on").prefs.grok, "off");
});

test("parse: the add-on takes only on/off (anything else: off) and defaults to on", () => {
  assert.equal(parseProviderPrefs("addon=off").prefs.addon, "off");
  assert.equal(parseProviderPrefs("addon=on").prefs.addon, "on");
  assert.equal(parseProviderPrefs("addon=cli").prefs.addon, "off");
  assert.equal(parseProviderPrefs("addon=firefox").prefs.addon, "off");
  assert.equal(parseProviderPrefs("codex=off").prefs.addon, "on");
  assert.equal(normalizeProviderPref("addon", "junk"), "on");
  assert.equal(normalizeProviderPref("addon", "OFF"), "off");
});

test("parse: providers missing from a given value keep their defaults", () => {
  assert.deepEqual({ ...parseProviderPrefs("grok=off").prefs }, { codex: "auto", claude: "auto", grok: "off", addon: "on" });
});

test("parse: a repeated provider takes its last value", () => {
  assert.equal(parseProviderPrefs("codex=off,codex=cli").prefs.codex, "cli");
});

const ALL_OFF = { codex: "off", claude: "off", grok: "off", addon: "off" };

test("parse: a value over the length cap turns every provider off", () => {
  const value = `codex=auto,${"x".repeat(PROVIDERS_ARG_MAX_LENGTH)}`;
  const parsed = parseProviderPrefs(value);
  assert.deepEqual({ ...parsed.prefs }, ALL_OFF);
  assert.deepEqual([...parsed.ignored], ["invalid value, all off"]);
});

test("parse: any character outside a-z, = and , turns every provider off", () => {
  for (const value of ["codex=auto;rm", "codex=auto&claude=auto", "codex=auto claude=auto", "codex=auto\nclaude=auto", "codex=auto,--debug", "codex=auto,\"x\""]) {
    const parsed = parseProviderPrefs(value);
    assert.deepEqual({ ...parsed.prefs }, ALL_OFF, value);
    assert.deepEqual([...parsed.ignored], ["invalid value, all off"], value);
  }
});

test("parse: a non-string value gives the defaults", () => {
  for (const value of [42, {}, ["codex=off"], null]) {
    assert.deepEqual({ ...parseProviderPrefs(value).prefs }, { ...DEFAULT_PROVIDER_PREFS });
  }
});

test("parse: the result is frozen", () => {
  const parsed = parseProviderPrefs("codex=off");
  assert.ok(Object.isFrozen(parsed));
  assert.ok(Object.isFrozen(parsed.prefs));
  assert.ok(Object.isFrozen(parsed.ignored));
});

test("parse: empty segments are skipped", () => {
  assert.deepEqual({ ...parseProviderPrefs(",,codex=off,,").prefs }, { codex: "off", claude: "auto", grok: "auto", addon: "on" });
});

test("normalizeProviderPref: unknown providers get nothing", () => {
  assert.equal(normalizeProviderPref("cursor", "auto"), "");
  assert.equal(normalizeProviderPref("claude", " Firefox "), "firefox");
});

test("sourceOrder covers every choice and its arrays are frozen", () => {
  assert.deepEqual([...sourceOrder("auto")], ["cli", "firefox"]);
  assert.deepEqual([...sourceOrder("cli")], ["cli"]);
  assert.deepEqual([...sourceOrder("firefox")], ["firefox"]);
  assert.deepEqual([...sourceOrder("on")], []);
  assert.deepEqual([...sourceOrder("off")], []);
  assert.deepEqual([...sourceOrder("bogus")], []);
  assert.ok(Object.isFrozen(sourceOrder("auto")));
  assert.equal(isProviderEnabled({ codex: "off" }, "codex"), false);
  assert.equal(isProviderEnabled({ codex: "cli" }, "codex"), true);
});

test("firefoxCookieKeys lists only the CLI providers allowed to read Firefox, never the add-on", () => {
  assert.deepEqual(firefoxCookieKeys(DEFAULT_PROVIDER_PREFS), ["codex", "claude", "grok"]);
  assert.deepEqual(firefoxCookieKeys({ ...DEFAULT_PROVIDER_PREFS, claude: "cli" }), ["codex", "grok"]);
  assert.deepEqual(firefoxCookieKeys({ ...DEFAULT_PROVIDER_PREFS, claude: "off" }), ["codex", "grok"]);
  assert.deepEqual(firefoxCookieKeys({ codex: "cli", claude: "cli", grok: "cli", addon: "on" }), []);
  assert.deepEqual(firefoxCookieKeys({ codex: "off", claude: "firefox", grok: "off", addon: "on" }), ["claude"]);
});

test("formatProviderPrefs round-trips through parseProviderPrefs", () => {
  const prefs = { codex: "firefox", claude: "cli", grok: "off", addon: "off" };
  const text = formatProviderPrefs(prefs);
  assert.equal(text, "codex=firefox,claude=cli,grok=off,addon=off");
  assert.deepEqual({ ...parseProviderPrefs(text).prefs }, prefs);
  assert.equal(formatProviderPrefs({}), "codex=auto,claude=auto,grok=auto,addon=on");
});

test("offResult has the off status, Off lines and no source for each provider", () => {
  assert.deepEqual(offResult("codex").lines, ["Daily: Off", "Weekly: Off"]);
  assert.deepEqual(offResult("claude").lines, ["Daily: Off", "Weekly: Off"]);
  assert.deepEqual(offResult("grok").lines, ["Weekly: Off", ""]);
  for (const provider of ["codex", "claude", "grok"]) {
    const result = offResult(provider);
    assert.equal(result.status, "off");
    assert.equal(result.source, "");
    assert.equal(result.loginRequired, false);
    assert.equal(result.note, "");
  }
});

test("off: no login read, no CLI call, no Firefox call, one log line", async () => {
  for (const provider of ["codex", "claude", "grok"]) {
    const s = spies();
    const result = await resolveProviderSource({ provider, pref: "off", label: provider, ...s.options });
    assert.deepEqual(s.calls, { readLogin: 0, runCli: 0, runFirefox: 0 }, provider);
    assert.equal(result.status, "off");
    assert.equal(result.source, "");
    assert.deepEqual(s.lines, ["off -> skipped"]);
  }
});

test("Firefox only: the CLI login is never read and the CLI never called", async () => {
  let s = spies();
  let result = await resolveProviderSource({ provider: "codex", pref: "firefox", label: "Codex", ...s.options });
  assert.deepEqual(s.calls, { readLogin: 0, runCli: 0, runFirefox: 1 });
  assert.equal(result.source, "firefox");
  assert.deepEqual(s.lines, ["Firefox only: CLI login not read"]);
  s = spies({ firefox: LOGIN_REQUIRED });
  result = await resolveProviderSource({ provider: "codex", pref: "firefox", label: "Codex", ...s.options });
  assert.equal(result.status, "login_required");
  assert.equal(result.source, "");
  assert.equal(s.calls.readLogin, 0);
});

test("Firefox only: a throw becomes this provider's error with the code only", async () => {
  const s = spies({ firefox: () => { throw Object.assign(new Error(`cookie db ${SECRET}`), { code: "EBUSY" }); } });
  const result = await resolveProviderSource({ provider: "claude", pref: "firefox", label: "Claude", ...s.options });
  assert.equal(result.status, "error");
  assert.match(result.note, /EBUSY/);
  assert.ok(!result.note.includes(SECRET));
  assert.equal(s.calls.readLogin, 0);
});

test("CLI only, working login: the CLI answers and Firefox is never called", async () => {
  const s = spies();
  const result = await resolveProviderSource({ provider: "codex", pref: "cli", label: "Codex", ...s.options });
  assert.deepEqual(s.calls, { readLogin: 1, runCli: 1, runFirefox: 0 });
  assert.equal(result.source, "cli");
  assert.equal(result.status, "ok");
});

for (const state of ["missing", "expired", "unsupported", "malformed"]) {
  test(`CLI only, login ${state}: sign-in needed, no CLI call, no Firefox call`, async () => {
    const s = spies({ login: fakeLogin(state) });
    const result = await resolveProviderSource({ provider: "codex", pref: "cli", label: "Codex", ...s.options });
    assert.deepEqual(s.calls, { readLogin: 1, runCli: 0, runFirefox: 0 });
    assert.equal(result.status, "login_required");
    assert.equal(result.loginRequired, true);
    assert.equal(result.source, "");
    assert.match(result.note, /Codex CLI login/);
    assert.match(result.note, /Run codex, then Refresh/);
    assert.match(s.lines[0], /^CLI only: Codex CLI login .* -> no Firefox fallback$/);
  });
}

test("CLI only, Grok and Claude name their own sign-in command", async () => {
  let s = spies({ login: fakeLogin("expired", { provider: "grok", cliName: "Grok CLI" }) });
  let result = await resolveProviderSource({ provider: "grok", pref: "cli", label: "Grok", ...s.options });
  assert.match(result.note, /Run grok login, then Refresh/);
  assert.deepEqual(result.lines, ["Weekly: unavailable", ""]);
  s = spies({ login: null });
  result = await resolveProviderSource({ provider: "claude", pref: "cli", label: "Claude", ...s.options });
  assert.match(result.note, /Run claude, then Refresh/);
  assert.equal(s.calls.runFirefox, 0);
});

test("CLI only, rejected token: sign-in needed and Firefox is never called", async () => {
  const s = spies({ cli: { rejected: true, status: 401 } });
  const result = await resolveProviderSource({ provider: "codex", pref: "cli", label: "Codex", ...s.options });
  assert.equal(s.calls.runFirefox, 0);
  assert.equal(result.status, "login_required");
  assert.match(result.note, /was rejected \(HTTP 401\)/);
});

test("CLI only, server error: the CLI's error is kept and Firefox is never called", async () => {
  const s = spies({ cli: { result: { status: "error", lines: ["Daily: unavailable", "Weekly: unavailable"], resetTexts: ["", ""], note: "Codex: HTTP 500", loginRequired: false } } });
  const result = await resolveProviderSource({ provider: "codex", pref: "cli", label: "Codex", ...s.options });
  assert.equal(s.calls.runFirefox, 0);
  assert.equal(result.status, "error");
  assert.equal(result.note, "Codex: HTTP 500");
  assert.equal(result.source, "cli");
});

test("CLI only, a 200 with no numbers becomes an error, not a usable answer", async () => {
  const s = spies({ cli: { result: { status: "partial", lines: ["Daily: unavailable", "Weekly: unavailable"], resetTexts: ["", ""], note: "", loginRequired: false } } });
  const result = await resolveProviderSource({ provider: "codex", pref: "cli", label: "Codex", ...s.options });
  assert.equal(s.calls.runFirefox, 0);
  assert.equal(result.status, "error");
  assert.match(result.note, /no usage numbers/);
});

test("CLI only, a throw in the CLI call is an error with the code only", async () => {
  const s = spies({ cli: () => { throw Object.assign(new Error(`header ${SECRET}`), { code: "UND_ERR_INVALID_ARG" }); } });
  const result = await resolveProviderSource({ provider: "codex", pref: "cli", label: "Codex", ...s.options });
  assert.equal(s.calls.runFirefox, 0);
  assert.equal(result.status, "error");
  assert.match(result.note, /UND_ERR_INVALID_ARG/);
  assert.ok(!result.note.includes(SECRET));
});

test("auto: unchanged phase 3 behaviour (CLI first, Firefox fallback)", async () => {
  let s = spies();
  let result = await resolveProviderSource({ provider: "codex", pref: "auto", label: "Codex", ...s.options });
  assert.deepEqual(s.calls, { readLogin: 1, runCli: 1, runFirefox: 0 });
  assert.equal(result.source, "cli");
  s = spies({ login: fakeLogin("missing") });
  result = await resolveProviderSource({ provider: "codex", pref: "auto", label: "Codex", ...s.options });
  assert.deepEqual(s.calls, { readLogin: 1, runCli: 0, runFirefox: 1 });
  assert.equal(result.source, "firefox");
  assert.deepEqual(s.lines, ["Codex CLI login missing -> trying Firefox"]);
});

test("no debug line from any path carries a token", async () => {
  const lines = [];
  const cases = [
    { pref: "off" }, { pref: "firefox" }, { pref: "cli" }, { pref: "auto" },
    { pref: "cli", cli: { rejected: true, status: 403 } }, { pref: "cli", login: fakeLogin("expired") }
  ];
  for (const c of cases) {
    const s = spies(c);
    await resolveProviderSource({ provider: "codex", pref: c.pref, label: "Codex", ...s.options });
    lines.push(...s.lines);
  }
  assert.ok(lines.length >= 6);
  for (const line of lines) assert.ok(!line.includes(SECRET), line);
});

test("overallStatusFor: Off providers count for nothing; Grok and the add-on only lower ok to partial", () => {
  const ok = { codex: "ok", claude: "ok", grok: "ok", addon: "ok" };
  assert.equal(overallStatusFor(ok), "ok");
  assert.equal(overallStatusFor({ ...ok, codex: "error" }), "error");
  assert.equal(overallStatusFor({ ...ok, claude: "login_required" }), "login_required");
  assert.equal(overallStatusFor({ ...ok, codex: "off", claude: "off" }), "ok");
  assert.equal(overallStatusFor({ ...ok, codex: "off", claude: "error" }), "error");
  assert.equal(overallStatusFor({ ...ok, grok: "error" }), "partial");
  assert.equal(overallStatusFor({ ...ok, grok: "off", addon: "off" }), "ok");
  assert.equal(overallStatusFor({ ...ok, addon: "no_subscription" }), "ok");
  assert.equal(overallStatusFor({ ...ok, grok: "off", codex: "error" }), "error");
  assert.equal(overallStatusFor({ codex: "off", claude: "off", grok: "off", addon: "off" }), "ok");
  assert.equal(overallStatusFor({ ...ok, codex: "partial" }), "partial");
});

test("overallStatusFor: an absent provider counts for nothing; the add-on is best-effort", () => {
  const three = { codex: "ok", claude: "ok", grok: "ok" };
  assert.equal(overallStatusFor(three), "ok");
  assert.equal(overallStatusFor({ ...three, addon: undefined }), "ok");
  assert.equal(overallStatusFor({ ...three, addon: "ok" }), "ok");
  assert.equal(overallStatusFor({ ...three, addon: "error" }), "partial");
  assert.equal(overallStatusFor({ ...three, addon: "login_required" }), "partial");
  assert.equal(overallStatusFor({ ...three, addon: "off" }), "ok");
  assert.equal(overallStatusFor({ ...three, addon: "free" }), "ok");
  assert.equal(overallStatusFor({ ...three, codex: "error", addon: "ok" }), "error");
  assert.equal(overallStatusFor({}), "ok");
});

test("shouldWriteClaudeProfileKeys: only when Firefox was scanned for Claude and the CLI did not supply it", () => {
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "auto", source: "firefox", scanned: true }), true);
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "auto", source: "", scanned: true }), true);
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "firefox", source: "firefox", scanned: true }), true);
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "auto", source: "cli", scanned: true }), false);
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "off", source: "", scanned: true }), false);
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "cli", source: "", scanned: true }), false);
  assert.equal(shouldWriteClaudeProfileKeys({ pref: "auto", source: "firefox", scanned: false }), false);
});

// The scraper runs a whole snapshot on import, so its wiring is checked by source.
function functionBody(source, name) {
  const start = source.search(new RegExp(`^(async )?function ${name}[(]`, "m"));
  assert.ok(start >= 0, `${name} not found in usage-scraper.mjs`);
  const rest = source.slice(start + 1);
  const end = rest.search(/^(async )?function \w+[(]/m);
  return end >= 0 ? source.slice(start, start + 1 + end) : source.slice(start);
}

test("the scraper runs every provider through resolveProviderSource and honours the choices", async () => {
  const { readFileSync } = await import("node:fs");
  const scraper = readFileSync(new URL("./usage-scraper.mjs", import.meta.url), "utf8");
  const collect = functionBody(scraper, "collectSnapshotResults");
  assert.match(collect, /resolveProviderSource[(]/);
  assert.doesNotMatch(collect, /resolveCliFirst[(]/);
  assert.match(collect, /pref: providerPrefs[.]prefs\[provider[.]key\]/);
  // The choices are read above the top-level try (temporal dead zone).
  const topTry = scraper.search(/^try \{/m);
  assert.ok(topTry > 0);
  assert.ok(scraper.indexOf("const providerPrefs = parseProviderPrefs(args.providers)") > 0);
  assert.ok(scraper.indexOf("const providerPrefs = parseProviderPrefs(args.providers)") < topTry);
  assert.ok(scraper.indexOf("const firefoxCookieKeySet") < topTry);
  assert.ok(scraper.indexOf("let sqliteReadyPromise") < topTry);
  // sqlite setup happens only for the Firefox path.
  assert.equal((scraper.match(/ensureSqlite3[(]/g) || []).length, 1);
  assert.match(functionBody(scraper, "ensureSqliteOnce"), /ensureSqlite3[(]/);
  assert.match(functionBody(scraper, "buildFirefoxCookieContext"), /await ensureSqliteOnce[(][)]/);
  // The cookie context scans and extracts only for the providers allowed to read Firefox.
  const context = functionBody(scraper, "buildFirefoxCookieContextWith");
  assert.match(context, /firefoxCookieKeySet[.]has[(]"claude"[)]/);
  assert.match(context, /filter[(]k => firefoxCookieKeySet[.]has[(]k[)][)]/);
  assert.match(context, /claudeScanned: scanClaude/);
  // Profile keys, overall status and the off status.
  assert.match(scraper, /shouldWriteClaudeProfileKeys[(]\{ pref: providerPrefs[.]prefs[.]claude/);
  assert.match(scraper, /output[.]overall_status = overallStatusFor[(]/);
  assert.doesNotMatch(scraper, /computeOverallStatus/);
  assert.match(functionBody(scraper, "normalizeStatus"), /status === "off"/);
});

test("the scraper loads the add-on only from --addonModule, and never when it is off", async () => {
  const { readFileSync } = await import("node:fs");
  const scraper = readFileSync(new URL("./usage-scraper.mjs", import.meta.url), "utf8");
  const topTry = scraper.search(/^try [{]/m);
  assert.ok(scraper.indexOf("const addonModuleGiven = args.addonModule !== undefined;") > 0);
  assert.ok(scraper.indexOf("const addonModuleGiven = args.addonModule !== undefined;") < topTry);
  // The module path has one source: the argument. No settings, state, snapshot or environment value.
  assert.equal((scraper.match(/args[.]addonModule/g) || []).length, 2);
  assert.equal((scraper.match(/loadAddon[(]/g) || []).length, 1);
  const collect = functionBody(scraper, "collectAddonFields");
  assert.match(collect, /loadAddon[(]args[.]addonModule[)]/);
  assert.doesNotMatch(collect, /process[.]env/);
  const offCheck = collect.indexOf('providerPrefs.prefs.addon === "off"');
  assert.ok(offCheck > 0 && offCheck < collect.indexOf("loadAddon("), "off is decided before any import");
  assert.match(collect, /if [(]!addonModuleGiven[)] return null;/);
  // The add-on runs alongside the other providers, and its keys are written only when it exists.
  assert.match(scraper, /Promise[.]all[(][[][\s]*collectSnapshotResults[(]providerTimeout[)],[\s]*collectAddonFields[(]providerTimeout[)]/);
  assert.match(functionBody(scraper, "writeOutputFile"), /outputData[.]addon_status !== undefined [?] ADDON_OUTPUT_KEYS : [[][\]]/);
  assert.match(scraper, /addon: output[.]addon_status/);
});
