import { strict as assert } from "node:assert";
import test from "node:test";
import { verifyAppStoreTransaction, APPLE_ROOT_G3_FINGERPRINT } from "../appStoreVerify.js";
import {
  BUNDLE_ID,
  PRODUCT_IDS,
  LEAF_DER_B64,
  INTER_DER_B64,
  base64Url,
  buildJws,
  validPayload,
  withTestAppleRoot,
} from "./fixtures/appleTransaction.js";

function verify(jws: string, now?: number) {
  return withTestAppleRoot(() => verifyAppStoreTransaction(jws, { bundleId: BUNDLE_ID, productIds: PRODUCT_IDS, now }));
}

test("a validly signed transaction, from the pinned root, verifies", () => {
  const jws = buildJws(validPayload());
  const result = verify(jws);
  assert.ok(result);
  assert.equal(result!.productId, "com.rudder.app.pro.monthly");
});

test("a bundle ID that doesn't match this app is rejected", () => {
  const jws = buildJws(validPayload({ bundleId: "com.someone.else" }));
  assert.equal(verify(jws), null);
});

test("a product ID outside the Pro set is rejected", () => {
  const jws = buildJws(validPayload({ productId: "com.rudder.app.something.else" }));
  assert.equal(verify(jws), null);
});

test("an expired subscription is rejected", () => {
  const jws = buildJws(validPayload({ expiresDate: Date.now() - 1000 }));
  assert.equal(verify(jws), null);
});

test("a revoked transaction is rejected even with a future expiresDate", () => {
  const jws = buildJws(validPayload({ revocationDate: Date.now() - 1000 }));
  assert.equal(verify(jws), null);
});

test("a transaction that isn't an auto-renewable subscription is rejected", () => {
  const jws = buildJws(validPayload({ type: "Non-Consumable" }));
  assert.equal(verify(jws), null);
});

test("a tampered payload (signature no longer matches) is rejected", () => {
  const jws = buildJws(validPayload());
  const [h, p, s] = jws.split(".");
  const forged = JSON.parse(Buffer.from(p!, "base64").toString("utf8"));
  forged.productId = "com.rudder.app.pro.annual";
  const forgedPayload = base64Url(JSON.stringify(forged));
  assert.equal(verify(`${h}.${forgedPayload}.${s}`), null);
});

test("a chain that doesn't terminate at the pinned root is rejected", () => {
  // Same leaf+intermediate, but the chain is missing the trusted root entirely --
  // its last certificate (the intermediate) doesn't match the pinned fingerprint.
  const jws = buildJws(validPayload(), { chain: [LEAF_DER_B64, INTER_DER_B64] });
  assert.equal(verify(jws), null);
});

test("a malformed token (wrong number of segments) is rejected without throwing", () => {
  assert.equal(verify("not-a-jws"), null);
});

test("an empty x5c chain is rejected without throwing", () => {
  const header = base64Url(JSON.stringify({ alg: "ES256", x5c: [] }));
  const payload = base64Url(JSON.stringify(validPayload()));
  assert.equal(verify(`${header}.${payload}.sig`), null);
});

test("the hardcoded Apple Root CA - G3 fingerprint matches the certificate Apple actually serves", () => {
  // Confirmed by downloading https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
  // and running `openssl x509 -inform DER -noout -fingerprint -sha256` on it.
  assert.equal(APPLE_ROOT_G3_FINGERPRINT, "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179");
});
