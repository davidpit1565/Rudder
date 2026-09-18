import Anthropic from "@anthropic-ai/sdk";
import { AnalysisRequestSchema } from "./schema.js";
import { analyse as defaultAnalyse, AnalysisError } from "./analyze.js";
import { checkRateLimit, checkDailyLimit } from "./rateLimit.js";
import { verifyClient } from "./attest.js";
import { tryAcquire, release } from "./concurrency.js";
import { isConfigured as isRedisConfigured } from "./redis.js";
import { verifyAppStoreTransaction } from "./appStoreVerify.js";
import { checkDeepDecisionQuota, refundDeepDecisionQuota, DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH } from "./quota.js";
import {
  checkGlobalFreeSpendCeiling,
  refundGlobalFreeSpend,
  checkAbsoluteSpendCeiling,
  refundAbsoluteSpend,
  ESTIMATED_COST_USD,
  DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD,
  DEFAULT_MONTHLY_ABSOLUTE_SPEND_CEILING_USD,
} from "./spendCeiling.js";

// Mirrors SubscriptionService.ProductID in App/Services/SubscriptionService.swift.
const PRO_PRODUCT_IDS = ["com.rudder.app.pro.monthly", "com.rudder.app.pro.annual"] as const;
// Best-effort default -- confirm against the Rudder target's actual
// PRODUCT_BUNDLE_IDENTIFIER and set DECIDE_BUNDLE_ID explicitly if it differs.
const BUNDLE_ID = process.env.DECIDE_BUNDLE_ID ?? "com.rudder.app";

export interface HandlerRequest {
  method: string;
  path: string;
  headers: Record<string, string | undefined>;
  body: string;
  clientKey: string;
}

export interface HandlerResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

/** Only ever overridden by tests, so they can drive the concurrency gate
 * without a real (or fake-but-slow) model call. */
export interface HandlerDependencies {
  analyse?: typeof defaultAnalyse;
}

let cachedClient: Anthropic | null = null;

function getClient(): Anthropic {
  if (!cachedClient) {
    // The credential lives here and only here. It is read from the environment
    // and never echoed into a response or a log line.
    cachedClient = new Anthropic();
  }
  return cachedClient;
}

/** Framework-agnostic so the same code runs standalone or on a serverless host. */
export async function handle(
  request: HandlerRequest,
  deps: HandlerDependencies = {}
): Promise<HandlerResponse> {
  const analyse = deps.analyse ?? defaultAnalyse;

  if (request.method === "GET" && request.path === "/healthz") {
    // redisConfigured is operational visibility, not a secret: whether the
    // rate/concurrency limits are backed by Redis or the (cross-instance
    // unreliable, on a serverless host) in-process fallback.
    return json(200, { status: "ok", redisConfigured: isRedisConfigured() });
  }

  if (request.method !== "POST" || request.path !== "/v1/decisions/analyze") {
    return json(404, { error: "not_found" });
  }

  const client = verifyClient(request.headers);
  if (!client.ok) {
    return json(client.status, { error: client.reason ?? "forbidden" });
  }

  const limit = await checkRateLimit(request.clientKey);
  if (!limit.allowed) {
    return json(429, { error: "rate_limited" }, { "Retry-After": String(limit.retryAfterSeconds) });
  }

  const daily = await checkDailyLimit(request.clientKey);
  if (!daily.allowed) {
    return json(429, { error: "daily_limit_reached" }, { "Retry-After": String(daily.retryAfterSeconds) });
  }

  if (request.body.length > 32_000) {
    return json(413, { error: "payload_too_large" });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(request.body);
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const parsed = AnalysisRequestSchema.safeParse(payload);
  if (!parsed.success) {
    // The reason is deliberately coarse: an error body is not a schema oracle.
    return json(400, { error: "invalid_request" });
  }

  // The Free/Pro line itself: unlimited for a verified Pro subscriber, and
  // bounded two ways otherwise -- per install (quota.ts) and, on top of
  // that, by an absolute monthly ceiling on total Free-tier spend
  // (spendCeiling.ts), whatever any one install's own quota allows. Neither
  // is just trusted from what the client declares. See quota.ts and
  // appStoreVerify.ts for why this exists and what it does and doesn't prove.
  const transactionHeader = request.headers["x-rudder-transaction"];
  const verifiedPro = transactionHeader
    ? verifyAppStoreTransaction(transactionHeader, { bundleId: BUNDLE_ID, productIds: PRO_PRODUCT_IDS })
    : null;

  let deepQuotaInstallId: string | null = null;
  let freeSpentEstimate = 0;
  let absoluteSpentEstimate = 0;

  // The absolute ceiling applies to every request, a verified Pro transaction
  // included -- see spendCeiling.ts for why the Free-only ceiling below isn't
  // enough on its own. This runs first: nothing spends money before it's
  // known to fit under the company-wide monthly bound.
  {
    const estimatedCost = ESTIMATED_COST_USD[parsed.data.complexity];
    const absoluteCeiling = Number(
      process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD ?? DEFAULT_MONTHLY_ABSOLUTE_SPEND_CEILING_USD
    );
    const absolute = await checkAbsoluteSpendCeiling(estimatedCost, absoluteCeiling);
    if (!absolute.allowed) {
      // A calendar-month circuit breaker, not a permanent shutoff: the
      // ceiling resets next month. No exception for verified Pro here --
      // that's the entire point of this ceiling.
      return json(503, { error: "monthly_ai_budget_exhausted" }, { "Retry-After": "3600" });
    }
    absoluteSpentEstimate = estimatedCost;
  }

  if (!verifiedPro) {
    const estimatedCost = ESTIMATED_COST_USD[parsed.data.complexity];
    const spendCeiling = Number(
      process.env.DECIDE_MONTHLY_FREE_SPEND_CEILING_USD ?? DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD
    );
    const spend = await checkGlobalFreeSpendCeiling(estimatedCost, spendCeiling);
    if (!spend.allowed) {
      // A calendar-month circuit breaker, not a permanent shutoff: the ceiling
      // resets next month, and a verified Pro transaction is never subject to it.
      await refundAbsoluteSpend(absoluteSpentEstimate);
      return json(503, { error: "monthly_free_budget_exhausted" }, { "Retry-After": "3600" });
    }
    freeSpentEstimate = estimatedCost;

    if (parsed.data.complexity === "complex") {
      const installId = sanitizeInstallId(request.headers["x-rudder-install-id"]) ?? request.clientKey;
      const limit = Number(process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH ?? DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH);
      const quota = await checkDeepDecisionQuota(installId, limit);
      if (!quota.allowed) {
        await refundGlobalFreeSpend(freeSpentEstimate);
        await refundAbsoluteSpend(absoluteSpentEstimate);
        return json(429, { error: "deep_decision_limit_reached" }, { "Retry-After": String(quota.retryAfterSeconds) });
      }
      deepQuotaInstallId = installId;
    }
  }

  async function refundSpend(): Promise<void> {
    if (deepQuotaInstallId) await refundDeepDecisionQuota(deepQuotaInstallId);
    if (freeSpentEstimate > 0) await refundGlobalFreeSpend(freeSpentEstimate);
    if (absoluteSpentEstimate > 0) await refundAbsoluteSpend(absoluteSpentEstimate);
  }

  // A ceiling on how many analyses can be in flight at once, independent of
  // client identity — see concurrency.ts for why identity alone is not enough.
  const maxConcurrent = Number(process.env.DECIDE_MAX_CONCURRENT_ANALYSES ?? 5);
  if (!(await tryAcquire(maxConcurrent))) {
    await refundSpend();
    return json(503, { error: "server_busy" }, { "Retry-After": "2" });
  }

  try {
    const result = await analyse(getClient(), parsed.data);
    return json(200, result);
  } catch (error) {
    // A failed attempt shouldn't cost a Free user real budget or a real
    // month's decision -- only a delivered result should.
    await refundSpend();
    if (error instanceof AnalysisError) {
      return json(error.status, { error: error.message });
    }
    return json(500, { error: "internal_error" });
  } finally {
    await release();
  }
}

function sanitizeInstallId(raw: string | undefined): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (trimmed.length === 0 || trimmed.length > 128) return null;
  return trimmed;
}

function json(status: number, body: unknown, extraHeaders: Record<string, string> = {}): HandlerResponse {
  return {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  };
}
