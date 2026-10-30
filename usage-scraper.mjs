import fs from "node:fs/promises";
import { existsSync, readFileSync, writeFileSync, renameSync, readdirSync, statSync, mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createTokenCache, removeLegacyPlaintextCache, runPowerShellFile } from "./token-cache.mjs";
import { debugJsonPreview, formatDebugLog, jsonKeyPaths, sanitize } from "./debug-redaction.mjs";
import { extractClaudeAccountLabelFromOrganizations, readClaudeDesktopAccountLabel } from "./claude-account-label.mjs";
import { ensureSqlite3 } from "./sqlite-tool.mjs";
import { buildCookieHostConditions, cookieDbFingerprint, createCookieDbCopies, querySessionExpiry, resolveSessionExpiries, sweepStaleTempDirs } from "./firefox-cookie-db.mjs";
import { chooseGrokUsagePercent, classifyClaudeSubscription, classifyCodexSubscription, classifyGrokBillingSubscription, classifyGrokSubscription, extractClaudeScopedWeeklyLimit, isClaudeNoSubscriptionUsage, parseGrokBillingUsage } from "./usage-classification.mjs";
import { fetchCliUsage, isAuthRejection, readClaudeCodeLogin, readCodexCliLogin, readGrokCliLogin } from "./cli-credentials.mjs";
import { firefoxCookieKeys, overallStatusFor, parseProviderPrefs, resolveProviderSource, shouldWriteClaudeProfileKeys } from "./provider-settings.mjs";
import { ADDON_OUTPUT_KEYS, addonLoadFailureFields, addonOffFields, addonOutputFields, buildAddonContext, loadAddon, runAddon } from "./addon-provider.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sqlite3Bin = path.join(__dirname, "sqlite3.exe");

const args = parseArgs(process.argv.slice(2));
const outFile = args.outFile || path.resolve(process.cwd(), "llm-usage-snapshot.txt");
const timeoutMs = toPositiveInt(args.timeoutMs, 30000);
const debugMode = args.debug === "true";
const requestedClaudeProfileName = sanitizeFirefoxProfileName(args.claudeProfile || process.env.LLM_USAGE_CLAUDE_PROFILE || "");
// The Settings window's per-provider choices (provider-settings.mjs): off / auto / cli / firefox, and
// on / off for a host's add-on. Without --providers every provider runs as before. A provider that is off
// reads no login, queries no cookie and makes no request.
const providerPrefs = parseProviderPrefs(args.providers);
// The providers allowed to read Firefox cookies; the cookie context extracts only these.
const firefoxCookieKeySet = new Set(firefoxCookieKeys(providerPrefs.prefs));
// The extra column a host script can plug in (addon-provider.mjs). Only the host can name the
// module, and only through this argument; without it the snapshot has no add-on keys at all.
const addonModuleGiven = args.addonModule !== undefined;
// The Claude Desktop label fallback is also opt-in (LLM_USAGE_CLAUDE_DESKTOP_LABEL=1, see
// claude-account-label.mjs); this flag further limits it to the default Firefox profile.
let allowClaudeDesktopAccountFallback = true;

const providers = [
  {
    key: "codex",
    label: "Codex",
    sessionUrl: "https://chatgpt.com/api/auth/session",
    apiUrl: "https://chatgpt.com/backend-api/wham/usage",
    refererUrl: "https://chatgpt.com/codex/settings/usage"
  },
  {
    key: "claude",
    label: "Claude",
    orgDiscoveryUrl: "https://claude.ai/api/organizations",
    apiUrlTemplate: "https://claude.ai/api/organizations/{orgId}/usage",
    // A profile only counts as a monitorable Claude account while this cookie is unexpired.
    // Without it, a profile that merely visited claude.ai (or was signed out months ago)
    // stays in the account-switch cycle and can be persisted as the monitored profile.
    sessionCookieName: "sessionKey",
    refererUrl: "https://claude.ai/settings/usage"
  },
  {
    // Grok exposes weekly Grok Build usage via a grpc-web (connect-es) call rather than
    // REST JSON. We POST the empty request frame and decode the protobuf response ourselves
    // (see runGrpcWebProvider / parseGrokCreditsUsage). Single "Weekly" window, no daily split.
    //
    // The credits call carries usage but NOT entitlement: an unsubscribed account still gets
    // a valid weekly config, and proto3 omits the zero percent, so it reads as "100% remaining"
    // exactly like a fresh subscriber's. subscriptionsUrl is the separate entitlement lookup
    // (plain REST JSON, same role as Claude's orgDiscoveryUrl → billing_type); see
    // discoverGrokSubscriptionState / classifyGrokSubscription.
    key: "grok",
    label: "Grok",
    apiUrl: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig",
    subscriptionsUrl: "https://grok.com/rest/subscriptions",
    refererUrl: "https://grok.com/?_s=usage",
    responseKind: "grpc-web",
    grpcContentType: "application/grpc-web+proto",
    grpcBody: [0, 0, 0, 0, 0],
    grpcExtraHeaders: { "x-grpc-web": "1", "x-user-agent": "connect-es/2.1.1" },
    singleWindow: true
  }
];

// --- Discovery cache ---------------------------------------------------------
// Only the *discovery* half of a snapshot is cached - the Codex bearer token and the
// Claude org lookup. The usage numbers are never cached; re-reading them is the entire
// point of a snapshot. This removes two of the six HTTPS requests each run makes,
// which matters because the GUI's cadence is now adaptive and can poll several times
// more often while values are actually moving.
//
// Correctness rules:
//   - keyed by Firefox profile, so switching Claude accounts can never reuse the
//     previous account's org UUID
//   - the Codex entry expires from the JWT's own `exp` claim, never a guessed TTL,
//     so a cached credential cannot outlive the real one
//   - a 401/403 on the usage call drops the entry and retries once with fresh
//     discovery, so a stale entry costs one extra request rather than a false
//     "login required"
//   - every read and write is wrapped: a missing, unreadable, corrupt, or
//     concurrently-written cache file just means a miss, and the run proceeds
//     exactly as it did before this cache existed
//
// Storage is split by sensitivity, both in the per-user data folder (--dataDir, which the GUI
// always passes; %LOCALAPPDATA%\LLMUsageMonitor when run by hand - keep that name in step with
// usageMonitorAppDirName in Usage_Monitor_GUI.ahk):
//   - credentials (the Codex bearer token, and anything a host's add-on caches through its
//     ctx.cache) go through tokenCache: DPAPI-encrypted, see token-cache.mjs
//   - everything else (the Claude org lookup, per-profile session expiries, an add-on's
//     ctx.discovery entries) stays in the plain JSON discovery cache below, so reading it never spawns anything
// The pre-DPAPI file in %TEMP% held credentials in plaintext and is deleted when found.
const usageStateDir = args.dataDir
  ? path.resolve(args.dataDir)
  : (process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, "LLMUsageMonitor") : "");
const discoveryCachePath = usageStateDir ? path.join(usageStateDir, "llm-usage-discovery-cache.json") : "";
const tokenCachePath = usageStateDir ? path.join(usageStateDir, "llm-usage-token-cache.dpapi") : "";
const CLAUDE_DISCOVERY_TTL_MS = 10 * 60 * 1000;
// Per-profile Claude session expiries (firefox-cookie-db.mjs) are re-read when a profile's cookie
// files change, and all of them at least once a day.
const SESSION_EXPIRY_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
// Private copies of Firefox's cookie database go here, one folder per copy.
const cookieTempRoot = process.env.TEMP || process.env.TMP || os.tmpdir();
// User-Agent for every request that carries Firefox cookies (decision C3, 2026-10-25): the
// requests ride that Firefox session, so they send a Firefox User-Agent rather than a tool name,
// which bot protection on these sites may challenge. Disclosed in the README.
const BROWSER_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0";
const TOKEN_EXPIRY_SKEW_MS = 60 * 1000;
// CLI logins first, Firefox second (decision A4; cli-credentials.mjs). A CLI request gets a shorter
// timeout so a failed CLI call plus the Firefox fallback stays inside the GUI's 55 s limit.
const CLI_REQUEST_TIMEOUT_MS = 12000;
// Which login supplied a provider's numbers (the <provider>_source keys): "cli", "firefox", or ""
// when none did. (An add-on's tag is its own; see addon-provider.mjs.)
const PROVIDER_SOURCES = new Set(["cli", "firefox"]);
// The Firefox cookie context (profile list plus cookie extraction) is built only when a provider
// falls back to Firefox, once per snapshot however many do; see getCookieContext.
let cookieContextPromise = null;
// sqlite3.exe is needed only for the Firefox path, so its setup (normally a no-op: it ships beside
// this script) runs on the first cookie-context build; see ensureSqliteOnce.
let sqliteReadyPromise = null;
let activeClaudeProfileName = "";
let activeDefaultProfileName = "";

function readDiscoveryCache() {
  try {
    if (!discoveryCachePath || !existsSync(discoveryCachePath)) return {};
    const parsed = JSON.parse(readFileSync(discoveryCachePath, "utf8"));
    return (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : {};
  } catch {
    return {};
  }
}

// Written via temp + rename so a snapshot running concurrently reads either the old
// file or the new one, never a half-written one.
function writeDiscoveryCache(cache) {
  try {
    if (!discoveryCachePath) return;
    mkdirSync(usageStateDir, { recursive: true });
    const tmp = `${discoveryCachePath}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(cache), "utf8");
    renameSync(tmp, discoveryCachePath);
  } catch {}
}

function discoveryCacheGet(key) {
  const entry = readDiscoveryCache()[key];
  if (!entry || typeof entry !== "object") return null;
  if (!Number.isFinite(entry.expiresAt) || Date.now() >= entry.expiresAt) return null;
  return entry.value ?? null;
}

function discoveryCacheSet(key, value, expiresAt) {
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) return;
  const cache = readDiscoveryCache();
  cache[key] = { value, expiresAt };
  writeDiscoveryCache(cache);
}

function discoveryCacheDrop(key) {
  const cache = readDiscoveryCache();
  if (!(key in cache)) return;
  delete cache[key];
  writeDiscoveryCache(cache);
}

// Expiry straight from the token's own payload. A token that is not a readable JWT
// with a finite `exp` is simply not cached.
function jwtExpiryMs(token) {
  try {
    const parts = String(token).split(".");
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    const exp = Number(payload && payload.exp);
    return Number.isFinite(exp) && exp > 0 ? exp * 1000 : null;
  } catch {
    return null;
  }
}

function claudeDiscoveryCacheKey() {
  return `claude:org:${activeClaudeProfileName || "(default)"}`;
}

function codexTokenCacheKey() {
  return `codex:token:${activeDefaultProfileName || "(default)"}`;
}

async function discoverClaudeApiUrlCached(allCookies, provider, timeout, forceFresh) {
  const key = claudeDiscoveryCacheKey();
  if (forceFresh) {
    discoveryCacheDrop(key);
  } else {
    const hit = discoveryCacheGet(key);
    if (hit && hit.apiUrl) {
      if (debugMode) debugLog.push(`[claude] org discovery -> cache hit`);
      return { discovery: hit, fromCache: true };
    }
  }
  const discovery = await discoverClaudeApiUrl(allCookies, provider, timeout);
  if (discovery && typeof discovery === "object" && discovery.apiUrl) {
    discoveryCacheSet(key, discovery, Date.now() + CLAUDE_DISCOVERY_TTL_MS);
  }
  return { discovery, fromCache: false };
}

async function discoverCodexTokenCached(allCookies, provider, timeout, forceFresh) {
  const key = codexTokenCacheKey();
  if (forceFresh) {
    await tokenCache.drop(key);
  } else {
    const hit = await tokenCache.get(key);
    if (hit && hit.token) {
      if (debugMode) debugLog.push(`[codex] session -> cache hit`);
      return { authResult: { token: hit.token, loginRequired: false, note: "" }, fromCache: true };
    }
  }
  const authResult = await discoverCodexToken(allCookies, provider, timeout);
  if (authResult && authResult.token) {
    const expMs = jwtExpiryMs(authResult.token);
    if (expMs) await tokenCache.set(key, { token: authResult.token }, expMs - TOKEN_EXPIRY_SKEW_MS);
  }
  return { authResult, fromCache: false };
}

const output = buildDefaultOutput();
const debugLog = [];
let exitCode = 0;
const tokenCache = createTokenCache(tokenCachePath, {
  log: message => { if (debugMode) debugLog.push(`[cache] ${message}`); }
});
removeLegacyPlaintextCache(os.tmpdir());

try {
  await fs.mkdir(path.dirname(outFile), { recursive: true });
  if (debugMode && providerPrefs.given) {
    debugLog.push(`[providers] set by --providers${providerPrefs.ignored.length ? `; ignored: ${providerPrefs.ignored.join(" ")}` : ""}`);
  }
  // Cookie-database copies a killed run left behind (older than 10 minutes, so never a live one).
  const sweptTempDirs = sweepStaleTempDirs(cookieTempRoot);
  if (debugMode && sweptTempDirs > 0) debugLog.push(`[cookies] removed ${sweptTempDirs} stale temp folder(s)`);
  const providerTimeout = Math.min(timeoutMs, 25000);
  const [results, addonFields] = await Promise.all([
    collectSnapshotResults(providerTimeout),
    collectAddonFields(providerTimeout)
  ]);
  let addonNote = "";
  if (addonFields) {
    const { note, ...keys } = addonFields;
    Object.assign(output, keys);
    addonNote = note || "";
  }

  setProviderOutput(output, "codex", results.codex);
  setProviderOutput(output, "claude", results.claude);
  setProviderOutput(output, "grok", results.grok);
  // The Firefox account switch belongs to the Firefox path (owner decision, 2026-10-26: "CLI wins; switch
  // on fallback"). While Claude Code's login supplies Claude the profile keys stay empty, which
  // hides the switch; the GUI keeps its saved profile because it only re-saves a non-empty one.
  // A failed build already reached the falling-back providers as their own error; here it only
  // means there are no profile keys to write.
  const cookieContext = cookieContextPromise ? await cookieContextPromise.catch(() => null) : null;
  if (cookieContext && shouldWriteClaudeProfileKeys({ pref: providerPrefs.prefs.claude, source: results.claude?.source, scanned: cookieContext.claudeScanned })) {
    output.claude_profile = cookieContext.claudeProfileName;
    output.claude_profile_choices = cookieContext.claudeProfileChoices.join("|");
    output.claude_next_profile = cookieContext.claudeNextProfileName;
    output.claude_profile_switch_available = cookieContext.claudeProfileChoices.length > 1 ? "1" : "0";
  }

  // Grok and a host's add-on are best-effort providers: a failure in either must not escalate the
  // overall status to error/login_required (login_required drives the GUI's Codex/Claude
  // sign-in layout, error sets a nonzero exit code) — cap their contribution at "partial".
  // A provider switched off counts for nothing (provider-settings.mjs overallStatusFor).
  output.overall_status = overallStatusFor({
    codex: output.codex_status,
    claude: output.claude_status,
    grok: output.grok_status,
    addon: output.addon_status
  });
  output.error = buildSummaryError(output, results.codex?.note, results.claude?.note, results.grok?.note, addonNote);

  if (output.overall_status === "error") {
    exitCode = 1;
  }
} catch (error) {
  output.overall_status = "error";
  output.error = `Unhandled scraper error: ${sanitize(error.message)}`;
  exitCode = 1;
}

await writeOutputFile(outFile, output);
// One DPAPI protect spawn at most, and only when a token changed during this run.
await tokenCache.flush();
if (debugMode && debugLog.length > 0) {
  await fs.writeFile(outFile + ".debug.txt", formatDebugLog(debugLog), "utf8");
}
// Drain window: AbortController-aborted sockets on Windows leave handles in UV_HANDLE_CLOSING
// state; calling process.exit() immediately triggers a libuv assertion (src\win\async.c:76).
await new Promise(resolve => setTimeout(resolve, 50));
process.exit(exitCode);

function parseArgs(argv) {
  const parsed = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      continue;
    }

    const key = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      parsed[key] = next;
      i += 1;
    } else {
      parsed[key] = "true";
    }
  }
  return parsed;
}

function toPositiveInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  if (Number.isFinite(parsed) && parsed > 0) {
    return parsed;
  }
  return fallback;
}

function getFirefoxProfilesRoot() {
  const appData = process.env.APPDATA;
  if (!appData) return null;
  return path.join(appData, "Mozilla", "Firefox", "Profiles");
}

function getFirefoxDir() {
  const appData = process.env.APPDATA;
  if (!appData) return null;
  return path.join(appData, "Mozilla", "Firefox");
}

// Locate the user's active Firefox profile directory (4 methods: InstallXXXX Default=, Profile* Default=1, *.default* scan, any dir with cookies.sqlite).
function findFirefoxProfile() {
  const ffDir = getFirefoxDir();
  const profilesDir = getFirefoxProfilesRoot();
  if (!ffDir || !profilesDir) return null;
  const hasCookies = (dir) => existsSync(path.join(dir, "cookies.sqlite"));

  try {
    const ini = readFileSync(path.join(ffDir, "profiles.ini"), "utf8");

    // Method 1: modern Firefox [InstallXXXX] section with Default= key
    const installMatch = ini.match(/\[Install[A-F0-9]+\][\s\S]*?Default=([^\r\n]+)/i);
    if (installMatch) {
      const rel = installMatch[1].trim();
      const full = path.isAbsolute(rel) ? rel : path.join(ffDir, rel);
      if (hasCookies(full)) return full;
    }

    // Method 2: legacy [Profile*] section with Default=1
    for (const section of ini.split(/\n(?=\[)/)) {
      if (/^\[Profile/i.test(section) && /^Default=1/m.test(section)) {
        const pm = section.match(/^Path=(.+)/m);
        if (pm) {
          const rel = pm[1].trim();
          const full = path.isAbsolute(rel) ? rel : path.join(ffDir, rel);
          if (hasCookies(full)) return full;
        }
      }
    }
  } catch {}

  // Methods 3 & 4: scan Profiles/ - prefer *.default*, then any dir with cookies.sqlite
  try {
    const dirs = readdirSync(profilesDir)
      .filter(d => statSync(path.join(profilesDir, d)).isDirectory())
      .filter(d => hasCookies(path.join(profilesDir, d)));
    const preferred = dirs.find(d => d.includes(".default")) || dirs[0];
    if (preferred) return path.join(profilesDir, preferred);
  } catch {}

  return null;
}

function listFirefoxProfiles() {
  const profilesDir = getFirefoxProfilesRoot();
  if (!profilesDir) return [];

  try {
    return readdirSync(profilesDir)
      .map(name => {
        const profilePath = path.join(profilesDir, name);
        const stats = statSync(profilePath);
        if (!stats.isDirectory()) return null;
        const cookiesDb = path.join(profilePath, "cookies.sqlite");
        const cookieStats = existsSync(cookiesDb) ? statSync(cookiesDb) : null;
        return {
          name,
          path: profilePath,
          hasCookies: !!cookieStats,
          cookieMtimeMs: cookieStats ? cookieStats.mtimeMs : 0
        };
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function sanitizeFirefoxProfileName(value) {
  const name = String(value ?? "").trim();
  if (!name || name.includes("..") || /[\\/:*?"<>|]/.test(name)) {
    return "";
  }
  if (!/^[A-Za-z0-9._ -]+$/.test(name)) {
    return "";
  }
  return name;
}

function resolveFirefoxProfileByName(profileName) {
  const safeName = sanitizeFirefoxProfileName(profileName);
  if (!safeName) return null;
  return listFirefoxProfiles().find(profile => profile.name === safeName) || null;
}

function providerListForKeys(keys) {
  const wanted = new Set(keys);
  return providers.filter(provider => wanted.has(provider.key));
}

function collectProviderHostnames(providerList) {
  const hostnames = new Set();
  for (const p of providerList) {
    for (const urlStr of [p.apiUrl, p.apiUrlTemplate, p.orgDiscoveryUrl, p.subscriptionsUrl, p.sessionUrl, p.refererUrl]) {
      if (urlStr) {
        try { hostnames.add(new URL(urlStr.replace("{orgId}", "x")).hostname); } catch {}
      }
    }
  }
  return [...hostnames];
}

// Latest expiry (unix seconds) of the providers' session cookie in one profile's database copy:
// 0 when there is none, null when the copy or the query failed. Without a session cookie name,
// any cookie for the providers' hosts counts.
function providerSessionExpiry(dbCopy, providerList) {
  const sessionNames = providerList.map(p => p.sessionCookieName).filter(Boolean);
  return querySessionExpiry(sqlite3Bin, dbCopy, collectProviderHostnames(providerList), sessionNames);
}

// Profiles holding an unexpired session for the provider (Claude: a sessionKey cookie). Each
// profile's latest session expiry is cached against its cookie-file fingerprint, so only a
// profile whose cookie files changed is copied and re-read; see firefox-cookie-db.mjs.
function listProfilesWithProviderCookies(providerKey, defaultProfileName, dbCopies) {
  const providerList = providerListForKeys([providerKey]);
  const candidates = listFirefoxProfiles()
    .filter(profile => profile.hasCookies)
    .map(profile => ({ ...profile, fingerprint: cookieDbFingerprint(profile.path) }));
  const cacheKey = `firefox:session-expiry:${providerKey}`;
  const { expiries, cache, changed, queried } = resolveSessionExpiries(candidates, {
    cache: discoveryCacheGet(cacheKey) || {},
    queryExpiry: profile => providerSessionExpiry(dbCopies.get(profile.path), providerList)
  });
  if (changed) discoveryCacheSet(cacheKey, cache, Date.now() + SESSION_EXPIRY_CACHE_TTL_MS);
  if (debugMode) {
    debugLog.push(`[profiles] ${providerKey} sign-in check: ${queried} profile(s) re-read, ${candidates.length - queried} unchanged since the last snapshot`);
  }

  const nowSec = Math.floor(Date.now() / 1000);
  const profiles = candidates
    .filter(profile => (expiries.get(profile.name) ?? 0) > nowSec)
    .map(profile => profile.name);

  return [...new Set(profiles)].sort((a, b) => {
    if (a === defaultProfileName) return -1;
    if (b === defaultProfileName) return 1;
    return a.localeCompare(b, undefined, { sensitivity: "base" });
  });
}

function profileNameFromPath(profilePath) {
  return profilePath ? path.basename(profilePath) : "";
}

function computeNextProfileName(profileChoices, currentProfileName) {
  if (!Array.isArray(profileChoices) || profileChoices.length <= 1) return "";
  const idx = profileChoices.indexOf(currentProfileName);
  if (idx < 0) return profileChoices[0] || "";
  return profileChoices[(idx + 1) % profileChoices.length] || "";
}

// sqlite3.exe setup, once per snapshot and only when the Firefox path is used. Normally a no-op:
// sqlite3.exe ships beside this script. See sqlite-tool.mjs.
function ensureSqliteOnce() {
  if (!sqliteReadyPromise) {
    sqliteReadyPromise = ensureSqlite3(sqlite3Bin).then(setup => {
      if (debugMode && setup.reason !== "present") debugLog.push(`[sqlite] sqlite3.exe setup -> ${setup.reason}`);
      return setup;
    });
  }
  return sqliteReadyPromise;
}

// One database copy per profile for the whole snapshot, removed when it ends.
async function buildFirefoxCookieContext(claudeProfileName) {
  await ensureSqliteOnce();
  const dbCopies = createCookieDbCopies(cookieTempRoot);
  try {
    return await buildFirefoxCookieContextWith(claudeProfileName, dbCopies);
  } finally {
    if (debugMode) debugLog.push(`[cookies] cookie database copies this snapshot: ${dbCopies.count}`);
    dbCopies.dispose();
  }
}

async function buildFirefoxCookieContextWith(claudeProfileName, dbCopies) {
  const defaultProfilePath = findFirefoxProfile();
  const defaultProfileName = profileNameFromPath(defaultProfilePath);
  // Firefox profiles are scanned for a Claude sign-in only when Claude may use Firefox (Settings:
  // auto or firefox), and cookies are extracted only for the providers allowed to read them.
  const scanClaude = firefoxCookieKeySet.has("claude");
  let claudeProfileChoices = [];
  let claudeProfilePath = "";
  if (scanClaude) {
    const requestedProfile = resolveFirefoxProfileByName(claudeProfileName);
    claudeProfileChoices = listProfilesWithProviderCookies("claude", defaultProfileName, dbCopies);

    // A requested (persisted) profile is honored only while it is still signed in; a stale
    // one falls back to the default profile, and the GUI re-persists what the snapshot reports.
    claudeProfilePath = defaultProfilePath;
    if (requestedProfile && claudeProfileChoices.includes(requestedProfile.name)) {
      claudeProfilePath = requestedProfile.path;
    } else if (!claudeProfileChoices.includes(defaultProfileName) && claudeProfileChoices.length > 0) {
      const firstClaudeProfile = resolveFirefoxProfileByName(claudeProfileChoices[0]);
      if (firstClaudeProfile) {
        claudeProfilePath = firstClaudeProfile.path;
      }
    }
  }

  const claudeProfileNameResolved = profileNameFromPath(claudeProfilePath);
  if (scanClaude) {
    allowClaudeDesktopAccountFallback = claudeProfileNameResolved !== "" && claudeProfileNameResolved === defaultProfileName;
  }
  // Cache keys are per-profile: a Claude account switch must not reuse the previous
  // account's org UUID, and Codex/Grok always ride the default profile.
  activeClaudeProfileName = claudeProfileNameResolved;
  activeDefaultProfileName = defaultProfileName;

  if (debugMode) {
    debugLog.push(`[profiles] default Firefox profile: ${defaultProfileName || "(none)"}`);
    if (scanClaude) {
      debugLog.push(`[profiles] selected Claude profile: ${claudeProfileNameResolved || "(none)"}`);
      debugLog.push(`[profiles] Claude profile choices: ${claudeProfileChoices.join(", ") || "(none)"}`);
    }
  }

  const profileFor = { codex: defaultProfilePath, claude: claudeProfilePath, grok: defaultProfilePath };
  const debugLabelFor = { codex: "codex-default", claude: "claude-selected", grok: "grok-default" };
  const cookiesByProvider = {};
  for (const key of ["codex", "claude", "grok"].filter(k => firefoxCookieKeySet.has(k))) {
    cookiesByProvider[key] = await extractFirefoxCookies({
      profileDir: profileFor[key],
      providers: providerListForKeys([key]),
      debugLabel: debugLabelFor[key],
      dbCopies
    });
  }

  return {
    cookiesByProvider,
    claudeScanned: scanClaude,
    claudeProfileName: claudeProfileNameResolved,
    claudeProfileChoices,
    claudeNextProfileName: computeNextProfileName(claudeProfileChoices, claudeProfileNameResolved)
  };
}

// Extract Firefox session cookies for selected provider domains and return as an array.
// Firefox stores cookies in plaintext - no decryption needed. Reads the snapshot's shared copy
// of the profile's database (options.dbCopies), never Firefox's own file.
async function extractFirefoxCookies(options = {}) {
  if (process.platform !== "win32") return [];
  if (!existsSync(sqlite3Bin)) return [];

  const providerList = Array.isArray(options.providers) && options.providers.length > 0
    ? options.providers
    : providers;
  const ffProfile = options.profileDir || findFirefoxProfile();
  if (!ffProfile || !options.dbCopies) return [];

  // Collect all relevant hostnames from every URL field across selected providers.
  const hostnames = collectProviderHostnames(providerList);
  if (hostnames.length === 0) return [];

  try {
    const dbCopy = options.dbCopies.get(ffProfile);
    if (!dbCopy) return [];

    const query = `SELECT name, value, host, path, isSecure, isHttpOnly FROM moz_cookies WHERE ${buildCookieHostConditions(hostnames)};`;
    const raw = execFileSync(sqlite3Bin, [dbCopy.tmpDb, query], {
      encoding: "utf8",
      timeout: 5000,
      windowsHide: true
    }).trim();

    // Keep extracted cookie rows in memory only; do not write query output to temp files.
    if (!raw) return [];

    const cookies = raw.split("\n")
      .filter(Boolean)
      .map(line => {
        const [name, value, host, cookiePath, isSecure, isHttpOnly] = line.split("|");
        return { name, value, domain: host, path: cookiePath || "/",
                 secure: isSecure === "1", httpOnly: isHttpOnly === "1" };
      })
      .filter(c => c.name && c.domain);

    if (debugMode) {
      const domainList = [...new Set(cookies.map(c => c.domain))].join(", ");
      debugLog.push(`[cookies] profile ${options.debugLabel || "selected"}: ${profileNameFromPath(ffProfile)}`);
      debugLog.push(`[cookies] extracted ${cookies.length} cookies for: ${domainList}`);
    }
    return cookies;
  } catch (e) {
    if (debugMode) debugLog.push(`[cookies] extractFirefoxCookies threw: ${e.message}`);
    return [];
  }
}

// Build a Cookie header string for the given request URL by domain-matching the cookie list.
// When chunked cookies exist (e.g. "token.0", "token.1"), the unchunked base cookie ("token")
// is dropped - sending both confuses servers like ChatGPT's NextAuth session endpoint.
function buildCookieHeader(allCookies, requestUrl) {
  let hostname;
  try { hostname = new URL(requestUrl).hostname; } catch { return ""; }
  const matched = allCookies.filter(c => {
    const d = c.domain.startsWith(".") ? c.domain.slice(1) : c.domain;
    return hostname === d || hostname.endsWith("." + d);
  });

  const names = new Set(matched.map(c => c.name));
  const filtered = matched.filter(c => {
    if (names.has(c.name + ".0")) return false;
    return true;
  });

  // Strip stray CR/LF from values so the Cookie header never becomes an invalid header value
  // (some providers, e.g. grok.com's OneTrust cookie, store odd characters).
  return filtered.map(c => `${c.name}=${String(c.value).replace(/[\r\n]/g, "")}`).join("; ");
}

// fetch() wrapper with AbortController-based timeout.
async function fetchWithTimeout(url, options, ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function buildDefaultOutput() {
  const now = new Date();
  return {
    fetched_at_utc: now.toISOString(),
    fetched_at_local: now.toLocaleString(),
    overall_status: "error",
    codex_status: "error",
    codex_source: "",
    codex_line_1: "Daily: unavailable",
    codex_line_2: "Weekly: unavailable",
    codex_line_1_reset_text: "",
    codex_line_2_reset_text: "",
    claude_status: "error",
    claude_source: "",
    claude_account_label: "",
    claude_profile: "",
    claude_profile_choices: "",
    claude_next_profile: "",
    claude_profile_switch_available: "0",
    claude_line_1: "Daily: unavailable",
    claude_line_2: "Weekly: unavailable",
    claude_line_3: "",
    claude_line_1_reset_text: "",
    claude_line_2_reset_text: "",
    claude_line_3_reset_text: "",
    grok_status: "error",
    grok_source: "",
    grok_line_1: "Weekly: unavailable",
    grok_line_2: "",
    grok_line_1_reset_text: "",
    grok_line_2_reset_text: "",
    error: "",
    error_code: ""
  };
}

// Firefox cookies for one provider, building the shared cookie context on first use.
function getCookieContext() {
  if (!cookieContextPromise) {
    cookieContextPromise = buildFirefoxCookieContext(requestedClaudeProfileName);
  }
  return cookieContextPromise;
}

async function firefoxCookiesFor(providerKey) {
  const context = await getCookieContext();
  return context.cookiesByProvider?.[providerKey] || [];
}

// Each provider runs the way its Settings choice allows (provider-settings.mjs resolveProviderSource):
// Codex, Claude and Grok by default try the user's CLI login first and fall back to Firefox cookies
// (cli-credentials.mjs resolveCliFirst); "cli" or "firefox" forces one source; "off" runs nothing.
async function collectSnapshotResults(timeout) {
  const cliTimeout = Math.min(timeout, CLI_REQUEST_TIMEOUT_MS);
  const cliSources = {
    codex: { read: readCodexCliLogin, run: login => runCodexCli(login, providerByKey("codex"), cliTimeout) },
    claude: { read: readClaudeCodeLogin, run: login => runClaudeCli(login, providerByKey("claude"), cliTimeout) },
    grok: { read: readGrokCliLogin, run: login => runGrokCli(login, providerByKey("grok"), cliTimeout) }
  };
  const entries = await Promise.all(
    providers.map(async (provider) => {
      const cli = cliSources[provider.key];
      const result = await resolveProviderSource({
        provider: provider.key,
        pref: providerPrefs.prefs[provider.key],
        label: provider.label,
        readLogin: cli?.read,
        runCli: cli?.run,
        runFirefox: async () => runSnapshotProvider(await firefoxCookiesFor(provider.key), provider, timeout),
        log: line => { if (debugMode) debugLog.push(`[${provider.key}] ${line}`); }
      });
      return [provider.key, result];
    })
  );
  return Object.fromEntries(entries);
}

// The host's add-on column (addon-provider.mjs): null when no module was named. Switched off, the
// module is not imported at all. The path never reaches a log line; it holds the user name.
async function collectAddonFields(timeout) {
  if (!addonModuleGiven) return null;
  const log = line => { if (debugMode) debugLog.push(`[addon] ${line}`); };
  if (providerPrefs.prefs.addon === "off") {
    log("off -> not loaded");
    return addonOffFields();
  }
  const loaded = await loadAddon(args.addonModule);
  if (!loaded.ok) {
    log(`not loaded: ${loaded.reason}`);
    return addonLoadFailureFields(loaded.reason);
  }
  const ctx = buildAddonContext(loaded.meta, {
    fetchWithTimeout,
    runPowerShellFile,
    tokenCache,
    discoveryGet: discoveryCacheGet,
    discoverySet: discoveryCacheSet,
    log,
    formatPercentLine,
    formatResetText,
    sanitize,
    timeoutMs: timeout,
    tokenExpirySkewMs: TOKEN_EXPIRY_SKEW_MS,
    debug: debugMode
  });
  const result = await runAddon(loaded.meta, ctx, { timeoutMs: timeout });
  log(`${loaded.meta.id} -> ${result.status}`);
  return { ...addonOutputFields(loaded.meta, result), note: result.note };
}

function providerByKey(key) {
  return providers.find(provider => provider.key === key);
}

function cliErrorResult(provider, note) {
  return {
    status: "error",
    lines: provider.singleWindow ? ["Weekly: unavailable", ""] : fallbackUsageLines(),
    resetTexts: ["", ""],
    note,
    loginRequired: false
  };
}

// One JSON usage call with a CLI login (cli-credentials.mjs fetchCliUsage: the provider's fixed URL,
// no redirects, error code only), parsed by the same builders the cookie path uses. Resolves to
// { result } or { rejected: true, status }; a rejection sends the caller to the Firefox fallback.
async function runCliJsonUsage(provider, login, timeout, providerMeta) {
  const reply = await fetchCliUsage({
    login,
    label: provider.label,
    timeoutMs: timeout,
    log: line => { if (debugMode) debugLog.push(`[${provider.key}] ${line}`); }
  });
  if (reply.rejected) return reply;
  if (!reply.body) return { result: cliErrorResult(provider, reply.note) };
  if (debugMode) {
    const keys = Object.keys(reply.body || {}).slice(0, 12).join(", ");
    debugLog.push(`[${provider.key}] response keys: ${keys || "(empty)"}`);
  }
  return {
    result: parseProviderSpecificUsage(provider, reply.body, providerMeta)
      || buildResultFromJson(provider, parseUsageFromJson(provider, [{ body: reply.body }]))
  };
}

// Claude through Claude Code's login: the usage call Claude Code's own /usage makes. The response has
// the same shape as claude.ai's org usage, so the existing builder applies. No account label: the
// login file holds no email (owner decision, 2026-10-26: "No label, tag says CLI").
async function runClaudeCli(login, provider, timeout) {
  return runCliJsonUsage(provider, login, timeout, { subscriptionState: login.plan });
}

// Codex through the Codex CLI's login: the same wham/usage call the cookie path makes, with the
// login's own bearer token and account header instead of a token fetched through Firefox.
async function runCodexCli(login, provider, timeout) {
  return runCliJsonUsage(provider, login, timeout, {});
}

// Grok through the Grok CLI's login: the Grok CLI's own billing call on the CLI proxy host xAI
// documents for auth.json tokens (cli-credentials.mjs GROK_CLI_BILLING_URL). Its JSON carries the
// same credits config the grok.com grpc call decodes; see parseProviderSpecificUsage.
async function runGrokCli(login, provider, timeout) {
  return runCliJsonUsage(provider, login, timeout, {});
}

// Fetch usage data for a single provider using Node.js fetch() with Firefox cookies:
// direct API calls with the user's own signed-in session; no browser is launched or automated.
async function runSnapshotProvider(allCookies, provider, timeout) {
  // grpc-web providers (Grok) need a POST with a framed body and a binary protobuf response,
  // so they take their own path instead of the REST/JSON one.
  if (provider.responseKind === "grpc-web") {
    return runGrpcWebProvider({ cookies: allCookies }, provider, timeout);
  }

  try {
    // Discovery (Claude org UUID, Codex bearer token) is cached; the usage call itself
    // never is. Attempt 0 may use cached discovery. If the server rejects it with
    // 401/403, attempt 1 drops those entries and repeats with fresh discovery, so a
    // stale cache costs one extra round trip instead of a spurious "login required".
    let apiUrl = null;
    let providerMeta = {};
    let response = null;

    for (let attempt = 0; ; attempt += 1) {
      const forceFresh = attempt > 0;
      let usedCache = false;
      apiUrl = provider.apiUrl;
      providerMeta = {};

      // Resolve the actual API URL (Claude requires org UUID discovery)
      if (!apiUrl && provider.orgDiscoveryUrl) {
        const { discovery, fromCache } = await discoverClaudeApiUrlCached(allCookies, provider, timeout, forceFresh);
        if (fromCache) usedCache = true;
        if (discovery && typeof discovery === "object") {
          apiUrl = discovery.apiUrl;
          providerMeta = discovery;
        } else {
          apiUrl = discovery;
        }
      }

      if (!apiUrl) {
        const discoveryLoginRequired = providerMeta.loginRequired === true;
        return withProviderMeta({
          status: discoveryLoginRequired ? "login_required" : "error",
          lines: fallbackUsageLines(),
          resetTexts: ["", ""],
          note: discoveryLoginRequired
            ? `${provider.label}: sign-in required.`
            : `${provider.label}: could not determine API URL`,
          loginRequired: discoveryLoginRequired
        }, providerMeta);
      }

      // Some APIs (ChatGPT backend-api) require a Bearer token in addition to cookies.
      let bearerToken = null;
      if (provider.sessionUrl) {
        const { authResult, fromCache } = await discoverCodexTokenCached(allCookies, provider, timeout, forceFresh);
        if (fromCache) usedCache = true;
        bearerToken = authResult.token;
        if (!bearerToken) {
          return {
            status: authResult.loginRequired ? "login_required" : "error",
            lines: fallbackUsageLines(),
            resetTexts: ["", ""],
            note: authResult.note || `${provider.label}: auth token unavailable.`,
            loginRequired: authResult.loginRequired
          };
        }
      }

      const cookieHeader = buildCookieHeader(allCookies, apiUrl);
      const requestHeaders = {
        "Cookie": cookieHeader,
        "Accept": "application/json",
        "User-Agent": BROWSER_USER_AGENT,
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": provider.refererUrl || new URL(apiUrl).origin + "/"
      };
      if (bearerToken) {
        requestHeaders["Authorization"] = `Bearer ${bearerToken}`;
      }

      response = await fetchWithTimeout(apiUrl, { headers: requestHeaders }, timeout);

      if (debugMode) {
        // The template, not the resolved URL: Claude's usage URL carries the org id.
        debugLog.push(`[${provider.key}] fetch ${provider.apiUrlTemplate || apiUrl} -> HTTP ${response.status}`);
      }

      // A cached token or org id the server has since rejected: drop it and repeat once
      // with fresh discovery, so a stale entry costs one extra request rather than a
      // false "login required" on a perfectly good session.
      if ((response.status === 401 || response.status === 403) && usedCache && attempt === 0) {
        if (debugMode) {
          debugLog.push(`[${provider.key}] cached discovery rejected -> retrying fresh`);
        }
        continue;
      }
      break;
    }

    if (response.status === 401 || response.status === 403) {
      return {
        status: "login_required",
        lines: fallbackUsageLines(),
        resetTexts: ["", ""],
        note: `${provider.label} login required.`,
        loginRequired: true
      };
    }

    if (!response.ok) {
      return {
        status: "error",
        lines: fallbackUsageLines(),
        resetTexts: ["", ""],
        note: `${provider.label}: HTTP ${response.status}`,
        loginRequired: false
      };
    }

    let body;
    try {
      body = await response.json();
    } catch {
      return {
        status: "error",
        lines: fallbackUsageLines(),
        resetTexts: ["", ""],
        note: `${provider.label}: invalid JSON response`,
        loginRequired: false
      };
    }

    if (debugMode) {
      const keys = Object.keys(body || {}).slice(0, 12).join(", ");
      debugLog.push(`[${provider.key}] response keys: ${keys || "(empty)"}`);
      debugLog.push(`[${provider.key}] response: ${debugJsonPreview(body, 400)}`);
    }

    const providerSpecificResult = parseProviderSpecificUsage(provider, body, providerMeta);
    if (providerSpecificResult) {
      return withProviderMeta(providerSpecificResult, providerMeta);
    }

    const jsonResult = parseUsageFromJson(provider, [{ body }]);
    return withProviderMeta(buildResultFromJson(provider, jsonResult), providerMeta);
  } catch (error) {
    if (error.name === "AbortError") {
      return {
        status: "error",
        lines: fallbackUsageLines(),
        resetTexts: ["", ""],
        note: `${provider.label}: request timed out`,
        loginRequired: false
      };
    }
    return {
      status: "error",
      lines: fallbackUsageLines(),
      resetTexts: ["", ""],
      note: `${provider.label} snapshot failed: ${sanitize(error.message)}`,
      loginRequired: false
    };
  }
}

// Fetch a grpc-web (connect-es) provider: POST the framed request body, then strip the grpc-web
// framing and decode the protobuf response. Used by Grok's Firefox path only: auth is { cookies }
// (cookie header, Firefox User-Agent). A Grok CLI token goes to the CLI proxy instead (runGrokCli).
async function runGrpcWebProvider(auth, provider, timeout) {
  const fallback = provider.singleWindow ? ["Weekly: unavailable", ""] : fallbackUsageLines();
  // Kick the entitlement lookup off alongside the usage call — it never rejects, so an
  // early return below simply drops it rather than leaving an unhandled rejection.
  const subscriptionStatePromise = provider.subscriptionsUrl
    ? discoverGrokSubscriptionState(auth, provider, timeout)
    : Promise.resolve("unknown");
  try {
    const origin = new URL(provider.apiUrl).origin;
    const cookieHeader = buildCookieHeader(auth?.cookies || [], provider.apiUrl);
    if (!cookieHeader) {
      return { status: "login_required", lines: fallback, resetTexts: ["", ""], note: `${provider.label} login required.`, loginRequired: true };
    }
    const headers = {
      "Cookie": cookieHeader,
      "User-Agent": BROWSER_USER_AGENT,
      "Accept": "*/*",
      "Accept-Language": "en-US,en;q=0.5",
      "Content-Type": provider.grpcContentType || "application/grpc-web+proto",
      "Origin": origin,
      "Referer": provider.refererUrl || origin + "/",
      ...(provider.grpcExtraHeaders || {})
    };

    const response = await fetchWithTimeout(provider.apiUrl, {
      method: "POST",
      headers,
      body: Buffer.from(provider.grpcBody || [0, 0, 0, 0, 0])
    }, timeout);

    const signInFailure = isAuthRejection;
    const grpcStatusHeader = response.headers.get("grpc-status");
    if (debugMode) {
      debugLog.push(`[${provider.key}] grpc-web POST ${provider.apiUrl} (cookies) → HTTP ${response.status} grpc-status(header)=${grpcStatusHeader ?? "(none)"}`);
    }
    if (signInFailure(response.status, grpcStatusHeader)) {
      return { status: "login_required", lines: fallback, resetTexts: ["", ""], note: `${provider.label} login required.`, loginRequired: true };
    }
    if (!response.ok) {
      return { status: "error", lines: fallback, resetTexts: ["", ""], note: `${provider.label}: HTTP ${response.status}`, loginRequired: false };
    }

    const buf = Buffer.from(await response.arrayBuffer());
    const frames = parseGrpcWebFrames(buf);
    if (frames.trailerStatus !== null && frames.trailerStatus !== 0) {
      const loginRequired = signInFailure(response.status, frames.trailerStatus);
      return {
        status: loginRequired ? "login_required" : "error",
        lines: fallback,
        resetTexts: ["", ""],
        note: loginRequired ? `${provider.label} login required.` : `${provider.label}: grpc-status ${frames.trailerStatus}`,
        loginRequired
      };
    }
    if (!frames.data || frames.data.length === 0) {
      return { status: "error", lines: fallback, resetTexts: ["", ""], note: `${provider.label}: empty grpc-web payload`, loginRequired: false };
    }

    const parsed = parseGrokCreditsUsage(frames.data);
    if (debugMode) {
      debugLog.push(`[${provider.key}] decoded message ${frames.data.length}B → ${parsed ? JSON.stringify(parsed.lines) : "(unparseable)"}`);
      debugLog.push(`[${provider.key}] protobuf fields: ${summarizeProtobufTree(parseProtobufTree(frames.data))}`);
      if (!parsed) {
        // Lengths only: the payload is the account's own billing data and is never dumped.
        debugLog.push(`[${provider.key}] content-type=${response.headers.get("content-type") ?? "(none)"} body ${buf.length}B, data frame ${frames.data.length}B (payload not logged)`);
      }
    }
    if (!parsed) {
      return { status: "error", lines: fallback, resetTexts: ["", ""], note: `${provider.label}: could not parse credits payload`, loginRequired: false };
    }
    return applyGrokSubscriptionState(parsed, await subscriptionStatePromise);
  } catch (error) {
    if (error.name === "AbortError") {
      return { status: "error", lines: fallback, resetTexts: ["", ""], note: `${provider.label}: request timed out`, loginRequired: false };
    }
    return { status: "error", lines: fallback, resetTexts: ["", ""], note: `${provider.label} snapshot failed: ${sanitize(error.message)}`, loginRequired: false };
  }
}

// Split a grpc-web body into its data frame (flag bit 0x80 clear) and trailer status (the
// trailer frame carries "grpc-status:N\r\n" as ascii). Each frame: 1 flag byte + 4-byte BE
// length + payload.
function parseGrpcWebFrames(buf) {
  let i = 0;
  let data = null;
  let trailerStatus = null;
  while (i + 5 <= buf.length) {
    const flag = buf[i];
    const len = buf.readUInt32BE(i + 1);
    const end = i + 5 + len;
    if (end > buf.length) break;
    const payload = buf.subarray(i + 5, end);
    i = end;
    if ((flag & 0x80) !== 0) {
      const match = payload.toString("latin1").match(/grpc-status:\s*(\d+)/i);
      if (match) trailerStatus = Number.parseInt(match[1], 10);
    } else if (!data) {
      data = Buffer.from(payload);
    }
  }
  return { data, trailerStatus };
}

// Minimal protobuf wire-format walker -> array of { field, wt, varint|f32|nested } nodes.
// The array's `complete` flag is true only when every byte parsed as well-formed fields; a
// length-delimited field whose bytes do not is a string or bytes value, not a nested message.
function parseProtobufTree(buf) {
  const out = [];
  let i = 0;
  let complete = true;
  while (i < buf.length) {
    const [tag, ni, tagOk] = readProtoVarint(buf, i);
    i = ni;
    if (!tagOk) { complete = false; break; }
    const field = Number(tag >> 3n);
    const wt = Number(tag & 7n);
    if (wt === 0) {
      const [v, n2, ok] = readProtoVarint(buf, i);
      i = n2;
      if (!ok) { complete = false; break; }
      out.push({ field, wt, varint: v });
    } else if (wt === 5) {
      if (i + 4 > buf.length) { complete = false; break; }
      out.push({ field, wt, f32: buf.readFloatLE(i), u32: buf.readUInt32LE(i) });
      i += 4;
    } else if (wt === 1) {
      if (i + 8 > buf.length) { complete = false; break; }
      out.push({ field, wt, f64: buf.readDoubleLE(i) });
      i += 8;
    } else if (wt === 2) {
      const [len, n2, ok] = readProtoVarint(buf, i);
      i = n2;
      const end = i + Number(len);
      if (!ok || end > buf.length) { complete = false; break; }
      const sub = buf.subarray(i, end);
      i = end;
      let nested = null;
      try { if (sub.length) nested = parseProtobufTree(sub); } catch {}
      out.push({ field, wt, nested, raw: sub });
    } else {
      complete = false;
      break;
    }
  }
  out.complete = complete && i === buf.length;
  return out;
}

// Returns [value, nextPos, ok]; ok is false when the buffer ends inside the varint.
function readProtoVarint(buf, i) {
  let result = 0n;
  let shift = 0n;
  let pos = i;
  while (pos < buf.length) {
    const b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) return [result, pos, true];
    shift += 7n;
  }
  return [result, pos, false];
}

// Decode GetGrokCreditsConfig → single "Weekly: X% remaining" line + reset date.
// Shape (decoded from the GrokCreditsConfig descriptor embedded in grok.com's JS —
// prod/grok/backend/proto/grok_build_billing.proto): outer #1 → config {
//   #1 f32 credit_usage_percent, #2/#3 Cent on_demand_cap/on_demand_used,
//   #4/#5 Timestamp billing_period_start/end, #7 repeated ProductUsage
//   { #1 billing_product.Product product, #2 f32 usage_percent }, #8 UsagePeriod
//   current_period, #11 bool is_unified_billing_user, #12 Cent prepaid_balance,
//   #13 TopUpMethod top_up_method }.
// proto3 omits zero-valued floats, so right after a billing-period rollover the config has
// NO percent field anywhere — that means 0% used (grok.com's frontend treats missing percent
// as 0), not a parse error. Note this message says nothing about entitlement; whether the
// account is subscribed at all comes from discoverGrokSubscriptionState.
function parseGrokCreditsUsage(dataBuf) {
  const tree = parseProtobufTree(dataBuf);
  const outer = tree.find(n => n.field === 1 && n.nested);
  const config = outer ? outer.nested : tree;
  if (!Array.isArray(config) || config.length === 0) {
    return null;
  }

  const scalar = config.find(n => n.field === 1 && n.wt === 5 && Number.isFinite(n.f32));
  const productUsages = grokProductUsages(config);
  let percentUsed = chooseGrokUsagePercent(scalar?.f32 ?? null, productUsages);
  if (percentUsed !== null) {
    percentUsed = clampPercent(percentUsed);
  }
  const resetMs = grokLatestTimestampMs(config);
  if (percentUsed === null) {
    if (resetMs === null) {
      return null;   // no percent AND no billing period — genuinely unrecognizable
    }
    percentUsed = 0; // valid config with a billing period but omitted percent = unused period
  }
  return buildGrokWeeklyResult(percentUsed, resetMs);
}

// The one Grok result shape, shared by the grok.com grpc path (cookies) and the CLI proxy's JSON.
function buildGrokWeeklyResult(percentUsed, resetMs) {
  const remaining = clampPercent(100 - clampPercent(percentUsed));
  const line = remaining <= 0 ? "Weekly: 0% remaining" : `Weekly: ${remaining}% remaining`;
  return {
    status: "ok",
    lines: [line, ""],
    resetTexts: [formatResetText(resetMs), ""],
    note: "",
    loginRequired: false
  };
}

// Product breakdown = repeated #7 entry { #1 kind, #2 f32 }. The unified top-level
// percentage is authoritative when present; this breakdown is only a legacy fallback.
function grokProductUsages(config) {
  const entries = config.filter(n => n.field === 7 && Array.isArray(n.nested));
  const productUsages = [];
  for (const entry of entries) {
    const kindNode = entry.nested.find(x => x.field === 1 && x.wt === 0);
    const valueNode = entry.nested.find(x => x.field === 2 && x.wt === 5);
    if (!valueNode || !Number.isFinite(valueNode.f32)) {
      continue;
    }
    productUsages.push({
      kind: kindNode ? Number(kindNode.varint) : null,
      percent: valueNode.f32
    });
  }
  return productUsages;
}

// Reset = the latest plausible unix-seconds timestamp anywhere in the config (the period end).
function grokLatestTimestampMs(config) {
  let maxMs = null;
  const walk = (nodes) => {
    for (const node of nodes) {
      if (node.wt === 0 && node.varint > 1700000000n && node.varint < 2000000000n) {
        const ms = Number(node.varint) * 1000;
        if (maxMs === null || ms > maxMs) maxMs = ms;
      }
      if (Array.isArray(node.nested)) walk(node.nested);
    }
  };
  walk(config);
  return maxMs;
}

// Discover the Claude org UUID by fetching /api/organizations and build the usage URL.
async function discoverClaudeApiUrl(allCookies, provider, timeout) {
  try {
    const cookieHeader = buildCookieHeader(allCookies, provider.orgDiscoveryUrl);
    const resp = await fetchWithTimeout(provider.orgDiscoveryUrl, {
      headers: {
        "Cookie": cookieHeader,
        "Accept": "application/json",
        "User-Agent": BROWSER_USER_AGENT,
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": provider.refererUrl || "https://claude.ai/"
      }
    }, Math.min(timeout, 8000));

    if (!resp.ok) {
      if (debugMode) debugLog.push(`[claude] org discovery -> HTTP ${resp.status}`);
      return (resp.status === 401 || resp.status === 403) ? { apiUrl: null, loginRequired: true } : null;
    }

    const data = await resp.json();

    if (debugMode) {
      debugLog.push(`[claude] org discovery response: ${debugJsonPreview(data, 200)}`);
    }

    // Claude may return an array of orgs or { organizations: [...] }
    const list = Array.isArray(data) ? data : (data?.organizations ?? []);
    const orgId = list[0]?.uuid || list[0]?.id || list[0]?.organization_id;
    const subscriptionState = classifyClaudeSubscription(list[0]);
    const accountLabel = extractClaudeAccountLabelFromOrganizations(data)
      || (allowClaudeDesktopAccountFallback ? readClaudeDesktopAccountLabel() : "");

    if (debugMode) {
      debugLog.push(`[claude] org discovery -> orgId: ${orgId ? "<present>" : "(not found)"}`);
    }

    if (debugMode) {
      debugLog.push(`[claude] subscription state: ${subscriptionState}`);
    }

    if (!orgId) return { apiUrl: null, accountLabel, subscriptionState };
    return {
      apiUrl: provider.apiUrlTemplate.replace("{orgId}", orgId),
      accountLabel,
      subscriptionState
    };
  } catch (e) {
    if (debugMode) debugLog.push(`[claude] org discovery threw: ${e.message}`);
    return null;
  }
}

// Grok entitlement lookup — the counterpart to discoverClaudeApiUrl's billing_type read.
// Plain REST JSON with the same cookies as the credits call (Firefox path only).
// Never throws and never reports "free" on a failure: an unreachable endpoint must leave the
// usage numbers alone.
async function discoverGrokSubscriptionState(auth, provider, timeout) {
  try {
    const cookieHeader = buildCookieHeader(auth?.cookies || [], provider.subscriptionsUrl);
    if (!cookieHeader) {
      return "unknown";
    }
    const headers = {
      "Cookie": cookieHeader,
      "Accept": "application/json",
      "User-Agent": BROWSER_USER_AGENT,
      "Accept-Language": "en-US,en;q=0.5",
      "Referer": provider.refererUrl || "https://grok.com/"
    };

    const resp = await fetchWithTimeout(provider.subscriptionsUrl, { headers }, Math.min(timeout, 8000));

    if (!resp.ok) {
      if (debugMode) debugLog.push(`[grok] subscriptions lookup → HTTP ${resp.status}`);
      return "unknown";
    }

    const data = await resp.json();
    const state = classifyGrokSubscription(data);

    if (debugMode) {
      const list = Array.isArray(data) ? data : (data?.subscriptions ?? []);
      const summary = (Array.isArray(list) ? list : [])
        .map(entry => `${entry?.tier ?? "?"}/${entry?.status ?? "?"}`)
        .join(", ");
      debugLog.push(`[grok] subscriptions: ${summary || "(none)"}`);
      debugLog.push(`[grok] subscription state: ${state}`);
    }

    return state;
  } catch (e) {
    if (debugMode) debugLog.push(`[grok] subscriptions lookup threw: ${e.message}`);
    return "unknown";
  }
}

// Overlay the entitlement state on a successfully decoded credits result. The real percentage
// is deliberately preserved on the free tier so the GUI's mini "Free" mode can still reveal it;
// the "free" status is what makes the default render say No Subscription (mirrors Codex/Claude).
function applyGrokSubscriptionState(result, subscriptionState) {
  if (!result || subscriptionState !== "free") {
    return result;
  }
  if (!/\d+%/.test(result.lines?.[0] ?? "")) {
    return buildNoSubscriptionResult({ singleWindow: true });
  }
  return { ...result, status: "free", note: "" };
}

function withProviderMeta(result, providerMeta) {
  if (!result || !providerMeta?.accountLabel) {
    return result;
  }
  return { ...result, accountLabel: providerMeta.accountLabel };
}

// Fetch a Bearer access token for Codex by calling ChatGPT's session endpoint.
async function discoverCodexToken(allCookies, provider, timeout) {
  try {
    const cookieHeader = buildCookieHeader(allCookies, provider.sessionUrl);
    if (!cookieHeader) {
      return { token: null, loginRequired: true, note: "Codex login required." };
    }

    const resp = await fetchWithTimeout(provider.sessionUrl, {
      headers: {
        "Cookie": cookieHeader,
        "Accept": "application/json",
        "User-Agent": BROWSER_USER_AGENT,
        "Accept-Language": "en-US,en;q=0.5",
        "Referer": provider.refererUrl || "https://chatgpt.com/"
      }
    }, Math.min(timeout, 8000));

    if (!resp.ok) {
      if (debugMode) debugLog.push(`[codex] session -> HTTP ${resp.status}`);
      return {
        token: null,
        loginRequired: resp.status === 401 || resp.status === 403,
        note: resp.status === 401 || resp.status === 403
          ? "Codex login required."
          : `Codex session token unavailable: HTTP ${resp.status}`
      };
    }

    const data = await resp.json();
    const token = data?.accessToken || null;

    if (debugMode) {
      debugLog.push(`[codex] session -> accessToken: ${token ? "<present>" : "(not found)"}`);
    }

    return {
      token,
      loginRequired: !token && !data?.user,
      note: token ? "" : "Codex session token unavailable."
    };
  } catch (e) {
    if (debugMode) debugLog.push(`[codex] session threw: ${e.message}`);
    return { token: null, loginRequired: false, note: `Codex session token failed: ${sanitize(e.message)}` };
  }
}

function parseUsageFromJson(provider, capturedResponses) {
  let daily  = { found: false, remaining: null, resetAt: null, confidence: 0 };
  let weekly = { found: false, remaining: null, resetAt: null, confidence: 0 };

  for (const { body } of capturedResponses) {
    walkJsonForUsage(body, "", (hint, pct, confidence, resetAt) => {
      if (/daily|today|24h|session|hour/.test(hint) && shouldReplaceMetric(daily, confidence, resetAt)) {
        daily = { found: true, remaining: clampPercent(pct), resetAt, confidence };
      }
      if (/weekly|week|7.day|all.model|seven/.test(hint) && shouldReplaceMetric(weekly, confidence, resetAt)) {
        weekly = { found: true, remaining: clampPercent(pct), resetAt, confidence };
      }
    });
  }
  return { daily, weekly };
}

function shouldReplaceMetric(currentMetric, incomingConfidence, incomingResetAt) {
  if (incomingConfidence > currentMetric.confidence) {
    return true;
  }
  if (incomingConfidence < currentMetric.confidence) {
    return false;
  }
  return !currentMetric.resetAt && !!incomingResetAt;
}

function walkJsonForUsage(obj, parentKey, cb) {
  if (Array.isArray(obj)) {
    for (const item of obj) {
      walkJsonForUsage(item, parentKey, cb);
    }
    return;
  }
  if (!obj || typeof obj !== "object") return;

  for (const [k, v] of Object.entries(obj)) {
    const hint = (parentKey ? `${parentKey}_${k}` : k).toLowerCase();

    if (v && typeof v === "object" && !Array.isArray(v)) {
      const limit     = toNumber(v.limit ?? v.max ?? v.total);
      const remaining = toNumber(v.remaining ?? v.left ?? v.remaining_count ?? v.messages_remaining ?? v.tokens_remaining);
      const used      = toNumber(v.used ?? v.consumed ?? v.used_count ?? v.messages_used ?? v.tokens_used);
      const pctField     = toNumber(v.percent ?? v.percentage ?? v.pct ?? v.percent_remaining ?? v.usage_percent ?? v.remaining_percent);
      const pctUsedField = toNumber(v.percent_used ?? v.percentUsed ?? v.used_percent ?? v.utilization);
      const resetAt      = extractResetTimestamp(v);

      // Enrich the hint with temporal scope when limit_window_seconds is present.
      // e.g. rate_limit_primary_window (604800s=7d) -> rate_limit_primary_window_weekly
      const windowSecs = toNumber(v.limit_window_seconds ?? v.window_seconds);
      let effectiveHint = hint;
      if (windowSecs !== null) {
        if (windowSecs >= 604800) effectiveHint = hint + "_weekly";
        else if (windowSecs < 86400) effectiveHint = hint + "_hourly";
      }

      if (limit !== null && limit > 0 && remaining !== null)
        cb(effectiveHint, remaining / limit * 100, 90, resetAt);
      else if (limit !== null && limit > 0 && used !== null)
        cb(effectiveHint, (1 - used / limit) * 100, 80, resetAt);
      else if (pctUsedField !== null)
        cb(effectiveHint, 100 - pctUsedField, 75, resetAt); // utilization/used_percent -> remaining
      else if (pctField !== null)
        cb(effectiveHint, pctField, 70, resetAt);
    }

    walkJsonForUsage(v, hint, cb);
  }
}

function toNumber(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number.parseFloat(value.replace(/,/g, ""));
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function extractResetTimestamp(obj) {
  const absoluteResetValue =
    obj.resets_at ??
    obj.reset_at ??
    obj.resetsAt ??
    obj.resetAt ??
    obj.reset_time ??
    obj.resetTime;
  const absoluteReset = parseTimestampLike(absoluteResetValue);
  if (absoluteReset) {
    return absoluteReset;
  }

  const resetAfterSeconds = toNumber(obj.reset_after_seconds);
  if (resetAfterSeconds !== null && resetAfterSeconds >= 0) {
    return Date.now() + Math.round(resetAfterSeconds * 1000);
  }

  return null;
}

function parseTimestampLike(value) {
  if (value === null || value === undefined) {
    return null;
  }

  if (value instanceof Date) {
    const ms = value.getTime();
    return Number.isFinite(ms) ? ms : null;
  }

  if (typeof value === "number" && Number.isFinite(value)) {
    if (value <= 0) {
      return null;
    }
    return value > 1e12 ? Math.round(value) : Math.round(value * 1000);
  }

  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) {
      return null;
    }

    if (/^\d+(\.\d+)?$/.test(trimmed)) {
      const numeric = Number.parseFloat(trimmed);
      if (Number.isFinite(numeric) && numeric > 0) {
        return numeric > 1e12 ? Math.round(numeric) : Math.round(numeric * 1000);
      }
    }

    // Offset-less ISO datetimes (e.g. "2026-07-03T19:20:00") parse as LOCAL time in JS,
    // but server APIs emit UTC wall time — pin them to UTC so a naive string can't shift
    // the reset by the machine's UTC offset. Strings with Z or +/-hh:mm are unambiguous.
    if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/.test(trimmed)) {
      const utcParsed = Date.parse(trimmed.replace(" ", "T") + "Z");
      if (Number.isFinite(utcParsed)) {
        return utcParsed;
      }
    }

    const parsed = Date.parse(trimmed);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }

  return null;
}

function buildResultFromJson(provider, jsonResult) {
  const dailyOk  = jsonResult.daily.found;
  const weeklyOk = jsonResult.weekly.found;
  const needsDaily = provider.hasDaily !== false;

  // When a plan has no daily window at all (e.g. Codex free plan), render a
  // neutral "n/a" placeholder rather than "unavailable" (which is reserved for
  // genuine fetch failures via fallbackUsageLines).
  const dailyLine = (!needsDaily && !dailyOk)
    ? "Daily: n/a"
    : formatPercentLine("Daily", jsonResult.daily);

  const lines = [
    dailyLine,
    formatPercentLine("Weekly", jsonResult.weekly)
  ];

  const resetTexts = [
    formatResetText(jsonResult.daily?.resetAt),
    formatResetText(jsonResult.weekly?.resetAt)
  ];

  let status = "partial";
  if (weeklyOk && (!needsDaily || dailyOk)) {
    status = "ok";
  }

  const note = status === "partial"
    ? `${provider.label} usage values were partially detected.`
    : "";

  return { status, lines, resetTexts, note, loginRequired: false };
}

function parseProviderSpecificUsage(provider, body, providerMeta = {}) {
  if (provider.key === "codex") {
    const codexSubscriptionState = classifyCodexSubscription(body);
    if (codexSubscriptionState === "inactive" || isCodexNoSubscriptionUsage(body)) {
      return buildNoSubscriptionResult();
    }
    return buildCodexUsageResult(body, codexSubscriptionState);
  }

  if (provider.key === "claude") {
    if (providerMeta.subscriptionState === "free") {
      return buildClaudeUsageResult(provider, body, "free");
    }
    if (providerMeta.subscriptionState !== "active" && isClaudeNoSubscriptionUsage(body)) {
      return buildNoSubscriptionResult();
    }
    // Route active/unknown accounts through the Claude builder too, so the
    // scoped per-model weekly line (claude_line_3) is emitted when present.
    return buildClaudeUsageResult(provider, body, providerMeta.subscriptionState);
  }

  if (provider.key === "grok") {
    // Key names only (never values), so a debug file shows the response's shape if it changes.
    if (debugMode) debugLog.push(`[grok] billing key paths: ${jsonKeyPaths(body, { maxPaths: 25 }).join(", ") || "(none)"}`);
    const usage = parseGrokBillingUsage(body);
    if (!usage) {
      return cliErrorResult(provider, `${provider.label}: could not parse billing response`);
    }
    return applyGrokSubscriptionState(buildGrokWeeklyResult(usage.percentUsed, usage.resetMs), classifyGrokBillingSubscription(body));
  }

  return null;
}

// Debug summary of a decoded protobuf: field numbers, wire types and numeric values only.
// String/bytes fields show their length, never their content.
function summarizeProtobufTree(nodes) {
  const summarize = (items) => items.map((node) => {
    if (Array.isArray(node.nested) && node.nested.complete) {
      return `#${node.field}{${summarize(node.nested)}}`;
    }
    if (node.wt === 2) return `#${node.field}=bytes:${node.raw ? node.raw.length : 0}`;
    if (node.wt === 0) return `#${node.field}=v:${node.varint}`;
    if (node.wt === 1) return `#${node.field}=f64:${node.f64}`;
    if (node.wt === 5) return `#${node.field}=f32:${node.f32}`;
    return `#${node.field}=wt:${node.wt}`;
  }).join(",");
  return summarize(nodes);
}

function buildClaudeUsageResult(provider, body, subscriptionState) {
  const result = buildResultFromJson(provider, parseUsageFromJson(provider, [{ body }]));

  // Per-model scoped weekly window (e.g. the "Fable" meter). It lives in the
  // `limits` array, not in a top-level seven_day_* key, and is invisible to the
  // generic walker (array items are recursed, never offered to the callback).
  // Absent window => no line_3 at all (the GUI collapses the row).
  const scoped = extractClaudeScopedWeeklyLimit(body);
  if (scoped) {
    result.lines[2] = formatPercentLine(scoped.label, { found: true, remaining: clampPercent(scoped.remainingPercent) });
    result.resetTexts[2] = formatResetText(scoped.resetAt);
  }

  if (subscriptionState === "free") {
    result.status = "free";
    result.note = "";
  }
  return result;
}

function buildCodexUsageResult(body, codexSubscriptionState = classifyCodexSubscription(body)) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return null;
  }

  const candidates = collectCodexLimitCandidates(body);
  let daily = chooseCodexMetric(candidates, "daily");
  let weekly = chooseCodexMetric(candidates, "weekly");

  if (!daily.found && !weekly.found && isCodexLimitReached(body)) {
    daily = buildZeroMetric();
    weekly = buildZeroMetric();
  }

  if (!daily.found && !weekly.found) {
    return null;
  }

  const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
  const noDailyWindow = !candidates.some(candidate => candidate.scope === "daily");
  const weeklyExhausted = weekly.found && weekly.remaining <= 0;
  const weeklyResetFarOut = Number.isFinite(weekly.resetAt)
    && (weekly.resetAt - Date.now()) > SEVEN_DAYS_MS;

  // Legacy fallback for responses that omit explicit plan metadata: no daily
  // window plus an exhausted long-reset weekly window is treated as inactive.
  // Explicit plan_type=free stays distinct so the GUI can optionally reveal it.
  if (codexSubscriptionState !== "free" && noDailyWindow && weeklyExhausted && weeklyResetFarOut) {
    return buildNoSubscriptionResult();
  }

  const result = buildResultFromJson({ label: "Codex", hasDaily: !noDailyWindow }, { daily, weekly });
  if (codexSubscriptionState === "free") {
    result.status = "free";
  }
  return result;
}

function collectCodexLimitCandidates(body) {
  const candidates = [];
  addCodexWindowCandidate(candidates, body?.rate_limit?.primary_window, "rate_limit.primary_window", 100);
  addCodexWindowCandidate(candidates, body?.rate_limit?.secondary_window, "rate_limit.secondary_window", 100);

  collectCodexWindowsFromObject(body?.additional_rate_limits, "additional_rate_limits", candidates, 85);
  collectCodexWindowsFromObject(body?.rate_limits, "rate_limits", candidates, 85);

  return candidates;
}

function collectCodexWindowsFromObject(value, pathHint, candidates, confidence) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => collectCodexWindowsFromObject(item, `${pathHint}.${index}`, candidates, confidence));
    return;
  }

  if (!value || typeof value !== "object") {
    return;
  }

  if (looksLikeCodexLimitWindow(value)) {
    addCodexWindowCandidate(candidates, value, pathHint, confidence);
  }

  for (const [key, child] of Object.entries(value)) {
    collectCodexWindowsFromObject(child, `${pathHint}.${key}`, candidates, Math.max(confidence - 5, 60));
  }
}

function addCodexWindowCandidate(candidates, windowData, pathHint, confidence) {
  const metric = codexMetricFromWindow(windowData, confidence);
  if (!metric) {
    return;
  }

  const scope = codexWindowScope(windowData, pathHint);
  if (!scope) {
    return;
  }

  candidates.push({ scope, metric });
}

function codexMetricFromWindow(windowData, confidence) {
  if (!windowData || typeof windowData !== "object" || Array.isArray(windowData)) {
    return null;
  }

  const limit = toNumber(windowData.limit ?? windowData.max ?? windowData.total);
  const remaining = toNumber(windowData.remaining ?? windowData.left ?? windowData.remaining_count ?? windowData.messages_remaining ?? windowData.tokens_remaining);
  const used = toNumber(windowData.used ?? windowData.consumed ?? windowData.used_count ?? windowData.messages_used ?? windowData.tokens_used);
  const pctRemaining = toNumber(windowData.percent ?? windowData.percentage ?? windowData.pct ?? windowData.percent_remaining ?? windowData.remaining_percent);
  const pctUsed = toNumber(windowData.percent_used ?? windowData.percentUsed ?? windowData.used_percent ?? windowData.utilization);

  let remainingPct = null;
  if (pctRemaining !== null) {
    remainingPct = pctRemaining;
  } else if (pctUsed !== null) {
    remainingPct = 100 - pctUsed;
  } else if (limit !== null && limit > 0 && remaining !== null) {
    remainingPct = remaining / limit * 100;
  } else if (limit !== null && limit > 0 && used !== null) {
    remainingPct = (1 - used / limit) * 100;
  } else if (windowData.limit_reached === true || windowData.allowed === false) {
    remainingPct = 0;
  }

  if (remainingPct === null) {
    return null;
  }

  return {
    found: true,
    remaining: clampPercent(remainingPct),
    resetAt: extractResetTimestamp(windowData),
    confidence
  };
}

function looksLikeCodexLimitWindow(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  return [
    "limit_window_seconds", "window_seconds", "used_percent", "percent_used",
    "percent_remaining", "remaining_percent", "reset_after_seconds", "reset_at",
    "resets_at", "limit_reached", "allowed"
  ].some(key => Object.prototype.hasOwnProperty.call(value, key));
}

function codexWindowScope(windowData, pathHint) {
  const windowSecs = toNumber(windowData?.limit_window_seconds ?? windowData?.window_seconds);
  if (windowSecs !== null) {
    if (windowSecs >= 604800) return "weekly";
    if (windowSecs > 0) return "daily";
  }

  const hint = String(pathHint || "").toLowerCase();
  if (/weekly|week|seven|secondary/.test(hint)) return "weekly";
  if (/daily|day|today|hour|primary/.test(hint)) return "daily";
  return "";
}

function chooseCodexMetric(candidates, scope) {
  let selected = { found: false, remaining: null, resetAt: null, confidence: 0 };
  for (const candidate of candidates) {
    if (candidate.scope !== scope) {
      continue;
    }
    if (shouldReplaceMetric(selected, candidate.metric.confidence, candidate.metric.resetAt)) {
      selected = candidate.metric;
    }
  }
  return selected;
}

function buildZeroMetric() {
  return { found: true, remaining: 0, resetAt: null, confidence: 100 };
}

function isCodexLimitReached(body) {
  return body?.rate_limit?.limit_reached === true
    || body?.rate_limit?.allowed === false
    || typeof body?.rate_limit_reached_type === "string";
}

function isCodexNoSubscriptionUsage(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return false;
  }

  if (classifyCodexSubscription(body) === "inactive") {
    return true;
  }

  const planType = String(body.plan_type ?? body.plan ?? body.subscription_type ?? "").trim().toLowerCase();
  return ["none", "no_subscription", "no-subscription", "unsubscribed"].includes(planType);
}

// Single-window providers (Grok) render one "Weekly:" row, so a two-line result would
// invent a Daily row the GUI has no control for.
function buildNoSubscriptionResult({ singleWindow = false } = {}) {
  return {
    status: "no_subscription",
    lines: singleWindow
      ? ["Weekly: No Subscription", ""]
      : ["Daily: No Subscription", "Weekly: No Subscription"],
    resetTexts: ["", ""],
    note: "",
    loginRequired: false
  };
}

function clampPercent(value) {
  if (!Number.isFinite(value)) {
    return 0;
  }
  if (value < 0) {
    return 0;
  }
  if (value > 100) {
    return 100;
  }
  return Math.round(value);
}

function formatPercentLine(label, metric) {
  if (!metric?.found) {
    return `${label}: unavailable`;
  }

  if (metric.remaining <= 0) {
    // Keep the line clean; the reset is carried in the separate *_reset_text
    // field and appended compactly by the GUI (which always shows it at 0%).
    return `${label}: 0% remaining`;
  }

  return `${label}: ${metric.remaining}% remaining`;
}

function formatResetLocal(timestampMs) {
  if (!Number.isFinite(timestampMs) || timestampMs <= 0) {
    return "";
  }

  const date = new Date(timestampMs);
  const month = date.getMonth() + 1;
  const day = date.getDate();
  const minutes = date.getMinutes();
  const rawHour = date.getHours();
  const hour12 = (rawHour % 12) || 12;
  const ampm = rawHour < 12 ? "am" : "pm";

  const minutePart = minutes === 0
    ? ""
    : `:${String(minutes).padStart(2, "0")}`;

  return `${month}/${day} at ${hour12}${minutePart}${ampm}`;
}

function formatResetText(timestampMs) {
  const local = formatResetLocal(timestampMs);
  if (!local) return "";
  return `resets ${local.replace(" at ", " ")}`;
}

function fallbackUsageLines() {
  return ["Daily: unavailable", "Weekly: unavailable"];
}

function setProviderOutput(outputData, prefix, result) {
  outputData[`${prefix}_status`] = normalizeStatus(result?.status);
  outputData[`${prefix}_source`] = PROVIDER_SOURCES.has(result?.source) ? result.source : "";
  if (Object.prototype.hasOwnProperty.call(result || {}, "accountLabel")) {
    outputData[`${prefix}_account_label`] = sanitize(result?.accountLabel ?? "");
  }
  const lines = ensureUsageLines(Array.isArray(result?.lines) ? result.lines : []);
  outputData[`${prefix}_line_1`] = sanitize(lines[0]);
  outputData[`${prefix}_line_2`] = sanitize(lines[1]);
  outputData[`${prefix}_line_3`] = sanitize(lines[2] ?? "");
  const resets = Array.isArray(result?.resetTexts) ? result.resetTexts : ["", ""];
  outputData[`${prefix}_line_1_reset_text`] = sanitize(resets[0] ?? "");
  outputData[`${prefix}_line_2_reset_text`] = sanitize(resets[1] ?? "");
  outputData[`${prefix}_line_3_reset_text`] = sanitize(resets[2] ?? "");
}

// Pads to the two guaranteed lines; a third (per-model scoped) line is
// optional and passes through when a provider supplies it.
function ensureUsageLines(lines) {
  const defaults = fallbackUsageLines();
  const result = [...lines];
  while (result.length < 2) {
    result.push(defaults[result.length]);
  }
  return result.slice(0, 3);
}

// "off" = switched off in Settings: no request was made (provider-settings.mjs offResult).
function normalizeStatus(status) {
  if (status === "ok" || status === "partial" || status === "login_required" || status === "error" || status === "no_subscription" || status === "free" || status === "off") {
    return status;
  }
  return "error";
}

function buildSummaryError(outputData, ...providerNotes) {
  const notes = providerNotes.filter(Boolean);

  if (outputData.overall_status === "ok") {
    return "";
  }

  if (notes.length > 0) {
    return sanitize(notes.join(" | "));
  }

  if (outputData.overall_status === "login_required") {
    return "Login required for one or both providers.";
  }

  if (outputData.overall_status === "partial") {
    return "Some usage values could not be parsed.";
  }

  return "Failed to collect usage data.";
}

async function writeOutputFile(filePath, outputData) {
  const orderedKeys = [
    "fetched_at_utc",
    "fetched_at_local",
    "overall_status",
    "codex_status",
    "codex_source",
    "codex_line_1",
    "codex_line_2",
    "codex_line_1_reset_text",
    "codex_line_2_reset_text",
    "claude_status",
    "claude_source",
    "claude_account_label",
    "claude_profile",
    "claude_profile_choices",
    "claude_next_profile",
    "claude_profile_switch_available",
    "claude_line_1",
    "claude_line_2",
    "claude_line_3",
    "claude_line_1_reset_text",
    "claude_line_2_reset_text",
    "claude_line_3_reset_text",
    "grok_status",
    "grok_source",
    "grok_line_1",
    "grok_line_2",
    "grok_line_1_reset_text",
    "grok_line_2_reset_text",
    // Only when a host named an add-on module (collectAddonFields).
    ...(outputData.addon_status !== undefined ? ADDON_OUTPUT_KEYS : []),
    "error",
    "error_code"
  ];

  const lines = orderedKeys.map((key) => `${key}=${sanitize(outputData[key] ?? "")}`);
  await fs.writeFile(filePath, `${lines.join("\n")}\n`, "utf8");
}
