import { randomUUID } from "node:crypto";
import { isConfigured, pipeline } from "./redis.js";
import type { AnalysisRequest, WireResponse } from "./schema.js";

/**
 * Everything needed to charge or refund a decision's quota/spend, captured
 * once at job creation so a later `continue` call (a different, possibly
 * much later HTTP request) can finish the exact same accounting handler.ts
 * already does for the synchronous path -- without re-deriving install IDs
 * or re-running the checks that already passed.
 */
export interface JobCharge {
  deepQuotaInstallId: string | null;
  dailyQuota: { bucket: string; installId: string } | null;
  freeSpentEstimate: number;
  absoluteSpentEstimate: number;
  quotaInfo: { bucket: string; used: number; limit: number; resetsAt: string } | null;
}

export interface AnalysisJob {
  id: string;
  request: AnalysisRequest;
  charge: JobCharge;
  status: "running" | "done" | "failed";
  /** How many full analyse() attempts have been started. Capped by the
   * caller (see MAX_JOB_ATTEMPTS in handler.ts) so a decision that keeps
   * losing the race against the clock eventually fails cleanly instead of
   * polling forever. */
  attempts: number;
  result?: WireResponse;
  errorMessage?: string;
  errorStatus?: number;
  /** Set once refundSpend() has run for this job, so a late-resolving
   * background attempt (see handler.ts) or a repeated `continue` call can
   * never refund the same job twice. */
  refunded: boolean;
  createdAt: number;
}

/**
 * Long enough that backgrounding or fully closing the app for a few minutes
 * and coming back still finds the job -- the whole point of this store --
 * short enough not to accumulate abandoned decisions in Redis forever if
 * someone never reopens the app.
 */
const JOB_TTL_SECONDS = 600;
const JOB_KEY_PREFIX = "decide:job:";

const localJobs = new Map<string, { job: AnalysisJob; expiresAt: number }>();

export function newJobId(): string {
  return randomUUID();
}

export async function createJob(id: string, request: AnalysisRequest, charge: JobCharge): Promise<AnalysisJob> {
  const job: AnalysisJob = {
    id,
    request,
    charge,
    status: "running",
    attempts: 0,
    refunded: false,
    createdAt: Date.now(),
  };
  await saveJob(job);
  return job;
}

export async function getJob(id: string): Promise<AnalysisJob | null> {
  if (isConfigured()) {
    try {
      const [raw] = await pipeline([["GET", JOB_KEY_PREFIX + id]]);
      if (typeof raw !== "string") return null;
      return JSON.parse(raw) as AnalysisJob;
    } catch {
      return null;
    }
  }
  const entry = localJobs.get(id);
  if (!entry) return null;
  if (entry.expiresAt < Date.now()) {
    localJobs.delete(id);
    return null;
  }
  return entry.job;
}

export async function saveJob(job: AnalysisJob): Promise<void> {
  if (isConfigured()) {
    try {
      await pipeline([["SET", JOB_KEY_PREFIX + job.id, JSON.stringify(job), "EX", JOB_TTL_SECONDS]]);
    } catch {
      // Best-effort: a lost save just means the next `continue` call starts a
      // fresh attempt instead of resuming from further along -- wasteful,
      // never incorrect, since the charge itself already happened once at
      // creation and this never repeats it.
    }
    return;
  }
  localJobs.set(job.id, { job, expiresAt: Date.now() + JOB_TTL_SECONDS * 1000 });
}
