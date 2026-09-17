import { strict as assert } from "node:assert";
import test from "node:test";
import { checkDeepDecisionQuota, refundDeepDecisionQuota, resetDeepDecisionQuota } from "../quota.js";

test.beforeEach(() => resetDeepDecisionQuota());

test("the first N spends within the limit are allowed", async () => {
  const now = Date.now();
  for (let i = 1; i <= 3; i++) {
    const decision = await checkDeepDecisionQuota("install-a", 3, now);
    assert.equal(decision.allowed, true, `spend ${i} should be allowed`);
    assert.equal(decision.used, i);
  }
});

test("a spend beyond the limit is refused", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-b", 3, now);
  await checkDeepDecisionQuota("install-b", 3, now);
  await checkDeepDecisionQuota("install-b", 3, now);
  const fourth = await checkDeepDecisionQuota("install-b", 3, now);
  assert.equal(fourth.allowed, false);
  assert.equal(fourth.used, 4);
});

test("different installs never share a bucket", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-c", 1, now);
  const other = await checkDeepDecisionQuota("install-d", 1, now);
  assert.equal(other.allowed, true);
});

test("a refund gives back exactly one spend", async () => {
  const now = Date.now();
  await checkDeepDecisionQuota("install-e", 1, now);
  await refundDeepDecisionQuota("install-e", now);
  const again = await checkDeepDecisionQuota("install-e", 1, now);
  assert.equal(again.allowed, true, "the refunded spend should be available again");
});

test("a new calendar month starts a fresh count", async () => {
  const monthOne = Date.UTC(2026, 0, 15);
  const monthTwo = Date.UTC(2026, 1, 3);
  await checkDeepDecisionQuota("install-f", 1, monthOne);
  const nextMonth = await checkDeepDecisionQuota("install-f", 1, monthTwo);
  assert.equal(nextMonth.allowed, true);
});
