import {
  SCHEMA_VERSION,
  type AnalysisRequest,
  type DecisionResponse,
  type WireResponse,
} from "./schema.js";
import type { Budget } from "./budget.js";

/**
 * The last gate before anything leaves this server.
 *
 * The model's output has already been schema-validated; this enforces the rules
 * a schema cannot express — no citation that was not retrieved, no question
 * beyond the budget, no recommendation pointing at an option that does not
 * exist, and no fabricated confidence.
 */
export function toWireResponse(
  response: DecisionResponse,
  request: AnalysisRequest,
  budget: Budget,
  retrievedUrls: Map<string, string>
): WireResponse {
  const criterionIds = new Set(response.criteria.map((criterion) => criterion.id));

  const options = response.options.map((option) => {
    const scores: Record<string, number> = {};
    for (const entry of option.scores) {
      if (!criterionIds.has(entry.criterionId)) continue;
      scores[entry.criterionId] = clamp(entry.score);
    }
    return {
      id: option.id,
      name: option.name,
      summary: option.summary,
      scores,
      failedConstraints: option.failedConstraints,
    };
  });

  const optionIds = new Set(options.map((option) => option.id));

  // A recommendation for an option that is not on the list is not a recommendation.
  let recommendation = response.recommendation;
  if (recommendation && !optionIds.has(recommendation.optionId)) {
    recommendation = null;
  }

  let preliminary = response.preliminaryRecommendation;
  if (preliminary && !optionIds.has(preliminary.optionId)) {
    preliminary = null;
  }

  // Questions beyond the budget never reach the app, whatever the model asked for.
  const requiredQuestions = response.requiredQuestions
    .filter((question) => !question.answerableByResearch)
    .slice(0, budget.questionsRemaining);

  // A citation is only allowed if this request actually retrieved it.
  const research = response.research.map((finding) => {
    const url = finding.sourceUrl && retrievedUrls.has(finding.sourceUrl) ? finding.sourceUrl : null;
    return {
      claim: stripConfidenceClaims(finding.claim),
      sourceTitle: url ? retrievedUrls.get(url) ?? finding.sourceTitle : finding.sourceTitle,
      sourceUrl: url,
      retrievedAt: url ? finding.retrievedAt ?? new Date().toISOString() : null,
      verified: Boolean(url) && finding.verified,
    };
  });

  // The model may not ask for more research than the app budgeted for.
  const requestedLevel = rankResearch(response.researchNeeded.level);
  const allowedLevel = rankResearch(request.researchLevel);
  const researchNeeded = {
    level: requestedLevel > allowedLevel ? request.researchLevel : response.researchNeeded.level,
    topics: response.researchNeeded.topics,
  };

  return {
    schemaVersion: SCHEMA_VERSION,
    decisionStatus: response.decisionStatus,
    category: response.category,
    complexity: response.complexity,
    understanding: {
      restatement: stripConfidenceClaims(response.understanding.restatement),
      knownContext: response.understanding.knownContext,
      whatMatters: response.understanding.whatMatters,
    },
    preliminaryRecommendation: preliminary,
    requiredQuestions,
    researchNeeded,
    criteria: response.criteria,
    options,
    recommendation: recommendation
      ? {
          optionId: recommendation.optionId,
          headline: stripConfidenceClaims(recommendation.headline),
          reasons: recommendation.reasons.map((reason) => ({
            title: stripConfidenceClaims(reason.title),
            detail: stripConfidenceClaims(reason.detail),
          })),
        }
      : null,
    tradeoffs: response.tradeoffs,
    risks: response.risks,
    assumptions: response.assumptions,
    research,
    conflicts: response.conflicts,
    whatCouldMakeMeWrong: response.whatCouldMakeMeWrong,
  };
}

const CONFIDENCE_PATTERNS: Array<[RegExp, string]> = [
  // "92% confident", "87% sure", "95% certain"
  [/\b\d{1,3}(?:\.\d+)?\s*%\s*(confiden\w*|sure|certain\w*|likely|probab\w*)/gi, "confident"],
  // "I'm 92% ..." / "with 0.9 confidence"
  [/\bconfidence\s*(?:of|:)?\s*(?:0?\.\d+|\d{1,3}\s*%)/gi, "confidence"],
  [/\b(?:I am|I'm)\s+\d{1,3}\s*%\s+\w+/gi, "I'd say"],
];

/**
 * RUDDER never reports a confidence number. Decision strength is computed on the
 * device by re-running the analysis under varied priorities, so a percentage here
 * would be invented certainty dressed as a measurement.
 */
export function stripConfidenceClaims(text: string): string {
  let result = text;
  for (const [pattern, replacement] of CONFIDENCE_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  return result;
}

function clamp(value: number): number {
  if (!Number.isFinite(value)) return 0.5;
  return Math.min(Math.max(value, 0), 1);
}

function rankResearch(level: string): number {
  return level === "deep" ? 2 : level === "light" ? 1 : 0;
}
