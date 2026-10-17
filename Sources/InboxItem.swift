import AttentionDomain

/// An identity-bound row from an ordinary domain projection, with optional local
/// visual metadata. Both sources use the same inbox navigation and card surface.
enum InboxItem: Identifiable {
    case request(InboxRequestRow)
    case example(SampleMessage, SampleResponse)

    var id: InboxSelection {
        switch self {
        case let .request(row): .request(row.key)
        case let .example(message, _): .sample(message.id)
        }
    }

    var preview: InboxCardPreview {
        switch self {
        case let .request(row): InboxCardPreview(sender: row.sender, title: row.title, body: row.bodyText ?? "")
        case let .example(message, _): InboxCardPreview(sender: message.sender, title: message.title, body: message.body)
        }
    }

    var accessibilityID: String {
        switch self {
        case let .request(row): "request-row-" + row.key.messageID.rawValue
        case let .example(message, _): message.id
        }
    }
}
