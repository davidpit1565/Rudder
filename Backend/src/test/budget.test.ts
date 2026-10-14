import { strict as assert } from "node:assert";
import test from "node:test";
import { budgetFor, STANDARD_MODEL, GROQ_MODEL } from "../budget.js";
import { AnalysisRequestSchema, SCHEMA_VERSION } from "../schema.js";

function makeRequest(overrides: Record<string, unknown> = {}) {
  return AnalysisRequestSchema.parse({
    schemaVersion: SCHEMA_VERSION,
    prompt: "Something to decide",
    category: "other",
    complexity: "medium",
    researchLevel: "light",
    maximumResearchCalls: 2,
    maximumSources: 4,
    questionsAlreadyAsked: 0,
    questionCeiling: 3,
    ...overrides,
  });
}

test("a trivial decision buys no research and the cheapest effort", () => {
  const budget = budgetFor(
    makeRequest({ complexity: "simple", researchLevel: "none", maximumResearchCalls: 0 })
  );
  assert.equal(budget.maxSearches, 0);
  assert.equal(budget.effort, "low");
  assert.equal(budget.model, STANDARD_MODEL);
});

test("a complex decision gets the full research/token budget, analysed on Groq", () => {
  // PREMIUM_MODEL is unused for now -- confirmed live, three times, that it
  // doesn't complete within Vercel's 60s ceiling even at the lowest effort
  // and zero research. See the comment on PREMIUM_MODEL/GROQ_MODEL in budget.ts.
  const budget = budgetFor(
    makeRequest({ complexity: "complex", researchLevel: "deep", maximumResearchCalls: 6, questionCeiling: 5 })
  );
  assert.equal(budget.effort, "medium");
  assert.equal(budget.maxSearches, 2);
  assert.equal(budget.maxTokens, 16000);
  assert.equal(budget.questionsRemaining, 5);
  assert.equal(budget.provider, "groq");
  assert.equal(budget.model, GROQ_MODEL);
  // Research always runs on Gemini, regardless of which provider analyses.
  assert.equal(budget.researchModel, STANDARD_MODEL);
});

test("simple and medium decisions are both analysed on Gemini's standard model; only complex moves to Groq", () => {
  for (const complexity of ["simple", "medium"] as const) {
    const budget = budgetFor(makeRequest({ complexity }));
    assert.equal(budget.provider, "gemini");
    assert.equal(budget.model, STANDARD_MODEL);
  }
  const complexBudget = budgetFor(makeRequest({ complexity: "complex" }));
  assert.equal(complexBudget.provider, "groq");
  assert.equal(complexBudget.model, GROQ_MODEL);
});

test("the app's cap wins when it is lower than the level's", () => {
  const budget = budgetFor(makeRequest({ researchLevel: "deep", maximumResearchCalls: 1 }));
  assert.equal(budget.maxSearches, 1);
});

test("questions already asked come out of the remaining budget", () => {
  const budget = budgetFor(makeRequest({ questionCeiling: 3, questionsAlreadyAsked: 3 }));
  assert.equal(budget.questionsRemaining, 0);
});

test("every budget stays inside its ceiling", () => {
  for (const complexity of ["simple", "medium", "complex"] as const) {
    for (const researchLevel of ["none", "light", "deep"] as const) {
      const budget = budgetFor(
        makeRequest({ complexity, researchLevel, maximumResearchCalls: 8, questionCeiling: 5 })
      );
      assert.ok(budget.maxSearches <= 2);
      assert.ok(budget.questionsRemaining <= 5);
      assert.ok(budget.maxTokens <= 16000);
    }
  }
});
