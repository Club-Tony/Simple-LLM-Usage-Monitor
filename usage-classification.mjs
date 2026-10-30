function normalizedBillingType(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

export function classifyClaudeSubscription(organization) {
  if (!organization || typeof organization !== "object" || Array.isArray(organization)) {
    return "unknown";
  }

  const billingType = normalizedBillingType(organization.billing_type);
  if (billingType === "none") {
    return "free";
  }
  if (billingType) {
    return "active";
  }
  return "unknown";
}

// Grok's entitlement signal, the direct analogue of Claude's organization billing_type:
// GET https://grok.com/rest/subscriptions returns { subscriptions: [{ tier, status, ... }] },
// a full history in which every past subscription stays listed as SUBSCRIPTION_STATUS_INACTIVE.
// grok.com's own frontend decides "is subscribed" the same way — it looks for an entry whose
// status is ACTIVE — so presence in the list means nothing on its own and only an ACTIVE entry
// counts. Tiers seen in the wild: SUBSCRIPTION_TIER_GROK_PRO (the "SuperGrok" plan),
// _SUPER_GROK_LITE/_PLUS/_PRO, and the X carryovers _X_BASIC/_X_PREMIUM/_X_PREMIUM_PLUS;
// SUBSCRIPTION_TIER_INVALID is a placeholder and never an entitlement.
export function classifyGrokSubscription(body) {
  const list = Array.isArray(body) ? body : body?.subscriptions;
  if (!Array.isArray(list)) {
    return "unknown";
  }

  const hasActive = list.some((entry) =>
    normalizedBillingType(entry?.status) === "subscription_status_active"
    && normalizedBillingType(entry?.tier) !== "subscription_tier_invalid"
  );

  // An empty list is a real answer (never subscribed), not a missing one.
  return hasActive ? "active" : "free";
}

// Legacy fallback for responses that omit the unified credit_usage_percent. The repeated
// ProductUsage entries carry a billing_product.Product enum, where 2 = PRODUCT_GROK_BUILD —
// the product this weekly window actually measures.
export function chooseGrokUsagePercent(unifiedPercent, productUsages = []) {
  if (Number.isFinite(unifiedPercent)) {
    return unifiedPercent;
  }

  const preferred = productUsages.find((entry) =>
    entry?.kind === 2 && Number.isFinite(entry?.percent)
  );
  if (preferred) {
    return preferred.percent;
  }

  const fallback = productUsages.find((entry) => Number.isFinite(entry?.percent));
  return fallback ? fallback.percent : null;
}

// The Grok CLI's own billing call (cli-chat-proxy.grok.com/v1/billing?format=credits, the host xAI
// documents for auth.json tokens). Its body carries the same GrokCreditsConfig the grok.com grpc call
// returns, in protobuf JSON form: camelCase keys, enums by name or number, Timestamps as RFC 3339
// strings. Returns { percentUsed, resetMs } or null when the body is not recognisable. As on the grpc
// path, a config with a billing period but no percent means nothing used yet.
const GROK_PRODUCT_ENUM = { PRODUCT_GROK_BUILD: 2 };

function grokProductKind(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    if (/^\d+$/.test(value.trim())) return Number(value.trim());
    return GROK_PRODUCT_ENUM[value.trim().toUpperCase()] ?? null;
  }
  return null;
}

// Plausible epoch milliseconds (2023 to 2033) from an RFC 3339 string, a { seconds } Timestamp, or
// epoch seconds / milliseconds.
function grokTimestampMs(value) {
  if (typeof value === "string") {
    const text = value.trim();
    if (/^\d{4}-\d{2}-\d{2}T/.test(text)) {
      const parsed = Date.parse(text);
      return Number.isFinite(parsed) ? parsed : null;
    }
    if (/^\d{10}$/.test(text) || /^\d{13}$/.test(text)) return grokTimestampMs(Number(text));
    return null;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    if (value > 1.7e9 && value < 2e9) return value * 1000;
    if (value > 1.7e12 && value < 2e12) return value;
  }
  return null;
}

function latestGrokTimestampMs(config) {
  let maxMs = null;
  const consider = (ms) => {
    if (ms !== null && ms > 1.67e12 && ms < 2e12 && (maxMs === null || ms > maxMs)) maxMs = ms;
  };
  const walk = (value, depth) => {
    if (depth > 6 || value === null || value === undefined) return;
    if (Array.isArray(value)) {
      for (const item of value) walk(item, depth + 1);
      return;
    }
    if (typeof value === "object") {
      if (value.seconds !== undefined) consider(grokTimestampMs(Number(value.seconds)));
      for (const item of Object.values(value)) walk(item, depth + 1);
      return;
    }
    consider(grokTimestampMs(value));
  };
  walk(config, 0);
  return maxMs;
}

export function parseGrokBillingUsage(body) {
  const config = body && typeof body === "object" && !Array.isArray(body) ? body.config : null;
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    return null;
  }
  const unified = toNumber(config.creditUsagePercent ?? config.credit_usage_percent);
  const productList = Array.isArray(config.productUsage) ? config.productUsage
    : (Array.isArray(config.product_usage) ? config.product_usage : []);
  const productUsages = productList
    .map((entry) => ({ kind: grokProductKind(entry?.product), percent: toNumber(entry?.usagePercent ?? entry?.usage_percent) }))
    .filter((entry) => Number.isFinite(entry.percent));
  let percentUsed = chooseGrokUsagePercent(unified, productUsages);
  const resetMs = latestGrokTimestampMs(config);
  if (percentUsed === null) {
    if (resetMs === null) {
      return null;
    }
    percentUsed = 0;
  }
  return { percentUsed, resetMs };
}

// Entitlement on the billing response. Only an explicit subscription list counts (the same shape as
// grok.com/rest/subscriptions); anything else is "unknown", which leaves the real numbers on screen.
export function classifyGrokBillingSubscription(body) {
  if (body && typeof body === "object" && Array.isArray(body.subscriptions)) {
    return classifyGrokSubscription(body);
  }
  return "unknown";
}

export function classifyCodexSubscription(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return "unknown";
  }

  // The top-level plan type is the authoritative entitlement signal. Check it
  // before recursively scanning billing-shaped metadata, which may describe
  // credits/spend controls rather than the ChatGPT subscription itself.
  const planType = normalizedBillingType(body.plan_type ?? body.plan ?? body.subscription_type);
  if (planType === "free") {
    return "free";
  }
  if (["none", "no_subscription", "no-subscription", "unsubscribed"].includes(planType)) {
    return "inactive";
  }
  if (planType) {
    return "active";
  }

  const billingState = findCodexBillingState(body);
  if (billingState === "inactive") {
    return "inactive";
  }
  if (billingState === "free") {
    return "free";
  }
  if (billingState === "active") {
    return "active";
  }

  return "unknown";
}

function findCodexBillingState(value) {
  if (!value || typeof value !== "object") {
    return "unknown";
  }

  let sawBillingMetadata = false;
  for (const [key, child] of Object.entries(value)) {
    const normalizedKey = key.toLowerCase();
    if (["billing", "billing_type", "billingtype", "billing_status", "billingstatus"].includes(normalizedKey)) {
      sawBillingMetadata = true;
      const billingValue = typeof child === "object" && child !== null
        ? child.type ?? child.status ?? child.kind
        : child;
      const normalizedValue = normalizedBillingType(billingValue);
      if (["none", "no_subscription", "no-subscription", "unsubscribed"].includes(normalizedValue)) {
        return "inactive";
      }
      if (normalizedValue === "free") {
        return "free";
      }
      if (normalizedValue) {
        return "active";
      }
    }

    if (child && typeof child === "object") {
      const nestedState = findCodexBillingState(child);
      if (nestedState === "inactive") {
        return "inactive";
      }
      if (nestedState === "free") {
        return "free";
      }
      if (nestedState === "active") {
        sawBillingMetadata = true;
      }
    }
  }

  return sawBillingMetadata ? "active" : "unknown";
}

// The claude.ai usage payload's `limits` array mirrors the frontend's own meter
// list: kind "session" (= five_hour), "weekly_all" (= seven_day), and
// "weekly_scoped" — a per-model weekly window identified by
// scope.model.display_name (e.g. "Fable"). `percent` is utilization (used),
// matching the top-level windows' `utilization` fields. Returns the first
// scoped weekly entry as { label, remainingPercent, resetAt(ms) } or null.
export function extractClaudeScopedWeeklyLimit(body) {
  const limits = body?.limits;
  if (!Array.isArray(limits)) {
    return null;
  }

  for (const entry of limits) {
    if (!entry || typeof entry !== "object" || entry.kind !== "weekly_scoped") {
      continue;
    }
    const percentUsed = toNumber(entry.percent);
    if (percentUsed === null) {
      continue;
    }
    const displayName = entry.scope?.model?.display_name;
    const label = typeof displayName === "string" && displayName.trim() ? displayName.trim() : "Model";
    return {
      label,
      remainingPercent: Math.min(100, Math.max(0, 100 - percentUsed)),
      resetAt: extractResetTimestamp(entry)
    };
  }

  return null;
}

export function isClaudeNoSubscriptionUsage(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return false;
  }

  const baseWindowsEmpty =
    isEmptyClaudeUsageWindow(body.five_hour) &&
    isEmptyClaudeUsageWindow(body.seven_day);

  if (!baseWindowsEmpty) {
    return false;
  }

  // Any populated non-base key (a `limits` array, spend/meta objects, a
  // per-model window) means quota structure exists, so the numbers stay
  // revealable — only the fully-null legacy shape is a no-subscription answer.
  return Object.entries(body)
    .filter(([key]) => key !== "five_hour" && key !== "seven_day")
    .every(([, value]) => value === null || value === undefined);
}

function isEmptyClaudeUsageWindow(windowData) {
  if (!windowData || typeof windowData !== "object" || Array.isArray(windowData)) {
    return false;
  }

  const utilization = toNumber(windowData.utilization ?? windowData.percent_used ?? windowData.used_percent);
  if (utilization !== 0 || extractResetTimestamp(windowData)) {
    return false;
  }

  const quotaKeys = [
    "limit", "max", "total", "remaining", "left", "remaining_count",
    "messages_remaining", "tokens_remaining", "used", "consumed",
    "used_count", "messages_used", "tokens_used", "limit_dollars",
    "remaining_dollars", "used_dollars"
  ];

  return quotaKeys.every((key) => toNumber(windowData[key]) === null);
}

function toNumber(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number.parseFloat(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function extractResetTimestamp(value) {
  const raw = value?.resets_at ?? value?.reset_at ?? value?.resetsAt ?? value?.resetAt;
  if (raw === null || raw === undefined || raw === "") return null;
  if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) return raw;
  if (typeof raw === "string" && /^\d+(\.\d+)?$/.test(raw.trim())) {
    const numeric = Number.parseFloat(raw);
    return Number.isFinite(numeric) && numeric > 0 ? numeric : null;
  }
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

