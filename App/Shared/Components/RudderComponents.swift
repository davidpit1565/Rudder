import SwiftUI
import Foundation
import RudderCore

// MARK: - Buttons

/// The one primary action on a screen. Full width, thumb-reachable, never below 44pt.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading: Bool = false
    var isEnabled: Bool = true
    /// Stable handle for UI tests. Invisible to users, and needed because more
    /// than one control can legitimately carry the same visible label.
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RudderSpacing.s) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(RudderColor.onAccent)
                }
                Text(title)
                    .font(RudderFont.headline)
                if let systemImage, !isLoading {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget)
            .padding(.vertical, RudderSpacing.s)
            .foregroundStyle(RudderColor.onAccent)
            .background(RudderColor.accent.opacity(isEnabled && !isLoading ? 1 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? title)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RudderSpacing.s) {
                Text(title).font(RudderFont.callout.weight(.medium))
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget)
            .foregroundStyle(RudderColor.accent)
            .background(RudderColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? title)
    }
}

// MARK: - Containers

struct RudderCard<Content: View>: View {
    var padding: CGFloat = RudderSpacing.m
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(RudderColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous)
                    .stroke(RudderColor.separator, lineWidth: 0.5)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            Text(title)
                .font(RudderFont.headline)
                .foregroundStyle(RudderColor.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Decision strength

/// Strength is communicated by shape, word and colour together — never colour alone.
struct StrengthBadge: View {
    let strength: DecisionStrength
    var showsExplanation: Bool = false

    private var colour: Color {
        switch strength {
        case .strong: return RudderColor.strong
        case .moderate: return RudderColor.moderate
        case .unclear: return RudderColor.unclear
        }
    }

    private var symbol: String {
        switch strength {
        case .strong: return "checkmark.circle.fill"
        case .moderate: return "exclamationmark.triangle.fill"
        case .unclear: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            HStack(spacing: RudderSpacing.s) {
                Image(systemName: symbol)
                    .font(.subheadline)
                Text(strength.title)
                    .font(RudderFont.subheadline.weight(.semibold))
            }
            .foregroundStyle(colour)

            if showsExplanation {
                Text(strength.explanation)
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decision strength: \(strength.title). \(strength.explanation)")
    }
}

// MARK: - Numbered reasons

struct NumberedRow: View {
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: RudderSpacing.m) {
            Text(String(format: "%02d", index))
                .font(RudderFont.monoLabel)
                .foregroundStyle(RudderColor.tertiaryText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text(title)
                    .font(RudderFont.callout.weight(.semibold))
                    .foregroundStyle(RudderColor.primaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - States

struct EmptyStateView: View {
    let title: String
    var message: String?
    var systemImage: String = "tray"

    var body: some View {
        VStack(spacing: RudderSpacing.s) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(RudderColor.tertiaryText)
            Text(title)
                .font(RudderFont.callout.weight(.medium))
                .foregroundStyle(RudderColor.secondaryText)
            if let message {
                Text(message)
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RudderSpacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// Reflects work that is actually happening. There is no decorative waiting in RUDDER.
struct WorkingStateView: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.m) {
            HStack(spacing: RudderSpacing.s) {
                ProgressView().progressViewStyle(.circular)
                Text(title)
                    .font(RudderFont.title)
                    .foregroundStyle(RudderColor.primaryText)
            }
            if let subtitle {
                Text(subtitle)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(title). \($0)" } ?? title)
    }
}

struct InlineNotice: View {
    enum Kind { case info, warning }

    let text: String
    var kind: Kind = .info

    private var symbol: String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: RudderSpacing.s) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(kind == .warning ? RudderColor.moderate : RudderColor.secondaryText)
            Text(text)
                .font(RudderFont.footnote)
                .foregroundStyle(RudderColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RudderSpacing.s)
        .background(RudderColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.s, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Layout helpers

extension View {
    func screenPadding() -> some View {
        padding(.horizontal, RudderSpacing.screenMargin)
    }
}

/// Accessibility identifiers for the controls the UI tests drive.
///
/// These are identifiers, not labels: nothing here changes what a user sees or
/// hears. They exist because a visible label is not always unique — "Decide" is
/// both a tab and the primary action on the home screen.
enum RudderID {
    static let startDecision = "decide.start"
    static let decisionInput = "decide.input"
    static let voiceInput = "decide.voiceInput"
    static let makeDecision = "decide.make"
    static let chooseSomethingElse = "decide.chooseOther"
    static let continueAfterQuestion = "decide.question.continue"
    static let doneWithDecision = "decide.done"
    static let tryAgain = "decide.retry"
    static let historyRow = "decide.historyRow"
    static func optionRow(_ optionID: String) -> String { "decide.option.\(optionID)" }
}
