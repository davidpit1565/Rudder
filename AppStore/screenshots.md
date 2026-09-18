# Screenshot plan

Seven screenshots, in this order. Each one makes a single claim, and the claim is
true of the build being submitted.

Sizes: as of 2026, Apple requires screenshots only for the largest display per
device family and scales them down for smaller ones. Rudder is iPhone-only
(`TARGETED_DEVICE_FAMILY = 1` in `Config/Shared.xcconfig` — no iPad support),
so only the **6.9" iPhone** size is required: 1320 × 2868, 1290 × 2796, or
1260 × 2736 px, portrait. No 6.5" or iPad screenshots are needed unless iPad
support is added later — confirm in App Store Connect at submission, since
Apple's accepted sizes have changed before and can again.

| # | Screen | Caption | What must be visible |
|---|---|---|---|
| 1 | Home, empty field | **Tell it what you're deciding.** | "What are you deciding?", the input, the Decide button |
| 2 | Question | **It asks only what it can't work out itself.** | "One thing I need to know" and a single question — no counter, no progress bar |
| 3 | Working state | **It looks up what it can.** | "Checking the information" with the preliminary direction card underneath |
| 4 | Recommendation, upper half | **An answer, and why it fits you.** | Option name, "Best fit for you", reasons 01–03 |
| 5 | Recommendation, trade-off + strength | **See what you give up.** | The trade-off card and the Strong badge with its explanation |
| 6 | Recommendation, self-challenge | **Know what could make it wrong.** | "What could make me wrong?" card |
| 7 | Choice confirmation | **You make the final call.** | "You chose", gaining / giving up, "Your choice is yours." |

## Rules for the captures

- Real output from a real decision. No mocked copy, no invented sources, no
  numbers the app would not produce.
- Use the laptop decision (MacBook Air vs MacBook Pro) throughout, so the seven
  screens read as one story.
- Light appearance for 1–4, dark for 5–7, to show both without saying so.
- Status bar: full signal, full battery, 9:41.
- Captions live in the frame above the screenshot, not on top of the UI.
- No device bezel mockups with a different device's shape.

## Preview video (optional)

If one is made: 15–20 seconds, no voiceover, no music bed with a countdown
feeling. Type a decision, one question appears, the recommendation appears,
the user picks the other option, the gaining/giving-up card appears. That is the
whole product.
