import CoreText
import SwiftUI

/// Semantic styles used by the Clawline type scale.
enum HarklightTextStyle: String, CaseIterable, Sendable {
    case brandLarge
    case messageTitle
    case rowTitleTop
    case rowTitleMiddle
    case rowTitleLow
    case body
    case bodySmall
    case label
    case sender
    case caption
    case timestamp
}

enum HarklightSpacing: String, CaseIterable, Sendable {
    case tiny
    case small
    case compact
    case base
    case comfortable
    case generous
    case large
}

enum HarklightRadius: String, CaseIterable, Sendable {
    case card
    case field
    case button
    case panel
    case inset
    case small
    case check
}

enum HarklightElevation: String, CaseIterable, Sendable {
    case raised
    case hover
    case flat
}

enum HarklightSystemTextStyle: String, Decodable, Sendable {
    case largeTitle
    case title
    case title2
    case headline
    case subheadline
    case body
    case caption
    case caption2

    var swiftUI: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .caption: .caption
        case .caption2: .caption2
        }
    }
}

struct HarklightTypeScaleToken: Decodable, Sendable {
    let size: Double
    let weight: Int
    let lineHeightMultiplier: Double?
    let tracking: Double?
    let relativeTo: HarklightSystemTextStyle

    var swiftUIFontWeight: Font.Weight {
        switch weight {
        case 300: .light
        case 400: .regular
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        default:
            preconditionFailure("Unsupported DM Sans weight token: \(weight).")
        }
    }
}

struct HarklightTypographyTokens: Decodable, Sendable {
    let family: String
    let postScriptName: String
    let styles: [String: HarklightTypeScaleToken]

    func token(for style: HarklightTextStyle) -> HarklightTypeScaleToken {
        guard let token = styles[style.rawValue] else {
            preconditionFailure("Design/tokens.json is missing the \(style.rawValue) type token.")
        }
        return token
    }

    func font(for style: HarklightTextStyle) -> Font {
        let token = token(for: style)
        HarklightBundledFonts.registerDMSansIfNeeded()

        let resolved = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard CTFontCopyPostScriptName(resolved) as String == postScriptName else {
            preconditionFailure("The bundled DM Sans font could not be resolved by its PostScript name.")
        }

        return .custom(postScriptName,
                       size: CGFloat(token.size),
                       relativeTo: token.relativeTo.swiftUI)
            .weight(token.swiftUIFontWeight)
    }
}

struct HarklightShadowToken: Decodable, Sendable {
    let x: Double
    let y: Double
    let blur: Double
    let color: String

    var colorValue: Color { Color(harklightToken: color) }
    var swiftUIRadius: CGFloat { CGFloat(blur / 2) }
    var xOffset: CGFloat { CGFloat(x) }
    var yOffset: CGFloat { CGFloat(y) }
}

struct HarklightElevationTokens: Decodable, Sendable {
    let raised: [HarklightShadowToken]
    let hover: [HarklightShadowToken]
    let flat: [HarklightShadowToken]

    func shadows(for elevation: HarklightElevation) -> [HarklightShadowToken] {
        switch elevation {
        case .raised: raised
        case .hover: hover
        case .flat: flat
        }
    }
}

struct HarklightGrainTokens: Decodable, Sendable {
    let opacity: Double
    let frequency: Double
    let octaves: Int
}

struct HarklightMotionTiming: Decodable, Sendable {
    let duration: Double
    let curve: String

    var animation: Animation {
        switch curve {
        case "easeInOut": .easeInOut(duration: duration)
        default: preconditionFailure("Unsupported motion curve token: \(curve).")
        }
    }
}

struct HarklightMotionTokens: Decodable, Sendable {
    let interaction: HarklightMotionTiming
    let theme: HarklightMotionTiming
    let pressScale: Double
    let hoverScale: Double
    let hoverLift: Double
}

private enum HarklightBundledFonts {
    private static let registration: Void = {
        guard let url = Bundle.main.url(forResource: "DMSans", withExtension: "ttf") else {
            preconditionFailure("The bundled DM Sans font resource is missing.")
        }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func registerDMSansIfNeeded() {
        _ = registration
    }
}

extension HarklightDesignSystem {
    static func typeStyle(_ style: HarklightTextStyle) -> HarklightTypeScaleToken {
        source.type.token(for: style)
    }

    static func font(for style: HarklightTextStyle) -> Font {
        source.type.font(for: style)
    }

    static func spacing(_ token: HarklightSpacing) -> CGFloat {
        numericToken(token.rawValue, from: source.space, group: "space")
    }

    static func radius(_ token: HarklightRadius) -> CGFloat {
        numericToken(token.rawValue, from: source.radius, group: "radius")
    }

    static func elevation(_ token: HarklightElevation,
                          for colorScheme: ColorScheme) -> [HarklightShadowToken] {
        palette(for: colorScheme).elevation.shadows(for: token)
    }

    static func grain(for colorScheme: ColorScheme) -> HarklightGrainTokens {
        palette(for: colorScheme).grain
    }

    static var motion: HarklightMotionTokens { source.motion }

    private static func numericToken(_ name: String,
                                     from group: [String: Double],
                                     group groupName: String) -> CGFloat {
        guard let value = group[name] else {
            preconditionFailure("Design/tokens.json is missing the \(groupName).\(name) token.")
        }
        return CGFloat(value)
    }
}
