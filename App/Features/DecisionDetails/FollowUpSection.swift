import SwiftUI
import Foundation
import RudderCore
import RudderFlow

/// Ask a question about an already-finished decision, without starting a new
/// one. Only ever shown here -- DecisionDetailsView only exists for a
/// decision whose analysis has already completed.
struct FollowUpSection: View {
    let record: DecisionRecord
    /// Lets the parent screen drive its own `DecisionFlowView` presentation,
    /// rather than this section owning a second one of its own.
    let onStartNewDecision: (String) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var exchanges: [FollowUpExchange] = []
    @State private var question = ""
    @State private var isAsking = false
    @State private var error: RudderServiceError?
    @FocusState private var isInputFocused: Bool

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var quota: QuotaBucketStatus? { environment.quotaStatus?.followup }
    private var isQuotaExhausted: Bool { quota.map { $0.used >= $0.limit } ?? false }
    private var canAsk: Bool { trimmedQuestion.count >= 3 && !isAsking && !isQuotaExhausted }

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(title: "Ask a follow-up")
            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.m) {
                    if exchanges.isEmpty {
                        Text("Ask anything about this decision — I'll answer from what I already know about it.")
                            .font(RudderFont.footnote)
                            .foregroundStyle(RudderColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(exchanges.enumerated()), id: \.element.id) { index, exchange in
                            if index > 0 { Divider().overlay(RudderColor.separator) }
                            FollowUpExchangeRow(
                                exchange: exchange,
                                showsMemoryConsent: environment.isPro,
                                onStartNewDecision: onStartNewDecision,
                                onRemember: {
                                    guard let statement = exchange.durablePreferenceStatement else { return }
                                    environment.acceptFollowUpPreference(statement, exchangeID: exchange.id)
                                    refreshExchanges()
                                },
                                onDecline: {
                                    environment.declineFollowUpPreference(exchangeID: exchange.id)
                                    refreshExchanges()
                                }
                            )
                        }
                    }

                    if isQuotaExhausted {
                        InlineNotice(text: "You've used today's follow-up questions on this plan. They reset tomorrow.", kind: .warning)
                    } else if let error {
                        InlineNotice(text: error.errorDescription ?? "Something went wrong", kind: .warning)
                    }

                    HStack(alignment: .bottom, spacing: RudderSpacing.s) {
                        TextField("Ask a follow-up…", text: $question, axis: .vertical)
                            .font(RudderFont.body)
                            .lineLimit(1...4)
                            .focused($isInputFocused)
                            .padding(RudderSpacing.m)
                            .background(RudderColor.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
                            .disabled(isAsking || isQuotaExhausted)
                            .accessibilityIdentifier(RudderID.followUpInput)

                        Button(action: ask) {
                            Group {
                                if isAsking {
                                    ProgressView().tint(RudderColor.onAccent)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.body.weight(.semibold))
                                }
                            }
                            .frame(width: RudderSpacing.minimumTouchTarget, height: RudderSpacing.minimumTouchTarget)
                            .foregroundStyle(RudderColor.onAccent)
                            .background(canAsk ? RudderColor.accent : RudderColor.accent.opacity(0.4), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAsk)
                        .accessibilityLabel("Ask")
                        .accessibilityIdentifier(RudderID.followUpAsk)
                    }

                    if let quota {
                        Text("\(max(0, quota.limit - quota.used)) of \(quota.limit) follow-ups left today")
                            .font(RudderFont.caption)
                            .foregroundStyle(RudderColor.tertiaryText)
                    }
                }
            }
        }
        .task {
            refreshExchanges()
            await environment.refreshQuotaStatus()
        }
    }

    private func refreshExchanges() {
        exchanges = environment.followUpExchanges(for: record)
    }

    private func ask() {
        let trimmed = trimmedQuestion
        guard trimmed.count >= 3 else { return }
        isInputFocused = false
        isAsking = true
        error = nil
        Task {
            do {
                let exchange = try await environment.askFollowUp(trimmed, about: record)
                exchanges.append(exchange)
                question = ""
                await environment.refreshQuotaStatus()
            } catch let serviceError as RudderServiceError {
                error = serviceError
            } catch {
                self.error = .unknown
            }
            isAsking = false
        }
    }
}

/// Rounded on three corners, pinched on the fourth -- the one detail that
/// reads as "chat bubble" rather than "card" at a glance.
private struct ChatBubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: RudderSpacing.cornerRadius,
            bottomLeadingRadius: isUser ? RudderSpacing.cornerRadius : RudderSpacing.xs,
            bottomTrailingRadius: isUser ? RudderSpacing.xs : RudderSpacing.cornerRadius,
            topTrailingRadius: RudderSpacing.cornerRadius,
            style: .continuous
        )
        return shape.path(in: rect)
    }
}

private extension View {
    func chatBubble(isUser: Bool) -> some View {
        padding(.horizontal, RudderSpacing.m)
            .padding(.vertical, RudderSpacing.s)
            .background(
                isUser ? RudderColor.accent : RudderColor.surfaceRaised,
                in: ChatBubbleShape(isUser: isUser)
            )
    }
}

private struct FollowUpExchangeRow: View {
    let exchange: FollowUpExchange
    let showsMemoryConsent: Bool
    let onStartNewDecision: (String) -> Void
    let onRemember: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            HStack {
                Spacer(minLength: RudderSpacing.xl)
                Text(exchange.question)
                    .font(RudderFont.body.weight(.medium))
                    .foregroundStyle(RudderColor.onAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .chatBubble(isUser: true)
            }

            HStack {
                Text(exchange.answer)
                    .font(RudderFont.body)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .chatBubble(isUser: false)
                Spacer(minLength: RudderSpacing.xl)
            }

            if let prompt = exchange.suggestedNewDecisionPrompt {
                SecondaryButton(title: "This needs a fresh look — start a new decision", systemImage: "arrow.right") {
                    onStartNewDecision(prompt)
                }
            }

            // Low-friction and inline, by design: a full-screen consent sheet
            // for every small thing a follow-up reveals would be exhausting.
            // The app's own published description promises Decision Memory
            // "stores only what you approve" -- so this still always asks,
            // just without blocking the conversation to do it.
            if showsMemoryConsent, let statement = exchange.durablePreferenceStatement {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    Text("I noticed something")
                        .font(RudderFont.caption.weight(.medium))
                        .foregroundStyle(RudderColor.tertiaryText)
                    Text(statement)
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    PrimaryButton(title: "Remember this", identifier: RudderID.followUpRemember, action: onRemember)
                    Button("Not now", action: onDecline)
                        .font(RudderFont.footnote)
                        .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget)
                }
                .padding(RudderSpacing.m)
                .background(RudderColor.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.s, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
    }
}
