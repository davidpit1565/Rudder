import type { AnalysisRequest } from "./schema.js";

/**
 * What one decision is allowed to spend.
 *
 * Model choice is the primary lever, split exactly on the Free/Pro boundary
 * the app already enforces: a complex ("deep") decision is the one that needs
 * Pro or the trial, so it's the only one that runs on the stronger model.
 * Simple and medium decisions are free and unlimited for everyone, and run on
 * the lighter model. Both models are on Gemini's free tier (see
 * Backend/README.md) -- no per-token credit balance that can silently run
 * out, only rate limits that fail loud and recover on their own. Effort
 * (thinking_level, output tokens, searches) is still the secondary lever
 * within whichever model a request gets.
 */
export const PREMIUM_MODEL = "gemini-3.8-flash";
export const STANDARD_MODEL = "gemini-3.5-flash-lite";

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
  // A complex decision runs two sequential model calls (research, then
  // analysis) on the stronger model. Kept at the same operational budget as
  // "medium" -- carried over from when this ran on a per-token-billed
  // provider and had to stay well clear of Vercel's 60s function-duration
  // ceiling. Re-measure against Gemini before raising these: the ceiling
  // itself hasn't moved, only the provider has. See AppStore/RELEASE.md.
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
