// CLI logins as a usage source (release plan A4, checklist G4): Claude Code, Codex CLI and Grok CLI
// keep their sign-in in a JSON file under the user's home folder. On every snapshot the monitor
// reads that file and sends its access token to the same provider's usage endpoint; when the
// login is missing, expired or rejected, the caller falls back to Firefox cookies.
//
// Rules this module keeps:
//   - Read only. The one file-system call is readFileSync; nothing here writes, renames, copies
//     or deletes, and the login file is read again on each snapshot (never cached anywhere).
//   - Never refresh. An expired token is reported as "expired" and the caller falls back.
//     Refreshing would rotate the CLI's refresh token and could sign that CLI out.
//   - The token lives only inside headers(); no returned string, JSON form or log line holds it.
//   - A token goes only to its own provider's fixed usage URL, and never through a redirect.
//
// fs, env, homeDir, now and fetch are injectable for tests.

import { readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// Requests that carry a CLI token name the tool honestly (owner decision, 2026-10-26). Requests that carry
// Firefox cookies keep the Firefox User-Agent (decision C3, usage-scraper.mjs).
export const TOOL_USER_AGENT = "LLMUsageMonitor/1.0";
// Replaces the home folder for all three lookups (ignoring CLAUDE_CONFIG_DIR and CODEX_HOME).
// For tests and unusual setups; pointing it at an empty folder forces the Firefox fallback.
export const CLI_HOME_ENV = "LLM_USAGE_CLI_HOME";
export const EXPIRY_SKEW_MS = 60 * 1000;
export const CLAUDE_OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
export const CLAUDE_OAUTH_BETA = "oauth-2025-04-20";
export const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
// The Grok CLI's own billing call, on the CLI proxy host that xAI's Grok CLI README documents for
// auth.json tokens ("Using auth.json for API Access"; moved here from grok.com after the C1 terms
// review, owner decision 2026-10-26). A Grok CLI token never goes to grok.com.
export const GROK_CLI_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
// The one JSON usage call each CLI login makes.
const CLI_USAGE_URLS = { claude: CLAUDE_OAUTH_USAGE_URL, codex: CODEX_USAGE_URL, grok: GROK_CLI_BILLING_URL };

const realFs = { readFileSync };
// Printable ASCII without spaces: anything else cannot be a header value, and undici's error
// for an invalid header value would quote it.
const HEADER_SAFE = /^[\x21-\x7E]+$/;
const USABLE_STATUSES = new Set(["ok", "partial", "free", "no_subscription"]);

function nonEmpty(value) {
  const text = String(value ?? "").trim();
  return text || "";
}

export function cliLoginPaths({ env = process.env, homeDir = os.homedir() } = {}) {
  const override = nonEmpty(env?.[CLI_HOME_ENV]);
  const home = override || homeDir;
  const claudeDir = (!override && nonEmpty(env?.CLAUDE_CONFIG_DIR)) || path.join(home, ".claude");
  const codexDir = (!override && nonEmpty(env?.CODEX_HOME)) || path.join(home, ".codex");
  return {
    claude: path.join(claudeDir, ".credentials.json"),
    codex: path.join(codexDir, "auth.json"),
    grok: path.join(home, ".grok", "auth.json")
  };
}

function readLoginFile(fs, filePath) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    const code = error?.code;
    return { state: code === "ENOENT" || code === "ENOTDIR" ? "missing" : "unreadable" };
  }
  try {
    const data = JSON.parse(String(raw).replace(/^\uFEFF/, ""));
    return data && typeof data === "object" && !Array.isArray(data) ? { data } : { state: "malformed" };
  } catch {
    return { state: "malformed" };
  }
}

function toEpochMs(value) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value > 1e12 ? value : value * 1000;
  }
  if (typeof value === "string" && value.trim()) {
    if (/^\d+$/.test(value.trim())) return toEpochMs(Number(value.trim()));
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function jwtExpiryMs(token) {
  try {
    const parts = String(token).split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    return toEpochMs(payload?.exp);
  } catch {
    return null;
  }
}

function headerSafe(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return HEADER_SAFE.test(text) ? text : "";
}

// The login object a caller sees. headers() is the only way to the token, and it is not an
// enumerable property, so JSON.stringify(login) and string templates never include it.
function makeLogin(provider, cliName, state, { expiresAtMs = null, plan = "", buildHeaders = null } = {}) {
  const login = { provider, cliName, state, expiresAtMs, plan };
  Object.defineProperty(login, "headers", {
    value: () => (state === "ok" && buildHeaders ? buildHeaders() : {}),
    enumerable: false
  });
  return Object.freeze(login);
}

// A known expiry in the past (with a minute of skew) means "expired". An unknown expiry is tried:
// the server rejects a stale token, and the caller then falls back.
function finishLogin(provider, cliName, expiresAtMs, now, plan, buildHeaders) {
  const state = Number.isFinite(expiresAtMs) && expiresAtMs - EXPIRY_SKEW_MS <= now() ? "expired" : "ok";
  return makeLogin(provider, cliName, state, { expiresAtMs, plan, buildHeaders });
}

// Claude Code: <CLAUDE_CONFIG_DIR or ~\.claude>\.credentials.json ->
// claudeAiOauth.{accessToken, expiresAt (ms), subscriptionType}. The access token lives 8 hours
// and Claude Code renews it only while it runs.
export function claudePlanState(subscriptionType) {
  const plan = nonEmpty(subscriptionType).toLowerCase();
  if (!plan) return "unknown";
  return plan === "free" ? "free" : "active";
}

export function readClaudeCodeLogin({ fs = realFs, env = process.env, homeDir = os.homedir(), now = Date.now } = {}) {
  const file = readLoginFile(fs, cliLoginPaths({ env, homeDir }).claude);
  if (file.state) return makeLogin("claude", "Claude Code", file.state);
  const oauth = file.data.claudeAiOauth;
  const token = headerSafe(oauth?.accessToken);
  if (!token) return makeLogin("claude", "Claude Code", "malformed");
  return finishLogin("claude", "Claude Code", toEpochMs(oauth.expiresAt), now, claudePlanState(oauth.subscriptionType), () => ({
    "Authorization": `Bearer ${token}`,
    "anthropic-beta": CLAUDE_OAUTH_BETA,
    "Accept": "application/json",
    "User-Agent": TOOL_USER_AGENT
  }));
}

// Codex CLI: <CODEX_HOME or ~\.codex>\auth.json -> tokens.{access_token (JWT, about 10 days),
// account_id}. A login made with an API key only has no ChatGPT usage to read: "unsupported".
export function readCodexCliLogin({ fs = realFs, env = process.env, homeDir = os.homedir(), now = Date.now } = {}) {
  const file = readLoginFile(fs, cliLoginPaths({ env, homeDir }).codex);
  if (file.state) return makeLogin("codex", "Codex CLI", file.state);
  const tokens = file.data.tokens;
  const token = headerSafe(tokens?.access_token);
  if (!token) {
    return makeLogin("codex", "Codex CLI", nonEmpty(file.data.OPENAI_API_KEY) ? "unsupported" : "malformed");
  }
  const accountId = headerSafe(tokens.account_id);
  return finishLogin("codex", "Codex CLI", jwtExpiryMs(token), now, "", () => ({
    "Authorization": `Bearer ${token}`,
    ...(accountId ? { "ChatGPT-Account-Id": accountId } : {}),
    "Accept": "application/json",
    "User-Agent": TOOL_USER_AGENT
  }));
}

// Grok CLI: ~\.grok\auth.json -> one entry (keyed by sign-in URL) with key (a JWT, about 6 hours),
// expires_at and user_id. The Grok CLI deletes this file itself when its login can no longer be
// renewed. The headers are the ones the README names for the proxy (X-XAI-Token-Auth tells it to
// validate a CLI session token), plus the x-userid header the Grok CLI's own billing call sends.
export function readGrokCliLogin({ fs = realFs, env = process.env, homeDir = os.homedir(), now = Date.now } = {}) {
  const file = readLoginFile(fs, cliLoginPaths({ env, homeDir }).grok);
  if (file.state) return makeLogin("grok", "Grok CLI", file.state);
  // One entry per sign-in; should there ever be several, the one expiring last is the live one.
  const entries = Object.values(file.data)
    .filter(value => value && typeof value === "object" && !Array.isArray(value) && headerSafe(value.key))
    .map(value => ({ value, expiresAtMs: toEpochMs(value.expires_at) ?? jwtExpiryMs(value.key) }))
    .sort((a, b) => (b.expiresAtMs ?? -Infinity) - (a.expiresAtMs ?? -Infinity));
  const entry = entries[0]?.value;
  const token = headerSafe(entry?.key);
  if (!token) return makeLogin("grok", "Grok CLI", "malformed");
  const expiresAtMs = entries[0].expiresAtMs;
  const userId = headerSafe(entry.user_id);
  return finishLogin("grok", "Grok CLI", expiresAtMs, now, "", () => ({
    "Authorization": `Bearer ${token}`,
    "X-XAI-Token-Auth": "xai-grok-cli",
    ...(userId ? { "x-userid": userId } : {}),
    "Accept": "application/json",
    "User-Agent": TOOL_USER_AGENT
  }));
}

function formatHours(ms) {
  const hours = ms / 3600000;
  return hours >= 48 ? `${Math.round(hours / 24)}d` : `${hours.toFixed(1)}h`;
}

// Token-free phrase for debug lines: "Claude Code login ok, expires in 7.2h",
// "Grok CLI login expired 2.1h ago", "Codex CLI login missing".
export function describeLogin(login, nowMs = Date.now()) {
  if (!login) return "CLI login unknown";
  const text = `${login.cliName} login ${login.state}`;
  if (!Number.isFinite(login.expiresAtMs) || (login.state !== "ok" && login.state !== "expired")) {
    return text;
  }
  const delta = login.expiresAtMs - nowMs;
  if (login.state === "expired") {
    return delta > 0 ? `${text} (expires within a minute)` : `${text} ${formatHours(-delta)} ago`;
  }
  return delta > 0 ? `${text}, expires in ${formatHours(delta)}` : `${text}, expiry passed`;
}

export function isAuthRejection(status, grpcStatus = null) {
  return status === 401 || status === 403 || String(grpcStatus ?? "") === "16";
}

// Error text that cannot carry a header value: the error's code or name only, never its message.
export function safeErrorText(error) {
  const code = error?.cause?.code || error?.code || error?.name || "error";
  return String(code).replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 40) || "error";
}

// One request with a CLI token. Never follows a redirect, so the token cannot be forwarded.
export async function fetchCliJson({ url, headers, fetch: fetchImpl = globalThis.fetch, timeoutMs = 12000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, { method: "GET", headers, redirect: "error", signal: controller.signal });
    if (isAuthRejection(response.status)) return { kind: "rejected", status: response.status };
    if (!response.ok) return { kind: "http-error", status: response.status };
    try {
      return { kind: "ok", status: response.status, body: await response.json() };
    } catch {
      return { kind: "invalid-json", status: response.status };
    }
  } catch (error) {
    if (error?.name === "AbortError") return { kind: "timeout" };
    return { kind: "error", code: safeErrorText(error) };
  } finally {
    clearTimeout(timer);
  }
}

// A CLI login's usage call (Claude Code, Codex CLI or Grok CLI), reduced to what the scraper needs:
// { body } to parse, { rejected: true, status } (Firefox fallback), or { note } for any other failure.
// Its one debug line carries the HTTP status or failure kind only.
export async function fetchCliUsage({ login, label, fetch: fetchImpl = globalThis.fetch, timeoutMs = 12000, log = () => {} }) {
  const url = CLI_USAGE_URLS[login?.provider];
  if (!url || login.state !== "ok") return { note: `${label}: no usable CLI login` };
  const reply = await fetchCliJson({ url, headers: login.headers(), fetch: fetchImpl, timeoutMs });
  log(`CLI login fetch -> ${reply.status ? `HTTP ${reply.status}` : reply.kind}`);
  if (reply.kind === "rejected") return { rejected: true, status: reply.status };
  if (reply.kind === "ok") return { body: reply.body };
  if (reply.kind === "timeout") return { note: `${label}: request timed out` };
  if (reply.kind === "http-error") return { note: `${label}: HTTP ${reply.status}` };
  if (reply.kind === "invalid-json") return { note: `${label}: invalid JSON response` };
  return { note: `${label}: fetch failed (${reply.code})` };
}

// An answer worth showing. "partial" counts only when some line carries a number: a 200 whose body
// parsed to nothing must not hide a Firefox session that would have worked.
export function isUsableResult(result) {
  if (!result || !USABLE_STATUSES.has(result.status)) return false;
  if (result.status !== "partial") return true;
  return (Array.isArray(result.lines) ? result.lines : []).some(line => /\d+(\.\d+)?%/.test(String(line)));
}

// CLI first, Firefox second. runCli(login) resolves to { result } or { rejected: true, status };
// runFirefox() resolves to a provider result. The returned result carries `source`:
//   "cli"     - the CLI login supplied it (or the CLI call failed for a reason other than a
//               rejection and Firefox could not do better: that error says more than "sign in")
//   "firefox" - the Firefox fallback supplied it
//   ""        - neither worked
export async function resolveCliFirst({ login, runCli, runFirefox, label = "", log = () => {}, now = Date.now }) {
  let cliFailure = null;
  if (login?.state === "ok") {
    let attempt;
    try {
      attempt = await runCli(login);
    } catch (error) {
      attempt = { result: { status: "error", note: `CLI request failed (${safeErrorText(error)})` } };
    }
    if (attempt && !attempt.rejected && isUsableResult(attempt.result)) {
      log(`${describeLogin(login, now())} -> used`);
      return { ...attempt.result, source: "cli" };
    }
    if (attempt?.rejected) {
      log(`${describeLogin(login, now())} -> rejected${attempt.status ? ` (HTTP ${attempt.status})` : ""}, trying Firefox`);
    } else {
      cliFailure = attempt?.result || null;
      if (cliFailure && cliFailure.status === "partial") {
        cliFailure = { ...cliFailure, status: "error", note: cliFailure.note || `${label || "Provider"}: response had no usage numbers` };
      }
      log(`${describeLogin(login, now())} -> request failed, trying Firefox`);
    }
  } else {
    log(`${describeLogin(login, now())} -> trying Firefox`);
  }

  // A throw in the fallback (the cookie-database build, say) stays this provider's error instead of
  // failing the whole snapshot and losing the other providers' answers.
  let firefoxResult;
  try {
    firefoxResult = await runFirefox();
  } catch (error) {
    firefoxResult = { status: "error", note: `${label || "Provider"}: fetch failed (Firefox fallback: ${safeErrorText(error)})`, loginRequired: false };
  }
  if (isUsableResult(firefoxResult)) {
    return { ...firefoxResult, source: "firefox" };
  }
  if (cliFailure && (!firefoxResult || firefoxResult.status === "login_required")) {
    return { ...cliFailure, source: "cli" };
  }
  return { ...(firefoxResult || { status: "error" }), source: "" };
}
