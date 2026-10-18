import SwiftUI

/// A share-ready snapshot of a finished decision, rendered to an image so it
/// looks the same everywhere it lands (iMessage, WhatsApp, Instagram Stories)
/// rather than depending on the receiving app's own link-preview rendering.
/// Deliberately carries no identifying information -- just the decision
/// itself and the Rudder name, since this image leaves the app entirely.
struct ShareableDecisionCard: View {
    let optionName: String
    let headline: String
    let topReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.l) {
            Text("RUDDER")
                .font(RudderFont.monoLabel)
                .foregroundStyle(RudderColor.accent)

            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text("I decided:")
                    .font(RudderFont.footnote.weight(.medium))
                    .foregroundStyle(RudderColor.secondaryText)
                Text(optionName)
                    .font(RudderFont.display)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headline)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let topReason {
                Rectangle()
                    .fill(RudderColor.separator)
                    .frame(height: 1)
                Text(topReason)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: RudderSpacing.m)

            Text("Decided with Rudder — the AI that actually makes up its mind.")
                .font(RudderFont.caption)
                .foregroundStyle(RudderColor.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RudderSpacing.xl)
        .frame(width: 400, height: 500, alignment: .topLeading)
        .background(RudderColor.background)
    }
}
