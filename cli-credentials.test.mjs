// Tests for the CLI-login loaders (release plan G5). Every credential here is invented; the real
// login files are never read (each test passes its own fake home folder and an empty env).
import test, { after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  CLAUDE_OAUTH_USAGE_URL,
  CLI_HOME_ENV,
  CODEX_USAGE_URL,
  GROK_CLI_BILLING_URL,
  TOOL_USER_AGENT,
  claudePlanState,
  cliLoginPaths,
  describeLogin,
  fetchCliJson,
  fetchCliUsage,
  isAuthRejection,
  isUsableResult,
  readClaudeCodeLogin,
  readCodexCliLogin,
  readGrokCliLogin,
  resolveCliFirst,
  safeErrorText
} from "./cli-credentials.mjs";

import { formatDebugLog } from "./debug-redaction.mjs";

const scratch = mkdtempSync(path.join(os.tmpdir(), "usage-cli-login-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const NOW = Date.parse("2026-10-26T12:00:00Z");
const HOUR = 60 * 60 * 1000;
const now = () => NOW;
const b64url = value => Buffer.from(JSON.stringify(value)).toString("base64url");
const fakeJwt = (expMs, extra = {}) => `eyJhbGciOiJub25lIn0.${b64url({ exp: Math.floor(expMs / 1000), ...extra })}.c2lnbmF0dXJlLWZpeHR1cmU`;

const FIXTURE_EMAIL = "fixture.person42@example.com";
const CLAUDE_TOKEN = "sk-ant-oat01-FIXTUREaccessTOKEN0000000000000000000000000000000000";
const CLAUDE_REFRESH = "sk-ant-ort01-FIXTURErefreshTOKEN000000000000000000000000000000000";
const CODEX_ACCESS = fakeJwt(NOW + 5 * 24 * HOUR, { scp: ["openid"] });
const CODEX_ID_TOKEN = fakeJwt(NOW - HOUR, { email: FIXTURE_EMAIL });
const CODEX_REFRESH = "rt_FIXTUREcodexREFRESHtoken0000000000";
const CODEX_ACCOUNT = "11111111-2222-4333-8444-555555555555";
const GROK_KEY = fakeJwt(NOW + 3 * HOUR, { tier: "fixture" });
const GROK_REFRESH = "grok-refresh-FIXTURE-0000000000000000";
const GROK_USER = "99999999-8888-4777-8666-555555555555";
const SECRETS = [CLAUDE_TOKEN, CLAUDE_REFRESH, CODEX_ACCESS, CODEX_ID_TOKEN, CODEX_REFRESH, CODEX_ACCOUNT, GROK_KEY, GROK_REFRESH, GROK_USER, FIXTURE_EMAIL];

const claudeFile = (oauth = {}) => ({ claudeAiOauth: { accessToken: CLAUDE_TOKEN, refreshToken: CLAUDE_REFRESH, expiresAt: NOW + 5 * HOUR, scopes: ["user:inference", "user:profile"], subscriptionType: "max", ...oauth } });
const codexFile = (tokens = {}, top = {}) => ({ OPENAI_API_KEY: null, tokens: { id_token: CODEX_ID_TOKEN, access_token: CODEX_ACCESS, refresh_token: CODEX_REFRESH, account_id: CODEX_ACCOUNT, ...tokens }, last_refresh: "2026-10-20T00:00:00Z", ...top });
const grokFile = (entry = {}) => ({ "https://accounts.x.ai/sign-in": { key: GROK_KEY, auth_mode: "oidc", user_id: GROK_USER, email: FIXTURE_EMAIL, refresh_token: GROK_REFRESH, expires_at: new Date(NOW + 3 * HOUR).toISOString(), ...entry } });

let homeCount = 0;
function fakeHome(files = {}) {
  const home = path.join(scratch, `home-${++homeCount}`);
  mkdirSync(home, { recursive: true });
  for (const [relative, content] of Object.entries(files)) {
    const full = path.join(home, relative);
    mkdirSync(path.dirname(full), { recursive: true });
    writeFileSync(full, typeof content === "string" ? content : JSON.stringify(content), "utf8");
  }
  return home;
}

const LOADERS = [
  {
    name: "Claude Code", provider: "claude", read: readClaudeCodeLogin, file: ".claude/.credentials.json", token: CLAUDE_TOKEN,
    valid: () => claudeFile(), expired: () => claudeFile({ expiresAt: NOW - 2 * HOUR }), noToken: () => ({ claudeAiOauth: { refreshToken: CLAUDE_REFRESH } }),
    url: CLAUDE_OAUTH_USAGE_URL, method: "GET"
  },
  {
    name: "Codex CLI", provider: "codex", read: readCodexCliLogin, file: ".codex/auth.json", token: CODEX_ACCESS,
    valid: () => codexFile(), expired: () => codexFile({ access_token: fakeJwt(NOW - HOUR) }), noToken: () => ({ tokens: { refresh_token: CODEX_REFRESH } }),
    url: CODEX_USAGE_URL, method: "GET"
  },
  {
    name: "Grok CLI", provider: "grok", read: readGrokCliLogin, file: ".grok/auth.json", token: GROK_KEY,
    valid: () => grokFile(), expired: () => grokFile({ expires_at: new Date(NOW - HOUR).toISOString() }), noToken: () => ({ "https://accounts.x.ai/sign-in": { refresh_token: GROK_REFRESH } }),
    url: GROK_CLI_BILLING_URL, method: "GET"
  }
];

function load(loader, files) {
  return loader.read({ env: {}, homeDir: fakeHome(files), now });
}

function assertNoSecrets(text, where) {
  for (const secret of SECRETS) {
    assert.ok(!String(text).includes(secret), `${where} must not contain a credential or id`);
  }
}

// A fetch stand-in that records each request and answers with the given status/body.
function fakeFetch(answer) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    const { status = 200, body = {}, throwError = null, grpcStatus = null } = typeof answer === "function" ? answer(url, init) : answer;
    if (throwError) throw throwError;
    return {
      status,
      ok: status >= 200 && status < 300,
      headers: { get: name => (name === "grpc-status" ? grpcStatus : null) },
      json: async () => {
        if (body === "not json") throw new SyntaxError("Unexpected token");
        return body;
      }
    };
  };
  return { calls, fetchImpl };
}

// The CLI half the scraper runs for each provider: the module's real fetchCliUsage, which the
// scraper's runClaudeCli / runCodexCli / runGrokCli all call through runCliJsonUsage.
function cliRunnerFor(loader, fetchImpl) {
  return async login => {
    const reply = await fetchCliUsage({ login, label: loader.name, fetch: fetchImpl, timeoutMs: 2000 });
    if (reply.rejected) return reply;
    if (!reply.body) return { result: { status: "error", note: reply.note } };
    return { result: { status: "ok", lines: ["Daily: 50% remaining", "Weekly: 80% remaining"] } };
  };
}

const firefoxOk = { status: "ok", lines: ["Daily: 10% remaining", "Weekly: 20% remaining"], note: "" };
const firefoxLogin = { status: "login_required", lines: ["Daily: unavailable", "Weekly: unavailable"], note: "Login required.", loginRequired: true };

for (const loader of LOADERS) {
  test(`${loader.name}: a valid login is ok and its token is reachable only through headers()`, () => {
    const login = load(loader, { [loader.file]: loader.valid() });
    assert.equal(login.state, "ok");
    assert.equal(login.provider, loader.provider);
    const headers = login.headers();
    assert.equal(headers.Authorization, `Bearer ${loader.token}`);
    assert.equal(headers["User-Agent"], TOOL_USER_AGENT);
    assertNoSecrets(JSON.stringify(login), "JSON.stringify(login)");
    assertNoSecrets(`${login}`, "the login as a string");
    assertNoSecrets(Object.keys(login).join(","), "the login's keys");
    assert.match(describeLogin(login, NOW), /login ok, expires in/);
    assertNoSecrets(describeLogin(login, NOW), "describeLogin");
  });

  test(`${loader.name}: a missing login file is "missing" and nothing throws`, () => {
    assert.equal(load(loader, {}).state, "missing");
    assert.equal(load(loader, { "unrelated.txt": "x" }).state, "missing");
    assert.deepEqual(load(loader, {}).headers(), {});
  });

  test(`${loader.name}: a malformed login file is "malformed" and yields no token`, () => {
    for (const content of ["{not json", "[]", "null", JSON.stringify(loader.noToken())]) {
      const login = load(loader, { [loader.file]: content });
      assert.equal(login.state, "malformed", `content ${content.slice(0, 20)}`);
      assert.deepEqual(login.headers(), {});
    }
  });

  test(`${loader.name}: an expired token is "expired", never sent, and the Firefox fallback is taken`, async () => {
    const login = load(loader, { [loader.file]: loader.expired() });
    assert.equal(login.state, "expired");
    assert.deepEqual(login.headers(), {});
    assert.match(describeLogin(login, NOW), /login expired .*ago/);
    let cliCalls = 0;
    let firefoxCalls = 0;
    const result = await resolveCliFirst({
      login,
      runCli: async () => { cliCalls++; return { result: { status: "ok" } }; },
      runFirefox: async () => { firefoxCalls++; return firefoxOk; },
      now
    });
    assert.equal(cliCalls, 0, "an expired token is never tried");
    assert.equal(firefoxCalls, 1);
    assert.equal(result.source, "firefox");
    assert.equal(result.status, "ok");
  });

  for (const status of [401, 403]) {
    test(`${loader.name}: a token the server rejects (HTTP ${status}) takes the Firefox fallback`, async () => {
      const login = load(loader, { [loader.file]: loader.valid() });
      const { calls, fetchImpl } = fakeFetch({ status });
      let firefoxCalls = 0;
      const result = await resolveCliFirst({
        login,
        runCli: cliRunnerFor(loader, fetchImpl),
        runFirefox: async () => { firefoxCalls++; return firefoxOk; },
        now
      });
      assert.equal(calls.length, 1, "one request, no retry and no refresh");
      assert.equal(firefoxCalls, 1);
      assert.equal(result.source, "firefox");
      assert.deepEqual(result.lines, firefoxOk.lines);
    });
  }

  test(`${loader.name}: a working login is used and Firefox is never touched`, async () => {
    const login = load(loader, { [loader.file]: loader.valid() });
    const { calls, fetchImpl } = fakeFetch({ status: 200, body: { ok: true } });
    let firefoxCalls = 0;
    const result = await resolveCliFirst({
      login,
      runCli: cliRunnerFor(loader, fetchImpl),
      runFirefox: async () => { firefoxCalls++; return firefoxOk; },
      now
    });
    assert.equal(result.source, "cli");
    assert.equal(firefoxCalls, 0);
    // Never a refresh: one bodiless GET to the provider's usage URL, the CLI's bearer token, no
    // cookies, redirects refused.
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, loader.url);
    assert.equal(calls[0].init.method, loader.method);
    if (loader.method === "GET") assert.equal(calls[0].init.body, undefined);
    assert.equal(calls[0].init.redirect, "error");
    assert.equal(calls[0].init.headers.Authorization, `Bearer ${loader.token}`);
    assert.equal("Cookie" in calls[0].init.headers, false);
    assert.ok(!/token|refresh|oauth2/i.test(new URL(calls[0].url).pathname), "not a token endpoint");
  });

  test(`${loader.name}: reading never writes, renames, copies or deletes the login file`, () => {
    const trips = [];
    const trip = name => () => { trips.push(name); throw new Error(`fs.${name} must not be called`); };
    const reads = [];
    const spyFs = {
      readFileSync: (...args) => { reads.push(args[0]); return readFileSync(...args); },
      writeFileSync: trip("writeFileSync"), appendFileSync: trip("appendFileSync"), renameSync: trip("renameSync"),
      copyFileSync: trip("copyFileSync"), unlinkSync: trip("unlinkSync"), rmSync: trip("rmSync"),
      mkdirSync: trip("mkdirSync"), openSync: trip("openSync"), utimesSync: trip("utimesSync")
    };
    for (const files of [{ [loader.file]: loader.valid() }, { [loader.file]: loader.expired() }, { [loader.file]: "{not json" }, {}]) {
      const home = fakeHome(files);
      const filePath = path.join(home, loader.file);
      const before = files[loader.file] ? { bytes: readFileSync(filePath), mtimeMs: statSync(filePath).mtimeMs } : null;
      const login = loader.read({ fs: spyFs, env: {}, homeDir: home, now });
      login.headers();
      describeLogin(login, NOW);
      if (before) {
        assert.ok(readFileSync(filePath).equals(before.bytes), "file bytes unchanged");
        assert.equal(statSync(filePath).mtimeMs, before.mtimeMs, "file mtime unchanged");
      }
    }
    assert.deepEqual(trips, []);
    assert.ok(reads.length > 0 && reads.every(file => path.basename(file) === path.basename(loader.file)));
  });
}

test("a Codex CLI signed in with an API key only is 'unsupported' (no ChatGPT usage to read)", () => {
  const login = readCodexCliLogin({ env: {}, homeDir: fakeHome({ ".codex/auth.json": { OPENAI_API_KEY: "sk-proj-FIXTUREapikey0000000000" } }), now });
  assert.equal(login.state, "unsupported");
  assert.deepEqual(login.headers(), {});
});

test("Codex sends the account header only when the file has an account id", () => {
  const withId = readCodexCliLogin({ env: {}, homeDir: fakeHome({ ".codex/auth.json": codexFile() }), now });
  assert.equal(withId.headers()["ChatGPT-Account-Id"], CODEX_ACCOUNT);
  const withoutId = readCodexCliLogin({ env: {}, homeDir: fakeHome({ ".codex/auth.json": codexFile({ account_id: undefined }) }), now });
  assert.equal("ChatGPT-Account-Id" in withoutId.headers(), false);
});

test("Claude Code's plan maps to the subscription states the parser expects", () => {
  assert.equal(claudePlanState("max"), "active");
  assert.equal(claudePlanState("Pro"), "active");
  assert.equal(claudePlanState("free"), "free");
  assert.equal(claudePlanState(""), "unknown");
  assert.equal(claudePlanState(undefined), "unknown");
  const login = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile({ subscriptionType: "pro" }) }), now });
  assert.equal(login.plan, "active");
  assert.equal(login.headers()["anthropic-beta"], "oauth-2025-04-20");
});

test("a token that could not be a header value is treated as malformed, never sent", () => {
  for (const bad of ["two words", "line\nbreak", "tab\there", ""]) {
    const login = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile({ accessToken: bad }) }), now });
    assert.equal(login.state, "malformed");
  }
});

test("an unknown expiry is tried (the server decides); Grok falls back to the JWT exp", () => {
  const claude = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile({ expiresAt: undefined }) }), now });
  assert.equal(claude.state, "ok");
  assert.equal(claude.expiresAtMs, null);
  const grokOk = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": grokFile({ expires_at: undefined }) }), now });
  assert.equal(grokOk.state, "ok");
  const grokExpired = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": grokFile({ expires_at: undefined, key: fakeJwt(NOW - HOUR) }) }), now });
  assert.equal(grokExpired.state, "expired");
  // Within the minute of skew counts as expired already.
  const edge = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile({ expiresAt: NOW + 30 * 1000 }) }), now });
  assert.equal(edge.state, "expired");
});

test("login paths follow CLAUDE_CONFIG_DIR and CODEX_HOME, and LLM_USAGE_CLI_HOME overrides all three", () => {
  const home = path.join(scratch, "paths-home");
  const plain = cliLoginPaths({ env: {}, homeDir: home });
  assert.equal(plain.claude, path.join(home, ".claude", ".credentials.json"));
  assert.equal(plain.codex, path.join(home, ".codex", "auth.json"));
  assert.equal(plain.grok, path.join(home, ".grok", "auth.json"));

  const custom = cliLoginPaths({ env: { CLAUDE_CONFIG_DIR: path.join(scratch, "cc"), CODEX_HOME: path.join(scratch, "cx") }, homeDir: home });
  assert.equal(custom.claude, path.join(scratch, "cc", ".credentials.json"));
  assert.equal(custom.codex, path.join(scratch, "cx", "auth.json"));

  const override = path.join(scratch, "empty-cli-home");
  const forced = cliLoginPaths({ env: { [CLI_HOME_ENV]: override, CLAUDE_CONFIG_DIR: path.join(scratch, "cc"), CODEX_HOME: path.join(scratch, "cx") }, homeDir: home });
  assert.equal(forced.claude, path.join(override, ".claude", ".credentials.json"));
  assert.equal(forced.codex, path.join(override, ".codex", "auth.json"));
  assert.equal(forced.grok, path.join(override, ".grok", "auth.json"));
  // An empty override folder means every CLI login is missing, which forces the Firefox path.
  const realHome = fakeHome({ ".claude/.credentials.json": claudeFile() });
  assert.equal(readClaudeCodeLogin({ env: { [CLI_HOME_ENV]: override }, homeDir: realHome, now }).state, "missing");
});

test("fetchCliJson classifies replies and never follows a redirect", async () => {
  const answers = [
    [{ status: 200, body: { five_hour: {} } }, "ok"],
    [{ status: 401 }, "rejected"],
    [{ status: 403 }, "rejected"],
    [{ status: 500 }, "http-error"],
    [{ status: 200, body: "not json" }, "invalid-json"]
  ];
  for (const [answer, kind] of answers) {
    const { calls, fetchImpl } = fakeFetch(answer);
    const reply = await fetchCliJson({ url: CLAUDE_OAUTH_USAGE_URL, headers: { Authorization: `Bearer ${CLAUDE_TOKEN}` }, fetch: fetchImpl });
    assert.equal(reply.kind, kind);
    assert.equal(calls[0].init.redirect, "error");
  }
  const abort = new Error("aborted");
  abort.name = "AbortError";
  assert.equal((await fetchCliJson({ url: CLAUDE_OAUTH_USAGE_URL, headers: {}, fetch: fakeFetch({ throwError: abort }).fetchImpl })).kind, "timeout");

  // An error whose message quotes the token reports only its code.
  const leaky = new TypeError(`Headers.append: "Bearer ${CLAUDE_TOKEN}" is an invalid header value.`);
  leaky.cause = { code: "ERR_INVALID_CHAR" };
  const reply = await fetchCliJson({ url: CLAUDE_OAUTH_USAGE_URL, headers: {}, fetch: fakeFetch({ throwError: leaky }).fetchImpl });
  assert.equal(reply.kind, "error");
  assert.equal(reply.code, "ERR_INVALID_CHAR");
  assertNoSecrets(JSON.stringify(reply), "a failed fetch's reply");
  assert.equal(safeErrorText(new Error(`boom ${CLAUDE_TOKEN}`)), "Error");
});

test("isAuthRejection covers 401, 403 and grpc-status 16 only", () => {
  assert.equal(isAuthRejection(401), true);
  assert.equal(isAuthRejection(403), true);
  assert.equal(isAuthRejection(200, "16"), true);
  assert.equal(isAuthRejection(200, 16), true);
  assert.equal(isAuthRejection(200, "0"), false);
  assert.equal(isAuthRejection(500), false);
  assert.equal(isAuthRejection(200), false);
});

test("resolveCliFirst: a CLI failure that is not a rejection still beats a Firefox sign-in prompt", async () => {
  const login = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile() }), now });
  const serverError = cliRunnerFor(LOADERS[0], fakeFetch({ status: 500 }).fetchImpl);

  const keptCliError = await resolveCliFirst({ login, runCli: serverError, runFirefox: async () => firefoxLogin, now });
  assert.equal(keptCliError.source, "cli");
  assert.equal(keptCliError.status, "error");

  const firefoxWins = await resolveCliFirst({ login, runCli: serverError, runFirefox: async () => firefoxOk, now });
  assert.equal(firefoxWins.source, "firefox");

  const thrown = await resolveCliFirst({ login, runCli: async () => { throw new Error(`boom ${CLAUDE_TOKEN}`); }, runFirefox: async () => firefoxOk, now });
  assert.equal(thrown.source, "firefox");
});

test("resolveCliFirst: with no usable CLI login and no Firefox session the source is empty", async () => {
  for (const loader of LOADERS) {
    const login = load(loader, {});
    const result = await resolveCliFirst({ login, runCli: async () => assert.fail("missing login must not run"), runFirefox: async () => firefoxLogin, now });
    assert.equal(result.source, "");
    assert.equal(result.status, "login_required");
  }
});

test("resolveCliFirst: free and no-subscription answers from a CLI login count as answers", async () => {
  const login = readCodexCliLogin({ env: {}, homeDir: fakeHome({ ".codex/auth.json": codexFile() }), now });
  for (const status of ["free", "no_subscription", "partial"]) {
    const lines = ["Daily: 40% remaining", "Weekly: unavailable"];
    const result = await resolveCliFirst({ login, runCli: async () => ({ result: { status, lines } }), runFirefox: async () => assert.fail("Firefox must not run"), now });
    assert.equal(result.source, "cli");
    assert.equal(result.status, status);
  }
});

test("the debug lines from every path hold no credential, id or email", async () => {
  const lines = [];
  const log = line => lines.push(line);
  for (const loader of LOADERS) {
    for (const files of [{ [loader.file]: loader.valid() }, { [loader.file]: loader.expired() }, { [loader.file]: "{not json" }, {}]) {
      const login = load(loader, files);
      for (const status of [200, 401, 500]) {
        await resolveCliFirst({ login, runCli: cliRunnerFor(loader, fakeFetch({ status, body: {} }).fetchImpl), runFirefox: async () => firefoxLogin, label: loader.name, log, now });
      }
    }
  }
  assert.ok(lines.length > 0);
  const text = lines.join("\n");
  assertNoSecrets(text, "debug lines");
  assertNoSecrets(formatDebugLog(lines), "the formatted debug log");
  assert.match(text, /Claude Code login ok, expires in .* -> used/);
  assert.match(text, /Codex CLI login missing -> trying Firefox/);
  assert.match(text, /Codex CLI login ok, expires in .* -> rejected \(HTTP 401\), trying Firefox/);
  assert.match(text, /Grok CLI login ok, expires in .* -> rejected \(HTTP 401\), trying Firefox/);
});

test("the loader module has no write, delete or token-refresh code", () => {
  const source = readFileSync(new URL("./cli-credentials.mjs", import.meta.url), "utf8");
  const code = source.split(/\r?\n/).filter(line => !line.trim().startsWith("//")).join("\n");
  assert.doesNotMatch(code, /writeFile|appendFile|rename|unlink|copyFile|mkdir|rmSync|\brm\(|createWriteStream|openSync|utimes/);
  assert.doesNotMatch(code, /refresh_?token|oauth\/token|grant_type/i);
  assert.match(code, /redirect: "error"/);
});

test("fetchCliUsage makes the real Claude, Codex and Grok requests and reduces each reply", async () => {
  const claude = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile() }), now });
  const codex = readCodexCliLogin({ env: {}, homeDir: fakeHome({ ".codex/auth.json": codexFile() }), now });
  const lines = [];
  const ok = fakeFetch({ status: 200, body: { five_hour: { utilization: 10 } } });
  const reply = await fetchCliUsage({ login: claude, label: "Claude", fetch: ok.fetchImpl, log: line => lines.push(line) });
  assert.deepEqual(reply, { body: { five_hour: { utilization: 10 } } });
  assert.equal(ok.calls[0].url, CLAUDE_OAUTH_USAGE_URL);
  assert.equal(ok.calls[0].init.headers["anthropic-beta"], "oauth-2025-04-20");
  assert.equal(ok.calls[0].init.headers["User-Agent"], TOOL_USER_AGENT);
  assert.deepEqual(lines, ["CLI login fetch -> HTTP 200"]);

  const cx = fakeFetch({ status: 200, body: {} });
  await fetchCliUsage({ login: codex, label: "Codex", fetch: cx.fetchImpl });
  assert.equal(cx.calls[0].url, CODEX_USAGE_URL);
  assert.equal(cx.calls[0].init.headers["ChatGPT-Account-Id"], CODEX_ACCOUNT);
  assert.equal(cx.calls[0].init.redirect, "error");

  assert.deepEqual(await fetchCliUsage({ login: claude, label: "Claude", fetch: fakeFetch({ status: 401 }).fetchImpl }), { rejected: true, status: 401 });
  assert.deepEqual(await fetchCliUsage({ login: codex, label: "Codex", fetch: fakeFetch({ status: 403 }).fetchImpl }), { rejected: true, status: 403 });
  assert.equal((await fetchCliUsage({ login: claude, label: "Claude", fetch: fakeFetch({ status: 502 }).fetchImpl })).note, "Claude: HTTP 502");
  assert.equal((await fetchCliUsage({ login: claude, label: "Claude", fetch: fakeFetch({ status: 200, body: "not json" }).fetchImpl })).note, "Claude: invalid JSON response");

  // Grok: the CLI proxy's billing call, with the headers xAI's Grok CLI README names.
  const grok = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": grokFile() }), now });
  const gx = fakeFetch({ status: 200, body: { config: {} } });
  await fetchCliUsage({ login: grok, label: "Grok", fetch: gx.fetchImpl });
  assert.equal(gx.calls[0].url, GROK_CLI_BILLING_URL);
  assert.equal(new URL(gx.calls[0].url).hostname, "cli-chat-proxy.grok.com");
  assert.equal(gx.calls[0].init.method, "GET");
  assert.equal(gx.calls[0].init.redirect, "error");
  assert.equal(gx.calls[0].init.headers["X-XAI-Token-Auth"], "xai-grok-cli");
  assert.equal(gx.calls[0].init.headers["x-userid"], GROK_USER);
  assert.equal(gx.calls[0].init.headers.Accept, "application/json");
  assert.equal(gx.calls[0].init.headers["User-Agent"], TOOL_USER_AGENT);

  // No request without a usable login.
  const none = fakeFetch({ status: 200 });
  const expired = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({ ".claude/.credentials.json": claudeFile({ expiresAt: NOW - HOUR }) }), now });
  const grokExpired = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": grokFile({ expires_at: new Date(NOW - HOUR).toISOString() }) }), now });
  assert.match((await fetchCliUsage({ login: expired, label: "Claude", fetch: none.fetchImpl })).note, /no usable CLI login/);
  assert.match((await fetchCliUsage({ login: grokExpired, label: "Grok", fetch: none.fetchImpl })).note, /no usable CLI login/);
  assert.equal(none.calls.length, 0);
});

test("a CLI answer that parsed to no numbers does not hide a working Firefox session", async () => {
  assert.equal(isUsableResult({ status: "partial", lines: ["Daily: unavailable", "Weekly: unavailable"] }), false);
  assert.equal(isUsableResult({ status: "partial", lines: ["Daily: 40% remaining", "Weekly: unavailable"] }), true);
  assert.equal(isUsableResult({ status: "ok", lines: [] }), true);
  assert.equal(isUsableResult({ status: "free", lines: ["Daily: No Subscription"] }), true);
  assert.equal(isUsableResult({ status: "login_required" }), false);
  assert.equal(isUsableResult(null), false);

  const login = readCodexCliLogin({ env: {}, homeDir: fakeHome({ ".codex/auth.json": codexFile() }), now });
  const parsedNothing = async () => ({ result: { status: "partial", lines: ["Daily: unavailable", "Weekly: unavailable"] } });
  const viaFirefox = await resolveCliFirst({ login, runCli: parsedNothing, runFirefox: async () => firefoxOk, label: "Codex", now });
  assert.equal(viaFirefox.source, "firefox");
  const neither = await resolveCliFirst({ login, runCli: parsedNothing, runFirefox: async () => firefoxLogin, label: "Codex", now });
  assert.equal(neither.source, "cli");
  assert.equal(neither.status, "error");
  assert.match(neither.note, /^Codex: response had no usage numbers/);
});

test("a failure inside the Firefox fallback stays that provider's error", async () => {
  const login = readClaudeCodeLogin({ env: {}, homeDir: fakeHome({}), now });
  const boom = new Error(`cookie copy failed near ${CLAUDE_TOKEN}`);
  boom.code = "EBUSY";
  const result = await resolveCliFirst({
    login,
    runCli: async () => assert.fail("a missing login must not run"),
    runFirefox: async () => { throw boom; },
    label: "Claude",
    now
  });
  assert.equal(result.status, "error");
  assert.equal(result.source, "");
  assert.equal(result.note, "Claude: fetch failed (Firefox fallback: EBUSY)");
  assertNoSecrets(JSON.stringify(result), "a failed fallback's result");
});

test("Grok: the x-userid header is sent only for a header-safe user id, and the id never leaks", () => {
  for (const userId of [undefined, "", "has space", "line\nbreak"]) {
    const login = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": grokFile({ user_id: userId }) }), now });
    assert.equal(login.state, "ok");
    assert.equal("x-userid" in login.headers(), false, String(userId));
  }
  const login = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": grokFile() }), now });
  assert.equal(login.headers()["x-userid"], GROK_USER);
  assertNoSecrets(JSON.stringify(login), "the Grok login object");
  assertNoSecrets(describeLogin(login, NOW), "the Grok login description");
  assert.equal(isAuthRejection(200, "7"), false);
});

test("Grok: with several sign-in entries the one expiring last is used", () => {
  const stale = { key: fakeJwt(NOW - HOUR), expires_at: new Date(NOW - HOUR).toISOString() };
  const fresh = { key: GROK_KEY, expires_at: new Date(NOW + 3 * HOUR).toISOString() };
  for (const data of [{ "https://old.example/sign-in": stale, "https://accounts.x.ai/sign-in": fresh }, { "https://accounts.x.ai/sign-in": fresh, "https://old.example/sign-in": stale }]) {
    const login = readGrokCliLogin({ env: {}, homeDir: fakeHome({ ".grok/auth.json": data }), now });
    assert.equal(login.state, "ok");
    assert.equal(login.headers().Authorization, `Bearer ${GROK_KEY}`);
  }
});

// The scraper runs a whole snapshot on import, so its CLI request code is checked by source: each
// CLI branch must use the module's guards.
function functionBody(source, name) {
  const start = source.search(new RegExp(`^(async )?function ${name}[(]`, "m"));
  assert.ok(start >= 0, `${name} not found in usage-scraper.mjs`);
  const rest = source.slice(start + 1);
  const end = rest.search(/^(async )?function \w+[(]/m);
  return end >= 0 ? source.slice(start, start + 1 + end) : source.slice(start);
}

test("the scraper's CLI requests use the module's guards", () => {
  const scraper = readFileSync(new URL("./usage-scraper.mjs", import.meta.url), "utf8");
  // grok.com is the Firefox path only: no CLI login reaches the grpc or subscription calls.
  for (const name of ["runGrpcWebProvider", "discoverGrokSubscriptionState"]) {
    assert.doesNotMatch(functionBody(scraper, name), /cliLogin|auth[?]?[.]login|[.]headers[(][)]/, `${name} is cookie-only`);
  }
  // Every CLI provider makes its one request through the module (fixed URL, no redirects, code-only errors).
  for (const name of ["runClaudeCli", "runCodexCli", "runGrokCli"]) {
    assert.match(functionBody(scraper, name), /runCliJsonUsage[(]/, `${name} goes through runCliJsonUsage`);
  }
  assert.match(functionBody(scraper, "runCliJsonUsage"), /fetchCliUsage[(]/);
  // Login headers are read only inside cli-credentials.mjs.
  const code = scraper.split(/\r?\n/).filter(line => !line.trim().startsWith("//")).join("\n");
  assert.doesNotMatch(code, /login[.]headers[(][)]/);
  // Grok's CLI JSON and its grpc payload end in the same result builder, so both paths read alike.
  const grokBranch = functionBody(scraper, "parseProviderSpecificUsage");
  assert.match(grokBranch, /parseGrokBillingUsage[(]/);
  assert.match(grokBranch, /buildGrokWeeklyResult[(]/);
  assert.match(functionBody(scraper, "parseGrokCreditsUsage"), /buildGrokWeeklyResult[(]/);
  // A CLI login's token never reaches the DPAPI token cache.
  assert.doesNotMatch(scraper, /tokenCache[.]set[(][^)]*login/);
});
