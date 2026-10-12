import type { AnalysisRequest } from "./schema.js";

/**
 * What one decision is allowed to spend.
 *
 * Model choice is the primary cost lever, split exactly on the Free/Pro boundary
 * the app already enforces: a complex ("deep") decision is the one that needs
 * Pro or the trial, so it's the only one that runs on the premium model. Simple
 * and medium decisions are free and unlimited for everyone, and run on the
 * cheap/fast model — real analysis, a small fraction of the per-call cost, so
 * the free tier stays genuinely generous without moving the $5/month ceiling.
 * Effort (reasoning depth, tokens, searches) is still the secondary lever
 * within whichever model a request gets.
 */
export const PREMIUM_MODEL = "claude-opus-5";
export const STANDARD_MODEL = "claude-haiku-5-5";

export type Effort = "low" | "medium" | "high";

export interface Budget {
  model: string;
  effort: Effort;
  maxTokens: number;
  /** Server-side web searches allowed for this decision. 0 means no research call at all. */
  maxSearches: number;
  /** Questions the model may return, after what has already been asked. */
  questionsRemaining: number;
}

export function budgetFor(request: AnalysisRequest): Budget {
  // A complex decision runs two sequential premium-model calls (research, then
  // analysis). Vercel's serverless function has a hard 60s ceiling (the max
  // the Hobby plan allows) -- confirmed live, twice, that even a trimmed
  // 4-search/12000-token/high-effort budget still blew through it
  // (504 FUNCTION_INVOCATION_TIMEOUT at exactly 60s both times). Brought down
  // to the same operational budget as "medium" -- the premium model is the
  // only remaining differentiator for Pro, not a larger search/token/effort
  // budget. If a paid Vercel plan lifts the ceiling later, these can grow
  // back; see AppStore/RELEASE.md.
  const effort: Effort = request.complexity === "simple" ? "low" : "medium";

  const maxTokens = 8000;

  // Research is capped by the app's budget and by complexity, whichever is lower.
  const byLevel = request.researchLevel === "deep" ? 2 : request.researchLevel === "light" ? 2 : 0;
  const maxSearches = Math.max(0, Math.min(byLevel, request.maximumResearchCalls));

  const questionsRemaining = Math.max(
    0,
    Math.min(request.questionCeiling - request.questionsAlreadyAsked, 5)
  );

  const model = request.complexity === "complex" ? PREMIUM_MODEL : STANDARD_MODEL;

  return { model, effort, maxTokens, maxSearches, questionsRemaining };
}
