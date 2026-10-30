# Third-party notices

The monitor's own code is under the MIT License (`LICENSE`). It ships one third-party file.

## SQLite: `sqlite3.exe`

- What: the SQLite command-line shell, version 3.47.2 (2024-12-07), used to read Firefox's cookie database.
- Source: SQLite's official `sqlite-tools-win-x64-3470200.zip`,
  https://www.sqlite.org/2024/sqlite-tools-win-x64-3470200.zip
- `sqlite3.exe` SHA-256: `5e33fe030fb7c3bbe2bca1f70f21a406716961aefdfb1bc030d7c65b7db055e9` (3,849,728 bytes),
  byte-identical to the copy in that zip. The zip's SHA3-256 as published by sqlite.org:
  `7e88369b0d37e188ccd2f840e871f6be8a03dd86a8441730136e7814e4794850`.
- License: SQLite is in the public domain, https://www.sqlite.org/copyright.html. No license is needed to use
  or redistribute it.

## Downloaded by the installer, not included

AutoHotkey v1 and Node.js are needed to run the monitor but are not part of the release download. The installer
fetches each from its own official source at install time, checks it against a pinned SHA-256, and keeps one
program file plus that program's license in the install folder's `runtime\`:

- **AutoHotkey v1.1.37.02**: `AutoHotkey_1.1.37.02.zip` from https://www.autohotkey.com (or AutoHotkey's GitHub
  releases), zip SHA-256 `6f3663f7cdd25063c8c8728f5d9b07813ced8780522fd1f124ba539e2854215f`. Kept:
  `AutoHotkeyU64.exe` and its `license.txt` (saved as `runtime\AutoHotkey-license.txt`). License: GNU GPL v2,
  https://www.autohotkey.com/docs/v1/license.htm. The monitor's scripts are run by this interpreter; they are not
  compiled into it.
- **Node.js v24.22.1**: `node-v24.22.1-win-x64.zip` from https://nodejs.org/dist/v24.22.1/, zip SHA-256
  `d2046d28c2c3dcd211ac5145c0bf30e2047ef9dfb306693c8c6e2eccd8b95fa5` (also checked against that release's
  `SHASUMS256.txt`). Kept: `node.exe` and its `LICENSE` (saved as `runtime\Node-LICENSE.txt`), which holds the
  MIT license of Node.js and the licenses of the libraries built into `node.exe`.

If a release ever bundles either program itself, for example a compiled (Ahk2Exe) executable, which contains the
AutoHotkey interpreter, this file will carry that program's license terms.
