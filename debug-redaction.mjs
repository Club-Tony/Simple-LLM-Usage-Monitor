// Redaction for usage-scraper.mjs --debug output.
//
// The <outFile>.debug.txt file is meant to be safe to paste into a bug report: request
// statuses and response shapes, never credentials or personal data. Two layers:
//   - redactForDebug() masks every value under a sensitive key in parsed JSON before a
//     preview is built, so the shape (the keys) survives and the values do not
//   - redactDebugString() runs over every string leaf and again over every finished line
//     (formatDebugLog), as a safety net for emails, JWTs, Claude session keys, UUIDs, long
//     opaque tokens or hex runs, and the user's home folder in paths
// Binary payloads (the Grok protobuf response) are never dumped; log their lengths instead.

import os from "node:os";

const SENSITIVE_KEY = /(^id$|uuid|token|secret|cookie|session|authorization|password|email|phone|user_id|account_id|organization_id|^(name|display_name|full_name|first_name|last_name|given_name|family_name)$)/i;

export function isSensitiveDebugKey(key) {
  return SENSITIVE_KEY.test(String(key));
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Matches the home folder with any run of slashes or backslashes between its parts, so a
// plain path, a forward-slash path and a JSON-escaped path ("C:\\Users\\me") all match.
function homeDirPattern(homeDir) {
  const parts = String(homeDir || "").split(/[\\/]+/).filter(Boolean);
  if (parts.length < 2) return null;
  return new RegExp(parts.map(escapeRegExp).join("[\\\\/]+"), "gi");
}

const defaultHomePattern = homeDirPattern(os.homedir());

export function redactDebugString(value, { homeDir } = {}) {
  if (typeof value !== "string") {
    return value;
  }
  const homePattern = homeDir === undefined ? defaultHomePattern : homeDirPattern(homeDir);
  let text = homePattern ? value.replace(homePattern, "~") : value;
  return text
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "<email>")
    // A JWT or any fragment of one: base64url JSON always starts with "eyJ".
    .replace(/\beyJ[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]*)*/g, "<jwt>")
    // Claude's sessionKey cookie value.
    .replace(/\bsk-ant-[A-Za-z0-9_-]+/g, "<session-key>")
    .replace(/\buser-[A-Za-z0-9_-]+\b/g, "<user-id>")
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "<uuid>")
    // Anything left that looks like an opaque token or a hex/base64 dump.
    .replace(/[A-Za-z0-9_+-]{40,}={0,2}/g, "<redacted>");
}

export function redactForDebug(value, options) {
  if (Array.isArray(value)) {
    return value.map(item => redactForDebug(item, options));
  }

  if (!value || typeof value !== "object") {
    return redactDebugString(value, options);
  }

  return Object.fromEntries(Object.entries(value).map(([key, child]) => {
    if (isSensitiveDebugKey(key)) {
      return [key, "<redacted>"];
    }
    return [key, redactForDebug(child, options)];
  }));
}

export function sanitize(value) {
  return String(value ?? "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// Redacts first, truncates second, so a cut can never expose part of a value.
export function debugJsonPreview(value, maxLength, options) {
  const json = JSON.stringify(redactForDebug(value, options)) ?? "";
  return json.length > maxLength ? `${json.slice(0, maxLength)}...` : json;
}

export function formatDebugLog(lines, options) {
  return lines.map(line => sanitize(redactDebugString(String(line), options))).join("\n") + "\n";
}

// The shape of a JSON body without any of its values: "config.productUsage[].usagePercent:number".
// For learning an unfamiliar response from a debug file. Keys that are not plain identifiers show as
// <key>, so a key that is itself data (an id, an email) cannot leak.
export function jsonKeyPaths(value, { maxDepth = 5, maxPaths = 40 } = {}) {
  const paths = [];
  const typeOf = item => (item === null ? "null" : Array.isArray(item) ? "array" : typeof item);
  const walk = (item, prefix, depth) => {
    if (paths.length >= maxPaths) return;
    if (Array.isArray(item)) {
      const first = item.find(entry => entry !== null && entry !== undefined);
      if (first !== undefined && depth < maxDepth && (typeof first === "object")) {
        walk(first, `${prefix}[]`, depth + 1);
      } else {
        paths.push(`${prefix || "(root)"}:array${first === undefined ? "" : `<${typeOf(first)}>`}`);
      }
      return;
    }
    if (item && typeof item === "object" && depth < maxDepth) {
      const keys = Object.keys(item);
      if (keys.length === 0) paths.push(`${prefix || "(root)"}:{}`);
      for (const key of keys) {
        const safe = /^[A-Za-z_][A-Za-z0-9_]{0,40}$/.test(key) ? key : "<key>";
        walk(item[key], prefix ? `${prefix}.${safe}` : safe, depth + 1);
        if (paths.length >= maxPaths) return;
      }
      return;
    }
    paths.push(`${prefix || "(root)"}:${typeOf(item)}`);
  };
  walk(value, "", 0);
  return paths;
}
