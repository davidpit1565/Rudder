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
            .clipShape(Capsule(style: .continuous))
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
            .clipShape(Capsule(style: .continuous))
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

/// A small icon container tinted by its own colour rather than sitting on a
/// neutral grey square -- the badge's wash matches the icon, so a row of
/// these reads as a set of distinct things rather than one repeated shape.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = RudderColor.accent
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A circular read on one ratio -- `value` is drawn as the filled arc, and
/// the raw fraction sits inside it as text, so the shape and the number
/// always agree.
struct RingStat: View {
    let value: Double
    let numeratorLabel: String
    var tint: Color = RudderColor.strong
    var diameter: CGFloat = 72
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(RudderColor.surfaceRaised, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(numeratorLabel)
                .font(RudderFont.subheadline.weight(.semibold))
                .foregroundStyle(RudderColor.primaryText)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
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

extension DecisionCategory {
    /// A single consistent icon per category -- used anywhere a decision or a
    /// category breakdown needs a quick visual anchor, not just a label.
    var icon: String {
        switch self {
        case .purchase: return "cart.fill"
        case .career: return "briefcase.fill"
        case .education: return "graduationcap.fill"
        case .travel: return "airplane"
        case .home: return "house.fill"
        case .subscription: return "repeat.circle.fill"
        case .finance: return "banknote.fill"
        case .technology: return "desktopcomputer"
        case .lifePlanning: return "signpost.right.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

extension DecisionComplexity {
    /// User-facing tier names -- "Quick/Standard/Deep" is how RUDDER explains
    /// its own research depth to the user, kept separate from the internal
    /// simple/medium/complex vocabulary the engine and backend use.
    var tierLabel: String {
        switch self {
        case .simple: return "Quick"
        case .medium: return "Standard"
        case .complex: return "Deep"
        }
    }
}

/// A small, understated tag for which research depth a decision is running
/// at -- shown on the working screen and the recommendation itself, so the
/// tier is never a guess.
struct TierTag: View {
    let complexity: DecisionComplexity

    var body: some View {
        Text(complexity.tierLabel)
            .font(RudderFont.caption.weight(.semibold))
            .foregroundStyle(RudderColor.secondaryText)
            .padding(.horizontal, RudderSpacing.s)
            .padding(.vertical, 4)
            .background(RudderColor.surfaceRaised, in: Capsule())
            .accessibilityLabel("\(complexity.tierLabel) analysis")
    }
}

// MARK: - Glass segmented control

/// A segmented control styled after Liquid Glass -- translucent material, a
/// soft specular highlight, and a thumb that slides between options -- built
/// from ordinary SwiftUI materials rather than the real `glassEffect()` API.
/// That API needs an SDK newer than this project's CI toolchain currently
/// ships (confirmed: CI still builds on Xcode 16.4), so using it directly
/// would fail to compile there; this gets the same look without it.
struct GlassSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Text(label(option))
                    .font(RudderFont.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? RudderColor.primaryText : RudderColor.secondaryText)
                    .padding(.vertical, RudderSpacing.s)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: RudderSpacing.minimumTouchTarget - RudderSpacing.s)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.35), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                )
                                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.75))
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "glassSegmentThumb", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selection = option
                        }
                    }
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(RudderColor.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(RudderColor.separator, lineWidth: 0.5))
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
    static let followUpInput = "decide.followUp.input"
    static let followUpAsk = "decide.followUp.ask"
    static let followUpRemember = "decide.followUp.remember"
    static let shareDecision = "decide.share"
    static let onboardingContinue = "onboarding.continue"
    static let onboardingFinish = "onboarding.finish"
}
