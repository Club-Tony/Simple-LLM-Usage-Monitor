// Add-on provider: one extra usage column that a host script can plug in.
//
// The monitor itself reads Codex, Claude and Grok. A script that hosts the popup (it sets
// usageMonitorHostAddonModule before including Usage_Monitor_GUI.ahk) can name ONE extra provider
// module; the GUI passes that path to the bridge as -AddonModule and the bridge to this scraper as
// --addonModule. Nothing else can name it: no settings.ini key, no state file, no snapshot value,
// no environment variable and no folder scan. The standalone app never sets it, so for its users
// the add-on column does not exist.
//
// Contract for the module (an ES module, .mjs). Its default export is:
//   {
//     id:              "example"            lowercase letters, digits, "-"; up to 16 characters
//     label:           "Example"            header text, up to 7 characters
//     lineLabels:      ["Pro", "Flash"]     two row labels, up to 6 characters each
//     sourceTag:       "api"                source tag text, a-z, up to 8 characters
//     link:            "https://..."        header link, or "" for none (https, no query string)
//     signInHint:      "..."                one line, up to 120 characters, or ""
//     settingsWarning: "..."                one line under its Settings row, up to 120, or ""
//     async run(ctx)                        returns { status, lines, resetTexts, note, loginRequired }
//   }
// run() may use only what ctx gives it (see buildAddonContext) and must not write to the console;
// importing the module must not do anything (no file, network or process work at import time).
// When the add-on is switched off in Settings the module is not imported at all.
//
// An add-on is code the host chose to run with the user's own rights: ctx is a convenience, not a
// sandbox. Everything that comes back from it is still cleaned here before it reaches the snapshot.

import { existsSync, statSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { isUsableResult, safeErrorText } from "./cli-credentials.mjs";

export const ADDON_PATH_MAX_LENGTH = 260;
export const ADDON_LABEL_MAX_LENGTH = 7;
export const ADDON_LINE_LABEL_MAX_LENGTH = 6;
export const ADDON_TEXT_MAX_LENGTH = 120;
export const ADDON_DEFAULT_LABEL = "Add-on";
export const ADDON_ID_PATTERN = /^[a-z][a-z0-9-]{0,15}$/;
export const ADDON_SOURCE_PATTERN = /^[a-z]{1,8}$/;
// https only, a plain host and path: no port, query, fragment, "%" escapes, quotes or spaces. The GUI
// checks the same pattern again before it opens the link.
export const ADDON_LINK_PATTERN = /^https:\/\/[A-Za-z0-9.-]+(\/[A-Za-z0-9._~\/-]*)?$/;
// An absolute drive path (no UNC share, no relative path) to a .mjs file, without characters that
// cannot appear in a Windows path or that would break quoting on the way through the bridge.
const ADDON_PATH_PATTERN = /^[A-Za-z]:\\[^"<>|?*\x00-\x1f]+\.mjs$/i;
const LABEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 ._+-]*$/;
const RESULT_STATUSES = new Set(["ok", "partial", "login_required", "error", "no_subscription", "free"]);
const LINE_MAX_LENGTH = 80;
const RESET_MAX_LENGTH = 40;
const NOTE_MAX_LENGTH = 200;
const LOG_MAX_LENGTH = 400;

// The snapshot keys the add-on writes, in file order; only present when a host named a module.
export const ADDON_OUTPUT_KEYS = Object.freeze([
  "addon_status",
  "addon_source",
  "addon_label",
  "addon_line_1",
  "addon_line_2",
  "addon_line_1_reset_text",
  "addon_line_2_reset_text",
  "addon_link",
  "addon_hint",
  "addon_warning"
]);

// One line of display text: control characters removed, whitespace collapsed, length capped.
export function cleanAddonText(value, maxLength = ADDON_TEXT_MAX_LENGTH) {
  return String(value ?? "")
    .replace(/[\x00-\x1f\x7f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

// Path check before anything is imported. Reasons are fixed words, so they are safe to log; the
// path itself never reaches a log, because it holds the Windows user name.
export function checkAddonPath(value, { exists = existsSync, stat = statSync } = {}) {
  if (typeof value !== "string" || value === "" || value === "true") return { ok: false, reason: "no path" };
  if (value.length > ADDON_PATH_MAX_LENGTH) return { ok: false, reason: "path too long" };
  if (!ADDON_PATH_PATTERN.test(value)) return { ok: false, reason: "path rejected" };
  if (value.split("\\").some(segment => segment === "..")) return { ok: false, reason: "path rejected" };
  try {
    if (!exists(value) || !stat(value).isFile()) return { ok: false, reason: "file not found" };
  } catch {
    return { ok: false, reason: "file not found" };
  }
  return { ok: true, path: value };
}

function checkLabel(value, maxLength) {
  return typeof value === "string" && value.length >= 1 && value.length <= maxLength && LABEL_PATTERN.test(value);
}

function checkOptionalText(value) {
  if (value === undefined || value === null || value === "") return "";
  if (typeof value !== "string") return null;
  const text = cleanAddonText(value, ADDON_TEXT_MAX_LENGTH + 1);
  return text.length > ADDON_TEXT_MAX_LENGTH ? null : text;
}

// The module's default export -> { ok, meta } or { ok: false, reason } naming the first bad field.
export function validateAddonModule(moduleNamespace) {
  const definition = moduleNamespace?.default;
  if (!definition || typeof definition !== "object") return { ok: false, reason: "invalid module (no default export)" };
  const fail = field => ({ ok: false, reason: `invalid module (${field})` });
  if (typeof definition.id !== "string" || !ADDON_ID_PATTERN.test(definition.id)) return fail("id");
  if (!checkLabel(definition.label, ADDON_LABEL_MAX_LENGTH)) return fail("label");
  const lineLabels = definition.lineLabels;
  if (!Array.isArray(lineLabels) || lineLabels.length !== 2 || !lineLabels.every(label => checkLabel(label, ADDON_LINE_LABEL_MAX_LENGTH))) {
    return fail("lineLabels");
  }
  if (typeof definition.sourceTag !== "string" || !ADDON_SOURCE_PATTERN.test(definition.sourceTag)) return fail("sourceTag");
  const link = definition.link ?? "";
  if (typeof link !== "string" || (link !== "" && !ADDON_LINK_PATTERN.test(link))) return fail("link");
  const signInHint = checkOptionalText(definition.signInHint);
  if (signInHint === null) return fail("signInHint");
  const settingsWarning = checkOptionalText(definition.settingsWarning);
  if (settingsWarning === null) return fail("settingsWarning");
  if (typeof definition.run !== "function") return fail("run");
  const run = definition.run.bind(definition);
  return {
    ok: true,
    meta: Object.freeze({
      id: definition.id,
      label: definition.label,
      lineLabels: Object.freeze([...lineLabels]),
      sourceTag: definition.sourceTag,
      link,
      signInHint,
      settingsWarning,
      run
    })
  };
}

// Checks the path, imports the module and validates it. Never throws; an import error is reduced
// to its code, because Node's message quotes the file URL (and so the user name).
export async function loadAddon(modulePath, { importFn = filePath => import(pathToFileURL(filePath).href), exists, stat } = {}) {
  const checked = checkAddonPath(modulePath, { exists, stat });
  if (!checked.ok) return { ok: false, reason: checked.reason };
  let moduleNamespace;
  try {
    moduleNamespace = await importFn(checked.path);
  } catch (error) {
    return { ok: false, reason: `import failed (${safeErrorText(error)})` };
  }
  return validateAddonModule(moduleNamespace);
}

// What run(ctx) may use. Cache keys are namespaced per add-on, so an add-on can neither read nor
// overwrite the monitor's own cached logins. log() lines get the scraper's usual debug handling
// (debug mode only, redacted when the debug file is written).
export function buildAddonContext(meta, {
  fetchWithTimeout,
  runPowerShellFile,
  tokenCache,
  discoveryGet,
  discoverySet,
  log = () => {},
  formatPercentLine,
  formatResetText,
  sanitize,
  timeoutMs,
  tokenExpirySkewMs,
  debug = false,
  now = Date.now
} = {}) {
  const key = name => `addon:${meta.id}:${String(name)}`;
  return Object.freeze({
    fetchWithTimeout,
    runPowerShellFile,
    cache: Object.freeze({
      get: name => tokenCache.get(key(name)),
      set: (name, value, expiresAt) => tokenCache.set(key(name), value, expiresAt),
      drop: name => tokenCache.drop(key(name))
    }),
    discovery: Object.freeze({
      get: name => discoveryGet(key(name)),
      set: (name, value, expiresAt) => discoverySet(key(name), value, expiresAt)
    }),
    log: line => log(cleanAddonText(line, LOG_MAX_LENGTH)),
    formatPercentLine,
    formatResetText,
    sanitize,
    timeoutMs,
    tokenExpirySkewMs,
    debug: Boolean(debug),
    now
  });
}

export function addonUnavailableLines(meta) {
  const [first, second] = meta?.lineLabels || [ADDON_DEFAULT_LABEL, ""];
  return [`${first}: unavailable`, second ? `${second}: unavailable` : ""];
}

function failureResult(meta, note, loginRequired = false) {
  return {
    status: loginRequired ? "login_required" : "error",
    lines: addonUnavailableLines(meta),
    resetTexts: ["", ""],
    note: cleanAddonText(note, NOTE_MAX_LENGTH),
    loginRequired
  };
}

function normalizeResult(meta, raw) {
  if (!raw || typeof raw !== "object") return failureResult(meta, `${meta.label}: no result`);
  const status = RESULT_STATUSES.has(raw.status) ? raw.status : "error";
  const fallback = addonUnavailableLines(meta);
  const rawLines = Array.isArray(raw.lines) ? raw.lines : [];
  const lines = [0, 1].map(index => {
    const text = cleanAddonText(rawLines[index], LINE_MAX_LENGTH);
    return text || fallback[index];
  });
  const rawResets = Array.isArray(raw.resetTexts) ? raw.resetTexts : [];
  return {
    status,
    lines,
    resetTexts: [0, 1].map(index => cleanAddonText(rawResets[index], RESET_MAX_LENGTH)),
    note: cleanAddonText(raw.note, NOTE_MAX_LENGTH),
    loginRequired: status === "login_required" || raw.loginRequired === true
  };
}

// Runs the add-on with a time limit and turns anything it does into a clean result. A timeout,
// a throw or a malformed result becomes an error row; nothing it returns is trusted as-is.
export async function runAddon(meta, ctx, { timeoutMs = 25000 } = {}) {
  let timer = null;
  const timedOut = new Promise(resolve => {
    timer = setTimeout(() => resolve({ timedOut: true }), timeoutMs);
  });
  try {
    const outcome = await Promise.race([
      Promise.resolve().then(() => meta.run(ctx)).then(result => ({ result })),
      timedOut
    ]);
    if (outcome.timedOut) return failureResult(meta, `${meta.label}: request timed out`);
    return normalizeResult(meta, outcome.result);
  } catch (error) {
    if (error?.name === "AbortError") return failureResult(meta, `${meta.label}: request timed out`);
    return failureResult(meta, `${meta.label}: add-on failed (${safeErrorText(error)})`);
  } finally {
    clearTimeout(timer);
  }
}

// The add-on's snapshot keys for one run. `source` is the module's tag when the result is usable.
export function addonOutputFields(meta, result) {
  const lines = Array.isArray(result?.lines) ? result.lines : addonUnavailableLines(meta);
  const resets = Array.isArray(result?.resetTexts) ? result.resetTexts : ["", ""];
  return {
    addon_status: result?.status || "error",
    addon_source: result?.status !== "off" && isUsableResult(result) ? meta.sourceTag : "",
    addon_label: meta.label,
    addon_line_1: cleanAddonText(lines[0], LINE_MAX_LENGTH),
    addon_line_2: cleanAddonText(lines[1], LINE_MAX_LENGTH),
    addon_line_1_reset_text: cleanAddonText(resets[0], RESET_MAX_LENGTH),
    addon_line_2_reset_text: cleanAddonText(resets[1], RESET_MAX_LENGTH),
    addon_link: meta.link,
    addon_hint: meta.signInHint,
    addon_warning: meta.settingsWarning
  };
}

// Switched off in Settings: the module was not imported, so there is no label or line text; the
// GUI keeps the last label it saw.
export function addonOffFields() {
  return {
    addon_status: "off",
    addon_source: "",
    addon_label: "",
    addon_line_1: "Off",
    addon_line_2: "",
    addon_line_1_reset_text: "",
    addon_line_2_reset_text: "",
    addon_link: "",
    addon_hint: "",
    addon_warning: ""
  };
}

// The module could not be used (bad path, import error, invalid export). `reason` is one of the
// fixed phrases above, so it is safe to show.
export function addonLoadFailureFields(reason) {
  return {
    addon_status: "error",
    addon_source: "",
    addon_label: "",
    addon_line_1: `${ADDON_DEFAULT_LABEL}: unavailable`,
    addon_line_2: "",
    addon_line_1_reset_text: "",
    addon_line_2_reset_text: "",
    addon_link: "",
    addon_hint: "",
    addon_warning: "",
    note: `${ADDON_DEFAULT_LABEL}: ${cleanAddonText(reason, 60)}`
  };
}
