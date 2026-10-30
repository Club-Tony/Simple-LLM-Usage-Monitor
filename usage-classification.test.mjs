import test from "node:test";
import assert from "node:assert/strict";
import {
  chooseGrokUsagePercent,
  classifyClaudeSubscription,
  classifyCodexSubscription,
  classifyGrokBillingSubscription,
  classifyGrokSubscription,
  extractClaudeScopedWeeklyLimit,
  isClaudeNoSubscriptionUsage,
  parseGrokBillingUsage
} from "./usage-classification.mjs";

// Shape captured live from GET https://grok.com/rest/subscriptions on 2026-08-17: every past
// subscription stays in the list as INACTIVE, so only an ACTIVE entry proves entitlement.
const grokLapsedHistory = [
  { tier: "SUBSCRIPTION_TIER_GROK_PRO", status: "SUBSCRIPTION_STATUS_INACTIVE", billingPeriodEnd: "2026-06-09T07:09:45Z" },
  { tier: "SUBSCRIPTION_TIER_GROK_PRO", status: "SUBSCRIPTION_STATUS_INACTIVE", billingPeriodEnd: "2026-08-10T01:02:47Z" }
];

const unusedWindow = {
  utilization: 0,
  resets_at: null,
  limit_dollars: null,
  used_dollars: null,
  remaining_dollars: null
};

test("Grok unified usage wins over product-credit breakdown", () => {
  assert.equal(chooseGrokUsagePercent(100, [
    { kind: 5, percent: 70 },
    { kind: 1, percent: 23 },
    { kind: 4, percent: 7 }
  ]), 100);
});

test("Grok legacy response prefers the SuperGrok product entry", () => {
  assert.equal(chooseGrokUsagePercent(null, [
    { kind: 5, percent: 70 },
    { kind: 2, percent: 41 }
  ]), 41);
});

test("lapsed Grok subscriptions do not count as an entitlement", () => {
  // The exact regression: an account whose last subscription ended still gets a valid weekly
  // credits config, which reads as "100% remaining" unless the entitlement says otherwise.
  assert.equal(classifyGrokSubscription({ subscriptions: grokLapsedHistory }), "free");
});

test("Grok is active when any entry is currently ACTIVE", () => {
  assert.equal(classifyGrokSubscription({
    subscriptions: grokLapsedHistory.concat([
      { tier: "SUBSCRIPTION_TIER_GROK_PRO", status: "SUBSCRIPTION_STATUS_ACTIVE", billingPeriodEnd: "2026-09-18T02:03:16Z" }
    ])
  }), "active");
  assert.equal(classifyGrokSubscription({
    subscriptions: [{ tier: "SUBSCRIPTION_TIER_SUPER_GROK_PRO", status: "SUBSCRIPTION_STATUS_ACTIVE" }]
  }), "active");
});

test("Grok with no subscriptions at all is free, not unknown", () => {
  assert.equal(classifyGrokSubscription({ subscriptions: [] }), "free");
});

test("an INVALID tier is never an entitlement even when marked active", () => {
  assert.equal(classifyGrokSubscription({
    subscriptions: [{ tier: "SUBSCRIPTION_TIER_INVALID", status: "SUBSCRIPTION_STATUS_ACTIVE" }]
  }), "free");
});

test("an unreadable Grok subscriptions response stays unknown so usage is left alone", () => {
  assert.equal(classifyGrokSubscription(null), "unknown");
  assert.equal(classifyGrokSubscription({}), "unknown");
  assert.equal(classifyGrokSubscription({ subscriptions: "nope" }), "unknown");
  assert.equal(classifyGrokSubscription("<html>login</html>"), "unknown");
});

test("free Claude organization remains distinguishable so its quota can be revealed", () => {
  const organization = { billing_type: "none", capabilities: ["chat"] };
  const usage = {
    five_hour: unusedWindow,
    seven_day: unusedWindow,
    limits: [{ kind: "session", percent: 0, resets_at: null, is_active: true }],
    member_dashboard_available: false
  };
  assert.equal(classifyClaudeSubscription(organization), "free");
  assert.equal(isClaudeNoSubscriptionUsage(usage), false);
});

test("paid Claude organization remains active with zero utilization", () => {
  assert.equal(classifyClaudeSubscription({ billing_type: "stripe", capabilities: ["chat"] }), "active");
});

test("Codex billing none is an inactive subscription", () => {
  assert.equal(classifyCodexSubscription({ billing: "none", rate_limit: { secondary_window: { percent: 100 } } }), "inactive");
  assert.equal(classifyCodexSubscription({ account: { billing_type: "none" } }), "inactive");
});

test("Codex free plan remains distinguishable from no subscription", () => {
  assert.equal(classifyCodexSubscription({ plan_type: "free", rate_limit: { primary_window: { used_percent: 79 } } }), "free");
  assert.equal(classifyCodexSubscription({ account: { billing_type: "free" } }), "free");
  assert.equal(classifyCodexSubscription({
    plan_type: "free",
    credits: { billing: "metered" },
    spend_control: { billing_status: "enabled" }
  }), "free");
});

test("paid Codex billing remains active", () => {
  assert.equal(classifyCodexSubscription({ billing: "chatgpt_plus" }), "active");
});

test("missing billing metadata stays unknown when quota data is valid", () => {
  assert.equal(classifyClaudeSubscription({ capabilities: ["chat"] }), "unknown");
  assert.equal(isClaudeNoSubscriptionUsage({
    five_hour: { utilization: 10, resets_at: "2026-07-19T01:00:00Z" },
    seven_day: { utilization: 5, resets_at: "2026-07-25T01:00:00Z" }
  }), false);
});

test("legacy structurally empty Claude usage falls back to no subscription", () => {
  assert.equal(isClaudeNoSubscriptionUsage({ five_hour: unusedWindow, seven_day: unusedWindow }), true);
});

// Shape captured live from GET https://claude.ai/api/organizations/{orgId}/usage on 2026-08-30:
// the per-model meter is NOT a top-level seven_day_* window (those were all null) — it is the
// `limits` entry with kind "weekly_scoped", whose `percent` is utilization (used) and whose
// scope.model.display_name names the model (e.g. "Fable").
const scopedWeeklyLimits = [
  { kind: "session", group: "session", percent: 75, severity: "warning", resets_at: "2026-08-31T02:49:59.949291+00:00", scope: null, is_active: true },
  { kind: "weekly_all", group: "weekly", percent: 8, severity: "normal", resets_at: "2026-08-31T01:59:59.949314+00:00", scope: null, is_active: false },
  { kind: "weekly_scoped", group: "weekly", percent: 11, severity: "normal", resets_at: "2026-08-31T01:59:59.949540+00:00", scope: { model: { id: "claude-fable-5", display_name: "Fable" }, surface: null }, is_active: false }
];

test("scoped weekly limit is extracted with model label and remaining percent", () => {
  const scoped = extractClaudeScopedWeeklyLimit({ limits: scopedWeeklyLimits });
  assert.equal(scoped.label, "Fable");
  assert.equal(scoped.remainingPercent, 89);
  assert.equal(scoped.resetAt, Date.parse("2026-08-31T01:59:59.949540+00:00"));
});

test("no scoped weekly limit means no third line", () => {
  assert.equal(extractClaudeScopedWeeklyLimit({ limits: scopedWeeklyLimits.slice(0, 2) }), null);
  assert.equal(extractClaudeScopedWeeklyLimit({ limits: [] }), null);
  assert.equal(extractClaudeScopedWeeklyLimit({}), null);
  assert.equal(extractClaudeScopedWeeklyLimit(null), null);
});

test("scoped weekly limit clamps percent and survives a missing model name", () => {
  const exhausted = extractClaudeScopedWeeklyLimit({
    limits: [{ kind: "weekly_scoped", percent: 130, resets_at: null, scope: { model: null } }]
  });
  assert.equal(exhausted.label, "Model");
  assert.equal(exhausted.remainingPercent, 0);
  assert.equal(exhausted.resetAt, null);

  const missingPercent = extractClaudeScopedWeeklyLimit({
    limits: [{ kind: "weekly_scoped", percent: null, scope: { model: { display_name: "Fable" } } }]
  });
  assert.equal(missingPercent, null);
});

// Grok CLI proxy billing (cli-chat-proxy.grok.com/v1/billing): protobuf-JSON form of the credits
// config. The keys follow the phase 3 probe (config.productUsage[].usagePercent,
// config.currentPeriod.{start,end}); the values are invented.
test("Grok billing JSON: the Grok Build product percent and the latest period end", () => {
  const body = {
    config: {
      productUsage: [{ product: "PRODUCT_GROK_BUILD", usagePercent: 7 }],
      currentPeriod: { start: "2026-10-20T00:00:00Z", end: "2026-10-27T00:00:00Z" }
    }
  };
  assert.deepEqual(parseGrokBillingUsage(body), { percentUsed: 7, resetMs: Date.parse("2026-10-27T00:00:00Z") });
});

test("Grok billing JSON: the unified percent wins over product rows; enum numbers and numeric strings work", () => {
  const body = { config: { creditUsagePercent: 40, productUsage: [{ product: 2, usagePercent: 7 }], billingPeriodEnd: "2026-11-01T00:00:00Z" } };
  assert.equal(parseGrokBillingUsage(body).percentUsed, 40);
  const rows = { config: { productUsage: [{ product: "PRODUCT_OTHER", usagePercent: "55.5" }, { product: "2", usagePercent: "12" }], currentPeriod: { end: "2026-11-01T00:00:00Z" } } };
  assert.equal(parseGrokBillingUsage(rows).percentUsed, 12);
  const snake = { config: { credit_usage_percent: 3, current_period: { end: "2026-11-01T00:00:00Z" } } };
  assert.equal(parseGrokBillingUsage(snake).percentUsed, 3);
});

test("Grok billing JSON: a period with no percent means nothing used; no config or no period means unrecognisable", () => {
  assert.deepEqual(parseGrokBillingUsage({ config: { productUsage: [], currentPeriod: { end: "2026-11-01T00:00:00Z" } } }),
    { percentUsed: 0, resetMs: Date.parse("2026-11-01T00:00:00Z") });
  assert.equal(parseGrokBillingUsage({ config: { productUsage: [] } }), null);
  assert.equal(parseGrokBillingUsage({}), null);
  assert.equal(parseGrokBillingUsage(null), null);
  assert.equal(parseGrokBillingUsage([]), null);
  assert.equal(parseGrokBillingUsage({ config: [] }), null);
});

test("Grok billing JSON: reset is the latest plausible timestamp in any form", () => {
  const end = Date.parse("2026-11-03T00:00:00Z");
  const forms = [
    { currentPeriod: { start: "2026-10-27T00:00:00Z", end: "2026-11-03T00:00:00Z" } },
    { currentPeriod: { end: { seconds: String(end / 1000) } } },
    { billingPeriodEnd: end / 1000 },
    { billingPeriodEnd: end }
  ];
  for (const extra of forms) {
    assert.equal(parseGrokBillingUsage({ config: { creditUsagePercent: 1, ...extra } }).resetMs, end, JSON.stringify(extra));
  }
  // A small number or a non-date string is not a timestamp.
  assert.equal(parseGrokBillingUsage({ config: { creditUsagePercent: 1, topUpMethod: 7, label: "7" } }).resetMs, null);
});

test("Grok billing entitlement: only an explicit subscription list decides; anything else is unknown", () => {
  assert.equal(classifyGrokBillingSubscription({ config: { creditUsagePercent: 1 } }), "unknown");
  assert.equal(classifyGrokBillingSubscription(null), "unknown");
  assert.equal(classifyGrokBillingSubscription({ subscriptions: [] }), "free");
  assert.equal(classifyGrokBillingSubscription({ subscriptions: [{ status: "SUBSCRIPTION_STATUS_ACTIVE", tier: "SUBSCRIPTION_TIER_SUPER_GROK" }] }), "active");
});
