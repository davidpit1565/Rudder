import { strict as assert } from "node:assert";
import test from "node:test";
import { handle } from "../handler.js";
import { resetRateLimits, resolveClientKey } from "../rateLimit.js";
import { resetConcurrency } from "../concurrency.js";
import { resetDeepDecisionQuota } from "../quota.js";
import { resetGlobalFreeSpend, resetAbsoluteSpend } from "../spendCeiling.js";
import { AnalysisRequestSchema, SCHEMA_VERSION } from "../schema.js";
import type { WireResponse } from "../schema.js";
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
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a non-complex decision never touches the deep-decision quota", async () => {
  resetDeepDecisionQuota();
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
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("two installs never share a deep-decision quota bucket", async () => {
  resetDeepDecisionQuota();
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
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a failed complex analysis refunds the quota instead of spending it for nothing", async () => {
  resetDeepDecisionQuota();
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
  resetGlobalFreeSpend();
  resetAbsoluteSpend();
});

test("a global monthly Free-spend ceiling trips once total estimated spend crosses it, across every install", async () => {
  resetDeepDecisionQuota();
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
