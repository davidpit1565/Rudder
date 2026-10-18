import SwiftUI

/// Shown once, on the very first launch, before anything else. Three short
/// pages, then straight into the app -- no sign-up, no permission prompts
/// here (those are asked for in context, when something actually needs them).
struct OnboardingView: View {
    let onFinish: () -> Void

    private struct Page: Identifiable {
        let id: Int
        let systemImage: String
        let title: String
        let message: String
    }

    private static let pages: [Page] = [
        Page(
            id: 0,
            systemImage: "arrow.triangle.branch",
            title: "RUDDER actually decides",
            message: "Describe a real decision you're stuck on. RUDDER weighs the trade-offs and tells you what it would choose -- not a list of pros and cons you still have to resolve yourself."
        ),
        Page(
            id: 1,
            systemImage: "clock.badge.checkmark",
            title: "A real answer, in under a minute",
            message: "RUDDER asks only what it actually needs to know, checks facts when it matters, and gives you a clear recommendation with the reasoning behind it -- not a wall of text."
        ),
        Page(
            id: 2,
            systemImage: "sparkles",
            title: "Free to start, upgrade if you want more",
            message: "Your first decisions are free. RUDDER Pro adds unlimited deep decisions and lets RUDDER remember your preferences across every decision you make."
        )
    ]

    @State private var pageIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pageIndex) {
                ForEach(Self.pages) { page in
                    pageView(page).tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: RudderSpacing.m) {
                if pageIndex < Self.pages.count - 1 {
                    PrimaryButton(title: "Continue", identifier: RudderID.onboardingContinue) {
                        withAnimation { pageIndex += 1 }
                    }
                    Button("Skip") { onFinish() }
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.secondaryText)
                        .frame(minHeight: RudderSpacing.minimumTouchTarget)
                } else {
                    PrimaryButton(title: "Get started", identifier: RudderID.onboardingFinish, action: onFinish)
                }
            }
            .screenPadding()
            .padding(.bottom, RudderSpacing.m)
        }
        .background(RudderColor.background)
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: RudderSpacing.l) {
            Spacer()
            Image(systemName: page.systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(RudderColor.accent)
            Text(page.title)
                .font(RudderFont.display)
                .foregroundStyle(RudderColor.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(page.message)
                .font(RudderFont.callout)
                .foregroundStyle(RudderColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .screenPadding()
    }
}
