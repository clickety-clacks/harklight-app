import Foundation

// The Harklight client API (r2): resources over parallel HTTPS and one change
// feed. These types carry requests and responses without knowing the field
// schemas, which the Server's `docs/client-api-v2.md` defines; the components
// that read and write the local model own those.

/// A person's change-log position. Every read and write reports the `rev` it
/// reflects, and the change feed is numbered by it.
public typealias Rev = UInt64

public struct APIRequest: Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }

    public var method: Method
    /// Path below the API root, for example `/v2/inbox`.
    public var path: String
    public var query: [String: String]
    public var body: Data?
    public var contentType: String?
    /// Minted once at user intent and persisted with the frozen request.
    public var idempotencyKey: UUID?
    public var ifMatch: String?

    public init(method: Method, path: String, query: [String: String] = [:], body: Data? = nil,
                contentType: String? = nil, idempotencyKey: UUID? = nil, ifMatch: String? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType ?? (body == nil ? nil : "application/json")
        self.idempotencyKey = idempotencyKey
        self.ifMatch = ifMatch
    }

    public static func get(_ path: String, query: [String: String] = [:]) -> Self {
        Self(method: .get, path: path, query: query)
    }
}

public struct APIResponse: Equatable, Sendable {
    public let status: Int
    /// Server-issued and safe to log.
    public let requestID: String?
    public let body: Data
    public let etag: String?
    /// The server returned the stored response of an earlier identical
    /// request. It counts as the original outcome.
    public let replayed: Bool

    public init(status: Int, requestID: String?, body: Data, etag: String? = nil, replayed: Bool = false) {
        self.status = status
        self.requestID = requestID
        self.body = body
        self.etag = etag
        self.replayed = replayed
    }

    /// The `rev` member of a JSON response body.
    public var rev: Rev? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["rev"].flatMap(Self.rev)
    }

    static func rev(_ value: Any) -> Rev? {
        if let number = value as? NSNumber, number.int64Value >= 0,
           CFNumberGetType(number) != .float64Type, CFNumberGetType(number) != .float32Type {
            return Rev(number.int64Value)
        }
        return nil
    }
}

/// Error tokens are a closed list in the API contract; anything else is
/// `other`, so no free-form server text is ever kept.
public enum APIErrorToken: String, Equatable, Sendable, CaseIterable {
    case notFound = "not_found"
    case invalidField = "invalid_field"
    case staleRequest = "stale_request"
    case alreadyAnswered = "already_answered"
    case alreadyRetracted = "already_retracted"
    case idempotencyConflict = "idempotency_conflict"
    case preconditionFailed = "precondition_failed"
    case cursorExpired = "cursor_expired"
    case unauthorized
    case forbidden
    case retryLater = "retry_later"
    case storageUnavailable = "storage_unavailable"
    case payloadTooLarge = "payload_too_large"
    case unsupported
    case other
}

/// A non-2xx answer from the server.
public struct APIError: Error, Equatable, Sendable {
    public let status: Int
    public let token: APIErrorToken
    public let retryable: Bool
    public let requestID: String?
    public let retryAfter: TimeInterval?

    public init(status: Int, token: APIErrorToken, retryable: Bool, requestID: String?,
                retryAfter: TimeInterval? = nil) {
        self.status = status
        self.token = token
        self.retryable = retryable
        self.requestID = requestID
        self.retryAfter = retryAfter
    }

    /// Reads `{error, retryable, request_id}`. A body that is missing or
    /// unreadable still yields the status, with `retryable` taken from it.
    public init(status: Int, body: Data, requestID: String?, retryAfter: TimeInterval?) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let token = (object?["error"] as? String).flatMap(APIErrorToken.init(rawValue:)) ?? .other
        let retryable = (object?["retryable"] as? Bool) ?? (status == 503 || status == 429)
        let bodyRequestID = object?["request_id"] as? String
        self.init(status: status, token: token, retryable: retryable,
                  requestID: requestID ?? bodyRequestID, retryAfter: retryAfter)
    }

    /// A definitive refusal: the same request will never succeed.
    public var isPermanent: Bool { !retryable && status != 401 && status != 503 }
}

/// One change from the feed, carrying the resulting state, not a delta.
public struct FeedChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case item, itemRemoved, entry, counts, settings
        case other(String)

        init(_ name: String) {
            switch name {
            case "item": self = .item
            case "item_removed": self = .itemRemoved
            case "entry": self = .entry
            case "counts": self = .counts
            case "settings": self = .settings
            default: self = .other(name)
            }
        }
    }

    public let rev: Rev
    public let kind: Kind
    public let data: Data

    public init(rev: Rev, kind: Kind, data: Data) {
        self.rev = rev
        self.kind = kind
        self.data = data
    }
}

/// What the live feed delivers, in order.
public enum FeedEvent: Equatable, Sendable {
    /// The server accepted the feed request (HTTP 200).
    case opened(requestID: String?)
    case change(FeedChange)
    /// Sent before a server-initiated end.
    case closing(reason: String)
}

/// One batch of the feed, for catch-up without holding a stream.
public struct FeedBatch: Equatable, Sendable {
    public let changes: [FeedChange]
    public let rev: Rev
    public let more: Bool

    public init(changes: [FeedChange], rev: Rev, more: Bool) {
        self.changes = changes
        self.rev = rev
        self.more = more
    }
}

/// The only way any component reaches the server. Every request stands alone;
/// any number may be in flight. Implementations throw `APIError` for a non-2xx
/// answer and the system error for a transport failure.
public protocol ClientAPITransport: Sendable {
    func send(_ request: APIRequest) async throws -> APIResponse
    /// `GET /v2/changes?after=` as Server-Sent Events: the backlog after
    /// `after`, then live changes, with no gap. A `410` is thrown as
    /// `APIError` with token `cursor_expired`.
    func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error>
    /// `GET /v2/changes?after=` as one JSON batch.
    func changeBatch(after: Rev) async throws -> FeedBatch
}

extension ErrorLogCorrelation {
    /// The server's `Request-Id` is the only identifier kept from a response.
    static func request(_ requestID: String?, operationID: UUID? = nil) -> Self {
        ErrorLogCorrelation(clientOperationID: operationID, requestID: requestID)
    }
}

extension ErrorLogReason {
    /// An API refusal is recorded by its status and closed-list token; a
    /// transport failure by its system domain and code.
    static func api(_ error: any Error) -> Self {
        if let error = error as? APIError {
            return error.token == .other ? .app("http_\(error.status)") : .serverReason(error.token.rawValue)
        }
        return .relay(error)
    }
}
