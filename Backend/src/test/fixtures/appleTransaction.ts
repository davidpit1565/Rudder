import { createPrivateKey, sign as cryptoSign } from "node:crypto";

/**
 * A synthetic, self-signed 3-certificate chain (root -> intermediate -> leaf,
 * all P-256/ES256) generated once with openssl for tests only -- it proves
 * the chain-walking and signature-verification *logic* is correct, never
 * that a real Apple-signed transaction verifies. `DECIDE_APPLE_ROOT_FINGERPRINT`
 * is overridden per test to this chain's own root, standing in for Apple's.
 */
export const ROOT_DER_B64 =
  "MIIBgzCCASmgAwIBAgIURxcVRFI8f/kw58OmacjZR+AJxvowCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMVGVzdCBSb290IENBMB4XDTI2MDkxNzAyNTA1OVoXDTM2MDkxNDAyNTA1OVowFzEVMBMGA1UEAwwMVGVzdCBSb290IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6WD2mm/7wv5RYQS/famTYI2ndxgvRkBV7WC5naKZ5wOwL3XEgkFMipLO6Oc/QKFMKSYCSRXV+IZcTqCFta2ajKNTMFEwHQYDVR0OBBYEFOp5snhXm08KNI300kF+I7/TYu+oMB8GA1UdIwQYMBaAFOp5snhXm08KNI300kF+I7/TYu+oMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgSnD0yIk8p+cos5zGlxyPr3pmX2cj/cDfxE6XGA5/0YQCIQDy8TyvMrRPUThJV1Y41buuluVSFrsnW4ZBZmkCk+jGIA==";
export const INTER_DER_B64 =
  "MIIBijCCATGgAwIBAgIUMyUgMwTAusFAh0crejJN9tGF/VowCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMVGVzdCBSb290IENBMB4XDTI2MDkxNzAyNTA1OVoXDTM2MDkxNDAyNTA1OVowHzEdMBsGA1UEAwwUVGVzdCBJbnRlcm1lZGlhdGUgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATyIEz3svn05tdiaBogrW3Aa96r1LdjzDhLRifhA/wwhFR6kd36EnT1+KNDlPdyYzSafk5Wd0BsyPgJJgvU7CAuo1MwUTAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRIt1v7+w6zdJyqohaN1p3vMK2YtDAfBgNVHSMEGDAWgBTqebJ4V5tPCjSN9NJBfiO/02LvqDAKBggqhkjOPQQDAgNHADBEAiBB3yLs+MX5ZsGPspzAfG0mwuzhr33MOhSlxV1lBRO0fQIgVT71aKQwSZxHHdhmAUfjCzI1P/42qTOTYvt2CX9FeTU=";
export const LEAF_DER_B64 =
  "MIIBhDCCASugAwIBAgIUa1mY/Jdw+eV2KrEgVoPGPAhmdAIwCgYIKoZIzj0EAwIwHzEdMBsGA1UEAwwUVGVzdCBJbnRlcm1lZGlhdGUgQ0EwHhcNMjYwOTE3MDI1MDU5WhcNMzYwOTE0MDI1MDU5WjAUMRIwEAYDVQQDDAlUZXN0IExlYWYwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASSrpnEKvtb1P6SINRVYDjMeQJM57nGrcYVWgyRQ5p0nkJCjs+UfXFZVZ91K55Xq3SrQdv4pb6ZtC+13p5x0LaFo1AwTjAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTBlzPqgPYHVSaDuaFaYj/rdNK5hzAfBgNVHSMEGDAWgBRIt1v7+w6zdJyqohaN1p3vMK2YtDAKBggqhkjOPQQDAgNHADBEAiAD9Cxj+yFyIgMXogSGx5hSFy2T2tjeETYu9t8byrRT0gIgWXc3SX99WQrwXtMM3kNAYdO2yty9pRtUND1pBaFCmPU=";
export const ROOT_FINGERPRINT = "DACFCC1E1B15A7E7F6046BA08020F662CD0A6EBB340D1FB15B69315A32FF42B5";
const LEAF_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgsi3q8l1lghA3HcG2
MVTxMoFxlxsiopmfShv/VEdg6I6hRANCAASSrpnEKvtb1P6SINRVYDjMeQJM57nG
rcYVWgyRQ5p0nkJCjs+UfXFZVZ91K55Xq3SrQdv4pb6ZtC+13p5x0LaF
-----END PRIVATE KEY-----`;

export const BUNDLE_ID = "com.rudder.app";
export const PRODUCT_IDS = ["com.rudder.app.pro.monthly", "com.rudder.app.pro.annual"] as const;

export function base64Url(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input;
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function buildJws(payload: Record<string, unknown>, opts: { chain?: string[] } = {}): string {
  const header = { alg: "ES256", x5c: opts.chain ?? [LEAF_DER_B64, INTER_DER_B64, ROOT_DER_B64] };
  const headerPart = base64Url(JSON.stringify(header));
  const payloadPart = base64Url(JSON.stringify(payload));
  const signingInput = `${headerPart}.${payloadPart}`;
  const key = createPrivateKey(LEAF_KEY_PEM);
  const signature = cryptoSign("sha256", Buffer.from(signingInput, "utf8"), { key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${base64Url(signature)}`;
}

export function validPayload(overrides: Record<string, unknown> = {}) {
  return {
    bundleId: BUNDLE_ID,
    productId: "com.rudder.app.pro.monthly",
    type: "Auto-Renewable Subscription",
    expiresDate: Date.now() + 30 * 24 * 60 * 60 * 1000,
    ...overrides,
  };
}

/** Runs `fn` with DECIDE_APPLE_ROOT_FINGERPRINT pointed at this fixture's own
 * synthetic root, standing in for the real pinned Apple root, and restores
 * whatever was there before as soon as `fn` returns.
 *
 * Deliberately synchronous, even though callers may pass something that
 * itself returns a Promise (e.g. `() => handle(request)`): the code that
 * actually reads this env var (verifyAppStoreTransaction, called from
 * handler.ts) runs synchronously before that returned promise's first
 * `await`, so the env var only needs to be in place for the synchronous call
 * to `fn()` itself, not for however long the promise it returns takes to
 * settle. */
export function withTestAppleRoot<T>(fn: () => T): T {
  const previous = process.env.DECIDE_APPLE_ROOT_FINGERPRINT;
  process.env.DECIDE_APPLE_ROOT_FINGERPRINT = ROOT_FINGERPRINT;
  try {
    return fn();
  } finally {
    if (previous === undefined) delete process.env.DECIDE_APPLE_ROOT_FINGERPRINT;
    else process.env.DECIDE_APPLE_ROOT_FINGERPRINT = previous;
  }
}
