# App Privacy answers

These are the answers to give in App Store Connect. They describe what the app
actually does — anything that changes here has to change in the code first.

## Data collected

### Other User Content — "Other User Content"

- **Collected:** Yes
- **Linked to the user:** No
- **Used for tracking:** No
- **Purpose:** App Functionality

The text of a decision, any answers the user gives, and any preferences they have
approved storing are sent to RUDDER's own endpoint so the decision can be
analysed. No account, device identifier or contact information is attached. The
endpoint forwards the decision text to a third-party AI provider (Anthropic) for
analysis; disclose that provider in the "third parties" section — Apple requires
third-party data handling to be declared as if it were the app's own.

## Data NOT collected

### Purchases — "Purchase History"

**Answer No.** Subscription state is read from StoreKit on the device to decide
whether Pro is active, and is never transmitted anywhere by this app. Apple's
definition of collection is data sent off the device, so answering Yes here would
overstate what RUDDER does. (Apple's own handling of the transaction is Apple's
to declare, not the developer's.)

Declare none of the following either:

- Contact info, name, email, phone number, physical address
- Health or fitness data
- Financial info beyond the subscription state above
- Precise or coarse location
- Contacts, photos, camera, microphone, calendar, reminders
- Search history, browsing history
- Identifiers (no IDFA, no IDFV sent anywhere, no device ID)
- Usage data, diagnostics, crash logs *(the shipped analytics implementation is a
  no-op — if a real provider is added, this answer must change first)*
- Sensitive info

## Tracking

**The app does not track.** No ATT prompt, no `NSPrivacyTrackingDomains`,
no advertising identifier.

## Data storage and deletion

- Decisions, Decision Memory and outcomes are stored on the device using
  SwiftData, in three separate entities.
- Profile ▸ Your data deletes each of them separately, or all of them at once.
- The backend keeps no decision text of its own: a request is analysed and the
  result returned. Anything a host or the model provider logs is governed by that
  provider's retention settings — set them, and reflect them in the privacy policy.

## Privacy policy

Apple requires a privacy policy URL for every app, and it must cover third-party
data handling. The URL is read from `RudderPrivacyPolicyURL` in
`Config/Shared.xcconfig`; the app hides the link entirely rather than showing a
broken one, so the placeholder cannot ship as a dead link — but the App Store
submission itself will be rejected without a real one.

The policy must state, at minimum:

1. What is sent off the device (the decision text and any answers) and why.
2. That a third-party AI provider processes it, named.
3. That decisions, memory and outcomes are stored on the device.
4. How to delete them (Profile ▸ Your data, or deleting the app).
5. That there is no account, no tracking and no advertising.
6. The retention period at the backend and at the provider.
7. A contact address for privacy questions.

## Privacy manifest

`App/Resources/PrivacyInfo.xcprivacy` declares the two data types above, no
tracking, and an empty required-reason API list. The app calls no required-reason
API directly — verify this with Xcode's privacy report when you archive, and add
an entry if a future dependency introduces one.
