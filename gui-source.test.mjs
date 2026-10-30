import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Static checks on the AutoHotkey sources (they cannot be unit-tested from Node).
const sources = ["Usage_Monitor_GUI.ahk", "Usage_Monitor.ahk"].map((name) => ({
  name,
  text: readFileSync(new URL(`./${name}`, import.meta.url), "utf8")
}));

test("every IniRead names a default, so a missing key never reads as the word ERROR", () => {
  // AutoHotkey v1's IniRead returns "ERROR" for a missing key when the Default parameter is
  // omitted or blank. A blank claudeProfile default once made fresh installs pass
  // -ClaudeProfile "ERROR" to the bridge and list "ERROR" in the Settings window.
  let count = 0;
  for (const { name, text } of sources) {
    text.split(/\r?\n/).forEach((line, index) => {
      const match = line.match(/^\s*IniRead\s*,(.*)$/i);
      if (!match) return;
      count++;
      const params = match[1].split(",").map((part) => part.trim());
      // OutputVar, Filename, Section, Key, Default
      assert.ok(params.length >= 5 && params[4] !== "", `${name}:${index + 1} IniRead has no default: ${line.trim()}`);
    });
  }
  assert.ok(count >= 15, `found only ${count} IniRead lines; the source pattern may have changed`);
});

// The add-on column (addon-provider.mjs): only the host script can name a module, and the GUI
// passes it to the bridge from that one place. No settings, state or snapshot value names code.
test("the add-on module comes only from the host setting, never from a file", () => {
  const gui = sources.find(source => source.name === "Usage_Monitor_GUI.ahk").text;
  const standalone = sources.find(source => source.name === "Usage_Monitor.ahk").text;
  const assignments = gui.split(/\r?\n/).filter(line => /^\s*usageMonitorAddonModule\s*:=/.test(line));
  assert.deepEqual(assignments.map(line => line.trim().replace(/\s*;.*$/, "")), ["usageMonitorAddonModule := usageMonitorHostAddonModule"]);
  assert.doesNotMatch(standalone, /usageMonitorHostAddonModule\s*:=/, "the standalone app never names an add-on");
  for (const { name, text } of sources) {
    for (const line of text.split(/\r?\n/)) {
      if (/^\s*IniRead\b/i.test(line)) assert.doesNotMatch(line, /addon\s*module|addonModule|AddonPath/i, `${name}: ${line.trim()}`);
    }
  }
  // The bridge argument carries that variable (or a word the bridge rejects), nothing else.
  assert.match(gui, /-AddonModule """ [.] [(]RegExMatch[(]usageMonitorAddonModule, /);
  assert.equal((gui.match(/-AddonModule/g) || []).length, 1);
});

// Extra dock apps (usageMonitorHostDockApps): a host-only list, parsed once. No settings, state or
// snapshot value adds a window to dock to.
test("extra dock apps come only from the host setting, never from a file", () => {
  const gui = sources.find(source => source.name === "Usage_Monitor_GUI.ahk").text;
  const standalone = sources.find(source => source.name === "Usage_Monitor.ahk").text;
  const assignments = gui.split(/\r?\n/).filter(line => /^\s*usageMonitorDockApps\s*:=/.test(line));
  assert.deepEqual(assignments.map(line => line.trim().replace(/\s*;.*$/, "")), ["usageMonitorDockApps := UsageMonitorParseDockApps(usageMonitorHostDockApps)"]);
  assert.doesNotMatch(standalone, /usageMonitorHostDockApps\s*:=/, "the standalone app adds no dock apps");
  for (const { name, text } of sources) {
    for (const line of text.split(/\r?\n/)) {
      if (/^\s*IniRead\b/i.test(line)) assert.doesNotMatch(line, /dock\s*apps?/i, `${name}: ${line.trim()}`);
    }
  }
  // The parser skips the built-in type names, so a host cannot take over their saved positions.
  assert.match(gui, /if appType in vscode,claude,codex,grok-terminal,screen/);
});

test("the add-on link is opened only after the strict https check", () => {
  const gui = sources.find(source => source.name === "Usage_Monitor_GUI.ahk").text;
  const body = gui.slice(gui.indexOf("UsageMonitorOpenAddonPage()\r\n{"), gui.indexOf("}", gui.indexOf("UsageMonitorOpenAddonPage()\r\n{")));
  assert.match(body, /UsageMonitorAddonLinkIsSafe[(]usageMonitorAddonLink[)]/);
  assert.match(gui, /UsageMonitorAddonLinkIsSafe[(]url[)]\r?\n\{\r?\n\s*return RegExMatch[(]url, "\^https:\/\/\[A-Za-z0-9[.]-\]\+[(]\/\[A-Za-z0-9[.]_~\/-\]\*[)]\?\$"[)] > 0/);
});

test("add-on controls are built, coloured and saved only when the host has an add-on", () => {
  const gui = sources.find(source => source.name === "Usage_Monitor_GUI.ahk").text;
  const lines = gui.split(/\r?\n/);
  // Every line that creates an add-on control sits inside an `if (usageMonitorAddonActive)` block
  // (or carries that condition itself); a colour key for a blank hwnd repaints the whole desktop.
  lines.forEach((line, index) => {
    if (!/Gui, UsageMon:Add, .*vUsageMon(Addon|MiniHideAddon|MiniDivider3)\b/.test(line)
      && !/usageMonitorCtrlColors\[usageMonitorHwnd(Addon\w*|MiniHideAddon)\] :=/.test(line)) return;
    const context = lines.slice(Math.max(0, index - 16), index + 1).join("\n");
    const hwnd = (line.match(/usageMonitorCtrlColors\[(usageMonitorHwnd\w+)\]/) || [])[1];
    const hwndGuard = hwnd && new RegExp(`if \\(${hwnd}\\)\\s*$`).test(lines[index - 1] || "");
    assert.ok(/usageMonitorAddonActive/.test(context) || hwndGuard, `line ${index + 1} is not gated: ${line.trim()}`);
  });
  // A Save where the row was not built leaves [Providers] addon alone (settings.ini is shared).
  assert.match(gui, /if [(]usageMonitorAddonActive && addonIndex[)]\r?\n\s*\{\r?\n\s*addon := /);
});
