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

  const maxTokens = request.complexity === "complex" ? 16000 : 8000;

  // Research is capped by the app's budget and by complexity, whichever is lower.
  const byLevel = request.researchLevel === "deep" ? 6 : request.researchLevel === "light" ? 2 : 0;
  const maxSearches = Math.max(0, Math.min(byLevel, request.maximumResearchCalls));

  const questionsRemaining = Math.max(
    0,
    Math.min(request.questionCeiling - request.questionsAlreadyAsked, 5)
  );

  const model = request.complexity === "complex" ? PREMIUM_MODEL : STANDARD_MODEL;

  return { model, effort, maxTokens, maxSearches, questionsRemaining };
}
