import * as z from "zod/v4";
import { GoogleGenAI } from "@google/genai";
import OpenAI from "openai";
import { AnalysisRequestSchema, FollowUpRequestSchema, type WireResponse } from "./schema.js";
import { analyse as defaultAnalyse, AnalysisError, type AnalysisClients } from "./analyze.js";
import { followUp as defaultFollowUp, FollowUpError } from "./followup.js";
import { checkRateLimit, checkDailyLimit } from "./rateLimit.js";
import { verifyClient } from "./attest.js";
import { tryAcquire, release } from "./concurrency.js";
import { isConfigured as isRedisConfigured } from "./redis.js";
import { verifyAppStoreTransaction } from "./appStoreVerify.js";
import { createJob, getJob, saveJob, newJobId, type AnalysisJob, type JobCharge } from "./jobs.js";
import {
  checkDeepDecisionQuota,
  refundDeepDecisionQuota,
  peekDeepDecisionQuota,
  DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH,
  checkDailyQuota,
  refundDailyQuota,
  peekDailyQuota,
  DEFAULT_FREE_MEDIUM_DAILY_LIMIT,
  DEFAULT_PRO_MEDIUM_DAILY_LIMIT,
  DEFAULT_PRO_COMPLEX_DAILY_LIMIT,
  DEFAULT_FREE_FOLLOWUP_DAILY_LIMIT,
  DEFAULT_PRO_FOLLOWUP_DAILY_LIMIT,
} from "./quota.js";
import {
  checkGlobalFreeSpendCeiling,
  refundGlobalFreeSpend,
  checkAbsoluteSpendCeiling,
  refundAbsoluteSpend,
  ESTIMATED_COST_USD,
  FOLLOWUP_ESTIMATED_COST_USD,
  DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD,
  DEFAULT_MONTHLY_ABSOLUTE_SPEND_CEILING_USD,
} from "./spendCeiling.js";

// Mirrors SubscriptionService.ProductID in App/Services/SubscriptionService.swift.
const PRO_PRODUCT_IDS = ["com.davidpitchkhadze.rudder.pro.monthly", "com.davidpitchkhadze.rudder.pro.annual"] as const;
// Best-effort default -- confirm against the Rudder target's actual
// PRODUCT_BUNDLE_IDENTIFIER and set DECIDE_BUNDLE_ID explicitly if it differs.
const BUNDLE_ID = process.env.DECIDE_BUNDLE_ID ?? "com.davidpitchkhadze.rudder";

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
  followUp?: typeof defaultFollowUp;
}

let cachedClients: AnalysisClients | null = null;

function getClients(): AnalysisClients {
  if (!cachedClients) {
    // The credentials live here and only here. Each is read from the
    // environment and never echoed into a response or a log line.
    cachedClients = {
      gemini: new GoogleGenAI({
        apiKey: process.env.GEMINI_API_KEY,
        // Confirmed live: the SDK's default retry policy (up to 5 attempts, up
        // to 60s between them) silently eats the whole request on a 429 or 5xx
        // -- indistinguishable from the app just hanging, and long enough on
        // its own to blow Vercel's 60s ceiling even for a "simple" decision.
        // Fail fast instead: a real rate limit or transient error surfaces
        // immediately as a normal thrown error (already handled below --
        // rate_limited_upstream / upstream_unavailable), which is a much
        // better experience than a minute of silence before a generic timeout.
        httpOptions: { retryOptions: { attempts: 1 } },
      }),
      // Groq's API is OpenAI-compatible, so the official `openai` SDK talks
      // to it directly -- no separate Groq SDK. Used for every decision's
      // analysis step now, every complexity (see budget.ts). Same fail-fast
      // reasoning as Gemini above: the OpenAI SDK also retries by default,
      // so pin it to 0 extra retries.
      //
      // Unlike GoogleGenAI, the OpenAI SDK throws at CONSTRUCTION time if no
      // key resolves (here or via OPENAI_API_KEY) -- confirmed live: with
      // GROQ_API_KEY unset, this crashed getClients() itself, which failed
      // every request of every complexity, not just "complex" ones, since
      // this function builds both clients up front. A placeholder keeps
      // construction safe; a real request with no real key still fails,
      // correctly, as a 401 from Groq once analyseWithGroq() actually calls it.
      groq: new OpenAI({
        apiKey: process.env.GROQ_API_KEY ?? "unset",
        baseURL: "https://api.groq.com/openai/v1",
        maxRetries: 0,
      }),
    };
  }
  return cachedClients;
}

/**
 * Which daily quota bucket (if any) governs a decision of this complexity
 * and Pro status, and its limit. "simple" is never governed by a daily
 * quota. A Free "complex" decision isn't either -- it stays governed
 * entirely by the existing monthly quota above (DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH),
 * whose whole point is to make a recurring Free complex decision not exist at
 * all, not to give it a daily allowance.
 */
function dailyQuotaFor(
  complexity: "simple" | "medium" | "complex",
  verifiedPro: boolean
): { bucket: string; limit: number } | null {
  if (complexity === "medium") {
    return verifiedPro
      ? { bucket: "medium-pro", limit: Number(process.env.DECIDE_PRO_MEDIUM_DAILY_LIMIT ?? DEFAULT_PRO_MEDIUM_DAILY_LIMIT) }
      : { bucket: "medium-free", limit: Number(process.env.DECIDE_FREE_MEDIUM_DAILY_LIMIT ?? DEFAULT_FREE_MEDIUM_DAILY_LIMIT) };
  }
  if (complexity === "complex" && verifiedPro) {
    return { bucket: "complex-pro", limit: Number(process.env.DECIDE_PRO_COMPLEX_DAILY_LIMIT ?? DEFAULT_PRO_COMPLEX_DAILY_LIMIT) };
  }
  return null;
}

/** Which daily quota bucket governs a follow-up question, by Pro status.
 * Unlike dailyQuotaFor() for decisions, every follow-up is governed by one of
 * these two -- there is no "simple, unlimited" case, since even the cheapest
 * follow-up is a real (if small) model call. */
function followUpDailyQuota(verifiedPro: boolean): { bucket: string; limit: number } {
  return verifiedPro
    ? { bucket: "followup-pro", limit: Number(process.env.DECIDE_PRO_FOLLOWUP_DAILY_LIMIT ?? DEFAULT_PRO_FOLLOWUP_DAILY_LIMIT) }
    : { bucket: "followup-free", limit: Number(process.env.DECIDE_FREE_FOLLOWUP_DAILY_LIMIT ?? DEFAULT_FREE_FOLLOWUP_DAILY_LIMIT) };
}

/**
 * Read-only: today's/this-month's usage across every quota the app shows,
 * without spending a unit of any of them. Lets the app display "X of Y used"
 * (e.g. in a Profile/account screen) at any time, not only right after a
 * decision completes. Uses the same verifiedPro/installId resolution as the
 * real analyze endpoint, so the numbers always match what analyze() would
 * actually enforce.
 */
async function handleQuotaStatus(request: HandlerRequest): Promise<HandlerResponse> {
  const client = verifyClient(request.headers);
  if (!client.ok) {
    return json(client.status, { error: client.reason ?? "forbidden" });
  }

  const transactionHeader = request.headers["x-rudder-transaction"];
  const verifiedPro =
    transactionHeader != null &&
    verifyAppStoreTransaction(transactionHeader, { bundleId: BUNDLE_ID, productIds: PRO_PRODUCT_IDS }) !== null;
  const installId = sanitizeInstallId(request.headers["x-rudder-install-id"]) ?? request.clientKey;

  const medium = dailyQuotaFor("medium", verifiedPro)!;
  const mediumUsage = await peekDailyQuota(medium.bucket, installId, medium.limit);

  const followup = followUpDailyQuota(verifiedPro);
  const followupUsage = await peekDailyQuota(followup.bucket, installId, followup.limit);

  let complexMonthly: { used: number; limit: number; resetsAt: string } | null = null;
  let complexDaily: { used: number; limit: number; resetsAt: string } | null = null;
  if (verifiedPro) {
    const complexPro = dailyQuotaFor("complex", true)!;
    const usage = await peekDailyQuota(complexPro.bucket, installId, complexPro.limit);
    complexDaily = { used: usage.used, limit: usage.limit, resetsAt: usage.resetsAt };
  } else {
    const monthlyLimit = Number(process.env.DECIDE_FREE_DEEP_DECISIONS_PER_MONTH ?? DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH);
    const usage = await peekDeepDecisionQuota(installId, monthlyLimit);
    complexMonthly = {
      used: usage.used,
      limit: usage.limit,
      resetsAt: new Date(Date.now() + usage.retryAfterSeconds * 1000).toISOString(),
    };
  }

  return json(200, {
    isPro: verifiedPro,
    simple: { limited: false },
    medium: { used: mediumUsage.used, limit: mediumUsage.limit, resetsAt: mediumUsage.resetsAt },
    complex: { monthly: complexMonthly, daily: complexDaily },
    followup: { used: followupUsage.used, limit: followupUsage.limit, resetsAt: followupUsage.resetsAt },
  });
}

/**
 * A follow-up question on an already-finished decision: its own route,
 * its own (much smaller) daily quota bucket, and its own (much cheaper, much
 * faster) model call -- see followup.ts. Mirrors the shape of the main
 * analyze flow below (client verification, rate limits, spend ceilings,
 * quota, concurrency gate, refund-on-failure) but without the
 * complexity-dependent branching that only a new decision needs.
 */
async function handleFollowUp(request: HandlerRequest, deps: HandlerDependencies): Promise<HandlerResponse> {
  const followUp = deps.followUp ?? defaultFollowUp;

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

  // Generous relative to AnalysisRequestSchema's 32_000: a follow-up thread
  // carries up to 10 prior exchanges (history) alongside the question itself.
  if (request.body.length > 48_000) {
    return json(413, { error: "payload_too_large" });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(request.body);
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const parsed = FollowUpRequestSchema.safeParse(payload);
  if (!parsed.success) {
    return json(400, { error: "invalid_request" });
  }

  const transactionHeader = request.headers["x-rudder-transaction"];
  const verifiedPro =
    transactionHeader != null &&
    verifyAppStoreTransaction(transactionHeader, { bundleId: BUNDLE_ID, productIds: PRO_PRODUCT_IDS }) !== null;

  let freeSpentEstimate = 0;
  let absoluteSpentEstimate = 0;

  {
    const absoluteCeiling = Number(
      process.env.DECIDE_MONTHLY_ABSOLUTE_SPEND_CEILING_USD ?? DEFAULT_MONTHLY_ABSOLUTE_SPEND_CEILING_USD
    );
    const absolute = await checkAbsoluteSpendCeiling(FOLLOWUP_ESTIMATED_COST_USD, absoluteCeiling);
    if (!absolute.allowed) {
      return json(503, { error: "monthly_ai_budget_exhausted" }, { "Retry-After": "3600" });
    }
    absoluteSpentEstimate = FOLLOWUP_ESTIMATED_COST_USD;
  }

  if (!verifiedPro) {
    const spendCeiling = Number(
      process.env.DECIDE_MONTHLY_FREE_SPEND_CEILING_USD ?? DEFAULT_MONTHLY_FREE_SPEND_CEILING_USD
    );
    const spend = await checkGlobalFreeSpendCeiling(FOLLOWUP_ESTIMATED_COST_USD, spendCeiling);
    if (!spend.allowed) {
      await refundAbsoluteSpend(absoluteSpentEstimate);
      return json(503, { error: "monthly_free_budget_exhausted" }, { "Retry-After": "3600" });
    }
    freeSpentEstimate = FOLLOWUP_ESTIMATED_COST_USD;
  }

  const installId = sanitizeInstallId(request.headers["x-rudder-install-id"]) ?? request.clientKey;
  const dailyBudget = followUpDailyQuota(verifiedPro);
  const decision = await checkDailyQuota(dailyBudget.bucket, installId, dailyBudget.limit);
  if (!decision.allowed) {
    if (freeSpentEstimate > 0) await refundGlobalFreeSpend(freeSpentEstimate);
    await refundAbsoluteSpend(absoluteSpentEstimate);
    return json(
      429,
      {
        error: "daily_followup_limit_reached",
        quota: { bucket: dailyBudget.bucket, used: decision.used, limit: decision.limit, resetsAt: decision.resetsAt },
      },
      { "Retry-After": String(decision.retryAfterSeconds) }
    );
  }
  const quotaInfo = { bucket: dailyBudget.bucket, used: decision.used, limit: decision.limit, resetsAt: decision.resetsAt };

  async function refundSpend(): Promise<void> {
    await refundDailyQuota(dailyBudget.bucket, installId);
    if (freeSpentEstimate > 0) await refundGlobalFreeSpend(freeSpentEstimate);
    if (absoluteSpentEstimate > 0) await refundAbsoluteSpend(absoluteSpentEstimate);
  }

  // Shares the same concurrency pool as /v1/decisions/analyze -- one global
  // ceiling on in-flight model calls regardless of which endpoint they came
  // from, since both ultimately compete for the same Groq capacity.
  const maxConcurrent = Number(process.env.DECIDE_MAX_CONCURRENT_ANALYSES ?? 5);
  if (!(await tryAcquire(maxConcurrent))) {
    await refundSpend();
    return json(503, { error: "server_busy" }, { "Retry-After": "2" });
  }

  try {
    const result = await followUp(getClients().groq, parsed.data);
    return json(200, { ...result, quota: quotaInfo });
  } catch (error) {
    await refundSpend();
    if (error instanceof FollowUpError) {
      return json(error.status, { error: error.message });
    }
    return json(500, { error: "internal_error" });
  } finally {
    await release();
  }
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

  if (request.method === "GET" && request.path === "/v1/quota/status") {
    return handleQuotaStatus(request);
  }

  if (request.method === "POST" && request.path === "/v1/decisions/followup") {
    return handleFollowUp(request, deps);
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

  // A `continue` call looks nothing like a decision request -- just the ID of
  // one already created below -- so it's checked for first and handled on
  // its own path, with none of the charge/quota logic a *new* decision goes
  // through (that already happened once, at creation).
  const continuation = ContinueRequestSchema.safeParse(payload);
  if (continuation.success) {
    return handleContinue(analyse, continuation.data.jobId);
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
  let dailyQuota: { bucket: string; installId: string } | null = null;
  let freeSpentEstimate = 0;
  let absoluteSpentEstimate = 0;
  let quotaInfo: { bucket: string; used: number; limit: number; resetsAt: string } | null = null;

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

  // Daily quota -- see dailyQuotaFor()'s doc comment for which complexities
  // and Pro states this governs. Runs after the monthly complex-only check
  // above regardless of verifiedPro, since it covers a different set of
  // cases (every "medium" decision, plus a verified-Pro "complex" one).
  const dailyBudget = dailyQuotaFor(parsed.data.complexity, verifiedPro !== null);
  if (dailyBudget) {
    const installId = sanitizeInstallId(request.headers["x-rudder-install-id"]) ?? request.clientKey;
    const decision = await checkDailyQuota(dailyBudget.bucket, installId, dailyBudget.limit);
    if (!decision.allowed) {
      if (freeSpentEstimate > 0) await refundGlobalFreeSpend(freeSpentEstimate);
      await refundAbsoluteSpend(absoluteSpentEstimate);
      return json(
        429,
        {
          error: "daily_decision_limit_reached",
          quota: { bucket: dailyBudget.bucket, used: decision.used, limit: decision.limit, resetsAt: decision.resetsAt },
        },
        { "Retry-After": String(decision.retryAfterSeconds) }
      );
    }
    dailyQuota = { bucket: dailyBudget.bucket, installId };
    quotaInfo = { bucket: dailyBudget.bucket, used: decision.used, limit: decision.limit, resetsAt: decision.resetsAt };
  }

  const charge: JobCharge = { deepQuotaInstallId, dailyQuota, freeSpentEstimate, absoluteSpentEstimate, quotaInfo };
  const job = await createJob(newJobId(), parsed.data, charge);

  // A ceiling on how many analyses can be in flight at once, independent of
  // client identity — see concurrency.ts for why identity alone is not enough.
  const maxConcurrent = Number(process.env.DECIDE_MAX_CONCURRENT_ANALYSES ?? 5);
  if (!(await tryAcquire(maxConcurrent))) {
    await refundJobCharge(job.charge);
    return json(503, { error: "server_busy" }, { "Retry-After": "2" });
  }

  try {
    await runJobAttempt(analyse, getClients(), job);
  } finally {
    await release();
  }
  return respondForJob(job);
}

/**
 * Wall-clock budget for one analyse() attempt inside a job, well under
 * Vercel's 60s hard function-duration ceiling (vercel.json) -- 15s of margin
 * for the checks, Redis round-trips and JSON work around it in both
 * `handle()` and this file. Deliberately tighter than analyse()'s own
 * internal PIPELINE_DEADLINE_MS (52s, see analyze.ts): the goal here isn't to
 * let one attempt run as long as it's individually allowed to, it's to make
 * sure this *invocation* always has time left to persist the job and respond
 * cleanly, whatever analyse() itself is doing.
 */
function jobRaceDeadlineMs(): number {
  // Overridable so tests can exercise the "still running" / retry paths
  // without actually waiting out a near-60s race.
  return Number(process.env.DECIDE_JOB_RACE_DEADLINE_MS ?? 45_000);
}

/** How many full analyse() attempts (each with its own fresh JOB_RACE_DEADLINE_MS,
 * not a shrinking shared one) a job gets before it's reported as failed and
 * refunded. Matters only when every attempt is either timing out or hitting a
 * real upstream error -- the ordinary case is done on the very first one. */
const MAX_JOB_ATTEMPTS = 4;

const ContinueRequestSchema = z.object({ jobId: z.string().min(1).max(100) });

interface RaceOutcome<T> {
  finished: boolean;
  value?: T;
  error?: unknown;
}

/** Races `promise` against a plain timer rather than cancelling it -- none of
 * the SDK calls inside analyse() support real cancellation, and even if they
 * did, Vercel gives this invocation no way to guarantee cleanup finishes
 * before the response goes out. The promise itself is always left to settle
 * on its own; `runJobAttempt` below decides what to do with it either way. */
function raceAttempt<T>(promise: Promise<T>, ms: number): Promise<RaceOutcome<T>> {
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolve({ finished: false });
    }, ms);
    promise.then(
      (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve({ finished: true, value });
      },
      (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve({ finished: true, error });
      }
    );
  });
}

async function refundJobCharge(charge: JobCharge): Promise<void> {
  if (charge.deepQuotaInstallId) await refundDeepDecisionQuota(charge.deepQuotaInstallId);
  if (charge.dailyQuota) await refundDailyQuota(charge.dailyQuota.bucket, charge.dailyQuota.installId);
  if (charge.freeSpentEstimate > 0) await refundGlobalFreeSpend(charge.freeSpentEstimate);
  if (charge.absoluteSpentEstimate > 0) await refundAbsoluteSpend(charge.absoluteSpentEstimate);
}

/** Mirrors handle()'s old inline needs_one_question adjustment: only the
 * user-facing decision-count quota is given back, never freeSpentEstimate /
 * absoluteSpentEstimate -- the real AI spend for this round already
 * happened and is never refunded just because the decision isn't finished. */
async function refundQuotaForNeedsQuestion(charge: JobCharge): Promise<void> {
  if (charge.deepQuotaInstallId) await refundDeepDecisionQuota(charge.deepQuotaInstallId);
  if (charge.dailyQuota) await refundDailyQuota(charge.dailyQuota.bucket, charge.dailyQuota.installId);
}

async function finishJobWithResult(job: AnalysisJob, result: WireResponse): Promise<void> {
  if (job.status !== "running") return; // already finished via another path (e.g. a late background resolve)
  job.status = "done";
  job.result = result;
  if (result.decisionStatus === "needs_one_question") {
    await refundQuotaForNeedsQuestion(job.charge);
    if (job.charge.quotaInfo) {
      job.charge.quotaInfo = { ...job.charge.quotaInfo, used: Math.max(0, job.charge.quotaInfo.used - 1) };
    }
  }
  await saveJob(job);
}

/** Only a genuinely transient upstream condition is worth another attempt --
 * the same "upstream_unavailable" class analyze.ts already uses for a
 * timeout or a 503/504 from the provider (see throwForUpstreamError). Every
 * other AnalysisError (a rate limit, a refused/content-filtered response, an
 * unparseable one) is deterministic: retrying it would just fail the same
 * way again, slower, so it's reported immediately instead -- exactly as it
 * was before this job model existed. */
function isRetryableError(error: unknown): boolean {
  return error instanceof AnalysisError && error.status === 503;
}

async function finishJobWithError(job: AnalysisJob, error: unknown): Promise<void> {
  if (job.status !== "running") return;
  if (isRetryableError(error) && job.attempts < MAX_JOB_ATTEMPTS) return; // the next `continue` call gets a fresh attempt
  job.status = "failed";
  if (error instanceof AnalysisError) {
    job.errorMessage = error.message;
    job.errorStatus = error.status;
  } else {
    job.errorMessage = "internal_error";
    job.errorStatus = 500;
  }
  if (!job.refunded) {
    job.refunded = true;
    await refundJobCharge(job.charge);
  }
  await saveJob(job);
}

/**
 * Runs exactly one analyse() attempt for `job`, racing it against
 * JOB_RACE_DEADLINE_MS so this invocation always has time left to persist the
 * outcome and respond -- never the open-ended wait that let a single slow
 * upstream call blow past Vercel's 60s ceiling with no response at all (see
 * analyze.ts's PIPELINE_DEADLINE_MS comment for how that actually happened).
 * Leaves `job.status` as "running" when the race times out or a non-final
 * error leaves attempts remaining: the caller (`handle()`, via
 * `respondForJob`) reports that as `{ pending: true }`, and the next
 * `continue` call -- whenever the client next makes one, including after the
 * app was fully closed and reopened -- starts a brand new attempt with its
 * own full budget rather than resuming mid-call, which nothing here could do
 * safely anyway.
 */
async function runJobAttempt(
  analyse: typeof defaultAnalyse,
  clients: AnalysisClients,
  job: AnalysisJob
): Promise<void> {
  job.attempts += 1;
  await saveJob(job);

  const attemptPromise = analyse(clients, job.request);
  const race = await raceAttempt(attemptPromise, jobRaceDeadlineMs());

  if (!race.finished) {
    // The same in-flight call, left running -- never a second, separately
    // billed attempt. Best-effort only: Vercel gives no guarantee this
    // instance survives long enough to see it settle, so correctness never
    // depends on it, only on the next `continue` call's own fresh attempt.
    attemptPromise.then(
      (value) => void finishJobWithResult(job, value),
      (error) => void finishJobWithError(job, error)
    );
    return;
  }

  if (race.error !== undefined) {
    await finishJobWithError(job, race.error);
    return;
  }

  await finishJobWithResult(job, race.value as WireResponse);
}

/**
 * quotaInfo is only ever set for a complexity/Pro-state dailyQuotaFor()
 * actually governs -- "simple", and a Free "complex" decision, carry no
 * quota field at all, rather than a misleading one.
 */
function respondForJob(job: AnalysisJob): HandlerResponse {
  if (job.status === "done" && job.result) {
    return json(200, job.charge.quotaInfo ? { ...job.result, quota: job.charge.quotaInfo } : job.result);
  }
  if (job.status === "failed") {
    return json(job.errorStatus ?? 500, { error: job.errorMessage ?? "internal_error" });
  }
  return json(200, { jobId: job.id, pending: true });
}

/**
 * The client's repeated check-in on a decision already created above -- no
 * new charge, no new quota check, just either the stored terminal outcome or
 * one more bounded attempt. The only path that can run arbitrarily long
 * after the original request returned, including after the app was closed
 * and reopened: `job` lives in Redis (jobs.ts), not in this invocation's
 * memory, so none of that matters to it.
 */
async function handleContinue(analyse: typeof defaultAnalyse, jobId: string): Promise<HandlerResponse> {
  const job = await getJob(jobId);
  if (!job) {
    return json(404, { error: "job_not_found" });
  }
  if (job.status !== "running") {
    return respondForJob(job);
  }
  if (job.attempts >= MAX_JOB_ATTEMPTS) {
    // Shouldn't normally be reachable -- finishJobWithError already marks the
    // job "failed" once attempts run out -- but never leaves a job stuck
    // "running" forever if it somehow is.
    job.status = "failed";
    job.errorMessage = "analysis_failed";
    job.errorStatus = 503;
    if (!job.refunded) {
      job.refunded = true;
      await refundJobCharge(job.charge);
    }
    await saveJob(job);
    return respondForJob(job);
  }

  const maxConcurrent = Number(process.env.DECIDE_MAX_CONCURRENT_ANALYSES ?? 5);
  if (!(await tryAcquire(maxConcurrent))) {
    // The job itself hasn't failed -- just this one check-in found the server
    // busy. No refund: the client simply polls again shortly.
    return json(503, { error: "server_busy" }, { "Retry-After": "2" });
  }
  try {
    await runJobAttempt(analyse, getClients(), job);
  } finally {
    await release();
  }
  return respondForJob(job);
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
