# Security policy

## Reporting a problem

Please report security problems privately, through GitHub's private vulnerability reporting: open this
repository's **Security** tab and choose **Report a vulnerability**. Please do not open a public issue for
a security problem.

A useful report says what you found, how to reproduce it, which version (release or commit) you used, and
whether a credential could be exposed. Reports are read and answered as soon as possible, and a fix ships
as a new release.

## What matters most

The monitor reads sign-ins that already exist on your PC (CLI login files and Firefox cookies), so these are
the problems to report:

- a credential leaving the PC for anywhere other than its own provider's usage endpoint, or following a
  redirect;
- a credential appearing in a file, log, snapshot, debug output or error message, or being written,
  copied, cached outside the DPAPI cache, or refreshed;
- the data folder, the hand-off files or the temporary cookie copies being readable by another Windows user;
- the Node.js or sqlite download accepting a file that does not match its published checksum;
- the installer accepting a release, an AutoHotkey zip or a Node.js zip that does not match its SHA-256, or
  writing, moving, deleting or stopping anything that is not its own (see below);
- any data file (`settings.ini`, the snapshot or hand-off files, the caches) naming code or a command to run, or
  getting one past the bridge's arguments. Only a host script can name an add-on module
  (`usageMonitorHostAddonModule`, passed on as the bridge's `-AddonModule`); see "Add-on provider" in
  `README.md`.

## How the installer checks what it installs

- The setup BAT carries the release ZIP and that ZIP's SHA-256. Its extractor hashes the embedded ZIP before
  writing or unpacking anything and stops on a mismatch. That hash proves the BAT is intact, not who made it:
  compare the downloaded file with the release page's `SHA256SUMS.txt`.
- Setup checks every program file against the release's `setup\payload-manifest.json` after copying it.
- AutoHotkey and Node.js zips must match the SHA-256 pinned in setup (Node.js's must also match nodejs.org's
  `SHASUMS256.txt`) before anything is unpacked; only `AutoHotkeyU64.exe`, `node.exe` and their licenses are kept.
- Setup moves or deletes an install folder only when it is named `LLMUsageMonitor` and holds this product's
  `install-state.json`; it changes or removes a shortcut only when it opens that folder; in the data folder it
  deletes only the files the app writes; and it stops only processes whose program or command line is inside the
  install folder, checked twice.

"Privacy and data" in `README.md` lists everything the monitor reads, writes and connects to.

## Out of scope

- A provider changing its service so the monitor stops working: please open a normal issue.
- Problems in the providers' own services.
- Attacks that need someone already running code as you on your PC: they could read the same sign-ins
  directly.
- What an add-on module does once a host script has chosen to load it: it runs with your rights by design.
  How the monitor loads it, and what it does with the add-on's results, is in scope.

## Supported versions

Fixes go into the latest release only.
