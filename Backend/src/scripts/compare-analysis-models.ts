/**
 * Compares candidate Groq-hosted models for the ANALYSIS step against the
 * one currently in production (`GROQ_MODEL` in budget.ts), on a handful of
 * representative decisions -- same prompt construction and schema
 * validation as production, via the real `analyseWithGroq()`. Research is
 * skipped (`researchLevel: "none"`) since this isolates the analysis call
 * itself; the research step stays on Gemini regardless of what this finds.
 *
 * Deliberately Groq-only, not Claude: this is for finding a better model
 * within the account already being billed for Groq, not for evaluating a
 * new provider.
 *
 * Requires GROQ_API_KEY in the environment -- the same key already used in
 * production, no new account or billing relationship. Each run makes a
 * small number of real, billed calls against that account; keep
 * CANDIDATE_MODELS and TEST_DECISIONS short while exploring.
 *
 * Model IDs below are a starting point, not guaranteed current -- Groq's
 * catalog changes. Check https://console.groq.com/docs/models for what is
 * actually available before running, and edit CANDIDATE_MODELS to match.
 *
 * Usage:
 *   GROQ_API_KEY=... npm run build && node dist/scripts/compare-analysis-models.js
 */
import OpenAI from "openai";
import { analyseWithGroq, extractJsonObject } from "../analyze.js";
import { budgetFor, GROQ_MODEL } from "../budget.js";
import { DecisionResponseSchema, type AnalysisRequest } from "../schema.js";

/** Edit this list after checking Groq's current model catalog. */
const CANDIDATE_MODELS = [
  GROQ_MODEL, // the current production choice, included as the baseline
  // "llama-3.3-70b-versatile",
  // "meta-llama/llama-4-scout-17b-16e-instruct",
];

/** No research, so this isolates the analysis call itself. */
function testDecision(overrides: Partial<AnalysisRequest>): AnalysisRequest {
  return {
    schemaVersion: 1,
    prompt: "",
    answers: [],
    knownPreferences: [],
    category: "other",
    complexity: "medium",
    researchLevel: "none",
    maximumResearchCalls: 0,
    maximumSources: 0,
    questionsAlreadyAsked: 0,
    questionCeiling: 0,
    strictSchema: false,
    locale: "en_US",
    ...overrides,
  };
}

const TEST_DECISIONS: AnalysisRequest[] = [
  testDecision({
    prompt: "MacBook Air or MacBook Pro for a university student who mostly writes essays and browses the web?",
    category: "technology",
    complexity: "simple",
  }),
  testDecision({
    prompt: "Should I take a new job offer with a 15% pay rise but a worse commute, or stay where I am?",
    category: "career",
    complexity: "medium",
  }),
  testDecision({
    prompt: "Should our 4-person startup move from a monolith to microservices before our Series A, given we have no dedicated DevOps engineer?",
    category: "technology",
    complexity: "complex",
  }),
];

/** Comfortably under Vercel's 60s ceiling, but this runs standalone so it
 * does not need to share the pipeline deadline production calls do. */
const PER_CALL_TIMEOUT_MS = 55_000;

interface Result {
  model: string;
  prompt: string;
  latencyMs: number;
  validJson: boolean;
  matchesSchema: boolean;
  error?: string;
}

async function runOne(client: OpenAI, model: string, request: AnalysisRequest): Promise<Result> {
  const budget = { ...budgetFor(request), model };
  const started = Date.now();
  const promptPreview = request.prompt.slice(0, 40);
  try {
    const text = await analyseWithGroq(client, request, budget, null, PER_CALL_TIMEOUT_MS);
    const latencyMs = Date.now() - started;
    let validJson = false;
    let matchesSchema = false;
    try {
      const parsed = JSON.parse(extractJsonObject(text));
      validJson = true;
      matchesSchema = DecisionResponseSchema.safeParse(parsed).success;
    } catch {
      // validJson stays false
    }
    return { model, prompt: promptPreview, latencyMs, validJson, matchesSchema };
  } catch (error) {
    return {
      model,
      prompt: promptPreview,
      latencyMs: Date.now() - started,
      validJson: false,
      matchesSchema: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function main(): Promise<void> {
  const apiKey = process.env.GROQ_API_KEY;
  if (!apiKey) {
    console.error("GROQ_API_KEY is not set -- this script makes real calls against your existing Groq account and needs it.");
    process.exitCode = 1;
    return;
  }
  const client = new OpenAI({ apiKey, baseURL: "https://api.groq.com/openai/v1" });

  const results: Result[] = [];
  for (const model of CANDIDATE_MODELS) {
    for (const request of TEST_DECISIONS) {
      process.stdout.write(`Running ${model} on "${request.prompt.slice(0, 40)}..."\n`);
      results.push(await runOne(client, model, request));
    }
  }

  console.log("\nResults:\n");
  console.log(
    "model".padEnd(30),
    "prompt".padEnd(42),
    "ms".padEnd(8),
    "valid JSON".padEnd(11),
    "matches schema".padEnd(15),
    "error"
  );
  for (const r of results) {
    console.log(
      r.model.padEnd(30),
      r.prompt.padEnd(42),
      String(r.latencyMs).padEnd(8),
      (r.validJson ? "yes" : "no").padEnd(11),
      (r.matchesSchema ? "yes" : "no").padEnd(15),
      r.error ?? ""
    );
  }
}

main();
