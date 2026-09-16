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

None at launch. If one is added later, the paywall must show the real terms
(what it costs after, and when) next to the offer — the code has no mechanism for
a countdown or a scarcity claim, and should not grow one.

## What App Review needs to see

- The paywall is reachable from Profile ▸ Your plan ▸ See Pro, without spending a
  free decision first.
- **Restore Purchases** is on the paywall and in Profile.
- Subscription terms, Privacy Policy and Terms of Use are linked from the paywall.
- Free users can complete a real decision. Reviewers must never hit a wall before
  seeing the product work — the first decision is always allowed, whatever the
  monthly count.

## Local testing

`Config/Rudder.storekit` mirrors the two products and is wired into the shared
scheme, so Run and Test exercise purchase, restore, cancellation and expiry in the
simulator without App Store Connect. Entitlement is always read back from
StoreKit — there is no debug switch that grants Pro, by design.
