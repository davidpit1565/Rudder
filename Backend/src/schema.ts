import * as z from "zod/v4";

/**
 * The contract between the iPhone app and this endpoint.
 *
 * It mirrors `AIDecisionResponse` in Packages/RudderKit/Sources/RudderCore/AI/AIContract.swift.
 * Both sides validate it: the model is not trusted, and neither is the network.
 */
export const SCHEMA_VERSION = 1;

export const CATEGORIES = [
  "purchase", "career", "education", "travel", "home",
  "subscription", "finance", "technology", "life_planning", "other",
] as const;

export const COMPLEXITIES = ["simple", "medium", "complex"] as const;
export const RESEARCH_LEVELS = ["none", "light", "deep"] as const;
export const DECISION_STATUSES = [
  "ready", "needs_research", "needs_one_question", "not_enough_to_decide",
] as const;
export const QUESTION_KINDS = ["single_choice", "multiple_choice", "free_text"] as const;
export const RISK_SEVERITIES = ["low", "medium", "high"] as const;

// --- Request -----------------------------------------------------------------

export const AnalysisRequestSchema = z.object({
  schemaVersion: z.literal(SCHEMA_VERSION),
  prompt: z.string().min(3).max(4000),
  answers: z.array(
    z.object({
      questionId: z.string().max(120),
      answer: z.string().max(2000),
    })
  ).max(10).default([]),
  knownPreferences: z.array(z.string().max(200)).max(20).default([]),
  category: z.enum(CATEGORIES),
  complexity: z.enum(COMPLEXITIES),
  researchLevel: z.enum(RESEARCH_LEVELS),
  maximumResearchCalls: z.number().int().min(0).max(8),
  maximumSources: z.number().int().min(0).max(20),
  questionsAlreadyAsked: z.number().int().min(0).max(10),
  questionCeiling: z.number().int().min(0).max(5),
  strictSchema: z.boolean().default(false),
  locale: z.string().max(40).default("en_US"),
});

export type AnalysisRequest = z.infer<typeof AnalysisRequestSchema>;

// --- Response ----------------------------------------------------------------
//
// This is also the schema handed to the model as the required output format, so
// the descriptions below are part of the prompt: they are what the model reads.

export const DecisionResponseSchema = z.object({
  decisionStatus: z.enum(DECISION_STATUSES)
    .describe("ready when you can recommend; needs_research when public facts are missing; needs_one_question when only the user can supply something decisive; not_enough_to_decide when no responsible recommendation exists."),
  category: z.enum(CATEGORIES),
  complexity: z.enum(COMPLEXITIES),
  understanding: z.object({
    restatement: z.string().max(600).describe("The decision in your own words, in one or two sentences, addressed to the user."),
    knownContext: z.array(z.string().max(200)).max(8).describe("What the user has already told you."),
    whatMatters: z.array(z.string().max(200)).max(8).describe("What this decision turns on."),
  }),
  preliminaryRecommendation: z.object({
    optionId: z.string().max(80),
    rationale: z.string().max(400),
  }).nullable().describe("An early direction, shown while the analysis finishes. null if you have none."),
  requiredQuestions: z.array(
    z.object({
      id: z.string().max(80),
      text: z.string().max(240),
      kind: z.enum(QUESTION_KINDS),
      choices: z.array(z.string().max(120)).max(6),
      expectedImpact: z.number().min(0).max(1).describe("How much the answer could move the recommendation."),
      friction: z.number().min(0).max(1).describe("How much effort the answer costs the user."),
      answerableByResearch: z.boolean().describe("True if you could find this out yourself. Such questions are never shown to the user."),
      knowledgeKey: z.string().max(120).nullable(),
    })
  ).max(5),
  researchNeeded: z.object({
    level: z.enum(RESEARCH_LEVELS),
    topics: z.array(z.string().max(160)).max(8),
  }),
  criteria: z.array(
    z.object({
      id: z.string().max(80),
      name: z.string().max(60),
      weight: z.number().min(0).max(1).describe("Relative importance. They do not need to sum to 1."),
      rationale: z.string().max(300).nullable(),
    })
  ).max(8),
  options: z.array(
    z.object({
      id: z.string().max(80),
      name: z.string().max(80),
      summary: z.string().max(300).nullable(),
      scores: z.array(
        z.object({
          criterionId: z.string().max(80),
          score: z.number().min(0).max(1).describe("0 is poor, 1 is excellent. Use 0.5 only when you genuinely do not know."),
        })
      ).max(8),
      failedConstraints: z.array(z.string().max(160)).max(5)
        .describe("Hard requirements from the user that this option breaks. A non-empty list eliminates it."),
    })
  ).max(8),
  recommendation: z.object({
    optionId: z.string().max(80),
    headline: z.string().max(140),
    reasons: z.array(
      z.object({
        title: z.string().max(90),
        detail: z.string().max(320),
      })
    ).max(3).describe("At most three, in the user's terms, not yours."),
  }).nullable(),
  tradeoffs: z.array(
    z.object({
      gaining: z.string().max(140)
        .describe("A sentence fragment, lowercase, no trailing period — it's embedded as \"...to get X\"."),
      givingUp: z.string().max(140)
        .describe("A sentence fragment, lowercase, no trailing period — it's embedded as \"...giving up X to get...\"."),
    })
  ).max(3),
  risks: z.array(
    z.object({
      title: z.string().max(90),
      detail: z.string().max(320),
      severity: z.enum(RISK_SEVERITIES),
    })
  ).max(4),
  assumptions: z.array(
    z.object({ statement: z.string().max(240), impactIfWrong: z.string().max(240) })
  ).max(4),
  research: z.array(
    z.object({
      claim: z.string().max(320),
      sourceTitle: z.string().max(160).nullable(),
      sourceUrl: z.string().max(400).nullable().describe("Only a URL you actually retrieved. Never construct one."),
      retrievedAt: z.string().max(40).nullable().describe("ISO 8601."),
      verified: z.boolean(),
    })
  ).max(12),
  conflicts: z.array(
    z.object({ topic: z.string().max(160), detail: z.string().max(320) })
  ).max(4),
  whatCouldMakeMeWrong: z.array(z.string().max(240)).max(4),
});

export type DecisionResponse = z.infer<typeof DecisionResponseSchema>;

/**
 * The wire shape the app decodes: scores as a map, plus the schema version.
 * The model produces scores as a list because JSON Schema cannot describe a map
 * with arbitrary keys as precisely.
 */
export interface WireResponse extends Omit<DecisionResponse, "options"> {
  schemaVersion: number;
  options: Array<{
    id: string;
    name: string;
    summary: string | null;
    scores: Record<string, number>;
    failedConstraints: string[];
  }>;
}

// --- Follow-up (chat on a finished decision) ----------------------------------
//
// Deliberately separate from AnalysisRequestSchema/DecisionResponseSchema above:
// a follow-up is a short, cheap, no-research Groq call that answers a question
// about a decision already finished, not a new full analysis. It mirrors
// `FollowUpResponse` in Packages/RudderKit/Sources/RudderCore/AI/
// FollowUpContract.swift.

export const FollowUpRequestSchema = z.object({
  schemaVersion: z.literal(SCHEMA_VERSION),
  /** The original decision's prompt, for grounding -- the model never re-derives it. */
  originalPrompt: z.string().min(3).max(4000),
  /** A compact, app-rendered summary of the finished decision (restatement,
   * recommendation, reasons, tradeoffs) -- not the full DecisionResult, which
   * would cost far more tokens than a short follow-up answer needs. */
  decisionContext: z.string().max(3000),
  /** Prior exchanges in this same follow-up thread, oldest first, so a second
   * or third question still has the earlier answers for continuity. */
  history: z.array(
    z.object({
      question: z.string().max(1000),
      answer: z.string().max(2000),
    })
  ).max(10).default([]),
  question: z.string().min(3).max(1000),
  locale: z.string().max(40).default("en_US"),
});

export type FollowUpRequest = z.infer<typeof FollowUpRequestSchema>;

export const FollowUpResponseSchema = z.object({
  answer: z.string().max(2000).describe("A direct, conversational answer grounded only in the decision context and history given -- never invented facts."),
  needsResearch: z.boolean()
    .describe("True only when answering well would require looking up current, external facts this call cannot verify -- not for anything answerable from the existing decision context."),
  suggestedNewDecisionPrompt: z.string().max(2000).nullable()
    .describe("When needsResearch is true, or the question is really a different decision, a ready-to-use prompt (including relevant context from the original decision) for starting a new decision. Otherwise null."),
  durablePreference: z.object({
    statement: z.string().max(200).describe("A short, behavioural, user-facing sentence, e.g. 'You prioritize flexibility over price.' Never an identity claim."),
  }).nullable().describe("Set only when this answer revealed a preference worth remembering for future decisions. Most answers set this to null."),
});

export type FollowUpResponse = z.infer<typeof FollowUpResponseSchema>;
