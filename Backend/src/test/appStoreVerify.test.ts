import { strict as assert } from "node:assert";
import test from "node:test";
import { createPrivateKey, sign as cryptoSign } from "node:crypto";
import { verifyAppStoreTransaction, APPLE_ROOT_G3_FINGERPRINT } from "../appStoreVerify.js";

/**
 * A synthetic, self-signed 3-certificate chain (root -> intermediate -> leaf,
 * all P-256/ES256) generated once with openssl for these tests only -- it
 * proves the chain-walking and signature-verification *logic* is correct,
 * never that a real Apple-signed transaction verifies. `DECIDE_APPLE_ROOT_FINGERPRINT`
 * is overridden per test to this chain's own root, standing in for Apple's.
 */
const ROOT_DER_B64 =
  "MIIBgzCCASmgAwIBAgIURxcVRFI8f/kw58OmacjZR+AJxvowCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMVGVzdCBSb290IENBMB4XDTI2MDkxNzAyNTA1OVoXDTM2MDkxNDAyNTA1OVowFzEVMBMGA1UEAwwMVGVzdCBSb290IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6WD2mm/7wv5RYQS/famTYI2ndxgvRkBV7WC5naKZ5wOwL3XEgkFMipLO6Oc/QKFMKSYCSRXV+IZcTqCFta2ajKNTMFEwHQYDVR0OBBYEFOp5snhXm08KNI300kF+I7/TYu+oMB8GA1UdIwQYMBaAFOp5snhXm08KNI300kF+I7/TYu+oMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgSnD0yIk8p+cos5zGlxyPr3pmX2cj/cDfxE6XGA5/0YQCIQDy8TyvMrRPUThJV1Y41buuluVSFrsnW4ZBZmkCk+jGIA==";
const INTER_DER_B64 =
  "MIIBijCCATGgAwIBAgIUMyUgMwTAusFAh0crejJN9tGF/VowCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMVGVzdCBSb290IENBMB4XDTI2MDkxNzAyNTA1OVoXDTM2MDkxNDAyNTA1OVowHzEdMBsGA1UEAwwUVGVzdCBJbnRlcm1lZGlhdGUgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATyIEz3svn05tdiaBogrW3Aa96r1LdjzDhLRifhA/wwhFR6kd36EnT1+KNDlPdyYzSafk5Wd0BsyPgJJgvU7CAuo1MwUTAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRIt1v7+w6zdJyqohaN1p3vMK2YtDAfBgNVHSMEGDAWgBTqebJ4V5tPCjSN9NJBfiO/02LvqDAKBggqhkjOPQQDAgNHADBEAiBB3yLs+MX5ZsGPspzAfG0mwuzhr33MOhSlxV1lBRO0fQIgVT71aKQwSZxHHdhmAUfjCzI1P/42qTOTYvt2CX9FeTU=";
const LEAF_DER_B64 =
  "MIIBhDCCASugAwIBAgIUa1mY/Jdw+eV2KrEgVoPGPAhmdAIwCgYIKoZIzj0EAwIwHzEdMBsGA1UEAwwUVGVzdCBJbnRlcm1lZGlhdGUgQ0EwHhcNMjYwOTE3MDI1MDU5WhcNMzYwOTE0MDI1MDU5WjAUMRIwEAYDVQQDDAlUZXN0IExlYWYwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASSrpnEKvtb1P6SINRVYDjMeQJM57nGrcYVWgyRQ5p0nkJCjs+UfXFZVZ91K55Xq3SrQdv4pb6ZtC+13p5x0LaFo1AwTjAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTBlzPqgPYHVSaDuaFaYj/rdNK5hzAfBgNVHSMEGDAWgBRIt1v7+w6zdJyqohaN1p3vMK2YtDAKBggqhkjOPQQDAgNHADBEAiAD9Cxj+yFyIgMXogSGx5hSFy2T2tjeETYu9t8byrRT0gIgWXc3SX99WQrwXtMM3kNAYdO2yty9pRtUND1pBaFCmPU=";
const ROOT_FINGERPRINT = "DACFCC1E1B15A7E7F6046BA08020F662CD0A6EBB340D1FB15B69315A32FF42B5";
const LEAF_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgsi3q8l1lghA3HcG2
MVTxMoFxlxsiopmfShv/VEdg6I6hRANCAASSrpnEKvtb1P6SINRVYDjMeQJM57nG
rcYVWgyRQ5p0nkJCjs+UfXFZVZ91K55Xq3SrQdv4pb6ZtC+13p5x0LaF
-----END PRIVATE KEY-----`;

const BUNDLE_ID = "com.rudder.app";
const PRODUCT_IDS = ["com.rudder.app.pro.monthly", "com.rudder.app.pro.annual"] as const;

function base64Url(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input;
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function buildJws(payload: Record<string, unknown>, opts: { chain?: string[] } = {}): string {
  const header = { alg: "ES256", x5c: opts.chain ?? [LEAF_DER_B64, INTER_DER_B64, ROOT_DER_B64] };
  const headerPart = base64Url(JSON.stringify(header));
  const payloadPart = base64Url(JSON.stringify(payload));
  const signingInput = `${headerPart}.${payloadPart}`;
  const key = createPrivateKey(LEAF_KEY_PEM);
  const signature = cryptoSign("sha256", Buffer.from(signingInput, "utf8"), { key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${base64Url(signature)}`;
}

function validPayload(overrides: Record<string, unknown> = {}) {
  return {
    bundleId: BUNDLE_ID,
    productId: "com.rudder.app.pro.monthly",
    type: "Auto-Renewable Subscription",
    expiresDate: Date.now() + 30 * 24 * 60 * 60 * 1000,
    ...overrides,
  };
}

function verify(jws: string, now?: number) {
  const previous = process.env.DECIDE_APPLE_ROOT_FINGERPRINT;
  process.env.DECIDE_APPLE_ROOT_FINGERPRINT = ROOT_FINGERPRINT;
  try {
    return verifyAppStoreTransaction(jws, { bundleId: BUNDLE_ID, productIds: PRODUCT_IDS, now });
  } finally {
    if (previous === undefined) delete process.env.DECIDE_APPLE_ROOT_FINGERPRINT;
    else process.env.DECIDE_APPLE_ROOT_FINGERPRINT = previous;
  }
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
