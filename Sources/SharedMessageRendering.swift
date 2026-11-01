import SwiftUI
import UIKit
import AttentionDomain
import ImageIO

enum MessageTextLinks {
    /// Makes ordinary web URLs tappable with the standard system link
    /// behavior. The visible characters stay exactly as written; nothing
    /// else — including email addresses — is interpreted as a link or
    /// other markup.
    static func attributed(_ string: String) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(string)
        }
        let matches = detector.matches(in: string,
                                       range: NSRange(string.startIndex..., in: string))
        guard !matches.isEmpty else { return AttributedString(string) }
        var result = AttributedString()
        var cursor = string.startIndex
        for match in matches {
            guard let url = match.url, isWebURL(url),
                  let range = Range(match.range, in: string),
                  range.lowerBound >= cursor else { continue }
            if cursor < range.lowerBound {
                result += AttributedString(String(string[cursor..<range.lowerBound]))
            }
            var link = AttributedString(String(string[range]))
            link.link = url
            result += link
            cursor = range.upperBound
        }
        if cursor < string.endIndex {
            result += AttributedString(String(string[cursor...]))
        }
        return result
    }

    private static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

/// Renders a request body with UIKit's built-in detectors and text interactions.
/// Keep this separate from `MessageTextLinks`, which ConversationView uses.
struct SystemDetectedMessageBody: UIViewRepresentable {
    let text: String
    let foregroundColor: Color

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = .all
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        updateColors(on: textView)
        textView.text = text
        textView.accessibilityIdentifier = "request-message-body"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        updateColors(on: textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fittingSize.height)
    }

    private func updateColors(on textView: UITextView) {
        let color = UIColor(foregroundColor)
        if textView.textColor?.isEqual(color) != true {
            textView.textColor = color
        }
        if textView.tintColor?.isEqual(color) != true {
            textView.tintColor = color
        }

        let currentLinkAttributes = textView.linkTextAttributes ?? [:]
        let currentLinkColor = currentLinkAttributes[.foregroundColor] as? UIColor
        let currentUnderline = (currentLinkAttributes[.underlineStyle] as? NSNumber)?.intValue
        let underlineStyle = NSUnderlineStyle.single.rawValue
        if currentLinkColor?.isEqual(color) != true || currentUnderline != underlineStyle {
            textView.linkTextAttributes = [
                .foregroundColor: color,
                .underlineStyle: underlineStyle
            ]
        }
    }
}

struct SceneTextView: View {
    let text: String
    let style: SceneTextStyle

    var body: some View {
        switch style {
        case .title:
            Text(text).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        case .body:
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        case .caption:
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PointGestureCapture {
    private var capturedBounds: CGRect?
    private var isCancelled = false

    mutating func update(at location: CGPoint, in bounds: CGRect) -> PointValue? {
        guard !isCancelled else { return nil }
        let isDragging = capturedBounds != nil
        if let capturedBounds, capturedBounds != bounds {
            isCancelled = true
            return nil
        }
        guard let point = PointTransform.select(pointerX: location.x,
                                                pointerY: location.y,
                                                bounds: bounds,
                                                dragging: isDragging) else {
            isCancelled = true
            return nil
        }
        if capturedBounds == nil {
            capturedBounds = bounds
        }
        return point
    }

    mutating func finish(at location: CGPoint, in bounds: CGRect) -> PointValue? {
        defer { gestureDidEnd() }
        guard !isCancelled,
              let capturedBounds,
              capturedBounds == bounds else { return nil }
        return PointTransform.select(pointerX: location.x,
                                     pointerY: location.y,
                                     bounds: bounds,
                                     dragging: true)
    }

    mutating func cancelIfBoundsChanged(to bounds: CGRect) {
        guard let capturedBounds, capturedBounds != bounds else { return }
        isCancelled = true
    }

    mutating func gestureDidEnd() {
        self = Self()
    }
}

private struct DecodedSenderPicture: @unchecked Sendable {
    let image: CGImage
}

private func decodeSenderPicture(at url: URL) -> DecodedSenderPicture? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
        kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
    return DecodedSenderPicture(image: image)
}

typealias SenderPictureLoader = @MainActor (ConversationFile) async throws -> URL

@MainActor
struct SenderIllustrationCanvas: View {
    let illustration: SenderIllustration
    let point: PointValue?
    let deliveredFiles: [ConversationFile]
    let pictureLoader: SenderPictureLoader?

    @State private var pictureStates: [ExactText: PictureState] = [:]

    private enum PictureState {
        case loading
        case unavailable
        case ready(DecodedSenderPicture)
    }

    init(illustration: SenderIllustration,
         point: PointValue?,
         deliveredFiles: [ConversationFile] = [],
         pictureLoader: SenderPictureLoader? = nil) {
        self.illustration = illustration
        self.point = point
        self.deliveredFiles = deliveredFiles
        self.pictureLoader = pictureLoader
    }

    var body: some View {
        GeometryReader { geometry in
            let rect = Self.fittedRect(size: geometry.size,
                                       sourceWidth: illustration.width,
                                       sourceHeight: illustration.height)
            Canvas { context, _ in
                context.clip(to: Path(rect))
                for primitive in illustration.primitives {
                    Self.draw(primitive, context: &context, rect: rect,
                              sourceWidth: illustration.width, sourceHeight: illustration.height,
                              pictureStates: pictureStates)
                }
                if let point {
                    Self.draw(point, context: &context, rect: rect)
                }
            }
        }
        .aspectRatio(CGFloat(illustration.width) / CGFloat(illustration.height), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .task(id: pictureTaskID) {
            await loadPictures()
        }
    }

    private var pictureTaskID: String {
        let filesByName = Dictionary(deliveredFiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return imageFileNames.map { name in
            let file = filesByName[name]
            return [name.rawValue, file?.sha256.rawValue ?? "", String(file?.byteCount ?? 0)].joined(separator: "\u{0}")
        }.sorted().joined(separator: "\n")
    }

    private var imageFileNames: Set<ExactText> {
        Set(illustration.primitives.compactMap { primitive in
            if case let .image(_, _, _, _, file) = primitive { return file }
            return nil
        })
    }

    private func loadPictures() async {
        pictureStates = [:]
        guard !imageFileNames.isEmpty else { return }
        let filesByName = Dictionary(deliveredFiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for name in imageFileNames {
            guard case nil = pictureStates[name] else { continue }
            guard let file = filesByName[name], let pictureLoader else {
                pictureStates[name] = .unavailable
                continue
            }
            pictureStates[name] = .loading
            do {
                let url = try await pictureLoader(file)
                let decoded = await Task.detached(priority: .userInitiated) {
                    decodeSenderPicture(at: url)
                }.value
                guard !Task.isCancelled else { return }
                pictureStates[name] = decoded.map(PictureState.ready) ?? .unavailable
            } catch {
                guard !Task.isCancelled else { return }
                pictureStates[name] = .unavailable
            }
        }
    }

    static func fittedRect(size: CGSize, sourceWidth: Int, sourceHeight: Int) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(sourceWidth), size.height / CGFloat(sourceHeight))
        let width = CGFloat(sourceWidth) * scale
        let height = CGFloat(sourceHeight) * scale
        return CGRect(x: (size.width - width) / 2,
                      y: (size.height - height) / 2,
                      width: width,
                      height: height)
    }

    static func imageDestinationRect(imageSize: CGSize, in elementRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              elementRect.width > 0, elementRect.height > 0 else { return .zero }
        let scale = min(elementRect.width / imageSize.width,
                        elementRect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: elementRect.midX - size.width / 2,
                      y: elementRect.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    private static func draw(_ primitive: GraphicPrimitive,
                             context: inout GraphicsContext,
                             rect: CGRect,
                             sourceWidth: Int,
                             sourceHeight: Int,
                             pictureStates: [ExactText: PictureState]) {
        let scaleX = rect.width / CGFloat(sourceWidth)
        let scaleY = rect.height / CGFloat(sourceHeight)
        func x(_ value: Int) -> CGFloat { rect.minX + CGFloat(value) * scaleX }
        func y(_ value: Int) -> CGFloat { rect.minY + CGFloat(value) * scaleY }

        switch primitive {
        case let .rect(px, py, width, height, fill):
            let shape = Path(CGRect(x: x(px), y: y(py), width: CGFloat(width) * scaleX, height: CGFloat(height) * scaleY))
            context.fill(shape, with: .color(Self.color(fill)))
        case let .circle(cx, cy, radius, fill):
            let width = CGFloat(radius) * scaleX
            let height = CGFloat(radius) * scaleY
            let shape = Path(ellipseIn: CGRect(x: x(cx) - width, y: y(cy) - height, width: width * 2, height: height * 2))
            context.fill(shape, with: .color(Self.color(fill)))
        case let .line(x1, y1, x2, y2, stroke, strokeWidth):
            var path = Path()
            path.move(to: CGPoint(x: x(x1), y: y(y1)))
            path.addLine(to: CGPoint(x: x(x2), y: y(y2)))
            context.stroke(path, with: .color(Self.color(stroke)), lineWidth: CGFloat(strokeWidth) * min(scaleX, scaleY))
        case let .text(px, py, value, fill, fontSize, align):
            let anchor: UnitPoint
            switch align {
            case .start: anchor = .bottomLeading
            case .middle: anchor = .bottom
            case .end: anchor = .bottomTrailing
            }
            let text = Text(value.rawValue)
                .font(.system(size: CGFloat(fontSize) * min(scaleX, scaleY)))
                .foregroundColor(Self.color(fill))
            context.draw(text, at: CGPoint(x: x(px), y: y(py)), anchor: anchor)
        case let .image(px, py, width, height, file):
            let elementRect = CGRect(x: x(px), y: y(py),
                                     width: CGFloat(width) * scaleX,
                                     height: CGFloat(height) * scaleY)
            switch pictureStates[file] {
            case let .ready(picture):
                let imageRect = Self.imageDestinationRect(
                    imageSize: CGSize(width: picture.image.width, height: picture.image.height),
                    in: elementRect)
                context.draw(Image(decorative: picture.image, scale: 1), in: imageRect)
            case .unavailable:
                Self.drawPictureFallback(in: elementRect, context: &context)
            case .loading:
                context.fill(Path(elementRect), with: .color(Color.gray.opacity(0.16)))
            case nil:
                if elementRect.isEmpty {
                    break
                }
                context.fill(Path(elementRect), with: .color(Color.gray.opacity(0.16)))
            }
        }
    }

    private static func drawPictureFallback(in rect: CGRect, context: inout GraphicsContext) {
        var fallbackContext = context
        fallbackContext.clip(to: Path(rect))
        fallbackContext.fill(Path(roundedRect: rect, cornerSize: CGSize(width: 6, height: 6)),
                             with: .color(Color.gray.opacity(0.32)))
        let fontSize = min(12, max(7, rect.width / 14))
        let label = Text("Picture could not\nbe shown")
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(.primary)
            .multilineTextAlignment(.center)
        fallbackContext.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private static func draw(_ point: PointValue, context: inout GraphicsContext, rect: CGRect) {
        let center = CGPoint(x: rect.minX + rect.width * CGFloat(point.x) / 1000,
                             y: rect.minY + rect.height * CGFloat(point.y) / 1000)
        let radius: CGFloat = 8
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(.white))
        context.stroke(circle, with: .color(.blue), lineWidth: 2)
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - 13, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + 13, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 13))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + 13))
        context.stroke(cross, with: .color(.blue), lineWidth: 2)
    }

    private static func color(_ value: ExactText) -> Color {
        let digits = Array(value.rawValue.utf8.dropFirst())
        guard digits.count == 6 else { return .clear }
        let parts = stride(from: 0, to: 6, by: 2).map { index in
            UInt8(String(decoding: digits[index..<(index + 2)], as: UTF8.self), radix: 16) ?? 0
        }
        return Color(red: Double(parts[0]) / 255, green: Double(parts[1]) / 255, blue: Double(parts[2]) / 255)
    }
}

struct AdaptiveGridLayout: Layout {
    let maxColumns: Int
    let minimumItemWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = max(1, proposal.width ?? minimumItemWidth * CGFloat(maxColumns))
        let columns = columnCount(width: availableWidth)
        let cellWidth = max(1, (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)) }
        var height: CGFloat = 0
        for start in stride(from: 0, to: sizes.count, by: columns) {
            let row = sizes[start..<min(start + columns, sizes.count)]
            height += row.map(\.height).max() ?? 0
            if start + columns < sizes.count { height += spacing }
        }
        return CGSize(width: availableWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(width: bounds.width)
        let cellWidth = max(1, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)) }
        var rowY = bounds.minY
        for start in stride(from: 0, to: sizes.count, by: columns) {
            let end = min(start + columns, sizes.count)
            let rowHeight = sizes[start..<end].map(\.height).max() ?? 0
            for index in start..<end {
                let column = index - start
                let origin = CGPoint(x: bounds.minX + CGFloat(column) * (cellWidth + spacing), y: rowY)
                subviews[index].place(at: origin,
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: cellWidth, height: rowHeight))
            }
            rowY += rowHeight + spacing
        }
    }

    private func columnCount(width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (minimumItemWidth + spacing))))
    }
}

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +))
        let result = layout(subviews, width: width)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: max(1, bounds.width))
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.origin.x,
                                              y: bounds.minY + placement.origin.y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: placement.size.width, height: placement.size.height))
        }
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (placements: [FlowPlacement], height: CGFloat) {
        var placements: [FlowPlacement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let itemWidth = min(width, max(44, ideal.width))
            let size = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            if x > 0 && x + itemWidth > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            placements.append(FlowPlacement(origin: CGPoint(x: x, y: y), size: CGSize(width: itemWidth, height: size.height)))
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (placements, placements.isEmpty ? 0 : y + rowHeight)
    }
}

private struct FlowPlacement {
    let origin: CGPoint
    let size: CGSize
}
