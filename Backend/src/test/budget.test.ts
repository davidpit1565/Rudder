import { strict as assert } from "node:assert";
import test from "node:test";
import { budgetFor, PREMIUM_MODEL, STANDARD_MODEL } from "../budget.js";
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

test("a complex decision runs on the premium model, within the same operational budget as medium", () => {
  const budget = budgetFor(
    makeRequest({ complexity: "complex", researchLevel: "deep", maximumResearchCalls: 6, questionCeiling: 5 })
  );
  assert.equal(budget.effort, "medium");
  assert.equal(budget.maxSearches, 2);
  assert.equal(budget.maxTokens, 16000);
  assert.equal(budget.questionsRemaining, 5);
  assert.equal(budget.model, PREMIUM_MODEL);
});

test("simple and medium decisions run on the standard model, free and unlimited", () => {
  for (const complexity of ["simple", "medium"] as const) {
    const budget = budgetFor(makeRequest({ complexity }));
    assert.equal(budget.model, STANDARD_MODEL);
  }
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
