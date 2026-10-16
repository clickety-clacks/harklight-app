import SwiftUI

struct InboxCardPreview {
    let sender: String
    let title: String
    let body: String
}

struct InboxCardContext {
    let position: Int
    let total: Int
    let previous: InboxCardPreview?
    let next: InboxCardPreview?
    let move: (Int) -> Void
    static var standalone: InboxCardContext {
        InboxCardContext(position: 1, total: 1, previous: nil, next: nil, move: { _ in })
    }
}

/// Native ScrollView and toolbar host shared by ordinary and synthetic messages.
/// Only the specified boundary-to-neighbor gesture needs a custom interaction.
struct MessageCardSurface<Content: View>: View {
    let context: InboxCardContext
    @ViewBuilder let content: () -> Content
    @State private var pull: CGFloat = 0
    @State private var armedDirection = 0

    var body: some View {
        ScrollView {
            content().frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("message-card-scroll")
        .scrollBounceBehavior(.always)
        .scrollDismissesKeyboard(.interactively)
        .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
        .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            let extent = max(0, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom)
            let bottom = top - extent
            if top < 0 { return -top }
            if bottom > 0 { return -bottom }
            return 0
        } action: { _, value in
            pull = value
            let direction = value > 0 ? -1 : 1
            let neighbor = direction < 0 ? context.previous : context.next
            armedDirection = abs(value) >= 80 && neighbor != nil ? direction : 0
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            if oldPhase == .interacting && newPhase != .interacting && armedDirection != 0 {
                context.move(armedDirection)
            }
        }
        .overlay(alignment: pull > 0 ? .top : .bottom) {
            if abs(pull) > 8, let neighbor = pull > 0 ? context.previous : context.next {
                MessageNeighborPreview(preview: neighbor, showingBottom: pull > 0, armed: armedDirection != 0)
                    .frame(height: armedDirection != 0 ? 104 : min(80, abs(pull)), alignment: pull > 0 ? .bottom : .top)
                    .clipped().allowsHitTesting(false)
                    .animation(.snappy, value: armedDirection)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("\(context.position) of \(context.total)").font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 7).glassEffect(in: Capsule())
            }
        }
        .accessibilityAction(named: "Previous message") { if context.previous != nil { context.move(-1) } }
        .accessibilityAction(named: "Next message") { if context.next != nil { context.move(1) } }
    }
}

struct MessageNeighborPreview: View {
    let preview: InboxCardPreview
    let showingBottom: Bool
    let armed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.sender).font(.subheadline.weight(.semibold))
            Text(preview.title).font(.title.bold())
            Text(preview.body).font(.body)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: showingBottom ? .bottom : .top)
        .clipped().background(Color(uiColor: .systemBackground))
        .padding(showingBottom ? .bottom : .top, 8).background(.white)
        .overlay(alignment: .trailing) {
            if armed { Image(systemName: showingBottom ? "arrow.down.circle.fill" : "arrow.up.circle.fill").padding().foregroundStyle(.blue) }
        }
    }
}

@MainActor
struct SampleCardScreen: View {
    let message: SampleMessage
    let response: SampleResponse
    let library: SampleLibrary
    let inlineChat: Bool
    let canInlineChat: Bool
    let openChat: () -> Void
    let context: InboxCardContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var chatPresented = false
    @State private var enlargedPicture: SampleOption?

    private var canFinish: Bool {
        if message.kind.isNotice || message.kind == .instructions { return true }
        if response.ownAnswer || message.kind == .note { return !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch message.kind {
        case .value: return (7...90).contains(response.number)
        case .point: return !response.marks.isEmpty || !response.strokes.isEmpty
        default: return !response.choices.isEmpty
        }
    }

    var body: some View {
        MessageCardSurface(context: context) {
            SampleCardContent(message: message, response: response, enlarge: { enlargedPicture = $0 })
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish locally", systemImage: "checkmark") {
                    response.finished = true
                    response.deferred = false
                }
                .labelStyle(.iconOnly).disabled(!canFinish || response.finished)
                .accessibilityIdentifier("sample-finish")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Later", systemImage: "clock") { response.deferred.toggle() }.labelStyle(.iconOnly)
                Spacer()
                Button("Chat", systemImage: "bubble.left.and.bubble.right") {
                    response.chatRead = true
                    if inlineChat { openChat() } else if canInlineChat {
                        openChat()
                    } else { chatPresented = true }
                }
                .labelStyle(.iconOnly)
                .popover(isPresented: $chatPresented, arrowEdge: .bottom) {
                    NavigationStack {
                        SampleChatView(sender: message.sender, title: message.title, response: response)
                            .toolbar {
                                if horizontalSizeClass == .compact {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Close", systemImage: "xmark") { chatPresented = false }.labelStyle(.iconOnly)
                                    }
                                }
                            }
                    }
                    .frame(idealWidth: 380, idealHeight: 560)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .sheet(item: $enlargedPicture) { picture in
            SamplePictureViewer(initialPicture: picture)
        }
        .onChange(of: inlineChat) { _, isInline in
            if isInline { chatPresented = false }
        }
    }
}

struct SampleCardContent: View {
    let message: SampleMessage
    @Bindable var response: SampleResponse
    let enlarge: (SampleOption) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            MessageHeading(sender: message.sender, initials: message.initials, title: message.title,
                           time: "2:14 PM", deadline: message.deadline, revised: message.revised,
                           chatUnread: message.hasChat ? message.chatUnread && !response.chatRead : nil)
                .padding(.horizontal, 22)
            Text("Local example · actions stay on this device").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 22)
            if response.deferred {
                HStack {
                    Label("Not now · local sample", systemImage: "clock")
                    Spacer()
                    Button("Undo") { response.deferred = false }
                }.font(.subheadline).padding(.horizontal, 22)
            }
            if response.finished {
                Label("Answered locally · nothing sent", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.green).padding(.horizontal, 22)
            }
            Text(message.body).textSelection(.enabled)
                .padding(message.kind.isNotice ? 16 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(message.kind.isNotice ? message.kind.color.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22)
            SampleRequestControls(message: message, response: response, enlarge: enlarge)
                .disabled(response.finished && message.kind != .pictureChoice)
        }
        .padding(.vertical, 24)
    }
}

struct MessageHeading: View {
    let sender: String
    let initials: String
    let title: String
    var time: String?
    var deadline: String?
    var revised = false
    var chatUnread: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text(initials).font(.caption.bold()).padding(9).background(.quaternary, in: Circle())
                Text(sender).font(.subheadline.weight(.semibold))
                if revised { Text("Revised").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let deadline { Text(deadline).font(.caption).foregroundStyle(.secondary) }
                if let chatUnread {
                    Image(systemName: "bubble.left.and.bubble.right").font(.caption)
                        .foregroundStyle(chatUnread ? .blue : .secondary)
                        .accessibilityLabel(chatUnread ? "Unread conversation" : "Conversation read")
                }
                if let time { Text(time).font(.caption).foregroundStyle(.secondary) }
            }
            Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SampleRequestControls: View {
    let message: SampleMessage
    @Bindable var response: SampleResponse
    let enlarge: (SampleOption) -> Void
    var body: some View {
        VStack(spacing: 14) {
            if message.kind == .review { SampleDiffView() }
            if message.kind == .pictureChoice {
                SamplePictureChoices(options: message.options, response: response, enlarge: enlarge)
                    .padding(.horizontal, 22)
            } else if message.kind == .value {
                SampleNumberInput(response: response).padding(.horizontal, 22)
            } else if message.kind == .point {
                SampleAnnotationEditor(response: response).padding(.horizontal, 22)
            } else if message.kind == .note {
                TextField("Your answer", text: $response.text, axis: .vertical)
                    .lineLimit(5...12).textFieldStyle(.roundedBorder).padding(.horizontal, 22)
            } else if !message.options.isEmpty {
                VStack(spacing: 12) {
                    ForEach(message.options) { option in
                        SampleChoiceRow(option: option, selected: response.choices.contains(option.id),
                                        multiple: message.kind == .multipleChoice,
                                        swatch: message.kind == .colorChoice ? option.id : nil,
                                        sound: message.kind == .soundChoice) {
                            response.choose(option.id, multiple: message.kind == .multipleChoice)
                        }
                    }
                    Button {
                        response.ownAnswer = true
                        response.choices = []
                    } label: {
                        MessageChoiceLabel(title: "Your own answer", detail: "Write it here, or say why none of these fit.",
                                          selected: response.ownAnswer, multiple: false, suggested: false)
                    }.buttonStyle(.plain)
                    if response.ownAnswer {
                        TextField("Your answer", text: $response.text, axis: .vertical)
                            .lineLimit(3...8).textFieldStyle(.roundedBorder)
                    }
                }.padding(.horizontal, 22)
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
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                if let swatch {
                    Circle().fill(swatch == "blue" ? Color.blue : swatch == "green" ? .green : .orange)
                        .frame(width: 34, height: 34)
                }
                if sound { Image(systemName: "waveform").frame(width: 34) }
                MessageChoiceLabel(title: option.title, detail: option.detail, selected: selected,
                                  multiple: multiple, suggested: option.role == .suggested,
                                  selectionColor: option.role == .destructive ? .red : .blue)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(option.role == .destructive ? Color.red : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct MessageChoiceLabel: View {
    let title: String
    let detail: String
    let selected: Bool
    let multiple: Bool
    let suggested: Bool
    var selectionColor: Color = .blue
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(selected ? selectionColor : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if suggested { Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(.blue) }
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? selectionColor.opacity(0.13) : suggested ? Color.blue.opacity(0.05) : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? selectionColor : Color(uiColor: .separator).opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SampleNumberInput: View {
    @Bindable var response: SampleResponse
    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Days", value: $response.number, format: .number)
                    .keyboardType(.numberPad).font(.system(size: 56, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center).frame(width: 150)
                Text("days").foregroundStyle(.secondary)
            }
            Slider(value: $response.number, in: 7...90, step: 1) { Text("Days to keep drafts") }
            HStack { Text("7 days"); Spacer(); Text("90 days") }.font(.caption).foregroundStyle(.secondary)
            if !(7...90).contains(response.number) { Text("Choose 7 to 90 days.").foregroundStyle(.red) }
        }
    }
}

struct SampleDiffView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("welcome.md · +2 −1").font(.caption.weight(.semibold)).padding(14)
            Text("− Welcome to our comprehensive collection of recent work.")
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.07))
            Text("+ A place for ideas to grow.\n+ Explore the journal, one page at a time.")
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.green.opacity(0.08))
        }
        .font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
