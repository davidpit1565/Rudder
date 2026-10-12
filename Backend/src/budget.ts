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
  const effort: Effort =
    request.complexity === "complex" ? "high"
    : request.complexity === "medium" ? "medium"
    : "low";

  // A complex decision runs two sequential premium-model calls (research, then
  // analysis) -- Vercel's serverless function has a hard 60s ceiling (the max
  // the Hobby plan allows), and 6 searches plus a 16000-token analysis
  // reliably blew through it (confirmed live: a 504 FUNCTION_INVOCATION_TIMEOUT
  // at exactly 60s). Trimmed to fit with margin; if a paid Vercel plan lifts
  // the ceiling later, these can grow back.
  const maxTokens = request.complexity === "complex" ? 12000 : 8000;

  // Research is capped by the app's budget and by complexity, whichever is lower.
  const byLevel = request.researchLevel === "deep" ? 4 : request.researchLevel === "light" ? 2 : 0;
  const maxSearches = Math.max(0, Math.min(byLevel, request.maximumResearchCalls));

  const questionsRemaining = Math.max(
    0,
    Math.min(request.questionCeiling - request.questionsAlreadyAsked, 5)
  );

  const model = request.complexity === "complex" ? PREMIUM_MODEL : STANDARD_MODEL;

  return { model, effort, maxTokens, maxSearches, questionsRemaining };
}
