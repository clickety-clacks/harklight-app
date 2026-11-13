import SwiftUI

/// A stock grouped-form section in the design's colors: groups in `group`,
/// headings in ordinary capitals in `label`.
struct HarklightFormSection<Content: View>: View {
    let title: LocalizedStringResource?
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: LocalizedStringResource? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Section {
            content()
                .foregroundStyle(.hkText)
        } header: {
            if let title {
                Text(title)
                    .harklightType(.settingsHeading)
                    .foregroundStyle(.hkLabel)
                    .textCase(nil)
            }
        }
        .listRowBackground(Rectangle().fill(.hkGroup))
        .listRowSeparatorTint(HarklightDesignSystem.palette(for: colorScheme).line)
    }
}

/// Lists and forms that sit on a sheet take the sheet's panel color; those on
/// a page take the page background.
struct HarklightListSurface: ViewModifier {
    enum Kind {
        case sheet
        case page
    }

    let kind: Kind

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                Rectangle()
                    .fill(kind == .sheet ? HarklightColor(token: .panel) : HarklightColor(token: .background))
                    .ignoresSafeArea()
            }
    }
}

extension View {
    func harklightListSurface(_ kind: HarklightListSurface.Kind = .sheet) -> some View {
        modifier(HarklightListSurface(kind: kind))
    }

    /// A stock sheet in the design's panel color with Apple's grabber.
    func harklightSheetSurface() -> some View {
        presentationBackground(.hkPanel)
    }

    /// Stock navigation title in Fraunces, as the drawings set sheet titles.
    func harklightSheetTitle(_ title: LocalizedStringResource) -> some View {
        navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .harklightType(.sheetTitle)
                        .foregroundStyle(.hkText)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

/// The Done check on a settings sheet: Apple's tinted button in amber.
struct HarklightDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Done", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .foregroundStyle(.hkOnAccent)
        }
        .tint(HarklightColor(token: .accentFill))
    }
}

/// The app accent is the design's amber.
struct HarklightAccentTint: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(HarklightDesignSystem.palette(for: colorScheme).amber)
    }
}
