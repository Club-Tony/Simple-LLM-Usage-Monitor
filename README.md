# Simple LLM Usage Monitor

How much of your Codex, Claude and Grok plan limits is left, in a small always-on-top Windows popup.

`Usage_Monitor_GUI.ahk` is a library, and a host script includes it:

- **`Usage_Monitor.ahk` - the standalone app.** Install it with the one-click installer (see "Install"
  below), which brings its own AutoHotkey and Node.js, or run it with AutoHotkey v1.1.33+. It adds a tray
  icon (left-click shows the popup; right-click: Show usage, Refresh now, Start with Windows, Open
  data folder, Settings..., About, Exit) and one global hotkey, Alt+Y by default. The popup floats in the
  bottom-right corner of the primary monitor until you drag it somewhere else.
- **Your own AutoHotkey v1 script** can host it instead and keep its own hotkey. It sets any host settings
  just above its `#Include`: for example `usageMonitorHostAnchorMode := "apps"` to dock to the tracked
  apps, `usageMonitorHostSpriteFile` for an animated GIF in the full view, `usageMonitorHostYieldWindows`
  (a `|`-separated list of window titles, such as a dictation overlay, that the popup drops below while
  any is up), `usageMonitorHostDockApps` (see "Extra dock apps") and `usageMonitorHostAddonModule` (see
  "Add-on provider"). All host settings are listed at the top of the GUI file.

### Data folder and settings

Everything the monitor writes lives in `%LOCALAPPDATA%\LLMUsageMonitor\`
(`LLM_USAGE_MONITOR_DATA_DIR` replaces it for portable or test use):
`settings.ini` (remembered view, theme, positions, Claude profile, plus the settings below),
`snapshot.log`, the two caches described under "What it writes" below, and `tmp\` for the short-lived
snapshot hand-off files.
"Privacy and data" below lists everything the monitor reads, writes and sends.

### Settings window

Open it from the standalone tray (`Settings...`) or press `O` while the popup has focus (both hosts).
It holds:

- **Hotkey** (standalone only): type it as `Ctrl+Alt+Y` or in AutoHotkey form `^!y`. A key with no Ctrl,
  Alt or Win, Shift alone with a typing key, Win+L, and Ctrl+Shift+Alt+Win (the Office key on Windows) are
  refused. When a host script owns the hotkey, the row shows the host's text (`usageMonitorHostHotkeyLabel`)
  and cannot be changed there.
- **Providers**: for Codex, Claude and Grok, `Auto (CLI, then Firefox)` (the default), `CLI only`,
  `Firefox only` or `Off`. A host script's add-on column (see "Add-on provider") gets `Off` or `On`.
  - `Off` reads no login, queries no cookie and sends no request for that provider. The full view shows
    its rows as a dim `Off`, and the mini view leaves it out whatever its mini mode.
  - `CLI only` never touches Firefox: an expired or missing CLI login reads `Run <cli>, then Refresh`.
  - `Firefox only` never reads the CLI login file.
- **Claude profile**: the Firefox profile Claude reads while it may use Firefox. `Automatic` goes back to the
  default profile. It is the same setting the `S` key and the account-label click change.
- **Position** (float on screen, or dock to tracked apps), **Refresh** (adaptive, or every 1, 2, 5 or 15
  minutes) and **Theme** (Default or Cyberpunk, the same setting as the `C` key).

Save applies everything at once: a new hotkey is registered before the old one is released (if Windows
refuses it, the old one keeps working and nothing is saved), and provider changes trigger a refresh. Only
the keys you changed are written, because both hosts can share one `settings.ini`. A position chosen from
one host therefore also applies to the other host.

The same settings by hand (comments must sit on their own lines: `IniRead` keeps anything after the value):

```ini
[Settings]
; Standalone only. AutoHotkey syntax: ! Alt, ^ Ctrl, + Shift, # Win.
hotkey=!y
; screen = float on screen; apps = dock to a tracked app (a host script can make it the default).
anchorMode=screen
; 0 = adaptive (15 s to 1 min); otherwise a fixed cadence in seconds (at least 5).
refreshSeconds=0

[Providers]
; auto | cli | firefox | off. Anything else counts as off.
codex=auto
claude=auto
grok=auto

[State]
; default | cyberpunk
theme=default
```

`screen` mode never hides for lack of an app and keeps refreshing on the adaptive cadence while
you are at the PC, whichever app has focus; after 5 minutes without input it stops until you
return. `apps` mode is the docked behaviour described in the notes below. `/startup` on the
standalone's command line (used by its Start with Windows shortcut) reopens the popup only if it
was open when the app last ran.

## What it does

- Fetches LLM usage data directly from provider APIs, using your CLI logins first (Claude Code, Codex CLI,
  Grok CLI) and your Firefox session cookies as the fallback.
  See "How it works", step 1.
- Full view shows a dim source tag beside each provider name: `CLI` or `Firefox` (Claude shows `CLI` in
  its account-label spot). Hovering a provider name or its tag says which login supplied the numbers; the mini
  view does not show the source.
- Writes a local key/value snapshot file that AutoHotkey renders in a small always-on-top popup
- Shows daily and weekly usage bars for Codex and Claude subscriptions — plus a third Claude line/bar for the
  per-model scoped weekly meter when the account has one (e.g. `Fable: 87% remaining`, labeled from the API's
  model display name; `F:87%` in mini view). The row appears only while the API reports the window and
  disappears cleanly when it goes away — plus a single weekly bar for Grok
  (SuperGrok credits — `Weekly: X% remaining`). Grok's usage comes from a grpc-web call
  (`GetGrokCreditsConfig`) decoded directly from the protobuf response, not REST JSON. The
  response's unified usage percentage is authoritative; per-product credit rows are retained
  only as a compatibility fallback for older response shapes.
  An untouched billing period reads as `Weekly: 100% remaining` — proto3 omits zero-valued
  percent fields, so right after the weekly rollover the config legitimately carries no
  percent at all (it is not a fetch/parse failure). Because that is indistinguishable from an
  unsubscribed account's config, entitlement is read separately from
  `GET https://grok.com/rest/subscriptions`.
- In full view, the underlined Codex, Claude, and Grok provider names are clickable shortcuts to the relevant
  usage pages. Codex and Grok open in Firefox's registered default profile. Claude opens Firefox's profile
  manager first so you can choose the account/profile, with normal URL fallback if Firefox cannot be launched.
- Full view stacks three sections (Codex, Claude, Grok); mini view shows up to three columns
  (`Codex | Claude | Grok`), plus one for a host script's add-on (see "Add-on provider")
- Shows `No Subscription` when an authenticated provider explicitly reports no subscription; Claude uses the
  primary organization billing type, Codex uses its billing metadata, and Grok uses its subscriptions list, so
  free accounts are not misread as unused `100% remaining` paid windows. Grok's list is a full history in which
  lapsed subscriptions remain present as `SUBSCRIPTION_STATUS_INACTIVE`, so only an entry that is currently
  `SUBSCRIPTION_STATUS_ACTIVE` counts as an entitlement. An unreachable or unreadable subscriptions response
  stays `unknown` and leaves the usage numbers untouched — it never downgrades a paying account to `No Subscription`.
- Supports a remembered full/mini view toggle; mini view omits unavailable providers and individual unavailable metrics
- Mini provider mode is independently persisted: hover a compact provider column for `Hide`, then use its full-view
  control. Each provider cycles `Auto` → `Free` → `On` → `Off`.
  `Auto-hidden` means Auto currently has no usable metric or its weekly allowance is exhausted. Free reveals the API-reported free-tier
  quota percentages; On forces a compact `(Free)` status when those rates are hidden
- Dragging the popup remembers a per-app hook position (VS Code, Claude, Codex, Grok terminal, and any extra dock
  app a host script adds) across reloads
- Full view shows delayed hover tooltips for the drag handle, `-` / `+`, and `X`
- The monitored Claude account label has its own independent hide/show toggle (an eye glyph beside the name),
  separate from the `Resets` toggle; when shown it can switch between authenticated Firefox profiles
- Mini view shows a small clickable active-account signal (e.g. `j42@`) stacked just beneath the `+` toggle,
  past the Claude column
- In mini view, `T` pops a transient panel listing the visible resets (Codex/Claude daily & weekly, plus
  `Claude F` when the per-model row is shown, and `Grok W`) below the HUD
- Auto-refreshes on an adaptive cadence while the popup is open: every 15s while
  values are moving (or while the popup is focused), backing off 15s -> 30s -> 60s
  once snapshots stop changing anything. It is never slower than the old fixed 60s,
  and up to 4x faster while you are actually burning quota.
- Automatic refreshes are **silent**: the numbers change in place, with no
  `Refreshing...` blanking and no repaint at all when nothing changed. Manual
  refreshes (`R` / the `Refresh` button) still show the load state, so a keypress
  always visibly registers.
- A fixed cadence comes from the Settings window's Refresh choice (`[Settings] refreshSeconds`). For a
  quick test there is also the older

  ```ini
  [Debug]
  autoRefreshMs=5000
  ```

  which counts only while `refreshSeconds` is not set. Both disable the adaptive tiers and are clamped to
  a 5000ms floor - each snapshot makes real API calls against your live provider sessions, so polling much
  faster risks rate limiting rather than better data.

## How it works

The scraper (`usage-scraper.mjs`) uses **Node.js `fetch()`** directly — no browser automation needed.

1. **CLI logins first** (`cli-credentials.mjs`) — Codex, Claude and Grok each try the login of their command-line
   tool before Firefox:

   | Provider | Login file (read only) | Call made with its access token |
   |----------|------------------------|---------------------------------|
   | Claude | `%USERPROFILE%\.claude\.credentials.json` (or `CLAUDE_CONFIG_DIR`), written by Claude Code | `GET https://api.anthropic.com/api/oauth/usage` (the call Claude Code's own `/usage` makes) |
   | Codex | `%USERPROFILE%\.codex\auth.json` (or `CODEX_HOME`), written by the Codex CLI | `GET https://chatgpt.com/backend-api/wham/usage` |
   | Grok | `%USERPROFILE%\.grok\auth.json`, written by the Grok CLI | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (the Grok CLI's own billing call, on the host xAI's Grok CLI README documents for `auth.json` tokens) |

   - The file is read on every refresh and never written, copied, cached or refreshed. An expired token is not
     renewed: renewing would rotate the CLI's own login and could sign that CLI out. Run the CLI and it renews
     its own login. The token goes only to its provider's usage URL, never through a redirect, and appears in no
     snapshot, log or debug line.
   - A missing, unreadable, malformed or expired login, or one the server rejects (HTTP 401/403), falls back to
     the Firefox path below. A Firefox cookie database is copied only when a provider falls back.
   - Claude Code and Grok CLI tokens last 8 and 6 hours and are renewed only while that CLI runs, so outside
     those hours those providers usually come from Firefox. The Codex CLI token lasts about 10 days.
   - While Claude Code's login supplies Claude, the account label shows `CLI` (the login file holds no email) and
     the Firefox account switch is off; it returns when Claude falls back to Firefox.
   - A Codex CLI login made with an API key only has no ChatGPT usage to read and is skipped.
   - `LLM_USAGE_CLI_HOME` replaces the home folder for all three lookups (ignoring `CLAUDE_CONFIG_DIR` and
     `CODEX_HOME`); pointing it at an empty folder forces the Firefox path, which is how the fallback is tested.
   - The Settings window can limit a provider to its CLI login or to Firefox, or switch it off (no read, no
     request). The bridge passes those choices to the scraper as `--providers`; without that argument (a run by
     hand) every provider behaves as above.
   - Grok's CLI call sends the headers the Grok CLI README names (`X-XAI-Token-Auth: xai-grok-cli`, plus the
     login's `x-userid`); it reads the same credits config as the grok.com call in step 5, as JSON. It carries
     no subscription list, so a Grok CLI login on a free account shows its real percentage rather than
     `No Subscription`.

2. **Cookie extraction** (the Firefox fallback) — `sqlite3.exe` reads Firefox's `moz_cookies` table (plaintext, no decryption
   needed). The DB (with its `cookies.sqlite-wal`, so a sign-in Firefox has not yet checkpointed is seen) is
   copied to a `%TEMP%\llm-usage-cookies-*` folder first so Firefox's file lock is never an issue.
   Extracted cookie rows stay in process memory/stdout only; no cookie-value query output file is written,
   and the temporary DB copy is removed immediately after each refresh (a run that was killed leaves one
   behind; the next run removes any older than 10 minutes). Each refresh copies a profile at most once
   and shares that copy between providers, and which profiles hold a Claude session is cached per
   profile until its cookie files change, so a steady-state refresh copies only the default profile
   (plus the selected Claude profile when that is a different one). `firefox-cookie-db.mjs` holds the details.

3. **Codex** — `GET https://chatgpt.com/backend-api/wham/usage`
   - The backend-api requires a Bearer token, not just cookies.
   - With the Codex CLI login (step 1) that is the login's own token plus a `ChatGPT-Account-Id` header.
   - On the Firefox path the token is obtained by first calling `GET https://chatgpt.com/api/auth/session` with
     cookies → response contains `{ "accessToken": "eyJ..." }` → sent as `Authorization: Bearer <token>`.

4. **Claude** — `GET https://claude.ai/api/organizations/{orgId}/usage` (Firefox path; the Claude Code path in
   step 1 calls `api.anthropic.com/api/oauth/usage`, which returns the same shape)
   - The org UUID is user-specific. It is discovered dynamically each run by calling
     `GET https://claude.ai/api/organizations` with cookies → `[0].uuid` used to build the URL.
   - No hardcoded UUIDs.
   - The per-model meter is NOT a top-level `seven_day_*` window (those are typically `null`); it lives in the
     response's `limits` array as the entry with `kind: "weekly_scoped"`, whose `percent` is utilization (used)
     and whose `scope.model.display_name` names the model (e.g. `Fable`). `extractClaudeScopedWeeklyLimit` in
     `usage-classification.mjs` turns it into the `claude_line_3` snapshot line; when the entry is absent the
     key is emitted empty and the GUI collapses the row.
   - Codex cookies stay on the default Firefox profile. Claude can use a selected Firefox profile, allowing
     two Claude accounts to be monitored when each account is logged into Claude in its own Firefox profile.

5. **Grok** (the Firefox fallback; the Grok CLI login goes to the CLI proxy in step 1) —
   `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` (grpc-web)
   - Firefox cookies only; a Grok CLI token never goes to grok.com. The empty 5-byte request frame
     is posted and the protobuf response is decoded in-process (see `parseGrokCreditsUsage`).
   - Entitlement comes from a second, plain-JSON call: `GET https://grok.com/rest/subscriptions`
     → `{ "subscriptions": [{ "tier": "SUBSCRIPTION_TIER_...", "status": "SUBSCRIPTION_STATUS_..." }] }`.
     This is the counterpart to Claude's organization `billing_type` — the credits config alone
     cannot tell a free account from a subscriber whose billing period just rolled over.
     Only `SUBSCRIPTION_STATUS_ACTIVE` counts; lapsed subscriptions stay in the list as `INACTIVE`.
   - Grok cookies come from the default Firefox profile.


## Extra dock apps (for host scripts)

In `apps` mode the popup docks to Claude Desktop, Codex Desktop, VS Code and a terminal whose title contains
`grok`. A host script can add its own windows by setting `usageMonitorHostDockApps` before its `#Include`,
as `|`-separated `type=kind:value` entries. Like the add-on, it has no `settings.ini` key.

```autohotkey
usageMonitorHostDockApps := "notes=exe:Notepad.exe|board=title:Project Board|logs=terminal:tail,logs"
```

- `exe:name.exe` matches any window of that process.
- `title:a,b` matches a window whose title contains `a` or `b` (case-insensitive), except in a terminal, so a
  shell running a same-named command is not mistaken for the app.
- `terminal:a,b` matches a terminal window (Windows Terminal, PowerShell, cmd, conhost) whose title has `a` or
  `b` as a whole word.
- `type` names the app's saved drag position: lowercase letters, digits and `-`. The built-in names
  (`vscode`, `claude`, `codex`, `grok-terminal`, `screen`), repeats and malformed entries are skipped.
- On a cold start the popup tries these after Claude and Codex, in the order given, before the Grok
  terminal and VS Code.

## Add-on provider (for host scripts)

A script that hosts the popup can add one extra provider column of its own. It sets
`usageMonitorHostAddonModule` to the full path of an ES module (`.mjs`) before it includes
`Usage_Monitor_GUI.ahk`. That setting is the only way to name one: no `settings.ini` key, state value,
snapshot value, environment variable or folder scan can. The standalone app never sets it, so for most
people the column does not exist.

- The path must be an absolute drive path to an existing `.mjs` file (no network share, no `..`, no quotes).
  The GUI passes it to the bridge as `-AddonModule`; the bridge checks it and passes it to the scraper as
  `--addonModule`, which checks it again before importing it. The path is never logged.
- The module's default export describes its column and has one function:
  `{ id, label, lineLabels: [a, b], sourceTag, link, signInHint, settingsWarning, run(ctx) }`. The contract
  and its limits are at the top of `addon-provider.mjs`: a label of up to 7 characters, two row labels of up
  to 6, a source tag of up to 8 lowercase letters, an `https://` link without a query string (or none), and
  one-line hint and warning texts.
- `run(ctx)` returns the same result as a built-in provider (`status`, two `lines`, `resetTexts`, `note`).
  `ctx` gives it the scraper's fetch helper and PowerShell runner, a DPAPI token cache and a discovery cache
  that are both namespaced to the add-on (it cannot read the monitor's own entries), a debug log, the line
  formatters and the time budget. Whatever it returns is cleaned and length-capped; a throw or a timeout
  becomes an error row, and the add-on counts like Grok: it can lower the overall status to `partial`, no more.
- The Settings window shows an `Off` / `On` row for it (`[Providers] addon`, on by default). `Off` means the
  module is not even imported. A Save from a host without the add-on leaves that key alone.
- An add-on is code the host chose to run with your own rights: `ctx` is a convenience, not a sandbox, so
  an add-on's own behaviour is outside this project's security scope (see `SECURITY.md`).

## Privacy and data

The monitor runs only on your PC. It has no telemetry, no analytics, no crash reporting and no update
check: the only network requests it makes are the usage calls below, plus the setup downloads it asks you
about. A provider set to `Off` in Settings is not read and not contacted at all.

### What it reads

| What | When | How |
|------|------|-----|
| `%USERPROFILE%\.claude\.credentials.json`, `%USERPROFILE%\.codex\auth.json`, `%USERPROFILE%\.grok\auth.json` (or `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `LLM_USAGE_CLI_HOME`) | Every refresh, for each provider allowed to use its CLI login | Read only: never written, copied, cached or refreshed. The token is held in memory for one request to that provider. |
| Firefox: `%APPDATA%\Mozilla\Firefox\profiles.ini`, the profile folder list, and each profile's `cookies.sqlite` and `cookies.sqlite-wal` | Only when a provider allowed to use Firefox falls back to it | The two cookie files are copied to a `%TEMP%\llm-usage-cookies-*` folder (Firefox locks the originals), queried with `sqlite3.exe` for the providers' own hosts only, and the copy is deleted at the end of the refresh. Cookie values stay in memory. To list the profiles signed in to Claude it also reads each profile's cookie-file size and time and the expiry of its claude.ai session cookie. |
| Whatever a host script's add-on module reads | Only when a host names one (the standalone app never does) | The add-on's own code; see "Add-on provider". |
| Claude Desktop's `%APPDATA%\Claude\Local Storage\leveldb` | Only if the host sets `LLM_USAGE_CLAUDE_DESKTOP_LABEL=1` | Searched for an account email to label Claude when claude.ai gives none. |
| `settings.ini` in the data folder | Start and each open | Your saved view, positions and settings. |

While you are away from the PC, the popup asks Windows to tell it about your next keyboard or mouse input so
it can wake up. It never looks at what was typed, and it stops listening at the first input.

### What it writes

Everything lives in the data folder, `%LOCALAPPDATA%\LLMUsageMonitor\` (or `LLM_USAGE_MONITOR_DATA_DIR`),
except where noted:

- `settings.ini`: your settings and window state. That means view, theme, position per tracked app, the
  monitored Claude Firefox profile's folder name, the account-label and mini-view toggles, the hotkey,
  anchor mode, refresh cadence, provider choices, and whether the popup was open.
- `snapshot.log`: one entry per refresh, trimmed to the last 50 once it passes 16 KB. Each entry holds the
  time, exit status, provider choices, each provider's status, source and usage lines, the masked Claude
  account label (for example `j***42@example.com`), the Claude Firefox profile name, the Node.js and
  hand-off file paths, and on a failure the error and the first 10 lines of Node's output.
- `tmp\`: the hand-off files between the scraper and the popup (the snapshot above, as key=value lines),
  deleted as soon as the popup has read them.
- `llm-usage-token-cache.dpapi`, encrypted with Windows DPAPI for your user account. It holds the
  ChatGPT access token fetched on the Firefox path (until that token expires) and anything a host's
  add-on caches through its `ctx.cache`, under its own prefix. CLI login tokens are never put here.
- `llm-usage-discovery-cache.json`, plain JSON with no credentials. It holds the Claude usage URL (which
  contains your Claude organization's ID), the masked account label and billing state per Firefox profile
  (kept 10 minutes), an add-on's own `ctx.discovery` entries, and per Firefox profile the
  cookie-file sizes and times and the Claude session's expiry time (kept 24 hours).
- `node\`: only in a copy run without the installer, if you answer Yes to the Node.js prompt and winget is
  unavailable (see "Running from source").
- `sqlite3.exe` beside the scripts: only if it is missing (see "Running from source").
- `<outFile>.debug.txt`: only when the scraper is run by hand with `--debug true`. Its response previews are
  redacted (tokens, cookies, session keys, emails, names, account and org IDs, your home folder path).
- Outside the data folder: the temporary cookie copies in `%TEMP%` (deleted after each refresh; a killed run's
  copy is removed by the next run after 10 minutes); a `%TEMP%\llm-usage-sqlite-*` folder during the one-time
  sqlite download (removed when it ends); `LLM Usage Monitor.lnk` in your Startup folder, only
  while Start with Windows is ticked.

It writes nothing to the registry, does not change `PATH`, and never writes to Firefox's files, the CLI login
files or Credential Manager.

The installer (see "Install") writes, in addition: the install folder `%LOCALAPPDATA%\Programs\LLMUsageMonitor\`
(the program, `runtime\` with AutoHotkey and Node.js, `setup\`, `release.json` and `install-state.json`, which
records the version, the folders, the shortcuts it made and the runtime hashes); `LLM Usage Monitor.lnk` in your
Start Menu, and in your Startup folder if you say yes; one registry key,
`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\LLMUsageMonitor`, which is the Settings > Apps entry;
and while it runs, a `%TEMP%\LLMUsageMonitor-Setup-*` folder and a `%TEMP%\LLMUsageMonitor-Extract-*.ps1` file
(the BAT's unpacked copy, deleted when setup ends) plus `LLMUsageMonitor.staging-*` beside the install folder
(renamed into place, or deleted on failure). It does not change `PATH` or any other installed program.

### Where it connects

| Provider | With the CLI login | With Firefox cookies |
|----------|--------------------|----------------------|
| Claude | `api.anthropic.com/api/oauth/usage` | `claude.ai/api/organizations`, `claude.ai/api/organizations/<org>/usage` |
| Codex | `chatgpt.com/backend-api/wham/usage` | `chatgpt.com/api/auth/session`, `chatgpt.com/backend-api/wham/usage` |
| Grok | `cli-chat-proxy.grok.com/v1/billing?format=credits` | `grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`, `grok.com/rest/subscriptions` |

All over HTTPS. A CLI token goes only to its own provider's URL above and never follows a redirect. Setup
downloads: the installer fetches `www.autohotkey.com/download/1.1/AutoHotkey_1.1.37.02.zip` (or the same zip from
`github.com/AutoHotkey/AutoHotkey/releases`) and `nodejs.org/dist/v24.22.1/` (`SHASUMS256.txt` and the win-x64 zip),
only on a first install or when an installed copy is missing or damaged. Without the installer, each only when
needed: `www.sqlite.org` (if `sqlite3.exe` is missing) and, after you answer Yes to the Node.js prompt, winget or
`nodejs.org`. Clicking a provider name opens that provider's page in Firefox; nothing else opens a browser.

User-Agents: `LLMUsageMonitor/1.0` on requests that carry a CLI token; the fixed Firefox string
`Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0` on requests that carry
Firefox cookies (plus `x-user-agent: connect-es/2.1.1` on the grok.com credits call); Node.js's own default on
the sqlite.org download; `LLMUsageMonitor-Setup/<version>`
on the installer's AutoHotkey and Node.js downloads; and PowerShell's default on the popup's own nodejs.org download
(copies run without the installer).

### How to remove everything

Installed with the installer: Settings > Apps > Installed apps > Simple LLM Usage Monitor > Uninstall, or run the
installer again and choose `2`. That does steps 1 to 3 below (see "Uninstall" under "Install" for exactly what it
removes and what it leaves). Otherwise, by hand:

1. Exit the app (tray icon, Exit).
2. Untick Start with Windows first, or delete `LLM Usage Monitor.lnk` from your Startup folder (`shell:startup`).
3. Delete the data folder, `%LOCALAPPDATA%\LLMUsageMonitor\` (or your `LLM_USAGE_MONITOR_DATA_DIR`).
4. Optional leftovers: any `%TEMP%\llm-usage-cookie*` or `%TEMP%\llm-usage-sqlite-*` folder (only after a
   killed run).

Your CLI logins and Firefox profiles belong to those programs; the monitor only reads them, so
removing it leaves them as they were.

## Install

Requirements: Windows 10 or 11, 64-bit, with Windows PowerShell 5.1 (built in). No administrator rights.
Setup downloads about 41 MB (AutoHotkey 5.1 MB, Node.js 36.0 MB) and needs about 100 MB of disk, most of it
`node.exe`. To read your usage the monitor needs a Claude Code, Codex CLI or Grok CLI login, or Firefox signed
in to those sites (see "What it does").

**One click:** download `LLMUsageMonitor-Setup-v<version>.bat` and double-click it. The same release has
`LLMUsageMonitor-v<version>.zip` with the same files for people who want to read them first: extract it and
double-click `Install.bat`. Both run `setup\Setup-LLMUsageMonitor.ps1`.

The first run shows where it installs and what it downloads, then on Enter:

1. Copies the program into `%LOCALAPPDATA%\Programs\LLMUsageMonitor\`, checking every file against the
   release's `setup\payload-manifest.json`.
2. Downloads AutoHotkey v1.1.37.02 from www.autohotkey.com (github.com if that fails) and Node.js v24.22.1
   from nodejs.org. Each zip must match a SHA-256 pinned in setup (Node's must also match nodejs.org's
   `SHASUMS256.txt`) before anything is unpacked. Only `AutoHotkeyU64.exe` and `node.exe`, with their licences,
   are kept, in the install folder's `runtime\`. Nothing else from the zips is written: no AutoHotkey compiler,
   no npm. If a download fails, save the zip it names next to the installer and run it again; setup uses it
   only if its SHA-256 matches the pin.
3. Adds a Start Menu shortcut and an entry in Settings > Apps > Installed apps.
4. Asks whether to start with Windows (default No; the tray's Start with Windows item changes it later), then
   starts the app.

PATH and the AutoHotkey or Node.js already on the PC are not touched. The bridge runs `runtime\node.exe` by its
full path. The install folder is the installer's own and is replaced whole on a reinstall, so keep nothing of
yours in it. Settings and caches live in the data folder (above), which setup does not create or change.

Running the installer again on an installed PC offers `[1] Reinstall` (puts the program files back and
re-checks AutoHotkey and Node.js, downloading only what changed or is damaged; your settings and Start with
Windows choice stay), `[2] Uninstall` and `[3] Close`.

### Uninstall

Settings > Apps > Installed apps > LLM Usage Monitor > Uninstall, or run the installer again and choose `2`.
It closes the app, then removes the install folder, the Start Menu shortcut, the Startup shortcut, the Settings >
Apps entry, and in the data folder only the files the app itself writes (`settings.ini`, `snapshot.log`, the two
caches, `tmp\` and any `node\` copy). It asks whether to keep `settings.ini` for a later reinstall. Anything else
in the data folder is left where it is and listed by full path; the folder goes when nothing else is in it. A
shortcut named `LLM Usage Monitor.lnk` that opens something other than this install is never changed or removed.
Your CLI logins and browser profiles are never touched, by the app or by setup.

### Setup options

For scripts: `Setup-LLMUsageMonitor.ps1` (or either BAT, which passes its arguments on) takes
`-Action Install | Reinstall | Uninstall | Status`, `-NonInteractive` (no prompts), `-Startup` / `-NoStartup`,
`-KeepSettings` / `-KeepData` (uninstall), `-NoLaunch`, and `-InstallRoot`, `-DataDir`, `-StartMenuDir`,
`-StartupDir` for other locations (the install folder must be named `LLMUsageMonitor`). Exit codes: 0 done,
1 stopped (an install or reinstall that fails leaves the previous install as it was), 2 a runtime could not be
downloaded, 3 the uninstall could not remove everything (run it again), 9 the BAT is damaged.

### Unknown publisher warnings

The release is not code-signed, so Windows SmartScreen or a browser may warn that the publisher is unknown,
and some antivirus programs flag any BAT that unpacks an embedded archive. The BAT is plain text: a short cmd
stub, a PowerShell extractor you can read, then the release zip as Base64. The extractor checks the zip's
SHA-256 before unpacking anything. Download only from the project's release page and compare the file's SHA-256
(`Get-FileHash <file>`) with that page's `SHA256SUMS.txt`; the ZIP shows every file as it is.

### Building a release

`installer\Build-UsageMonitorRelease.ps1` writes `dist\` (gitignored): the BAT, the ZIP, `release.json` (version
from `package.json`, source commit, file hashes, runtime pins) and `SHA256SUMS.txt`. Two builds of the same
source are byte-identical. It reads only this folder, refuses uncommitted changes in it unless `-AllowDirty`,
and stops on any file here that is neither shipped nor excluded in the builder.
`npm test` runs `installer\Test-Installer.ps1`, an offline test of the build, the BAT and the whole install,
reinstall and uninstall cycle against fixture runtimes, fenced away from the real install, shortcuts and
registry.

## Running from source

Run `Usage_Monitor.ahk` with AutoHotkey v1.1.33+. No npm packages are required: the scraper uses only Node.js
built-ins plus `sqlite3.exe`, which ships in this folder.

Node.js: the bridge (`Get-LLMUsageSnapshot.ps1`) runs `node.exe` by its full path, looking first for the
installer's copy beside the scripts (`runtime\node.exe`), then the data folder's own copy
(`%LOCALAPPDATA%\LLMUsageMonitor\node`), then on `PATH`, then in the usual install folders. It never edits
`PATH`. When none is found, the popup asks before installing anything. Yes runs
`winget install OpenJS.NodeJS.LTS --scope user` (which accepts the winget source and package agreements for you,
as the prompt says), or, without winget, downloads the latest LTS zip from nodejs.org, checks it against that
release's `SHASUMS256.txt` and unpacks it into the data folder's `node` folder. An existing folder there is renamed
aside, never deleted, and nothing else on the machine is touched. `Test-NodeInstall.ps1` (run by `npm test`)
covers the zip path offline.

`sqlite3.exe` (tracked since 2026-03-19): `sqlite3 --version` reports
`3.47.2 2024-12-07 20:39:59 2aabe05e2e8cae4847a802ee2daddc1d7413d8fc560254d93ee3e72c14685b6c (64-bit)`;
SHA-256 `5e33fe030fb7c3bbe2bca1f70f21a406716961aefdfb1bc030d7c65b7db055e9`, 3,849,728 bytes: byte-identical to
the copy in SQLite's official `sqlite-tools-win-x64-3470200.zip` (checked 2026-10-25 by downloading the zip through
the scraper's own verified install path). If the file is missing, the scraper
downloads that zip once (`sqlite-tool.mjs`) and installs `sqlite3.exe` only when the zip's SHA3-256 matches the
one sqlite.org published for it (`7e88369b0d37e188ccd2f840e871f6be8a03dd86a8441730136e7814e4794850`); anything
else installs nothing.

## Hotkeys in popup

- `Alt+Y` — open the popup, or focus it when it is already on screen. Pressing `Alt+Y` while the popup is
  focused only *unfocuses* it (the red focus border clears, the overlay stays put); it never hides the
  overlay. Focus returns to the window you came from.
- `Esc` — close popup. Exception: in mini view with the transient `T` resets panel open, the first `Esc`
  only dismisses that panel and unfocuses the popup — press `Esc` again (or with no panel up) to close.
- `R` — refresh now
- `T` — view-aware. In full view (or the clickable `Resets`) it toggles reset dates on all metrics, not just at
  `0%`. In mini view it pops a transient themed panel listing all four resets (Codex/Claude daily & weekly) docked
  below the HUD (auto-flips above when near the taskbar), auto-hiding after ~8 seconds; press `T` again to dismiss
  early. The mini panel is display-only and does not change the persisted full-view `Resets` state.
- `S` — switch to the next monitored Claude account (works whenever the account label is shown)
- `A` — hide/show the active account display for the current view (full-view label / mini-view signal); the two
  views remember their state independently
- `M` or the `-` / `+` button — switch between the full popup and the remembered mini view
- `C` or the 🎨 button in full view — toggle the color theme (Default ⇄ Cyberpunk); the choice persists across reloads
- `O` — open the Settings window (see "Settings window" above)
- Top-left `::` handle in full view — drag the popup; the bottom-left hook is remembered per tracked app across reloads. Hover it for a short tooltip.
- Hover the drag handle, `-` / `+`, or `X` for 2 seconds without moving or clicking to see a short control tooltip.
- In full view, click the eye glyph (`👁` / `🙈`) beside the Claude account name to hide/show the account label;
  this is independent of the `Resets` toggle.
- When the account label is shown, hover it for `Switch Monitored Account?`; click it to switch to the next
  authenticated Claude Firefox profile and refresh immediately.
- In mini view, the account signal (e.g. `j42@`) is stacked just beneath the `+` button (past the Claude column) and
  shows the active account; click it to collapse it to a small `·` dot in the same spot. The collapsed dot is a
  hover-only peek — it appears only while the cursor is over the HUD and hides when you move away (hover and click the
  dot, or press `A`, to show the full account code again).
- In mini view, hover any visible provider column to reveal its bordered `Hide` control. The choice persists across
  popup closes, script reloads, and Windows restarts. Full view always keeps every diagnostic section visible and
  provides a mode control beside each provider header. `Auto` follows usable-data eligibility, `Free` reveals an
  explicit free tier when available, `On` forces a compact status cell, and `Off` hides it. All three providers
  include Free in their cycle — Grok's free tier still reports weekly credits, so Free reveals that percentage
  instead of the default `No Subscription`. In Auto mode, Codex, Claude, and Grok collapse when their weekly allowance reaches `0%`; On keeps an exhausted provider visible for diagnosis.

## Notes

- The monitor consumes no LLM inference tokens.
- The popup anchors to the bottom-left of the selected desktop app. Focused tracked window first,
  then last-focused, then cold-start fallback: Claude Desktop, Codex Desktop, a host script's extra
  dock apps in its order (see "Extra dock apps"), a Grok-tagged terminal, then any visible VS Code window.
- Transient dialog/popup windows (e.g. VS Code's external-link "open the external website?" trust
  prompt) are ignored as anchor targets, so the HUD stays docked to the main editor instead of jumping
  to the dialog's corner.
- A dragged bottom-left offset is saved per tracked app type in the monitor state file and restored
  when that app is focused again, including across reopen/reload. An app you have never dragged
  still uses the default bottom-left hook.
- The popup attaches itself. Once opened it stays armed across reloads and restarts: when the last
  tracked app window closes or minimizes it hides, and it reappears as soon as one is back, usually
  within about 2 seconds (at login it waits for your first tracked app instead of giving up). While
  hidden it listens for window events and also runs one cheap window check every 2 seconds, so a
  missed event can't leave it hidden. `Esc` or `X` closes it for real; it then stays
  closed until the next `Alt+Y`.
- It only polls while you are using it. With a tracked app or the popup focused it follows its anchor
  every 150 ms and refreshes on the adaptive 15-60 s cadence. With another app focused, after 5 minutes
  without keyboard or mouse input, or while hidden waiting for an app, nothing runs at all: Windows wakes
  it when a window activates, when the cursor reaches the popup, or on your next input. A snapshot older
  than the cadence refreshes once when you come back; quick app switches reuse the existing schedule.
- The full-view drag handle and mini-view body use a hand cursor on hover and a closed-hand cursor while dragging.
- Full view stays readable while idle, then drops to about 90% transparent / 10% opaque when the mouse
  is over the popup. Non-interactive areas remain click-through; buttons, links,
  and the close/toggle/drag controls keep the normal full-view opacity in a small padded hit zone.
  When restoring from mini view, full view stays fully opaque until the mouse leaves the popup once.
  A host's animated sprite is input-transparent and keeps the hover transparency behavior. Its embedded browser is forced
  to 100% optical zoom and re-pinned after footer reflow so the complete frame remains visible.
- Clickable controls highlight on hover and show a brief pressed state when clicked.
- Mini view hides the refresh/help/reset controls and visible progress bars, stays solid instead of click-through,
  and can be dragged from anywhere except interactive controls. Individual `n/a`, unavailable, and `No Subscription`
  metrics collapse while valid sibling metrics remain (for example, Codex `Daily: n/a` + `Weekly: 80%` becomes only
  `W:80%`). In Auto mode a provider collapses when it has no usable metric; On forces an informative `n/a` cell, or
  `(Free)` for a Claude account explicitly reporting no subscription. If all three are Off/auto-hidden, mini view
  shrinks to the `+` restore control only.
  `Esc`, `R`, `T`, `S`, `A`, `C`, `M` and `O` still work while mini view is open (the 🎨 button is full-view only).
- If a Daily/Weekly metric reaches `0%`, the line always includes a local reset suffix when available,
  e.g. `Weekly: 0% remaining - resets 3/12 1pm.`
- Press `T` or click `Resets` in full view to show reset dates on all metrics regardless of percentage,
  e.g. `Weekly: 70% remaining - resets 3/12 1pm.`
- When the account label is shown (toggled with the eye glyph or `A`, independent of `Resets`), the full-view Claude
  header includes a masked account label from the same Claude org discovery response when available, e.g.
  `j***42@example.com`; raw emails are not written to debug output. When that response carries no email, the label
  can instead come from Claude Desktop's own storage (`%APPDATA%\Claude\Local Storage\leveldb`), but only if the
  host opts in with `EnvSet, LLM_USAGE_CLAUDE_DESKTOP_LABEL, 1` above its `#Include`: it is off by default because
  it reads another app's data and can pick up the wrong address. If more than one Firefox profile is signed in to
  Claude (an unexpired `sessionKey` cookie), that label is clickable and switches the monitored Claude account. The
  selected Firefox profile name is stored locally in the monitor state file; cookie values are not. A stored profile
  that has since been signed out is dropped from the cycle and the monitor falls back to the default Firefox profile.
- Mini view derives a compact account signal from that masked label (collapsing `head***tail` → `head+tail`, e.g.
  `j***42` → `j42@`); no raw email is exposed. The full-view and mini-view hide/show states each persist independently
  in the monitor state file (`showClaudeAccountFull` / `showClaudeAccountMini`).
- If a provider has no active subscription, full view shows `No Subscription` and Auto mode hides that provider in
  mini view. Selecting Free reveals the API-reported free-tier rates; On instead forces a compact `(Free)` status.
  Claude entitlement is read from the same primary organization used for its usage request: `billing_type=none` is
  retained as a free status, a non-empty paid billing type is active, and missing metadata uses the conservative
  legacy quota fallback.
- Codex free plan (no active subscription): `plan_type=free` is retained as a distinct snapshot status. Auto renders
  `No Subscription` in full view and hides it in mini; selecting `Mini: Free` reveals the actual free-tier percentage
  lines in both views. `n/a` still means "no such window on this plan" and is distinct from `unavailable`, which
  signals a genuine fetch failure.
- When Grok specifically fails to fetch (`unavailable` / could-not-parse), the full-view `Weekly:` line becomes a
  clickable accent-colored link (`→ Open Grok`) that opens `https://grok.com/?_s=usage` in Firefox — the browser whose cookies
  the scraper reads — so you land in the same session to log in / check. Mini view collapses the Grok column instead.
- Provider fetch failures are summarized in the red status row as a compact actionable message with the first
  sanitized cause per provider; detailed raw output remains available through the scraper debug/log path.
- When a red error/status message is shown in full view, the popup grows to fit it (the footer shifts down and the
  window re-sizes) so long messages are never clipped or overlapping the footer. Sign-in failures use this one
  actionable row only (for example, `Codex sign-in required. Open Codex above, then Refresh.`); the underlined
  provider headers remain the sole webpage links, so no duplicate login hint is shown.
- Default and Cyberpunk route all visible text states through the active palette, including refresh, disabled,
  Resets, hover, and pressed states. `npm test --prefix Usage_Monitor` enforces at least 4.5:1 contrast for
  every text role against its theme background.
- **DPI / scaling model**: all popup GUIs are created with `-DPIScale`, so every coordinate in the script (controls,
  `WinGetPos`, mouse hit-zones) lives in one space — raw physical pixels — and `UsScale`/`UsFont` own all scaling
  explicitly. The real DPI of the monitor the popup shows on is read via a temporary `SetThreadDpiAwarenessContext`
  (per-monitor-v2) around `GetDpiForMonitor` (the plain call is virtualized: a system-DPI-aware process would get the
  sign-in system DPI for every monitor). Target magnification is `min(monitorDPI/96, usageMonitorUiScaleCap)` in
  `auto` mode (physical-size parity with the 96-DPI design, capped at 1.5 by default) or a forced number. Coordinates
  and fonts use different factors (`target*A_ScreenDPI/monDPI` vs `target*96/monDPI`) because a system-DPI-aware
  window is DWM-stretched by `monDPI/systemDPI` while GDI renders point sizes at the system DPI. A 100% monitor
  renders byte-for-byte as designed.
- Codex token/session failures are treated as fetch errors unless the session endpoint explicitly reports login required.
- If values show as unavailable after refreshing, click the underlined provider names in full view, confirm the
  relevant pages are logged in, then press `Refresh`. Codex and Grok use the registered default Firefox profile;
  Claude prompts you to choose a Firefox profile before opening its usage page. The account label still identifies
  which profile the monitor reads for Claude usage and can switch that monitored account independently.
- If the Codex plan changes or Claude's org structure changes, run with `--debug true` to inspect
  redacted API response shapes in `<outFile>.debug.txt`. It is meant to be safe to share: cookie values,
  tokens, session keys, emails, names, account and org ids, your home folder path and raw binary payloads
  are masked or left out (`debug-redaction.mjs`, covered by `npm test`).
- The scraper makes direct API calls with your own signed-in session (the same requests the provider's
  usage page makes); it does not launch or automate a browser.
- User-Agent: requests that carry a CLI login's token (Claude Code, Codex CLI, Grok CLI) name the tool:
  `LLMUsageMonitor/1.0` (`TOOL_USER_AGENT` in `cli-credentials.mjs`). Requests that carry Firefox cookies (Codex,
  Claude, Grok) send a fixed Firefox User-Agent
  (`Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0`, `BROWSER_USER_AGENT` in
  `usage-scraper.mjs`), because they ride that Firefox session; the tool does not name itself to those sites.
- Sign-in: when Codex or Claude has no working login, the status line names the ways back that its Settings
  choice allows, e.g. `Codex sign-in required. Run codex or open Codex above, then Refresh.` (Auto),
  `Run claude, then Refresh.` (CLI only) or `Open Codex above, then Refresh.` (Firefox only).
