import { X509Certificate, createHash, verify as cryptoVerify } from "node:crypto";

/**
 * Independent, server-side proof that a request comes from a paying Pro
 * subscriber -- never trust from the client alone.
 *
 * StoreKit 2 already verifies a transaction's signature on-device before
 * handing the app a `.verified` case, but that verification only convinces
 * the *app*. Nothing stops a modified client, or a caller that skips the app
 * entirely, from just claiming `isPro: true`. The only trustworthy signal is
 * the transaction's own signed JWS (`VerificationResult.jwsRepresentation`),
 * re-verified here against Apple's public root of trust -- the same
 * "re-validated here rather than trusted" principle `analyze.ts` already
 * applies to the model's own JSON output.
 *
 * Fails closed on anything unexpected: a malformed token, an unknown signer,
 * an expired or revoked subscription, or a bundle/product mismatch all
 * return `null` (not Pro), never throw. `handler.ts` treats `null` the same
 * as "no proof offered" and falls back to the Free quota -- so the worst
 * case of a bug here is a paying user being held to the Free limit (visible,
 * recoverable), never the server granting unmetered access it can't afford.
 *
 * NOT verified from this environment: there is no Xcode/macOS or real Apple
 * Developer transaction available here, so this has been exercised only
 * against a synthetic certificate chain built for the unit tests
 * (`test/appStoreVerify.test.ts`) -- never against a real StoreKit
 * transaction end to end. Treat that as an open item for the Product
 * Reality Test, the same way App Attest (`attest.ts`) is an open item.
 */

export interface VerifiedTransaction {
  productId: string;
  expiresAt: number;
}

/** Apple Root CA - G3, SHA-256 fingerprint of the DER certificate. Public
 * information, safe to hardcode. Confirmed against the certificate actually
 * served at https://www.apple.com/certificateauthority/AppleRootCA-G3.cer at
 * the time this was written (`openssl x509 -inform DER -noout -fingerprint
 * -sha256`) -- re-check it if Apple ever rotates this root. A mismatch fails
 * closed (every transaction rejected), it does not fail open. Overridable
 * for testing via DECIDE_APPLE_ROOT_FINGERPRINT. */
export const APPLE_ROOT_G3_FINGERPRINT =
  "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179";
const DEFAULT_APPLE_ROOT_FINGERPRINT = APPLE_ROOT_G3_FINGERPRINT;

function trustedRootFingerprint(): string {
  return (process.env.DECIDE_APPLE_ROOT_FINGERPRINT ?? DEFAULT_APPLE_ROOT_FINGERPRINT).toUpperCase();
}

function base64UrlDecode(segment: string): Buffer {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(padded, "base64");
}

interface JwsHeader {
  alg?: string;
  x5c?: string[];
}

/** Verifies the certificate chain embedded in the JWS header (`x5c`) up to
 * the pinned Apple root, then the JWS signature itself, then the payload's
 * business rules. Returns null on any failure. */
export function verifyAppStoreTransaction(jws: string, options: { bundleId: string; productIds: readonly string[]; now?: number }): VerifiedTransaction | null {
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return null;
    const [headerPart, payloadPart, signaturePart] = parts as [string, string, string];

    const header = JSON.parse(base64UrlDecode(headerPart).toString("utf8")) as JwsHeader;
    if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 2) return null;

    const chain = header.x5c.map((der) => new X509Certificate(Buffer.from(der, "base64")));

    // Each certificate must actually be signed by the next one in the chain.
    for (let i = 0; i < chain.length - 1; i++) {
      const cert = chain[i]!;
      const issuer = chain[i + 1]!;
      if (!cert.checkIssued(issuer) || !cert.verify(issuer.publicKey)) return null;
    }

    // The chain must terminate at Apple's pinned root -- either because the
    // last certificate presented *is* that root, or because it is signed by
    // it; either way its own fingerprint is what we actually trust.
    const last = chain[chain.length - 1]!;
    if (fingerprint(last) !== trustedRootFingerprint()) return null;

    const leaf = chain[0]!;
    const signingInput = `${headerPart}.${payloadPart}`;
    const signature = base64UrlDecode(signaturePart);
    const signatureValid = cryptoVerify(
      "sha256",
      Buffer.from(signingInput, "utf8"),
      { key: leaf.publicKey, dsaEncoding: "ieee-p1363" },
      signature
    );
    if (!signatureValid) return null;

    const payload = JSON.parse(base64UrlDecode(payloadPart).toString("utf8")) as Record<string, unknown>;
    return checkClaims(payload, options);
  } catch {
    return null;
  }
}

function fingerprint(cert: X509Certificate): string {
  return createHash("sha256").update(cert.raw).digest("hex").toUpperCase();
}

function checkClaims(
  payload: Record<string, unknown>,
  options: { bundleId: string; productIds: readonly string[]; now?: number }
): VerifiedTransaction | null {
  const now = options.now ?? Date.now();

  if (payload["bundleId"] !== options.bundleId) return null;

  const productId = payload["productId"];
  if (typeof productId !== "string" || !options.productIds.includes(productId)) return null;

  if (payload["type"] !== "Auto-Renewable Subscription") return null;

  // A revoked transaction (refund, family-sharing removal, chargeback) is
  // never valid, however far in the future expiresDate claims to be.
  if (payload["revocationDate"] != null) return null;

  const expiresAt = payload["expiresDate"];
  if (typeof expiresAt !== "number" || expiresAt <= now) return null;

  return { productId, expiresAt };
}
