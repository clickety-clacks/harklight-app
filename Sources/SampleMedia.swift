import SwiftUI

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
    let enlarge: (SampleOption) -> Void
    var body: some View {
        VStack(spacing: 20) {
            ForEach(options) { option in
                Button {
                    if response.finished || response.choices.contains(option.id) { enlarge(option) }
                    else { response.choose(option.id, multiple: false) }
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        SamplePicture(name: option.id)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(response.choices.contains(option.id) ? Color.blue : .clear, lineWidth: 3))
                        HStack {
                            Text(option.title).font(.headline)
                            Spacer()
                            if response.choices.contains(option.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
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
    @State private var tool: AnnotationTool = .spot
    @State private var stroke: [SampleMark] = []
    @State private var enlarged = false
    enum AnnotationTool: String, CaseIterable, Identifiable {
        case spot = "Spot", draw = "Draw", note = "Note"
        var id: Self { self }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geometry in
                ZStack {
                    SamplePicture(name: "harbor")
                    Canvas { context, size in
                        for line in response.strokes + [stroke] {
                            guard let first = line.first else { continue }
                            var path = Path()
                            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                            for point in line.dropFirst() { path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height)) }
                            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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
                                if tool == .draw { stroke.append(normalized(value.location, in: geometry.size)) }
                            }
                            .onEnded { value in
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
            .aspectRatio(1.5, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cover annotation")
            .accessibilityIdentifier("sample-annotation-canvas")
            .accessibilityAction(named: "Add a spot at the center") { response.addMark(SampleMark(x: 0.5, y: 0.5)) }
            HStack {
                Picker("Annotation tool", selection: $tool) {
                    ForEach(AnnotationTool.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    response.undoAnnotation()
                }.labelStyle(.iconOnly).disabled(response.strokes.isEmpty && response.marks.isEmpty)
                Button("Enlarge picture", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }.labelStyle(.iconOnly)
            }
            ForEach($response.marks) { $mark in
                HStack {
                    Image(systemName: "scope")
                    TextField("Note for this spot", text: $mark.note)
                    Button("Remove spot", systemImage: "minus.circle") { response.removeMark(mark.id) }.labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $enlarged) { SamplePictureViewer(initialPicture: SampleCatalog.pictures[1]) }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> SampleMark {
        SampleMark(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }
}

struct SampleChatView: View {
    let sender: String
    let title: String
    @Bindable var response: SampleResponse
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        VStack(spacing: 0) {
            if verticalSizeClass != .compact {
                VStack(alignment: .leading, spacing: 5) {
                    Text(sender).font(.headline)
                    Text("About \(title)").font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(response.chat) { line in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(line.fromPerson ? "You" : sender).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(line.text).textSelection(.enabled)
                                ForEach(line.attachmentNames, id: \.self) { name in Label(name, systemImage: "doc") }
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.fromPerson ? Color.blue.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            .id(line.id)
                        }
                    }.padding(.horizontal)
                }
                .onChange(of: response.chat.count) { _, _ in
                    if let id = response.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Text("Local conversation · nothing sent").font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
            SampleChatComposer(response: response).padding(verticalSizeClass == .compact ? 4 : 12)
        }
        .onAppear { response.chatRead = true }
    }
}

struct SampleChatComposer: View {
    @Bindable var response: SampleResponse
    @State private var attachmentChoices = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { attachmentChoices = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
            .accessibilityLabel("Add sample attachment")
            .confirmationDialog("Add a local example", isPresented: $attachmentChoices, titleVisibility: .visible) {
                Button("Sample photo") { addAttachment("Photo") }
                Button("Sample file") { addAttachment("Document") }
                Button("Sample camera image") { addAttachment("Camera") }
                Button("Cancel", role: .cancel) {}
            }
            VStack(alignment: .leading, spacing: 8) {
                if !response.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(response.attachments, id: \.self) { name in
                                VStack(spacing: 4) {
                                    if name.hasPrefix("Document") {
                                        Image(systemName: "doc.text.fill").font(.title).frame(width: 72, height: 48)
                                    } else { SamplePicture(name: "harbor").frame(width: 72) }
                                    Text(name).font(.caption2).lineLimit(1)
                                    Button("Remove", systemImage: "xmark.circle.fill") { response.attachments.removeAll { $0 == name } }.labelStyle(.iconOnly)
                                }
                            }
                        }
                    }
                }
                TextField("Write a message…", text: $response.chatDraft, axis: .vertical)
                    .lineLimit(1...5).accessibilityIdentifier("sample-chat-composer")
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sample-chat-input-surface")
            Button { response.sendLocalChat() } label: {
                Image(systemName: "arrow.up").font(.headline)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
            .accessibilityLabel("Send locally")
            .disabled(response.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && response.attachments.isEmpty)
        }
    }

    private func addAttachment(_ kind: String) {
        var number = 1
        while response.attachments.contains("\(kind) \(number)") { number += 1 }
        response.attachments.append("\(kind) \(number)")
    }
}
