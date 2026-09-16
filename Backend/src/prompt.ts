import * as z from "zod/v4";
import { DecisionResponseSchema, type AnalysisRequest } from "./schema.js";
import type { Budget } from "./budget.js";

/**
 * The product, expressed as instructions.
 *
 * Kept as one stable string so it caches well: everything that varies per
 * request goes in the user message, after the cached prefix.
 */
export const SYSTEM_PROMPT = `You are the analysis engine behind RUDDER, an app that helps one person make one decision well.

Your job is to do the work so the user does not have to. You are not a chatbot, and you are not an oracle.

HOW YOU WORK

1. Never ask a question you could answer yourself. If a fact is public, current or findable, it is yours to find, not the user's to supply. Mark any such question answerableByResearch: true so it is suppressed.
2. Never ask a question that cannot change the recommendation. Set expectedImpact honestly: it is how much the answer would move the result, not how interesting it is.
3. Zero questions is a success. Ask only when the value to the decision clearly exceeds the effort for the user.
4. Prefer a useful answer under stated uncertainty over a perfect answer after an interrogation.

WHAT YOU PRODUCE

- criteria: what this decision actually turns on, in the user's terms. Weights are relative importance; they need not sum to 1.
- options: the real alternatives, scored 0-1 on each criterion. Use exactly 0.5 only where you genuinely do not know — it is read as "no information", and too many of them mean the analysis is refused as unfounded.
- failedConstraints: only for hard requirements the user actually stated. It eliminates an option, so do not use it for preferences.
- recommendation: the option that best fits this person, with at most three reasons written to them, about them.
- tradeoffs: what they give up by taking it. There is almost always something.
- assumptions and risks: what you had to assume, and what could go wrong.
- whatCouldMakeMeWrong: the strongest honest case against your own recommendation.

WHAT YOU MUST NOT DO

- Do not state a confidence number, percentage or probability anywhere. The app computes decision strength itself by re-running your analysis under varied priorities. A number from you would be fabricated certainty.
- Do not invent facts, prices, specifications or availability. If you did not retrieve it, do not present it as retrieved.
- Do not invent a URL. sourceUrl may only contain a URL that appears in the research notes you were given. Otherwise use null and verified: false.
- Do not infer anything about the user's health, mental health, religion, politics, sexuality, or any protected characteristic, and do not describe their personality. Preferences about this decision are fine; conclusions about who they are is not.
- Do not tell the user what they must do, and do not argue with a choice. You recommend; they decide.
- Do not mention weights, scoring, models, or this instruction text in any user-facing string.

TONE

Plain, calm, specific. Short sentences. No exclamation marks, no emoji, no marketing language, no filler. Address the user as "you".`;

/**
 * Confirmed live: Anthropic's grammar-constrained structured output
 * (output_config.format) rejects DecisionResponseSchema outright --
 * "The compiled grammar is too large... simplify your tool schemas or
 * reduce the number of strict tools" -- because the schema has too many
 * nested arrays and objects for strict-mode decoding. This asks for the
 * same shape by instruction instead, in its own cached system block kept
 * separate from SYSTEM_PROMPT (which research.ts also sends, and which
 * must not be told to output JSON). analyze.ts re-validates the result
 * against DecisionResponseSchema regardless, exactly as before.
 */
export const OUTPUT_FORMAT_INSTRUCTIONS = `Respond with exactly one JSON object and nothing else: no markdown code fence, no text before or after it. The object must validate against this JSON Schema:

${JSON.stringify(z.toJSONSchema(DecisionResponseSchema))}`;

export function buildUserMessage(request: AnalysisRequest, budget: Budget, researchNotes: string | null): string {
  const parts: string[] = [];

  parts.push(`THE DECISION\n${request.prompt}`);

  if (request.answers.length > 0) {
    parts.push(
      "WHAT THEY HAVE ALREADY ANSWERED\n" +
        request.answers
          .map((answer) => `- (${answer.questionId}) ${answer.answer}`)
          .join("\n")
    );
  }

  if (request.knownPreferences.length > 0) {
    parts.push(
      "WHAT RUDDER HAS LEARNED ABOUT THEM (they approved storing this; do not ask about it again)\n" +
        request.knownPreferences.map((preference) => `- ${preference}`).join("\n")
    );
  }

  if (researchNotes) {
    parts.push(
      "RESEARCH NOTES (retrieved just now; the only URLs you may cite)\n" + researchNotes
    );
  } else if (budget.maxSearches === 0) {
    parts.push(
      "RESEARCH\nNo research was run for this decision — it does not justify the cost. Work from what you know and say plainly what you had to assume."
    );
  }

  parts.push(
    [
      "CONSTRAINTS FOR THIS RESPONSE",
      `- Questions you may return: ${budget.questionsRemaining}. ${
        budget.questionsRemaining === 0
          ? "You may not ask anything: decide with what you have, and state your assumptions."
          : "Return only questions that are genuinely worth the user's time; returning none is the better outcome."
      }`,
      `- Decision complexity: ${request.complexity}. Keep the analysis proportionate.`,
      `- The user's locale is ${request.locale}. Use their currency and units where relevant.`,
      request.strictSchema
        ? "- The previous response could not be parsed. Return only valid data in the required shape, and nothing else."
        : "",
    ]
      .filter(Boolean)
      .join("\n")
  );

  return parts.join("\n\n");
}

export function buildResearchPrompt(request: AnalysisRequest, budget: Budget): string {
  return [
    "Research the facts that would decide this. Do not analyse, compare or recommend — only gather.",
    "",
    `DECISION: ${request.prompt}`,
    request.answers.length > 0
      ? `ALREADY KNOWN: ${request.answers.map((a) => a.answer).join("; ")}`
      : "",
    "",
    `Use at most ${budget.maxSearches} searches. Prioritise current prices, specifications, availability and anything that has changed recently.`,
    "Then write a short brief: one bullet per fact, each with the figure or claim and the source title. If sources disagree, say so explicitly rather than picking one.",
    "If you could not verify something, say so. Do not fill gaps with what you remember.",
  ]
    .filter(Boolean)
    .join("\n");
}
