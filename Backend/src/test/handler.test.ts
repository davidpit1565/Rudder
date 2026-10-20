import { strict as assert } from "node:assert";
import test from "node:test";
import { handle } from "../handler.js";
import { AnalysisError } from "../analyze.js";
import { resetRateLimits, resolveClientKey } from "../rateLimit.js";
import { resetConcurrency } from "../concurrency.js";
import { resetDeepDecisionQuota, resetDailyQuota } from "../quota.js";
import { resetGlobalFreeSpend, resetAbsoluteSpend } from "../spendCeiling.js";
import { AnalysisRequestSchema, SCHEMA_VERSION } from "../schema.js";
import type { WireResponse, FollowUpResponse } from "../schema.js";
import { buildJws, validPayload, withTestAppleRoot } from "./fixtures/appleTransaction.js";

function verifiedProHeaders(): Record<string, string> {
  return { "x-rudder-transaction": buildJws(validPayload()) };
}

/** A fake analyse() whose completion this test controls, so it can hold a
 * concurrency slot open on purpose instead of racing a real timer. */
function controllableAnalyse() {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const analyse = async (): Promise<WireResponse> => {
    await gate;
    return { schemaVersion: SCHEMA_VERSION } as unknown as WireResponse;
  };
  return { analyse, release };
}

function validBody(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    schemaVersion: SCHEMA_VERSION,
    prompt: "MacBook Air or MacBook Pro?",
    answers: [],
    knownPreferences: [],
    category: "technology",
    complexity: "medium",
    researchLevel: "light",
    maximumResearchCalls: 2,
    maximumSources: 4,
    questionsAlreadyAsked: 0,
    questionCeiling: 3,
    strictSchema: false,
    locale: "en_GB",
    ...overrides,
  });
}

function request(overrides: Partial<Parameters<typeof handle>[0]> = {}) {
  return {
    method: "POST",
    path: "/v1/decisions/analyze",
    headers: {},
    body: validBody(),
    clientKey: `test-${Math.random()}`,
    ...overrides,
  };
}

/** A fake followUp() whose completion this test controls, mirroring
 * controllableAnalyse() above. */
function controllableFollowUp() {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const followUp = async (): Promise<FollowUpResponse> => {
    await gate;
    return { answer: "Stub answer.", needsResearch: false, suggestedNewDecisionPrompt: null, durablePreference: null };
  };
  return { followUp, release };
}

function validFollowUpBody(overrides: Record<string, unknown> = {}) {
  return JSON.stringify({
    schemaVersion: SCHEMA_VERSION,
    originalPrompt: "MacBook Air or MacBook Pro for photo editing?",
    decisionContext: "Recommended the MacBook Air for portability.",
    history: [],
    question: "What about exporting 4K video occasionally?",
    locale: "en_GB",
    ...overrides,
  });
}

function followUpRequest(overrides: Partial<Parameters<typeof handle>[0]> = {}) {
  return {
    method: "POST",
    path: "/v1/decisions/followup",
    headers: {},
    body: validFollowUpBody(),
    clientKey: `test-followup-${Math.random()}`,
    ...overrides,
  };
}

test("health check responds without touching the model", async () => {
  const response = await handle(request({ method: "GET", path: "/healthz" }));
  assert.equal(response.status, 200);
  const body = JSON.parse(response.body);
  assert.equal(body.status, "ok");
  assert.equal(typeof body.redisConfigured, "boolean");
});

test("unknown routes are 404, not 500", async () => {
  const response = await handle(request({ method: "GET", path: "/" }));
  assert.equal(response.status, 404);
});

test("malformed JSON is rejected before anything is spent", async () => {
  const response = await handle(request({ body: "{not json" }));
  assert.equal(response.status, 400);
  assert.equal(JSON.parse(response.body).error, "invalid_json");
});

test("a request that does not match the contract is rejected", async () => {
  const response = await handle(request({ body: JSON.stringify({ prompt: "hi" }) }));
  assert.equal(response.status, 400);
  assert.equal(JSON.parse(response.body).error, "invalid_request");
});

test("the error body never leaks which field failed", async () => {
  const response = await handle(request({ body: validBody({ category: "nonsense" }) }));
  assert.equal(response.status, 400);
  assert.deepEqual(Object.keys(JSON.parse(response.body)), ["error"]);
});

test("an oversized payload is refused", async () => {
  const response = await handle(request({ body: "x".repeat(40_000) }));
  assert.equal(response.status, 413);
});

test("rate limiting refuses a flood and says when to come back", async () => {
  resetRateLimits();
  process.env.DECIDE_RATE_LIMIT = "3";
  const key = "flood-client";

  for (let index = 0; index < 3; index += 1) {
    const response = await handle(request({ clientKey: key, body: "{bad" }));
    assert.equal(response.status, 400, "within the limit, the request is processed");
  }

  const blocked = await handle(request({ clientKey: key, body: "{bad" }));
  assert.equal(blocked.status, 429);
  assert.ok(Number(blocked.headers["Retry-After"]) > 0);

  delete process.env.DECIDE_RATE_LIMIT;
  resetRateLimits();
});

test("a bearer token is enforced when one is configured", async () => {
  resetRateLimits();
  process.env.DECIDE_CLIENT_TOKEN = "s3cret";

  const rejected = await handle(request({ body: "{bad" }));
  assert.equal(rejected.status, 401);

  const accepted = await handle(
    request({ headers: { authorization: "Bearer s3cret" }, body: "{bad" })
  );
  assert.equal(accepted.status, 400, "past the gate, normal validation applies");

  delete process.env.DECIDE_CLIENT_TOKEN;
});

test("required attestation refuses rather than pretending to check", async () => {
  resetRateLimits();
  process.env.DECIDE_REQUIRE_ATTESTATION = "1";
  const response = await handle(request({ body: "{bad" }));
  assert.equal(response.status, 501);
  delete process.env.DECIDE_REQUIRE_ATTESTATION;
});

test("responses are not cacheable and are typed", async () => {
  const response = await handle(request({ method: "GET", path: "/healthz" }));
  assert.equal(response.headers["Cache-Control"], "no-store");
  assert.equal(response.headers["Content-Type"], "application/json");
  assert.equal(response.headers["X-Content-Type-Options"], "nosniff");
  assert.ok(response.headers["Strict-Transport-Security"]?.includes("max-age"));
});

test("the daily limit trips even while the burst window is nowhere near full", async () => {
  resetRateLimits();
  process.env.DECIDE_RATE_LIMIT = "100";
  process.env.DECIDE_DAILY_LIMIT = "2";
  const key = "sustained-client";

  for (let index = 0; index < 2; index += 1) {
    const response = await handle(request({ clientKey: key, body: "{bad" }));
    assert.equal(response.status, 400, "within the daily limit, the request is processed");
  }

  const blocked = await handle(request({ clientKey: key, body: "{bad" }));
  assert.equal(blocked.status, 429);
  assert.equal(JSON.parse(blocked.body).error, "daily_limit_reached");
  assert.ok(Number(blocked.headers["Retry-After"]) > 0);

  delete process.env.DECIDE_RATE_LIMIT;
  delete process.env.DECIDE_DAILY_LIMIT;
  resetRateLimits();
});

test("a global concurrency cap holds even across many client identities", async () => {
  resetConcurrency();
  process.env.DECIDE_MAX_CONCURRENT_ANALYSES = "2";

  const { analyse, release } = controllableAnalyse();

  // Three different identities: the cap has to hold with no shared client key
  // to hang the block on, or a spoofed identity would buy a spoofed slot.
  const first = handle(request({ clientKey: "a" }), { analyse });
  const second = handle(request({ clientKey: "b" }), { analyse });
  await new Promise((resolve) => setImmediate(resolve));

  const third = await handle(request({ clientKey: "c" }), { analyse });
  assert.equal(third.status, 503, "a third identity does not buy a third concurrent slot");
  assert.equal(JSON.parse(third.body).error, "server_busy");
  assert.ok(Number(third.headers["Retry-After"]) > 0);

  release();
  const [firstResult, secondResult] = await Promise.all([first, second]);
  assert.equal(firstResult.status, 200);
  assert.equal(secondResult.status, 200);

  delete process.env.DECIDE_MAX_CONCURRENT_ANALYSES;
  resetConcurrency();
});

test("a slot is released even when the analysis throws", async () => {
  resetConcurrency();
  process.env.DECIDE_MAX_CONCURRENT_ANALYSES = "1";

  const failing = async (): Promise<WireResponse> => {
    throw new Error("boom");
  };
  const first = await handle(request({ clientKey: "a" }), { analyse: failing });
  assert.equal(first.status, 500);

  // If the slot had leaked, this would come back 503 instead.
  const second = await handle(request({ clientKey: "b" }), { analyse: failing });
  assert.equal(second.status, 500);

  delete process.env.DECIDE_MAX_CONCURRENT_ANALYSES;
  resetConcurrency();
});

test("the request contract accepts what the app actually sends", () => {
  const parsed = AnalysisRequestSchema.safeParse(JSON.parse(validBody()));
  assert.ok(parsed.success);
});

test("an old schema version is refused rather than misread", () => {
  const parsed = AnalysisRequestSchema.safeParse(JSON.parse(validBody({ schemaVersion: 0 })));
  assert.equal(parsed.success, false);
});

test("a forged forwarded-for header cannot buy a fresh rate-limit budget", () => {
  const headers = { "x-forwarded-for": "1.2.3.4" };

  // Exposed directly: the socket address is what counts, so rotating the header
  // changes nothing.
  assert.equal(resolveClientKey(headers, "10.0.0.1", false), "10.0.0.1");
  assert.equal(resolveClientKey({ "x-forwarded-for": "9.9.9.9" }, "10.0.0.1", false), "10.0.0.1");

  // Behind a proxy that sets it, the real client is what counts.
  assert.equal(resolveClientKey(headers, "10.0.0.1", true), "1.2.3.4");
  assert.equal(resolveClientKey({ "x-forwarded-for": "1.2.3.4, 10.0.0.9" }, "10.0.0.1", true), "1.2.3.4");
});

test("a request with no identifiable client still gets a key", () => {
  assert.equal(resolveClientKey({}, undefined, true), "unknown");
});

test("a complex decision is capped per install once Free's monthly quota is spent", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  // Set explicitly so this test's expectations don't silently drift if the
  // shipped default ever changes.
  process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH = "3";
  const { analyse, release } = controllableAnalyse();
  release(); // let every analyse() call resolve immediately

  const headers = { "x-rudder-install-id": "quota-test-install" };
  for (let i = 1; i <= 3; i++) {
    const response = await handle(request({ headers, body: validBody({ complexity: "complex" }) }), { analyse });
    assert.equal(response.status, 200, `decision ${i} of 3 should be allowed`);
  }

  const fourth = await handle(request({ headers, body: validBody({ complexity: "complex" }) }), { analyse });
  assert.equal(fourth.status, 429);
  assert.equal(JSON.parse(fourth.body).error, "deep_decision_limit_reached");
  assert.ok(Number(fourth.headers["Retry-After"]) > 0);

  delete process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a non-complex decision never touches the deep-decision quota", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  const { analyse, release } = controllableAnalyse();
  release();

  const headers = { "x-rudder-install-id": "quota-test-medium" };
  for (let i = 0; i < 5; i++) {
    const response = await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse });
    assert.equal(response.status, 200);
  }

  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("two installs never share a deep-decision quota bucket", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH = "3";
  const { analyse, release } = controllableAnalyse();
  release();

  for (let i = 0; i < 3; i++) {
    await handle(request({ headers: { "x-rudder-install-id": "install-x" }, body: validBody({ complexity: "complex" }) }), { analyse });
  }
  const blocked = await handle(request({ headers: { "x-rudder-install-id": "install-x" }, body: validBody({ complexity: "complex" }) }), { analyse });
  assert.equal(blocked.status, 429);

  const otherInstall = await handle(request({ headers: { "x-rudder-install-id": "install-y" }, body: validBody({ complexity: "complex" }) }), { analyse });
  assert.equal(otherInstall.status, 200, "a different install starts with its own fresh quota");

  delete process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a failed complex analysis refunds the quota instead of spending it for nothing", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_MAX_CONCURRENT_ANALYSES = "5";
  // Set explicitly: the shipped default is 0 (no recurring Free allowance beyond
  // the first-ever decision), which would exhaust immediately and never reach the
  // refund path this test is actually about.
  process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH = "3";

  const failing = async (): Promise<WireResponse> => {
    throw new Error("boom");
  };
  const headers = { "x-rudder-install-id": "quota-refund-install" };

  for (let i = 0; i < 10; i++) {
    const response = await handle(request({ headers, body: validBody({ complexity: "complex" }) }), { analyse: failing });
    assert.equal(response.status, 500, "every attempt fails, but none should exhaust the quota");
  }

  delete process.env.DECIDE_MAX_CONCURRENT_ANALYSES;
  delete process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH;
  resetConcurrency();
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a global monthly Free-spend ceiling trips once total estimated spend crosses it, across every install", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_MONTHLY_FREE_SPEND_CEILING_USD = "0.10";
  const { analyse, release } = controllableAnalyse();
  release();

  // Two different installs, well under either one's own per-install quota --
  // the global ceiling is what should trip here, not quota.ts.
  const first = await handle(
    request({ headers: { "x-rudder-install-id": "spend-a" }, body: validBody({ complexity: "medium" }) }),
    { analyse }
  );
  assert.equal(first.status, 200);

  const second = await handle(
    request({ headers: { "x-rudder-install-id": "spend-b" }, body: validBody({ complexity: "medium" }) }),
    { analyse }
  );
  assert.equal(second.status, 503);
  assert.equal(JSON.parse(second.body).error, "monthly_free_budget_exhausted");

  delete process.env.DECIDE_MONTHLY_FREE_SPEND_CEILING_USD;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a verified Pro transaction is never subject to the Free-spend ceiling", async () => {
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_MONTHLY_FREE_SPEND_CEILING_USD = "0"; // already exhausted, on purpose
  const { analyse, release } = controllableAnalyse();
  release();

  // No real transaction header is presented here (that path is covered by
  // appStoreVerify.test.ts's synthetic chain), so this exercises the other
  // half: an *unverifiable* transaction header must fall back to the Free
  // ceiling rather than silently granting Pro.
  const stillFree = await handle(
    request({ headers: { "x-rudder-transaction": "not-a-real-transaction" }, body: validBody({ complexity: "medium" }) }),
    { analyse }
  );
  assert.equal(stillFree.status, 503, "an unverifiable transaction is not proof of Pro");

  delete process.env.DECIDE_MONTHLY_FREE_SPEND_CEILING_USD;
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("the absolute spend ceiling trips even for a verified Pro transaction", async () => {
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD = "0.10";
  const { analyse, release } = controllableAnalyse();
  release();

  const first = await withTestAppleRoot(() =>
    handle(request({ headers: verifiedProHeaders(), body: validBody({ complexity: "medium" }) }), { analyse })
  );
  assert.equal(first.status, 200, "the first request fits under the ceiling");

  const second = await withTestAppleRoot(() =>
    handle(request({ headers: verifiedProHeaders(), body: validBody({ complexity: "medium" }) }), { analyse })
  );
  assert.equal(second.status, 503, "a verified Pro transaction gets no exception from the absolute ceiling");
  assert.equal(JSON.parse(second.body).error, "monthly_ai_budget_exhausted");
  assert.ok(Number(second.headers["Retry-After"]) > 0);

  delete process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD;
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("the absolute spend ceiling is shared between Free and Pro traffic", async () => {
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD = "0.10";
  const { analyse, release } = controllableAnalyse();
  release();

  const freeRequest = await handle(
    request({ headers: { "x-rudder-install-id": "absolute-shared-free" }, body: validBody({ complexity: "medium" }) }),
    { analyse }
  );
  assert.equal(freeRequest.status, 200);

  const proRequest = await withTestAppleRoot(() =>
    handle(request({ headers: verifiedProHeaders(), body: validBody({ complexity: "medium" }) }), { analyse })
  );
  assert.equal(proRequest.status, 503, "Free spend already used up the shared absolute ceiling");
  assert.equal(JSON.parse(proRequest.body).error, "monthly_ai_budget_exhausted");

  delete process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD;
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a failed Pro analysis refunds the absolute ceiling instead of spending it for nothing", async () => {
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD = "0.10";

  const failing = async (): Promise<WireResponse> => {
    throw new Error("boom");
  };

  for (let i = 0; i < 5; i++) {
    const response = await withTestAppleRoot(() =>
      handle(request({ headers: verifiedProHeaders(), body: validBody({ complexity: "medium" }) }), { analyse: failing })
    );
    assert.equal(response.status, 500, "every attempt fails, but none should exhaust the absolute ceiling");
  }

  delete process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD;
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

// --- Daily quota (medium, and complex for a verified Pro subscriber) ---

test("a Free medium decision is capped per install per day, at the Free limit", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT = "3";
  const { analyse, release } = controllableAnalyse();
  release();

  const headers = { "x-rudder-install-id": "daily-medium-free" };
  for (let i = 1; i <= 3; i++) {
    const response = await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse });
    assert.equal(response.status, 200, `decision ${i} of 3 should be allowed`);
    const body = JSON.parse(response.body);
    assert.equal(body.quota.bucket, "medium-free");
    assert.equal(body.quota.used, i);
    assert.equal(body.quota.limit, 3);
  }

  const fourth = await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse });
  assert.equal(fourth.status, 429);
  assert.equal(JSON.parse(fourth.body).error, "daily_decision_limit_reached");
  assert.ok(Number(fourth.headers["Retry-After"]) > 0);

  delete process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a verified Pro subscriber gets a higher daily medium limit than Free, in its own bucket", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT = "1";
  process.env.DECIDE_PRO_MEDIUM_DAILY_LIMIT = "2";
  const { analyse, release } = controllableAnalyse();
  release();

  const headers = { "x-rudder-install-id": "daily-medium-pro", ...verifiedProHeaders() };
  const first = await withTestAppleRoot(() => handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse }));
  assert.equal(first.status, 200);
  assert.equal(JSON.parse(first.body).quota.bucket, "medium-pro");
  // A Free request from the SAME install-id, with no transaction header, is a
  // separate bucket -- would already be over Free's limit of 1 if it shared
  // Pro's count.
  const second = await withTestAppleRoot(() => handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse }));
  assert.equal(second.status, 200, "Pro's own limit of 2 allows a second medium decision today");

  const third = await withTestAppleRoot(() => handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse }));
  assert.equal(third.status, 429, "the third exceeds Pro's own limit of 2");

  delete process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT;
  delete process.env.DECIDE_PRO_MEDIUM_DAILY_LIMIT;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a verified Pro subscriber still has a daily cap on complex decisions, separate from Free's monthly one", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_PRO_COMPLEX_DAILY_LIMIT = "2";
  const { analyse, release } = controllableAnalyse();
  release();

  const headers = { "x-rudder-install-id": "daily-complex-pro", ...verifiedProHeaders() };
  for (let i = 1; i <= 2; i++) {
    const response = await withTestAppleRoot(() =>
      handle(request({ headers, body: validBody({ complexity: "complex" }) }), { analyse })
    );
    assert.equal(response.status, 200, `Pro complex decision ${i} of 2 should be allowed`);
    assert.equal(JSON.parse(response.body).quota.bucket, "complex-pro");
  }

  const third = await withTestAppleRoot(() =>
    handle(request({ headers, body: validBody({ complexity: "complex" }) }), { analyse })
  );
  assert.equal(third.status, 429);
  assert.equal(JSON.parse(third.body).error, "daily_decision_limit_reached");

  delete process.env.DECIDE_PRO_COMPLEX_DAILY_LIMIT;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a simple decision never carries a quota field and is never daily-limited", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  const { analyse, release } = controllableAnalyse();
  release();

  const headers = { "x-rudder-install-id": "daily-simple-unlimited" };
  for (let i = 0; i < 10; i++) {
    const response = await handle(request({ headers, body: validBody({ complexity: "simple" }) }), { analyse });
    assert.equal(response.status, 200);
    assert.equal(JSON.parse(response.body).quota, undefined);
  }

  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a failed medium analysis refunds the daily quota instead of spending it for nothing", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT = "1";
  const failing = async (): Promise<WireResponse> => {
    throw new Error("boom");
  };

  const headers = { "x-rudder-install-id": "daily-medium-refund" };
  for (let i = 0; i < 5; i++) {
    const response = await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse: failing });
    assert.equal(response.status, 500, "every attempt fails, but none should exhaust the daily quota");
  }

  delete process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT;
  resetDeepDecisionQuota();
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

// --- GET /v1/quota/status ---

test("quota status reports Free medium usage and the complex monthly state, unauthenticated as Free", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();

  const headers = { "x-rudder-install-id": "status-free-install" };
  const { analyse, release } = controllableAnalyse();
  release();
  await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse });

  const status = await handle({ method: "GET", path: "/v1/quota/status", headers, body: "", clientKey: "status-test" });
  assert.equal(status.status, 200);
  const body = JSON.parse(status.body);
  assert.equal(body.isPro, false);
  assert.equal(body.simple.limited, false);
  assert.equal(body.medium.used, 1);
  assert.ok(body.medium.limit > 0);
  assert.equal(body.complex.daily, null, "a Free install has no daily complex bucket");
  assert.ok(body.complex.monthly, "a Free install's complex status is the monthly quota");

  resetDeepDecisionQuota();
  resetDailyQuota();
});

test("quota status reports Pro's daily complex bucket instead of the monthly one", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();

  const headers = { "x-rudder-install-id": "status-pro-install", ...verifiedProHeaders() };
  const status = await withTestAppleRoot(() =>
    handle({ method: "GET", path: "/v1/quota/status", headers, body: "", clientKey: "status-test-pro" })
  );
  assert.equal(status.status, 200);
  const body = JSON.parse(status.body);
  assert.equal(body.isPro, true);
  assert.equal(body.complex.monthly, null, "a Pro install's complex status is the daily bucket, not monthly");
  assert.ok(body.complex.daily, "a Pro install has a daily complex bucket");
  assert.equal(body.complex.daily.used, 0);

  resetDeepDecisionQuota();
  resetDailyQuota();
});

test("quota status never spends a unit of what it reports", async () => {
  resetDeepDecisionQuota();
  resetDailyQuota();

  const headers = { "x-rudder-install-id": "status-no-spend" };
  const first = await handle({ method: "GET", path: "/v1/quota/status", headers, body: "", clientKey: "status-peek" });
  const second = await handle({ method: "GET", path: "/v1/quota/status", headers, body: "", clientKey: "status-peek" });
  assert.equal(JSON.parse(first.body).medium.used, 0);
  assert.equal(JSON.parse(second.body).medium.used, 0, "reading status twice must not look like two decisions");

  resetDeepDecisionQuota();
  resetDailyQuota();
});

test("quota status also reports today's follow-up usage", async () => {
  resetDailyQuota();

  const headers = { "x-rudder-install-id": "status-followup" };
  const status = await handle({ method: "GET", path: "/v1/quota/status", headers, body: "", clientKey: "status-followup-test" });
  assert.equal(status.status, 200);
  const body = JSON.parse(status.body);
  assert.equal(body.followup.used, 0);
  assert.ok(body.followup.limit > 0);

  resetDailyQuota();
});

// --- POST /v1/decisions/followup ---

test("a follow-up question is answered and reports its own quota bucket", async () => {
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT = "3";
  const { followUp, release } = controllableFollowUp();
  release();

  const headers = { "x-rudder-install-id": "followup-happy-path" };
  const response = await handle(followUpRequest({ headers }), { followUp });
  assert.equal(response.status, 200);
  const body = JSON.parse(response.body);
  assert.equal(body.answer, "Stub answer.");
  assert.equal(body.quota.bucket, "followup-free");
  assert.equal(body.quota.used, 1);
  assert.equal(body.quota.limit, 3);

  delete process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT;
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a follow-up request that does not match the contract is rejected", async () => {
  const response = await handle(followUpRequest({ body: JSON.stringify({ question: "hi" }) }));
  assert.equal(response.status, 400);
  assert.equal(JSON.parse(response.body).error, "invalid_request");
});

test("an oversized follow-up payload is refused", async () => {
  const response = await handle(followUpRequest({ body: "x".repeat(50_000) }));
  assert.equal(response.status, 413);
});

test("a Free follow-up is capped per install per day, in its own bucket from decisions", async () => {
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT = "2";
  const { followUp, release } = controllableFollowUp();
  release();

  const headers = { "x-rudder-install-id": "followup-daily-free" };
  for (let i = 1; i <= 2; i++) {
    const response = await handle(followUpRequest({ headers }), { followUp });
    assert.equal(response.status, 200, `follow-up ${i} of 2 should be allowed`);
  }

  const third = await handle(followUpRequest({ headers }), { followUp });
  assert.equal(third.status, 429);
  assert.equal(JSON.parse(third.body).error, "daily_followup_limit_reached");
  assert.ok(Number(third.headers["Retry-After"]) > 0);

  delete process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT;
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a verified Pro subscriber gets a higher daily follow-up limit, in its own bucket", async () => {
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT = "1";
  process.env.DECIDE_PRO_FOLLOWUP_DAILY_LIMIT = "2";
  const { followUp, release } = controllableFollowUp();
  release();

  const headers = { "x-rudder-install-id": "followup-daily-pro", ...verifiedProHeaders() };
  const first = await withTestAppleRoot(() => handle(followUpRequest({ headers }), { followUp }));
  assert.equal(first.status, 200);
  assert.equal(JSON.parse(first.body).quota.bucket, "followup-pro");

  const second = await withTestAppleRoot(() => handle(followUpRequest({ headers }), { followUp }));
  assert.equal(second.status, 200, "Pro's own limit of 2 allows a second follow-up today");

  const third = await withTestAppleRoot(() => handle(followUpRequest({ headers }), { followUp }));
  assert.equal(third.status, 429, "the third exceeds Pro's own limit of 2");

  delete process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT;
  delete process.env.DECIDE_PRO_FOLLOWUP_DAILY_LIMIT;
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("two installs never share a follow-up quota bucket", async () => {
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT = "1";
  const { followUp, release } = controllableFollowUp();
  release();

  const blocked = await handle(followUpRequest({ headers: { "x-rudder-install-id": "followup-install-x" } }), { followUp });
  assert.equal(blocked.status, 200);
  const secondForX = await handle(followUpRequest({ headers: { "x-rudder-install-id": "followup-install-x" } }), { followUp });
  assert.equal(secondForX.status, 429);

  const otherInstall = await handle(followUpRequest({ headers: { "x-rudder-install-id": "followup-install-y" } }), { followUp });
  assert.equal(otherInstall.status, 200, "a different install starts with its own fresh follow-up quota");

  delete process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT;
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a failed follow-up refunds its quota instead of spending it for nothing", async () => {
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
  resetConcurrency();
  process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT = "1";

  const failing = async (): Promise<FollowUpResponse> => {
    throw new Error("boom");
  };
  const headers = { "x-rudder-install-id": "followup-refund-install" };

  for (let i = 0; i < 5; i++) {
    const response = await handle(followUpRequest({ headers }), { followUp: failing });
    assert.equal(response.status, 500, "every attempt fails, but none should exhaust the follow-up quota");
  }

  delete process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT;
  resetDailyQuota();
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a global concurrency cap is shared between analyze and follow-up", async () => {
  resetConcurrency();
  process.env.DECIDE_MAX_CONCURRENT_ANALYSES = "1";

  const { analyse, release: releaseAnalyse } = controllableAnalyse();
  const first = handle(request({ clientKey: "shared-a" }), { analyse });
  await new Promise((resolve) => setImmediate(resolve));

  const { followUp } = controllableFollowUp();
  const second = await handle(followUpRequest({ clientKey: "shared-b" }), { followUp });
  assert.equal(second.status, 503, "a follow-up does not get a slot the analyze call is already holding");

  releaseAnalyse();
  await first;

  delete process.env.DECIDE_MAX_CONCURRENT_ANALYSES;
  resetConcurrency();
});

// MARK: Job model -- the resumable path a slow or interrupted analysis takes
// instead of hanging the request until Vercel kills it (see handler.ts's
// JOB_RACE_DEADLINE_MS / runJobAttempt doc comments for the real failure this
// replaces). DECIDE_JOB_RACE_DEADLINE_MS lets these races resolve in
// milliseconds instead of the real ~45s default.

test("a slow analysis comes back as a pending job instead of hanging, and continuing it finds the finished result", async () => {
  resetConcurrency();
  process.env.DECIDE_JOB_RACE_DEADLINE_MS = "20";

  const { analyse, release } = controllableAnalyse();
  const first = await handle(request(), { analyse });
  assert.equal(first.status, 200);
  const created = JSON.parse(first.body);
  assert.equal(created.pending, true);
  assert.ok(typeof created.jobId === "string" && created.jobId.length > 0);

  release();
  // The first attempt's own background resolve (see runJobAttempt) may or may
  // not have landed by the time this runs -- either way, continuing must
  // reach "done", whether by finding it already resolved or by making a
  // fresh attempt of its own (the gate is already open, so that resolves
  // immediately too).
  let final = await handle(request({ body: JSON.stringify({ jobId: created.jobId }) }), { analyse });
  if (JSON.parse(final.body).pending) {
    final = await handle(request({ body: JSON.stringify({ jobId: created.jobId }) }), { analyse });
  }
  assert.equal(final.status, 200);
  const finalBody = JSON.parse(final.body);
  assert.equal(finalBody.pending, undefined);
  assert.equal(finalBody.schemaVersion, SCHEMA_VERSION);

  delete process.env.DECIDE_JOB_RACE_DEADLINE_MS;
  resetConcurrency();
});

test("continuing an unknown job id reports not_found rather than hanging or crashing", async () => {
  const response = await handle(request({ body: JSON.stringify({ jobId: "does-not-exist" }) }));
  assert.equal(response.status, 404);
  assert.equal(JSON.parse(response.body).error, "job_not_found");
});

test("a job that keeps hitting a retryable upstream error eventually fails and refunds, instead of retrying forever", async () => {
  resetConcurrency();
  resetDailyQuota();
  process.env.DECIDE_JOB_RACE_DEADLINE_MS = "20";

  const alwaysUnavailable = async (): Promise<WireResponse> => {
    throw new AnalysisError("upstream_unavailable", 503);
  };
  const headers = { "x-rudder-install-id": "retry-exhaust-install" };

  const first = await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse: alwaysUnavailable });
  assert.equal(first.status, 200);
  assert.equal(JSON.parse(first.body).pending, true);
  const { jobId } = JSON.parse(first.body);

  let last = first;
  for (let i = 0; i < 5 && JSON.parse(last.body).pending; i++) {
    last = await handle(request({ headers, body: JSON.stringify({ jobId }) }), { analyse: alwaysUnavailable });
  }
  assert.equal(last.status, 503, "every attempt fails the same way, so it must eventually give up rather than poll forever");
  assert.equal(JSON.parse(last.body).error, "upstream_unavailable");

  // The daily quota this decision would have spent is given back, exactly as
  // an immediate same-call failure already does on the fast path.
  const status = await handle({ method: "GET", path: "/v1/quota/status", headers, body: "", clientKey: "retry-exhaust-status" });
  assert.equal(JSON.parse(status.body).medium.used, 0);

  delete process.env.DECIDE_JOB_RACE_DEADLINE_MS;
  resetConcurrency();
  resetDailyQuota();
});

test("a non-retryable error fails a job immediately, on the very first attempt", async () => {
  resetConcurrency();
  resetDailyQuota();

  const refused = async (): Promise<WireResponse> => {
    throw new AnalysisError("refused", 422);
  };
  const headers = { "x-rudder-install-id": "non-retryable-install" };

  const response = await handle(request({ headers, body: validBody({ complexity: "medium" }) }), { analyse: refused });
  assert.equal(response.status, 422, "a deterministic failure is reported right away, not retried");
  assert.equal(JSON.parse(response.body).error, "refused");
  assert.equal(JSON.parse(response.body).pending, undefined);

  resetConcurrency();
  resetDailyQuota();
});
