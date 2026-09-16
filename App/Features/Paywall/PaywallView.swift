import SwiftUI
import Foundation
import RudderFlow
import StoreKit

/// Shown only after RUDDER has already been useful. No countdowns, no invented
/// scarcity, no "1,000 AI messages" — the product is decision intelligence.
struct PaywallView: View {
    enum Context: String, Identifiable {
        case deepDecisionLimit
        case history
        case memory
        case profile

        var id: String { rawValue }

        var headline: String {
            "Make better decisions, with less effort."
        }

        var lead: String? {
            switch self {
            case .deepDecisionLimit:
                return "You've used your deep decisions for this month. Pro removes the cap."
            case .history:
                return "Pro shows your full decision history."
            case .memory:
                return "Decision Memory learns what you actually care about, with Pro."
            case .profile:
                return nil
            }
        }
    }

    let context: Context

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProductID = SubscriptionService.ProductID.annual
    @State private var isPurchasing = false
    @State private var message: String?

    private var subscriptions: SubscriptionService { environment.subscriptions }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RudderSpacing.l) {
                    header
                    benefits
                    plans
                    if let message {
                        InlineNotice(text: message, kind: .warning)
                    }
                    legal
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.m)
            }
            .background(RudderColor.background)
            .navigationTitle("RUDDER Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: RudderSpacing.s) {
                    PrimaryButton(
                        title: "Start Pro",
                        isLoading: isPurchasing,
                        isEnabled: selectedProduct != nil
                    ) {
                        purchase()
                    }
                    Button("Restore Purchases") { restore() }
                        .font(RudderFont.footnote)
                        .frame(minHeight: RudderSpacing.minimumTouchTarget)
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.s)
                .background(.bar)
            }
            .task {
                await subscriptions.loadProducts()
                environment.analytics.track(.paywallShown)
            }
            .onChange(of: subscriptions.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    private var selectedProduct: Product? {
        subscriptions.products.first { $0.id == selectedProductID }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            Text(context.headline)
                .font(RudderFont.display)
                .foregroundStyle(RudderColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let lead = context.lead {
                Text(lead)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Only what Pro actually changes. The analysis itself is the same either way,
    /// and saying so is worth more than a longer list.
    private var benefits: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.m) {
            benefit(
                "Deep decisions, uncapped",
                "Free covers \(FeatureAccess.freeDeepDecisionsPerMonth) of the research-heavy ones each month. Pro removes the cap."
            )
            benefit(
                "Decision Memory",
                "RUDDER learns what you actually care about from decisions you've made — and only stores what you approve."
            )
            benefit(
                "Outcome learning",
                "Tell it how a decision went, and that changes what it learns. A choice you regretted stops counting."
            )
            benefit(
                "Your full history",
                "Free keeps your last \(FeatureAccess.freeHistoryLimit) decisions in view. Pro shows all of them, searchable."
            )

            InlineNotice(
                text: "The analysis is the same either way. Free decisions get the same research, stress testing and self-challenge — Pro removes the limits."
            )
        }
    }

    private func benefit(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: RudderSpacing.m) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RudderColor.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RudderFont.callout.weight(.semibold))
                    .foregroundStyle(RudderColor.primaryText)
                Text(detail)
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var plans: some View {
        if subscriptions.isLoadingProducts {
            HStack(spacing: RudderSpacing.s) {
                ProgressView()
                Text("Loading plans…")
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if subscriptions.products.isEmpty {
            InlineNotice(
                text: "I couldn't load the plans from the App Store. Check your connection and try again.",
                kind: .warning
            )
        } else {
            VStack(spacing: RudderSpacing.s) {
                ForEach(subscriptions.products, id: \.id) { product in
                    PlanRow(
                        product: product,
                        isSelected: product.id == selectedProductID,
                        savingPercentage: product.id == SubscriptionService.ProductID.annual
                            ? subscriptions.annualSavingPercentage
                            : nil
                    ) {
                        selectedProductID = product.id
                    }
                }
            }
        }
    }

    private var legal: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            Text("Subscriptions renew automatically until cancelled. Cancel any time in your Apple Account settings, at least 24 hours before the period ends.")
                .font(RudderFont.caption)
                .foregroundStyle(RudderColor.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: RudderSpacing.m) {
                if let url = environment.configuration.privacyPolicyURL {
                    Link("Privacy Policy", destination: url).font(RudderFont.caption)
                }
                if let url = environment.configuration.termsURL {
                    Link("Terms of Use", destination: url).font(RudderFont.caption)
                }
            }
            .frame(minHeight: RudderSpacing.minimumTouchTarget * 0.8)
        }
    }

    private func purchase() {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        message = nil
        Task {
            let outcome = await subscriptions.purchase(product)
            isPurchasing = false
            switch outcome {
            case .success:
                environment.analytics.track(.subscriptionStarted)
                dismiss()
            case .pending:
                message = "That purchase needs approval before it can start. I'll unlock Pro as soon as it goes through."
            case .cancelled:
                break
            case .failed(let reason):
                message = reason
            }
        }
    }

    private func restore() {
        isPurchasing = true
        message = nil
        Task {
            let outcome = await subscriptions.restorePurchases()
            isPurchasing = false
            if case .failed(let reason) = outcome { message = reason }
        }
    }
}

private struct PlanRow: View {
    let product: Product
    let isSelected: Bool
    let savingPercentage: Int?
    let action: () -> Void

    private var periodDescription: String {
        guard let subscription = product.subscription else { return "" }
        let unit = subscription.subscriptionPeriod.unit
        let value = subscription.subscriptionPeriod.value
        switch unit {
        case .month: return value == 1 ? "per month" : "every \(value) months"
        case .year: return value == 1 ? "per year" : "every \(value) years"
        case .week: return value == 1 ? "per week" : "every \(value) weeks"
        case .day: return value == 1 ? "per day" : "every \(value) days"
        @unknown default: return ""
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RudderSpacing.m) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? RudderColor.accent : RudderColor.tertiaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(RudderFont.callout.weight(.semibold))
                        .foregroundStyle(RudderColor.primaryText)
                    Text("\(product.displayPrice) \(periodDescription)")
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.secondaryText)
                }

                Spacer(minLength: RudderSpacing.s)

                if let savingPercentage, savingPercentage > 0 {
                    Text("Save \(savingPercentage)%")
                        .font(RudderFont.caption.weight(.semibold))
                        .foregroundStyle(RudderColor.strong)
                }
            }
            .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget, alignment: .leading)
            .padding(RudderSpacing.m)
            .background(RudderColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous)
                    .stroke(isSelected ? RudderColor.accent : RudderColor.separator, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
