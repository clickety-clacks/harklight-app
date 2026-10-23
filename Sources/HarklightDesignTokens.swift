import Foundation
import SwiftUI

enum HarklightMessageType: String, CaseIterable, Sendable {
    case request
    case info
    case done
    case warning
    case error
}

struct HarklightDesignSource: Decodable, Sendable {
    let light: Appearance
    let dark: Appearance

    struct Appearance: Decodable, Sendable {
        let neutral: Neutral
        let accent: Accent
        let detail: Detail
        let types: [String: MessageType]

        func messageType(_ type: HarklightMessageType) -> MessageType {
            guard let result = types[type.rawValue] else {
                preconditionFailure("Design/tokens.json is missing the \(type.rawValue) message palette.")
            }
            return result
        }
    }

    struct Neutral: Decodable, Sendable {
        let bg: String
        let text: String
        let text2: String
        let separator: String
        let replySurface: String
        let glass: String
        let glassEdge: String
        let tabOn: String

        var backgroundColor: Color { Color(harklightToken: bg) }
        var textColor: Color { Color(harklightToken: text) }
        var secondaryTextColor: Color { Color(harklightToken: text2) }
        var separatorColor: Color { Color(harklightToken: separator) }
        var replySurfaceColor: Color { Color(harklightToken: replySurface) }
        var glassColor: Color { Color(harklightToken: glass) }
        var glassEdgeColor: Color { Color(harklightToken: glassEdge) }
        var selectedTabColor: Color { Color(harklightToken: tabOn) }
    }

    struct Accent: Decodable, Sendable {
        let accent: String
        let onAccent: String
        let seen: String

        var color: Color { Color(harklightToken: accent) }
        var onAccentColor: Color { Color(harklightToken: onAccent) }
        var seenColor: Color { Color(harklightToken: seen) }
    }

    struct Detail: Decodable, Sendable {
        let selectedChoice: String
        let replyField: String

        var selectedChoiceColor: Color { Color(harklightToken: selectedChoice) }
        var replyFieldColor: Color { Color(harklightToken: replyField) }
    }

    struct MessageType: Decodable, Sendable {
        let background: String
        let text: String
        let secondaryText: String
        let listIcon: String
        let cameBackBar: String

        var backgroundColor: Color { Color(harklightToken: background) }
        var textColor: Color { Color(harklightToken: text) }
        var secondaryTextColor: Color { Color(harklightToken: secondaryText) }
        var listIconColor: Color { Color(harklightToken: listIcon) }
        var cameBackBarColor: Color { Color(harklightToken: cameBackBar) }
    }
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
}

extension Color {
    init(harklightToken token: String) {
        if token.hasPrefix("#"), let value = UInt32(token.dropFirst(), radix: 16) {
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
            self.init(red: components[0] / 255,
                      green: components[1] / 255,
                      blue: components[2] / 255,
                      opacity: components[3])
            return
        }

        preconditionFailure("Unsupported Harklight color token: \(token)")
    }
}
