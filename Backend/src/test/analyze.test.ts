import { strict as assert } from "node:assert";
import test from "node:test";
import { extractJsonObject } from "../analyze.js";

test("plain JSON with no wrapping passes through unchanged", () => {
  const text = '{"a":1}';
  assert.equal(extractJsonObject(text), text);
});

test("a code fence wrapping the whole response is stripped", () => {
  const text = '```json\n{"a":1}\n```';
  assert.equal(extractJsonObject(text), '{"a":1}');
});

test("a code fence is found even with prose before it", () => {
  // Confirmed live: adding research notes to the prompt made the model more
  // likely to add a line of commentary first, despite being told not to.
  const text = 'Here is the analysis based on the research:\n```json\n{"a":1}\n```';
  assert.equal(extractJsonObject(text), '{"a":1}');
});

test("stray prose with no fence falls back to the outermost braces", () => {
  const text = 'Sure, here you go: {"a":1} -- let me know if you need anything else.';
  assert.equal(extractJsonObject(text), '{"a":1}');
});
