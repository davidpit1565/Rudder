import * as z from "zod/v4";
import type OpenAI from "openai";
import { APIConnectionTimeoutError } from "openai";
import { FollowUpResponseSchema, type FollowUpRequest } from "./schema.js";
import { GROQ_MODEL } from "./budget.js";
import { extractJsonObject } from "./analyze.js";

export class FollowUpError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "FollowUpError";
  }
}

/**
 * Well under Vercel's 60s ceiling, and far tighter than a full analysis's
 * PIPELINE_DEADLINE_MS: a follow-up answers from context already computed,
 * with no research call, so there is no reason for it to run anywhere near
 * as long. See analyze.ts's PIPELINE_DEADLINE_MS for the live-confirmed
 * reasoning behind bounding every upstream call explicitly rather than
 * trusting the SDK's own timeout.
 */
const FOLLOWUP_TIMEOUT_MS = 20_000;

const SYSTEM_PROMPT = `You are RUDDER, answering a follow-up question about a decision you already finished analysing for this user.

You are not starting a new analysis. Answer only from the original decision, its recommendation, and the conversation history given to you -- never invent facts, prices or specifications you were not given.

If answering well would require looking up current, external facts you were not given and cannot verify, set needsResearch to true and write a suggestedNewDecisionPrompt the user could start as a fresh decision, including enough context from the original one that it stands alone. Otherwise leave both null/false.

If the user's answer reveals a preference worth remembering for future decisions (not just for this one), set durablePreference to a short, behavioural, user-facing sentence, e.g. "You prioritize flexibility over price." Never an identity claim, never about health, politics, religion or any protected characteristic. Most answers do not reveal this -- leave it null unless it is genuinely clear.

Keep the answer direct, conversational and short. Plain, calm, specific. No exclamation marks, no emoji, no filler. Address the user as "you".

Respond with exactly one JSON object and nothing else: no markdown code fence, no text before or after it. The object must validate against this JSON Schema:

${JSON.stringify(z.toJSONSchema(FollowUpResponseSchema))}`;

function buildUserMessage(request: FollowUpRequest): string {
  const parts: string[] = [];

  parts.push(`THE ORIGINAL DECISION\n${request.originalPrompt}`);
  parts.push(`WHAT WAS DECIDED\n${request.decisionContext}`);

  if (request.history.length > 0) {
    parts.push(
      "EARLIER FOLLOW-UP QUESTIONS IN THIS CONVERSATION\n" +
        request.history.map((exchange) => `Q: ${exchange.question}\nA: ${exchange.answer}`).join("\n\n")
    );
  }

  parts.push(`NEW QUESTION\n${request.question}`);
  parts.push(`The user's locale is ${request.locale}. Use their currency and units where relevant.`);

  return parts.join("\n\n");
}

/** Server-side only, never sent to the client -- same reasoning as
 * throwForUpstreamError in analyze.ts, duplicated rather than shared since
 * the two error types (AnalysisError/FollowUpError) are intentionally
 * distinct. */
function throwForUpstreamError(error: unknown): never {
  const status = typeof (error as { status?: unknown })?.status === "number"
    ? (error as { status: number }).status
    : undefined;
  const isTimeout =
    (error as { name?: unknown })?.name === "RequestTimeoutError" || error instanceof APIConnectionTimeoutError;
  console.error("Groq API error (followup)", {
    name: error instanceof Error ? error.name : typeof error,
    status,
    isTimeout,
    message: error instanceof Error ? error.message : String(error),
  });

  if (status === 429) {
    throw new FollowUpError("rate_limited_upstream", 429);
  }
  if (status === 503 || status === 504 || status === 408 || isTimeout) {
    throw new FollowUpError("upstream_unavailable", 503);
  }
  if (status !== undefined) {
    throw new FollowUpError("upstream_error", 502);
  }
  throw new FollowUpError("followup_failed", 502);
}

/** A single short, cheap call: answers a question about an already-finished
 * decision. No research, no multi-step pipeline -- see SYSTEM_PROMPT. */
export async function followUp(client: OpenAI, request: FollowUpRequest): Promise<z.infer<typeof FollowUpResponseSchema>> {
  let completion;
  try {
    completion = await client.chat.completions.create(
      {
        model: GROQ_MODEL,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: buildUserMessage(request) },
        ],
        reasoning_effort: "low",
        max_completion_tokens: 2000,
      },
      { timeout: FOLLOWUP_TIMEOUT_MS }
    );
  } catch (error) {
    throwForUpstreamError(error);
  }

  const choice = completion.choices[0];
  if (choice?.finish_reason === "content_filter") {
    throw new FollowUpError("refused", 422);
  }

  const text = choice?.message?.content ?? "";
  let rawOutput: unknown;
  try {
    rawOutput = JSON.parse(extractJsonObject(text));
  } catch {
    console.error("Groq follow-up response was not valid JSON", { textLength: text.length });
    throw new FollowUpError("unparseable_response", 502);
  }

  const parsed = FollowUpResponseSchema.safeParse(rawOutput);
  if (!parsed.success) {
    console.error("Groq follow-up response was valid JSON but failed the contract", {
      issues: parsed.error.issues.slice(0, 5).map((issue) => ({ path: issue.path.join("."), message: issue.message })),
    });
    throw new FollowUpError("unparseable_response", 502);
  }

  return parsed.data;
}
