import SwiftUI
import AttentionDomain

struct SamplePicture: View {
    let name: String
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(LinearGradient(colors: name == "night" ? [.indigo, .black] : name == "harbor" ? [.orange.opacity(0.7), .blue] : [.cyan.opacity(0.4), .green], startPoint: .top, endPoint: .bottom))
                Circle().fill(.white.opacity(0.8))
                    .frame(width: geometry.size.width * 0.13, height: geometry.size.width * 0.13)
                    .position(x: geometry.size.width * 0.72, y: geometry.size.height * 0.23)
                SampleHills().fill(name == "night" ? Color.indigo.opacity(0.65) : name == "harbor" ? .blue.opacity(0.5) : .green.opacity(0.7))
                VStack(alignment: .leading) {
                    Spacer()
                    Text("FIELD NOTES").font(.caption.weight(.semibold)).tracking(3)
                    Text(name == "night" ? "After dusk" : name == "harbor" ? "Still water" : "Room to grow")
                        .font(.system(.largeTitle, design: .serif)).bold()
                }
                .foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(name == "night" ? "Night sky cover" : name == "harbor" ? "Harbor cover" : "Meadow cover")
    }
}

private struct SampleHills: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.height * 0.65))
            path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.7),
                          control1: CGPoint(x: rect.width * 0.35, y: rect.height * 0.25),
                          control2: CGPoint(x: rect.width * 0.6, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
    }
}

struct SamplePictureChoices: View {
    let options: [SampleOption]
    let response: SampleResponse
    var isReadOnly = false
    let enlarge: (SampleOption) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var messageColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    var body: some View {
        VStack(spacing: 20) {
            ForEach(options) { option in
                Button {
                    if isReadOnly || response.finished || response.choices.contains(option.id) { enlarge(option) }
                    else { response.choose(option.id, multiple: false) }
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        SamplePicture(name: option.id)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(response.choices.contains(option.id)
                                                ? messageColors.textColor
                                                : messageColors.textColor.opacity(0.3),
                                            lineWidth: 1)
                            }
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title).font(.headline).foregroundStyle(messageColors.textColor)
                                Text(option.detail).font(.subheadline).foregroundStyle(messageColors.secondaryTextColor)
                            }
                            Spacer()
                            if response.choices.contains(option.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(messageColors.textColor)
                            }
                        }
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture().onEnded { _ in enlarge(option) })
                .accessibilityAction(named: "Enlarge picture") { enlarge(option) }
            }
        }
    }
}

struct SamplePictureViewer: View {
    let initialPicture: SampleOption
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SampleOption?
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                SamplePicture(name: (selected ?? initialPicture).id)
                Text((selected ?? initialPicture).title).font(.headline)
                Spacer()
                HStack {
                    ForEach(SampleCatalog.pictures) { picture in
                        Button { selected = picture } label: {
                            SamplePicture(name: picture.id).frame(maxWidth: 150)
                        }.buttonStyle(.plain).accessibilityLabel(picture.title)
                    }
                }
            }
            .padding()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { dismiss() }.labelStyle(.iconOnly) } }
        }
    }
}

struct SampleAnnotationEditor: View {
    @Bindable var response: SampleResponse
    let illustration: SenderIllustration
    let point: PointValue?
    let isReadOnly: Bool
    @State private var tool: AnnotationTool = .spot
    @State private var stroke: [SampleMark] = []
    @State private var enlarged = false
    enum AnnotationTool: String, CaseIterable, Identifiable {
        case spot = "Spot", draw = "Draw", note = "Note"
        var id: Self { self }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SenderIllustrationCanvas(illustration: illustration, point: point)
                .overlay {
                    GeometryReader { geometry in
                        ZStack {
                            Canvas { context, size in
                                for line in response.strokes + [stroke] {
                                    guard let first = line.first else { continue }
                                    var path = Path()
                                    path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                                    for point in line.dropFirst() {
                                        path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                                    }
                                    context.stroke(path, with: .color(.white),
                                                   style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                }
                            }
                            ForEach(response.marks) { mark in
                                Image(systemName: mark.note.isEmpty ? "scope" : "text.bubble.fill")
                                    .font(.title).foregroundStyle(.white).shadow(radius: 2)
                                    .position(x: mark.x * geometry.size.width, y: mark.y * geometry.size.height)
                            }
                            Color.clear.contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard !isReadOnly, tool == .draw else { return }
                                        stroke.append(normalized(value.location, in: geometry.size))
                                    }
                                    .onEnded { value in
                                        guard !isReadOnly else { return }
                                        if tool == .draw {
                                            response.addStroke(stroke)
                                            stroke = []
                                        } else {
                                            var mark = normalized(value.location, in: geometry.size)
                                            if tool == .note { mark.note = "Note" }
                                            response.addMark(mark)
                                        }
                                    })
                                .onChange(of: geometry.size) { _, _ in stroke = [] }
                        }
                    }
                }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(illustration.label.rawValue)
            .accessibilityIdentifier("sample-annotation-canvas")
            .accessibilityAction(named: "Set point at center") {
                guard !isReadOnly else { return }
                response.addMark(SampleMark(x: 0.5, y: 0.5))
            }
            HStack {
                Picker("Annotation tool", selection: $tool) {
                    ForEach(AnnotationTool.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(isReadOnly)
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    response.undoAnnotation()
                }.labelStyle(.iconOnly).disabled(isReadOnly || (response.strokes.isEmpty && response.marks.isEmpty))
                Button("Enlarge picture", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }.labelStyle(.iconOnly)
            }
            ForEach($response.marks) { $mark in
                HStack {
                    Image(systemName: "scope")
                    TextField("Note for this spot", text: $mark.note).disabled(isReadOnly)
                    Button("Remove spot", systemImage: "minus.circle") { response.removeMark(mark.id) }
                        .labelStyle(.iconOnly).disabled(isReadOnly)
                }
            }
        }
        .sheet(isPresented: $enlarged) {
            SampleIllustrationViewer(illustration: illustration, point: point)
        }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> SampleMark {
        SampleMark(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }
}

private struct SampleIllustrationViewer: View {
    let illustration: SenderIllustration
    let point: PointValue?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SenderIllustrationCanvas(illustration: illustration, point: point)
                .padding()
                .navigationTitle(illustration.label.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                }
        }
    }
}

struct SampleChoiceRow: View {
    let option: SampleOption
    let selected: Bool
    let multiple: Bool
    let swatch: String?
    let sound: Bool
    let choose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var messageColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    private var suggested: Bool {
        if case .suggested = option.role { return true }
        return false
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                if let swatch {
                    Circle().fill(SampleSwatch.color(for: swatch))
                        .frame(width: 34, height: 34)
                        .accessibilityLabel("\(option.title) swatch")
                }
                if sound { Image(systemName: "waveform").frame(width: 34) }
                MessageChoiceLabel(title: option.title, detail: option.detail, selected: selected,
                                   multiple: multiple, suggested: suggested)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(messageColors.textColor)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private enum SampleSwatch {
    static func color(for sampleID: String) -> Color {
        switch sampleID {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        default: .gray
        }
    }
}

struct SampleNumberInput: View {
    @Bindable var response: SampleResponse
    var isReadOnly = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var messageColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Days", value: $response.number, format: .number)
                    .keyboardType(.numberPad).font(.system(size: 56, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center).frame(width: 150)
                    .foregroundStyle(messageColors.textColor)
                    .tint(messageColors.textColor)
                    .disabled(isReadOnly)
                Text("days").foregroundStyle(messageColors.secondaryTextColor)
            }
            Slider(value: $response.number, in: 7...90, step: 1) { Text("Days to keep drafts") }
                .tint(messageColors.textColor)
                .disabled(isReadOnly)
            HStack { Text("7 days"); Spacer(); Text("90 days") }
                .font(.caption).foregroundStyle(messageColors.secondaryTextColor)
            if !(7...90).contains(response.number) {
                Text("Choose 7 to 90 days.").foregroundStyle(messageColors.secondaryTextColor)
            }
        }
    }
}

struct SampleDiffView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var messageColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("welcome.md · +2 −1").font(.caption.weight(.semibold)).padding(14)
            Text("− Welcome to our comprehensive collection of recent work.")
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            Text("+ A place for ideas to grow.\n+ Explore the journal, one page at a time.")
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.subheadline, design: .monospaced))
        .foregroundStyle(messageColors.textColor)
        .textSelection(.enabled)
    }
}

struct LocalSampleContext: View {
    let response: SampleResponse
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var messageColors: HarklightDesignSource.MessageType {
        HarklightDesignSystem.palette(for: colorScheme).messageType(messageType)
    }

    var body: some View {
        HStack(spacing: 10) {
            if response.message.revised {
                Label("Revised", systemImage: "arrow.triangle.2.circlepath")
            }
            if let deadline = response.message.deadline {
                Label(deadline, systemImage: "clock")
                    .foregroundStyle(messageColors.secondaryTextColor)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct SampleChatView: View {
    let sender: String
    let title: String
    let response: SampleResponse
    var body: some View {
        ConversationPanel(store: response.viewModel, key: response.key, sender: sender, title: title)
            .onAppear { response.chatRead = true }
    }
}
