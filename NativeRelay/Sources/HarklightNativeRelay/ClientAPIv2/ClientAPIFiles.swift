import AttentionDomain
import Foundation

/// Stages a draft file, discards an unused upload, or fetches an attached file.
/// The reply outbox receives only staged handles after upload succeeds.
public struct ClientAPIFiles: Sendable {
    private let transport: any ClientAPITransport

    public init(transport: any ClientAPITransport) {
        self.transport = transport
    }

    /// The caller keeps this key with the staged draft operation for retries.
    public func upload(_ bytes: Data, name: ExactText, contentType: String,
                       idempotencyKey: UUID) async throws -> APIFileCreated {
        guard !name.rawValue.isEmpty,
              let filename = name.rawValue.addingPercentEncoding(withAllowedCharacters: Self.filenameCharacters) else {
            throw ClientAPIModelError.invalid("file_created.name")
        }
        let reply = try await transport.send(APIRequest(method: .post, path: "/v2/files",
            body: bytes, contentType: contentType, idempotencyKey: idempotencyKey,
            contentDisposition: "attachment; filename*=UTF-8''\(filename)"))
        return try APIFileCreated(json: JSONValue.parse(reply.body))
    }

    public func download(_ id: FileDownloadID) async throws -> Data {
        let response = try await transport.send(APIRequest(method: .get,
            path: Self.path(id.value), accept: "*/*"))
        return response.body
    }

    public func discard(_ handle: UploadHandle) async throws {
        _ = try await transport.send(APIRequest(method: .delete, path: Self.path(handle.value)))
    }

    private static func path(_ id: ExactText) -> String {
        "/v2/files/\(ClientAPIWrites.component(id))"
    }

    /// The unreserved ASCII subset of RFC 5987's attr-char.
    private static let filenameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
