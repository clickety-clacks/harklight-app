import Foundation
import SwiftUI

enum HarklightMessageType: String, CaseIterable, Sendable {
    case request
    case info
    case done
    case warning
    case error

    /// The type symbol drawn beside a message title.
    var symbol: String {
        switch self {
        case .request: "questionmark.circle"
        case .info: "info.circle"
        case .done: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

/// A parsed color token. Tokens are `#RRGGBB` or `rgba(r,g,b,a)` strings in
/// Design/tokens.json; mixing keeps derived colors in one place.
struct HarklightRGBA: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(token: String) {
        if token.hasPrefix("#"), token.count == 7, let value = UInt32(token.dropFirst(), radix: 16) {
            self.init(red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
            return
        }
        if token.hasPrefix("rgba("), token.hasSuffix(")") {
            let components = token.dropFirst(5).dropLast().split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard components.count == 4 else {
                preconditionFailure("Invalid Harklight color token: \(token)")
            }
            self.init(red: components[0] / 255, green: components[1] / 255,
                      blue: components[2] / 255, alpha: components[3])
            return
        }
        preconditionFailure("Unsupported Harklight color token: \(token)")
    }

    var color: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }

    /// This color at `share` laid over an opaque `base`, as one opaque color.
    func mixed(_ share: Double, over base: HarklightRGBA) -> HarklightRGBA {
        HarklightRGBA(red: red * share + base.red * (1 - share),
                      green: green * share + base.green * (1 - share),
                      blue: blue * share + base.blue * (1 - share))
    }

    /// WCAG relative luminance of an opaque color.
    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static func contrast(_ first: HarklightRGBA, _ second: HarklightRGBA) -> Double {
        let lighter = max(first.luminance, second.luminance)
        let darker = min(first.luminance, second.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension Color {
    init(harklightToken token: String) {
        self = HarklightRGBA(token: token).color
    }
}

/// The app's one token source, decoded from Design/tokens.json: the
/// revision 7 design's light and dark colors, type and shapes.
struct HarklightDesignSource: Decodable, Sendable {
    let light: Appearance
    let dark: Appearance
    let type: HarklightTypeTokens
    let shape: [String: Double]

    struct Colors: Decodable, Sendable {
        let background: String
        let text: String
        let secondary: String
        let label: String
        let line: String
        let raised: String
        let field: String
        let panel: String
        let group: String
        let amber: String
        let teal: String
        let sky: String
        let violet: String
        let coral: String
        let onBeam: String
        let inverse: String
        let onInverse: String
        let accentFill: String
        let onAccent: String
    }

    struct Derived: Decodable, Sendable {
        let typeTint: [String: String]
        let urgentWash: String
        let highWash: String
        let replyPane: String
        let sheetDim: String
    }

    struct Appearance: Decodable, Sendable {
        let color: Colors
        let derived: Derived

        var background: Color { Color(harklightToken: color.background) }
        var text: Color { Color(harklightToken: color.text) }
        var secondary: Color { Color(harklightToken: color.secondary) }
        var label: Color { Color(harklightToken: color.label) }
        var line: Color { Color(harklightToken: color.line) }
        var raised: Color { Color(harklightToken: color.raised) }
        var field: Color { Color(harklightToken: color.field) }
        var panel: Color { Color(harklightToken: color.panel) }
        var group: Color { Color(harklightToken: color.group) }
        var amber: Color { Color(harklightToken: color.amber) }
        var teal: Color { Color(harklightToken: color.teal) }
        var sky: Color { Color(harklightToken: color.sky) }
        var violet: Color { Color(harklightToken: color.violet) }
        var coral: Color { Color(harklightToken: color.coral) }
        var onBeam: Color { Color(harklightToken: color.onBeam) }
        var inverse: Color { Color(harklightToken: color.inverse) }
        var onInverse: Color { Color(harklightToken: color.onInverse) }
        var accentFill: Color { Color(harklightToken: color.accentFill) }
        var onAccent: Color { Color(harklightToken: color.onAccent) }
        var urgentWash: Color { Color(harklightToken: derived.urgentWash) }
        var highWash: Color { Color(harklightToken: derived.highWash) }
        var replyPane: Color { Color(harklightToken: derived.replyPane) }
        var sheetDim: Color { Color(harklightToken: derived.sheetDim) }

        func typeColorToken(_ type: HarklightMessageType) -> String {
            switch type {
            case .request: color.violet
            case .info: color.sky
            case .done: color.teal
            case .warning: color.amber
            case .error: color.coral
            }
        }

        /// The beam color for a message's type, used for its symbol, the
        /// picked border and the iPad open row.
        func typeColor(_ type: HarklightMessageType) -> Color {
            Color(harklightToken: typeColorToken(type))
        }

        /// The faint fill behind an open message of this type.
        func typeTint(_ type: HarklightMessageType) -> Color {
            Color(harklightToken: typeTintToken(type))
        }

        func typeTintToken(_ type: HarklightMessageType) -> String {
            guard let token = derived.typeTint[type.rawValue] else {
                preconditionFailure("Design/tokens.json is missing the \(type.rawValue) type tint.")
            }
            return token
        }

        /// Fill of a picked choice, picked reply card and answered card:
        /// the type color at 9 percent over whatever is behind.
        func pickedFill(_ type: HarklightMessageType) -> Color {
            typeColor(type).opacity(0.09)
        }

        /// iPad open row fill: the type color at 15 percent.
        func openRowFill(_ type: HarklightMessageType) -> Color {
            typeColor(type).opacity(0.15)
        }

        /// iPad open row bar: the type color at 55 percent over the background.
        func openRowBar(_ type: HarklightMessageType) -> Color {
            HarklightRGBA(token: typeColorToken(type))
                .mixed(0.55, over: HarklightRGBA(token: color.background)).color
        }
    }
}

enum HarklightShape: String, CaseIterable, Sendable {
    case card
    case small
    case settingsGroup
    case rowInitials
    case messageInitials
    case rowVerticalPadding
    case rowHorizontalPadding
    case glassButton
    case lineWidth
    case priorityEdge
    case selectionBar
    case selectionIndent
    case replyPaneMinHeight
}

enum HarklightDesignSystem {
    static let source: HarklightDesignSource = {
        guard let url = Bundle.main.url(forResource: "tokens", withExtension: "json")
            ?? Bundle.main.url(forResource: "tokens", withExtension: "json", subdirectory: "Design") else {
            preconditionFailure("Design/tokens.json is missing from the app resources.")
        }
        do {
            return try JSONDecoder().decode(HarklightDesignSource.self, from: Data(contentsOf: url))
        } catch {
            preconditionFailure("Design/tokens.json could not be decoded: \(error)")
        }
    }()

    static func palette(for colorScheme: ColorScheme) -> HarklightDesignSource.Appearance {
        colorScheme == .dark ? source.dark : source.light
    }

    static func shape(_ token: HarklightShape) -> CGFloat {
        guard let value = source.shape[token.rawValue] else {
            preconditionFailure("Design/tokens.json is missing the shape.\(token.rawValue) token.")
        }
        return CGFloat(value)
    }
}

/// Colors for content shown inside an open message of one type.
struct HarklightMessageColors {
    let type: HarklightMessageType
    /// The open message background: the type's faint tint.
    let tint: Color
    let text: Color
    let secondary: Color
    let label: Color
    /// The type's beam color, for its symbol and picked borders.
    let beam: Color
    let line: Color
    let raised: Color
    let field: Color
    let pickedFill: Color
    let replyPane: Color
}

extension HarklightDesignSource.Appearance {
    func message(_ type: HarklightMessageType) -> HarklightMessageColors {
        HarklightMessageColors(type: type, tint: typeTint(type), text: text,
                               secondary: secondary, label: label, beam: typeColor(type),
                               line: line, raised: raised, field: field, pickedFill: pickedFill(type),
                               replyPane: replyPane)
    }
}

/// A design color that resolves for the current light or dark appearance, so
/// views can use tokens wherever a shape style is accepted.
struct HarklightColor: ShapeStyle {
    enum Token: Sendable {
        case background, text, secondary, label, line, raised, field, panel, group
        case amber, teal, sky, violet, coral, onBeam, inverse, onInverse, accentFill, onAccent
    }

    let token: Token

    func resolve(in environment: EnvironmentValues) -> Color {
        let palette = HarklightDesignSystem.palette(for: environment.colorScheme)
        return switch token {
        case .background: palette.background
        case .text: palette.text
        case .secondary: palette.secondary
        case .label: palette.label
        case .line: palette.line
        case .raised: palette.raised
        case .field: palette.field
        case .panel: palette.panel
        case .group: palette.group
        case .amber: palette.amber
        case .teal: palette.teal
        case .sky: palette.sky
        case .violet: palette.violet
        case .coral: palette.coral
        case .onBeam: palette.onBeam
        case .inverse: palette.inverse
        case .onInverse: palette.onInverse
        case .accentFill: palette.accentFill
        case .onAccent: palette.onAccent
        }
    }
}

extension ShapeStyle where Self == HarklightColor {
    static var hkBackground: HarklightColor { HarklightColor(token: .background) }
    static var hkText: HarklightColor { HarklightColor(token: .text) }
    static var hkSecondary: HarklightColor { HarklightColor(token: .secondary) }
    static var hkLabel: HarklightColor { HarklightColor(token: .label) }
    static var hkLine: HarklightColor { HarklightColor(token: .line) }
    static var hkRaised: HarklightColor { HarklightColor(token: .raised) }
    static var hkField: HarklightColor { HarklightColor(token: .field) }
    static var hkPanel: HarklightColor { HarklightColor(token: .panel) }
    static var hkGroup: HarklightColor { HarklightColor(token: .group) }
    static var hkAmber: HarklightColor { HarklightColor(token: .amber) }
    static var hkTeal: HarklightColor { HarklightColor(token: .teal) }
    static var hkCoral: HarklightColor { HarklightColor(token: .coral) }
    static var hkOnBeam: HarklightColor { HarklightColor(token: .onBeam) }
    static var hkAccentFill: HarklightColor { HarklightColor(token: .accentFill) }
    static var hkOnAccent: HarklightColor { HarklightColor(token: .onAccent) }
}
