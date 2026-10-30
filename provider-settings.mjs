// Per-provider choices from the Settings window (release plan D5): whether each provider runs, and
// which login it may use. The GUI passes them through the bridge as
//   --providers codex=auto,claude=cli,grok=off,addon=on
//
//   auto    - the CLI login first, Firefox cookies as the fallback (the phase 3 behaviour)
//   cli     - the CLI login only; Firefox is never touched
//   firefox - Firefox cookies only; the CLI login file is never read
//   off     - nothing at all: no login read, no cookie query, no request
//
// "addon" (on / off) is the extra column a host script can plug in (addon-provider.mjs). It exists
// only when the host named a module (--addonModule); "off" means the module is not even imported.
//
// With no --providers argument every provider runs as before, so a hand-run scraper, the tests and
// an older GUI keep working.
//
// Everything a provider calls is passed in (readLogin, runCli, runFirefox, runDirect), so tests can
// prove with spies that "off" calls nothing and a forced source never touches the other one.

import { describeLogin, isUsableResult, resolveCliFirst, safeErrorText } from "./cli-credentials.mjs";

export const PROVIDER_KEYS = Object.freeze(["codex", "claude", "grok", "addon"]);
const CLI_PROVIDER_KEYS = Object.freeze(["codex", "claude", "grok"]);
// Providers whose only choice is on / off.
const ON_OFF_KEYS = Object.freeze(["addon"]);
export const SOURCE_PREFS = Object.freeze(["auto", "cli", "firefox", "off"]);
export const ADDON_PREFS = Object.freeze(["on", "off"]);
// The add-on defaults to on: a host that names a module has already chosen to show it.
export const DEFAULT_PROVIDER_PREFS = Object.freeze({ codex: "auto", claude: "auto", grok: "auto", addon: "on" });
// What a user runs to sign a CLI in again; named in the "CLI only" sign-in note.
export const CLI_SIGN_IN_COMMANDS = Object.freeze({ codex: "codex", claude: "claude", grok: "grok login" });
export const PROVIDERS_ARG_MAX_LENGTH = 200;
const ARG_PATTERN = /^[a-z=,]+$/;
const SEGMENT_PATTERN = /^([a-z]+)=([a-z]+)$/;

const SOURCE_ORDERS = Object.freeze({
  auto: Object.freeze(["cli", "firefox"]),
  cli: Object.freeze(["cli"]),
  firefox: Object.freeze(["firefox"]),
  off: Object.freeze([])
});

const OFF_LINES = Object.freeze({
  codex: Object.freeze(["Daily: Off", "Weekly: Off"]),
  claude: Object.freeze(["Daily: Off", "Weekly: Off"]),
  grok: Object.freeze(["Weekly: Off", ""])
});

const UNAVAILABLE_LINES = Object.freeze({
  codex: Object.freeze(["Daily: unavailable", "Weekly: unavailable"]),
  claude: Object.freeze(["Daily: unavailable", "Weekly: unavailable"]),
  grok: Object.freeze(["Weekly: unavailable", ""])
});

// One provider's choice, cleaned: an unknown value becomes that provider's default.
export function normalizeProviderPref(provider, value) {
  const text = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (ON_OFF_KEYS.includes(provider)) return ADDON_PREFS.includes(text) ? text : DEFAULT_PROVIDER_PREFS[provider];
  if (!CLI_PROVIDER_KEYS.includes(provider)) return "";
  return SOURCE_PREFS.includes(text) ? text : DEFAULT_PROVIDER_PREFS[provider];
}

const ALL_OFF = Object.freeze({ codex: "off", claude: "off", grok: "off", addon: "off" });

// The --providers value -> { prefs, given, ignored }. `given` says an argument was supplied;
// `ignored` lists what was dropped (charset-limited, so safe to log). A provider missing from a
// given value keeps its default. A value that cannot be read fails closed, so a garbled setting
// never makes requests the user switched off: one that is too long or has any character outside
// a-z, "=" and "," turns every provider off, and an unknown choice turns that provider off.
export function parseProviderPrefs(value) {
  const prefs = { ...DEFAULT_PROVIDER_PREFS };
  const ignored = [];
  const given = typeof value === "string" && value !== "" && value !== "true";
  const done = () => Object.freeze({ prefs: Object.freeze(prefs), given, ignored: Object.freeze(ignored) });
  if (!given) {
    if (value !== undefined && value !== null && value !== "" && value !== "true") ignored.push("invalid value");
    return done();
  }
  const text = value.trim().toLowerCase();
  if (text.length > PROVIDERS_ARG_MAX_LENGTH || !ARG_PATTERN.test(text)) {
    Object.assign(prefs, ALL_OFF);
    ignored.push("invalid value, all off");
    return done();
  }
  for (const segment of text.split(",")) {
    if (!segment) continue;
    const match = SEGMENT_PATTERN.exec(segment);
    if (!match) {
      ignored.push(segment);
      continue;
    }
    const [, provider, choice] = match;
    if (!PROVIDER_KEYS.includes(provider)) {
      ignored.push(provider);
      continue;
    }
    const allowed = ON_OFF_KEYS.includes(provider) ? ADDON_PREFS : SOURCE_PREFS;
    if (allowed.includes(choice)) {
      prefs[provider] = choice;
    } else {
      prefs[provider] = "off";
      ignored.push(segment);
    }
  }
  return done();
}

export function formatProviderPrefs(prefs) {
  return PROVIDER_KEYS.map(provider => `${provider}=${normalizeProviderPref(provider, prefs?.[provider])}`).join(",");
}

// The logins a choice may use, in order. Unknown choices use nothing.
export function sourceOrder(pref) {
  return SOURCE_ORDERS[pref] || SOURCE_ORDERS.off;
}

export function isProviderEnabled(prefs, provider) {
  return sourceOrder(prefs?.[provider]).length > 0;
}

// The providers whose Firefox cookies a snapshot may read; the cookie context extracts only these,
// and scans Firefox profiles for a Claude sign-in only when "claude" is listed.
export function firefoxCookieKeys(prefs) {
  return CLI_PROVIDER_KEYS.filter(provider => sourceOrder(prefs?.[provider]).includes("firefox"));
}

export function offResult(provider) {
  return {
    status: "off",
    lines: [...(OFF_LINES[provider] || OFF_LINES.codex)],
    resetTexts: ["", ""],
    note: "",
    loginRequired: false,
    source: ""
  };
}

function unavailableLines(provider) {
  return [...(UNAVAILABLE_LINES[provider] || UNAVAILABLE_LINES.codex)];
}

function baseOverallStatus(statuses) {
  if (statuses.includes("error")) return "error";
  if (statuses.includes("login_required")) return "login_required";
  if (statuses.includes("partial")) return "partial";
  return "ok";
}

// Codex and Claude set the overall status; Grok and the add-on are best-effort and can at most
// lower "ok" to "partial". A provider that is off counts for nothing either way, and so does one
// that is absent from this snapshot (no add-on module).
export function overallStatusFor({ codex, claude, grok, addon } = {}) {
  const present = status => status !== undefined && status !== null && status !== "off";
  let overall = baseOverallStatus([codex, claude].filter(present));
  const bestEffortHealthy = status => status === "ok" || status === "no_subscription" || status === "free";
  if (overall === "ok" && [grok, addon].filter(present).some(status => !bestEffortHealthy(status))) {
    overall = "partial";
  }
  return overall;
}

// The Claude account-switch keys belong to the Firefox path ("CLI wins; switch on fallback"): written
// only when this snapshot scanned the Firefox profiles for Claude and the CLI did not supply Claude.
export function shouldWriteClaudeProfileKeys({ pref, source, scanned } = {}) {
  return Boolean(scanned) && pref !== "off" && pref !== "cli" && source !== "cli";
}

function cliOnlySignInResult(provider, label, login, detail) {
  const cliName = login?.cliName || `${label} CLI`;
  const command = CLI_SIGN_IN_COMMANDS[provider] || "the CLI";
  return {
    status: "login_required",
    lines: unavailableLines(provider),
    resetTexts: ["", ""],
    note: `${label}: ${cliName} login ${detail}. Run ${command}, then Refresh.`,
    loginRequired: true,
    source: ""
  };
}

function errorResult(provider, note) {
  return { status: "error", lines: unavailableLines(provider), resetTexts: ["", ""], note, loginRequired: false };
}

// Runs one provider the way its choice allows and returns its result with `source` set
// ("cli" / "firefox" / ""). readLogin() reads the CLI login; runCli(login) resolves to
// { result } or { rejected: true, status }; runFirefox() resolves to a result.
export async function resolveProviderSource({
  provider,
  pref,
  label = "",
  readLogin,
  runCli,
  runFirefox,
  log = () => {},
  now = Date.now
} = {}) {
  const name = label || provider || "Provider";
  const choice = normalizeProviderPref(provider, pref);

  if (choice === "off" || choice === "") {
    log("off -> skipped");
    return offResult(provider);
  }

  if (choice === "firefox") {
    log("Firefox only: CLI login not read");
    let result;
    try {
      result = await runFirefox();
    } catch (error) {
      result = errorResult(provider, `${name}: fetch failed (Firefox: ${safeErrorText(error)})`);
    }
    result = result || errorResult(provider, `${name}: no result`);
    return { ...result, source: isUsableResult(result) ? "firefox" : "" };
  }

  if (choice === "cli") {
    const login = readLogin();
    if (login?.state !== "ok") {
      log(`CLI only: ${describeLogin(login, now())} -> no Firefox fallback`);
      return cliOnlySignInResult(provider, name, login, login?.state || "missing");
    }
    let attempt;
    try {
      attempt = await runCli(login);
    } catch (error) {
      attempt = { result: errorResult(provider, `${name}: CLI request failed (${safeErrorText(error)})`) };
    }
    if (attempt?.rejected) {
      log(`CLI only: ${describeLogin(login, now())} -> rejected${attempt.status ? ` (HTTP ${attempt.status})` : ""}`);
      return cliOnlySignInResult(provider, name, login, `was rejected${attempt.status ? ` (HTTP ${attempt.status})` : ""}`);
    }
    let result = attempt?.result || errorResult(provider, `${name}: no result`);
    if (result.status === "partial" && !isUsableResult(result)) {
      result = { ...result, status: "error", note: result.note || `${name}: response had no usage numbers` };
    }
    log(`CLI only: ${describeLogin(login, now())} -> ${isUsableResult(result) ? "used" : "request failed"}`);
    return { ...result, source: "cli" };
  }

  // auto: the phase 3 path, unchanged.
  return resolveCliFirst({ login: readLogin(), runCli, runFirefox, label: name, log, now });
}
