import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const guiSource = readFileSync(new URL("./Usage_Monitor_GUI.ahk", import.meta.url), "utf8");
const textRoles = ["header", "text", "dim", "dimmer", "good", "warn", "bad", "close", "drag", "strong", "hint"];

function readPalette(name) {
  const body = guiSource.match(new RegExp(`static ${name} := \\{([^}]+)\\}`, "s"))?.[1];
  assert.ok(body, `Could not find ${name} theme palette`);

  const palette = {};
  for (const match of body.matchAll(/(\w+):\s*0x([0-9A-Fa-f]{6})/g)) {
    palette[match[1]] = match[2];
  }
  return palette;
}

function luminance(hex) {
  const channels = [0, 2, 4].map((offset) => {
    const channel = Number.parseInt(hex.slice(offset, offset + 2), 16) / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function contrast(foreground, background) {
  const light = Math.max(luminance(foreground), luminance(background));
  const dark = Math.min(luminance(foreground), luminance(background));
  return (light + 0.05) / (dark + 0.05);
}

for (const [themeName, sourceName] of [["Default", "def"], ["Cyberpunk", "cyber"]]) {
  test(`${themeName} text roles meet 4.5:1 contrast`, () => {
    const palette = readPalette(sourceName);

    for (const role of textRoles) {
      assert.ok(palette[role], `${themeName} is missing ${role}`);
      assert.ok(
        contrast(palette[role], palette.bg) >= 4.5,
        `${themeName} ${role} (${palette[role]}) is unreadable on ${palette.bg}`
      );
    }

    for (const backgroundRole of ["btnHover", "btnPressed"]) {
      assert.ok(
        contrast(palette.strong, palette[backgroundRole]) >= 4.5,
        `${themeName} hover text is unreadable on ${backgroundRole}`
      );
    }

    // The Settings window's Edit and drop-down fields draw "text" on the "track" color.
    assert.ok(
      contrast(palette.text, palette.track) >= 4.5,
      `${themeName} Settings field text is unreadable on track ${palette.track}`
    );
  });
}

test("every role used as a font color is a contrast-checked text role", () => {
  // The footer help line once used "divider" (a bar color) as its font color and failed
  // contrast in both themes while this file only checked the roles listed above.
  const used = new Set();
  for (const match of guiSource.matchAll(/Font,[^\r\n]*UsageMonitorThemeRgb\("(\w+)"\)/g)) used.add(match[1]);
  for (const match of guiSource.matchAll(/UsageMonitorSettingsFont\("(\w+)"/g)) used.add(match[1]);
  assert.ok(used.size >= 5, `found only ${used.size} font roles; the source pattern may have changed`);
  for (const role of used) {
    assert.ok(textRoles.includes(role), `font color role "${role}" is not contrast-checked`);
  }
});

test("registered control colors are unique Default literals that the theme remap carries", () => {
  const def = readPalette("def");
  const values = Object.values(def).map((hex) => hex.toUpperCase());
  assert.equal(new Set(values).size, values.length, "Default palette values must be unique: the theme remap is keyed by them");

  const remapList = guiSource.match(/UsageMonitorApplyTheme\(\)[\s\S]*?for _, slot in \[([^\]]+)\]/)?.[1];
  assert.ok(remapList, "Could not find the theme remap slot list");
  const remapped = [...remapList.matchAll(/"(\w+)"/g)].map((match) => match[1]);

  const literals = [...guiSource.matchAll(/usageMonitorCtrl(?:Bg)?Colors\[[^\]]+\] := 0x([0-9A-Fa-f]{6})/g)].map((match) => match[1]);
  assert.ok(literals.length >= 20, `found only ${literals.length} registered colors; the source pattern may have changed`);
  for (const bgr of literals) {
    const rgb = (bgr.slice(4, 6) + bgr.slice(2, 4) + bgr.slice(0, 2)).toUpperCase();
    const slot = Object.keys(def).find((key) => def[key].toUpperCase() === rgb);
    assert.ok(slot, `registered color 0x${bgr} is not a Default palette value`);
    assert.ok(remapped.includes(slot), `registered "${slot}" color is missing from the theme remap, so it never changes theme`);
  }
});
