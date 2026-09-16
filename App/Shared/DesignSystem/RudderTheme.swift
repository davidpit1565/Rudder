import SwiftUI
import Foundation
import UIKit

/// The visual language: calm, serious, minimal. Colours carry hierarchy and
/// trust rather than decoration, and every semantic colour is defined for both
/// appearances so nothing has to be special-cased at the call site.
enum RudderColor {

    // MARK: Surfaces

    static let background = Color(
        light: Color(red: 0.98, green: 0.98, blue: 0.97),
        dark: Color(red: 0.05, green: 0.05, blue: 0.06)
    )

    static let surface = Color(
        light: .white,
        dark: Color(red: 0.10, green: 0.10, blue: 0.11)
    )

    static let surfaceRaised = Color(
        light: Color(red: 0.96, green: 0.96, blue: 0.95),
        dark: Color(red: 0.14, green: 0.14, blue: 0.15)
    )

    static let separator = Color(
        light: Color(red: 0.88, green: 0.88, blue: 0.87),
        dark: Color(red: 0.22, green: 0.22, blue: 0.24)
    )

    // MARK: Text

    static let primaryText = Color(
        light: Color(red: 0.07, green: 0.07, blue: 0.08),
        dark: Color(red: 0.96, green: 0.96, blue: 0.96)
    )

    static let secondaryText = Color(
        light: Color(red: 0.38, green: 0.38, blue: 0.40),
        dark: Color(red: 0.66, green: 0.66, blue: 0.69)
    )

    static let tertiaryText = Color(
        light: Color(red: 0.56, green: 0.56, blue: 0.58),
        dark: Color(red: 0.48, green: 0.48, blue: 0.51)
    )

    // MARK: Accent

    static let accent = Color(
        light: Color(red: 0.11, green: 0.24, blue: 0.40),
        dark: Color(red: 0.62, green: 0.76, blue: 0.95)
    )

    static let onAccent = Color(
        light: .white,
        dark: Color(red: 0.05, green: 0.08, blue: 0.13)
    )

    // MARK: Decision strength
    //
    // Never the only signal: every use pairs the colour with a shape and a word.

    static let strong = Color(
        light: Color(red: 0.13, green: 0.47, blue: 0.29),
        dark: Color(red: 0.45, green: 0.80, blue: 0.58)
    )

    static let moderate = Color(
        light: Color(red: 0.65, green: 0.47, blue: 0.09),
        dark: Color(red: 0.93, green: 0.76, blue: 0.36)
    )

    static let unclear = Color(
        light: Color(red: 0.66, green: 0.24, blue: 0.20),
        dark: Color(red: 0.95, green: 0.55, blue: 0.48)
    )
}

extension Color {
    /// Builds a colour that resolves per appearance, so the whole palette works in
    /// light and dark without a second definition at every call site.
    init(light: Color, dark: Color) {
        self.init(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            }
        )
    }
}

/// Type scale. Everything is built on text styles so Dynamic Type works end to end.
enum RudderFont {
    static let display = Font.system(.largeTitle, design: .serif, weight: .semibold)
    static let title = Font.system(.title2, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    static let subheadline = Font.system(.subheadline)
    static let footnote = Font.system(.footnote)
    static let caption = Font.system(.caption)
    static let monoLabel = Font.system(.caption, design: .monospaced, weight: .medium)
}

enum RudderSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    /// Apple's minimum comfortable target. Nothing tappable goes below it.
    static let minimumTouchTarget: CGFloat = 44
    static let cornerRadius: CGFloat = 16
    static let screenMargin: CGFloat = 20
}
