import CoreText
import SwiftUI
import UIKit

/// Type roles from the revision 7 design. Headings use the bundled Fraunces;
/// everything else uses the system font. Sizes are at the default text size
/// and scale with Dynamic Type.
enum HarklightTextStyle: String, CaseIterable, Sendable {
    case brand
    case rowTitle
    case messageTitle
    case sheetTitle
    case messageBody
    case rowBody
    case newSummary
    case newStatus
    case urgencyPill
    case priorityLine
    case rowSender
    case messageSender
    case rowTime
    case sectionHeading
    case more
    case choiceTitle
    case choiceDetail
    case suggested
    case chatTurn
    case chatSpeaker
    case delivered
    case positionPill
    case settingsRow
    case settingsDetail
    case settingsHeading
}

enum HarklightSystemTextStyle: String, Decodable, Sendable {
    case largeTitle
    case title
    case title2
    case headline
    case subheadline
    case body
    case callout
    case footnote
    case caption
    case caption2

    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }
}

struct HarklightTypeToken: Decodable, Sendable {
    enum Face: String, Decodable, Sendable {
        case heading
        case system
    }

    let face: Face
    let size: Double
    let weight: Int
    /// Line height as a multiple of the size, as the design's CSS states it.
    let lineHeight: Double?
    /// Letter spacing in ems.
    let tracking: Double?
    let relativeTo: HarklightSystemTextStyle
}

struct HarklightTypeTokens: Decodable, Sendable {
    let headingFamily: String
    let headingResource: String
    let styles: [String: HarklightTypeToken]

    func token(for style: HarklightTextStyle) -> HarklightTypeToken {
        guard let token = styles[style.rawValue] else {
            preconditionFailure("Design/tokens.json is missing the \(style.rawValue) type token.")
        }
        return token
    }
}

/// A resolved font for one style at one Dynamic Type size.
struct HarklightResolvedType {
    let font: UIFont
    let tracking: CGFloat
    let lineSpacing: CGFloat

    var swiftUIFont: Font { Font(font) }
}

enum HarklightTypography {
    nonisolated(unsafe) private static let headingDescriptor: CTFontDescriptor = {
        let resource = HarklightDesignSystem.source.type.headingResource
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            preconditionFailure("The bundled \(resource) font resource is missing.")
        }
        return descriptor
    }()

    private static func fourCC(_ tag: String) -> NSNumber {
        NSNumber(value: tag.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    /// Fraunces at a weight, with the optical size following the point size
    /// as browsers do for the site, and the plain (not soft or wonky) forms.
    fileprivate static func heading(size: CGFloat, weight: Int) -> UIFont {
        let opticalSize = min(max(size, 9), 144)
        var descriptor = headingDescriptor
        for (tag, value) in [("wght", Double(weight)), ("opsz", Double(opticalSize)),
                             ("SOFT", 0), ("WONK", 0)] {
            descriptor = CTFontDescriptorCreateCopyWithVariation(
                descriptor, fourCC(tag), CGFloat(value))
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as UIFont
    }

    private static func systemWeight(_ weight: Int) -> UIFont.Weight {
        switch weight {
        case 300: .light
        case 400: .regular
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        default: preconditionFailure("Unsupported type weight token: \(weight).")
        }
    }

    static func resolve(_ style: HarklightTextStyle,
                        dynamicTypeSize: DynamicTypeSize = .large) -> HarklightResolvedType {
        let token = HarklightDesignSystem.source.type.token(for: style)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let size = UIFontMetrics(forTextStyle: token.relativeTo.uiKit)
            .scaledValue(for: CGFloat(token.size), compatibleWith: traits)
        let font = switch token.face {
        case .heading: heading(size: size, weight: token.weight)
        case .system: UIFont.systemFont(ofSize: size, weight: systemWeight(token.weight))
        }
        let lineSpacing = token.lineHeight.map { max(0, CGFloat($0) * size - font.lineHeight) } ?? 0
        return HarklightResolvedType(font: font,
                                     tracking: CGFloat(token.tracking ?? 0) * size,
                                     lineSpacing: lineSpacing)
    }
}

extension HarklightTypography {
    /// Large navigation titles (such as enrollment's) use the heading face.
    @MainActor
    static func configureNavigationTitles() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let size = UIFontMetrics(forTextStyle: .largeTitle).scaledValue(for: 34, compatibleWith: traits)
        let largeTitle = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: heading(size: size, weight: 300))
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeTitle]
    }
}

private struct HarklightTypeModifier: ViewModifier {
    let style: HarklightTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let resolved = HarklightTypography.resolve(style, dynamicTypeSize: dynamicTypeSize)
        content
            .font(resolved.swiftUIFont)
            .tracking(resolved.tracking)
            .lineSpacing(resolved.lineSpacing)
    }
}

extension View {
    /// Sets a design type role: face, size, weight, tracking and line height.
    func harklightType(_ style: HarklightTextStyle) -> some View {
        modifier(HarklightTypeModifier(style: style))
    }
}

extension HarklightDesignSystem {
    static func font(_ style: HarklightTextStyle,
                     dynamicTypeSize: DynamicTypeSize = .large) -> Font {
        HarklightTypography.resolve(style, dynamicTypeSize: dynamicTypeSize).swiftUIFont
    }
}
