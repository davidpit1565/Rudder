import Anthropic from "@anthropic-ai/sdk";
import { AnalysisRequestSchema } from "./schema.js";
import { analyse as defaultAnalyse, AnalysisError } from "./analyze.js";
import { checkRateLimit, checkDailyLimit } from "./rateLimit.js";
import { verifyClient } from "./attest.js";
import { tryAcquire, release } from "./concurrency.js";
import { isConfigured as isRedisConfigured } from "./redis.js";
import { verifyAppStoreTransaction } from "./appStoreVerify.js";
import { checkDeepDecisionQuota, refundDeepDecisionQuota, DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH } from "./quota.js";

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

  // The Free/Pro line itself: a "complex" (deep) decision is unlimited for a
  // verified Pro subscriber, and capped per install per month otherwise --
  // enforced here, not just trusted from whatever the client declares. See
  // quota.ts and appStoreVerify.ts for why this exists and what it does and
  // doesn't prove.
  let deepQuotaInstallId: string | null = null;
  if (parsed.data.complexity === "complex") {
    const transactionHeader = request.headers["x-rudder-transaction"];
    const verifiedPro = transactionHeader
      ? verifyAppStoreTransaction(transactionHeader, { bundleId: BUNDLE_ID, productIds: PRO_PRODUCT_IDS })
      : null;

    if (!verifiedPro) {
      const installId = sanitizeInstallId(request.headers["x-rudder-install-id"]) ?? request.clientKey;
      const limit = Number(process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH ?? DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH);
      const quota = await checkDeepDecisionQuota(installId, limit);
      if (!quota.allowed) {
        return json(429, { error: "deep_decision_limit_reached" }, { "Retry-After": String(quota.retryAfterSeconds) });
      }
      deepQuotaInstallId = installId;
    }
  }

  // A ceiling on how many analyses can be in flight at once, independent of
  // client identity — see concurrency.ts for why identity alone is not enough.
  const maxConcurrent = Number(process.env.DECIDE_MAX_CONCURRENT_ANALYSES ?? 5);
  if (!(await tryAcquire(maxConcurrent))) {
    if (deepQuotaInstallId) await refundDeepDecisionQuota(deepQuotaInstallId);
    return json(503, { error: "server_busy" }, { "Retry-After": "2" });
  }

  try {
    const result = await analyse(getClient(), parsed.data);
    return json(200, result);
  } catch (error) {
    // A failed attempt shouldn't cost a Free user a real month's decision --
    // only a delivered result should.
    if (deepQuotaInstallId) await refundDeepDecisionQuota(deepQuotaInstallId);
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
