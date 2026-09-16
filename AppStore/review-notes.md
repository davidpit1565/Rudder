# App Review notes

Paste into the "Notes" field in App Store Connect.

```
RUDDER analyses a decision the user describes in their own words and returns a
recommendation, the trade-off involved, how stable that recommendation is, and
the strongest case against it.

NO ACCOUNT IS NEEDED
There is no sign-in and no demo account. Open the app and type a decision.

HOW TO SEE THE FULL FLOW
1. On the Decide tab, tap the example "Which laptop should I buy?" (or type any
   decision) and tap Decide.
2. The app analyses it. If something material cannot be worked out, it asks one
   question — there is no questionnaire and no fixed number of questions.
3. The recommendation screen shows the option, why it fits, the trade-off, the
   decision strength and what could make it wrong. "See analysis" opens the
   criteria, comparison, assumptions, risks and sources.
4. "Make my decision" saves the choice. "Choose something else" shows the other
   options — picking one is recorded without any attempt to change the user's mind.
5. The Decisions tab holds the history. The Profile tab holds learned preferences
   and the controls to delete decisions, memory, outcomes, or everything.

SUBSCRIPTION
RUDDER Pro (monthly com.rudder.app.pro.monthly, annual com.rudder.app.pro.annual)
adds deeper research, more analysis, Decision Memory and full history. The paywall
is reachable at any time from Profile > Your plan > See Pro, and Restore Purchases
is on both the paywall and the Profile tab. The first decision is never blocked.

AI AND DATA
The text of the decision is sent to our own endpoint, which forwards it to
Anthropic for analysis. No account, device identifier or contact information is
attached. Decisions, learned preferences and outcomes are stored on the device
and can be deleted individually or all at once from Profile > Your data.

The app shows what it assumed, what it could not verify, and what would change
its answer. It does not present its output as certain, and does not give
financial, legal or medical advice.

NETWORK
A new decision needs a connection. Without one, the app says so and still shows
previously saved decisions.
```

## Rejection risks, and what was done about them

| Risk | Where it stands |
|---|---|
| 3.1.1 — in-app purchase | StoreKit 2 only. No external purchase link, no alternative payment. |
| 3.1.2 — subscription information | Terms, renewal, cancellation and both links are on the paywall. |
| 2.1 — Restore Purchases missing | Present on the paywall and in Profile. |
| 5.1.1 — data collection beyond need | No account, no analytics provider shipped, no identifiers. |
| 5.1.1(v) — account deletion | No account exists, so no deletion flow is required; all local data can still be deleted in app. |
| 5.1.2 — third-party data sharing | The AI provider is declared in App Privacy and named in the privacy policy. |
| 2.3.1 — hidden features | No debug or test-only behaviour in the release configuration. |
| 2.3.7 — misleading metadata | No accuracy or guarantee claims anywhere in the listing. |
| 4.2 — minimum functionality | The app performs real analysis, keeps history, and works offline for saved decisions. |
| 1.4.1 — medical or physical harm | The listing and the app both state it is not professional advice. |
