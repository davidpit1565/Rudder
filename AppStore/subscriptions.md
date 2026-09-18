# Subscription setup

## Product identifiers

These are compiled into `SubscriptionService.ProductID` and must match App Store
Connect exactly:

| Product | Identifier | Duration |
|---|---|---|
| RUDDER Pro Monthly | `com.rudder.app.pro.monthly` | 1 month |
| RUDDER Pro Annual | `com.rudder.app.pro.annual` | 1 year |

Both belong to one subscription group (**RUDDER Pro**) so a user can move between
them without holding two subscriptions.

## Pricing

Nothing is hard-coded. The app reads `displayPrice` and the period from StoreKit
and computes the annual saving from the two live prices, so a price change in App
Store Connect propagates without a build. Starting point:

| Plan | Price |
|---|---|
| Monthly | €8.99 |
| Annual | €49.99 |

That is roughly 54% off the monthly rate over a year — the paywall shows whatever
the real numbers work out to, so it can never overstate the saving.

No lifetime plan, and no weekly plan. A weekly price on a decision tool reads as
a trap, and a lifetime plan on a product with a per-decision serving cost is one.

## Metadata per product

- **Display name:** Monthly / Annual
- **Description:** "Unlimited deep decisions, Decision Memory, outcome learning
  and your full history."
- **Review screenshot:** the paywall, showing both plans and Restore Purchases.

## Introductory offers

Both products offer a **7-day free trial** (`introductoryOffer`, `paymentMode:
free`, `subscriptionPeriod: P1W`, `numberOfPeriods: 1` — set per product in App
Store Connect; mirrored locally in `Config/Rudder.storekit` for testing).

This replaces a recurring monthly free allowance as the try-before-you-buy
mechanism: Free still always allows one real, finished decision (see
`FeatureAccess.allowsDeepDecision`), but beyond that there is no standing
monthly quota of deep decisions — `DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH` /
`FeatureAccess.freeDeepDecisionsPerMonth` are both `0`. A recurring allowance,
even a small one, is something a casual user can settle into permanently; a
trial has a natural end and converts into a real subscription unless
cancelled.

The paywall reads the trial's real terms straight from StoreKit
(`Product.SubscriptionInfo.introductoryOffer`) and each Apple Account's actual
eligibility (`isEligibleForIntroOffer`) — it shows "N days free, then
$price/period" next to the plan, and only when this Apple Account hasn't
already used the offer. No countdown, no invented scarcity, and no
hard-coded trial length — if App Store Connect's offer ever changes, the
paywall reflects it automatically.

## What App Review needs to see

- The paywall is reachable from Profile ▸ Your plan ▸ See Pro, without spending a
  free decision first.
- **Restore Purchases** is on the paywall and in Profile.
- Subscription terms, Privacy Policy and Terms of Use are linked from the paywall.
- The free trial's real terms (length, and what it costs after) shown on the
  paywall for a reviewer account that hasn't used it yet.
- Free users can complete a real decision. Reviewers must never hit a wall before
  seeing the product work — the first decision is always allowed, regardless of
  trial eligibility.

## Local testing

`Config/Rudder.storekit` mirrors the two products and is wired into the shared
scheme, so Run and Test exercise purchase, restore, cancellation and expiry in the
simulator without App Store Connect. Entitlement is always read back from
StoreKit — there is no debug switch that grants Pro, by design.
