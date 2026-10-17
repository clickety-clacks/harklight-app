import AttentionDomain
import CryptoKit
import Foundation

public enum ConversationFileTransportError: Error, Equatable {
    case server(status: Int, reason: ExactText)
}

/// Raw-byte file routes on the existing server. The separately configured port
/// must be supplied explicitly; enrollment/relay ports never imply it.
public struct ConversationFileWire: Sendable {
    public let profile: ProfileContext
    public let originURL: URL
    public init(profile: ProfileContext, originURL: URL, endpointHost: String? = nil) throws {
        guard profile.transportMode == .relay else { throw RelayWireError.wrongActor }
        guard originURL.scheme == "https",
              originURL.host == (endpointHost ?? profile.identity.trustedRelayAuthority.rawValue),
              originURL.port != nil, originURL.path == "/origin/v1", originURL.query == nil,
              originURL.fragment == nil, originURL.user == nil, originURL.password == nil else {
            throw InstallationTransportError.invalidEndpoint
        }
        self.profile = profile
        self.originURL = originURL
    }
    public func limitsRequest() -> URLRequest {
        var request = URLRequest(url: originURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"v":1,"type":"file_limits","ref":"native-file-limits"}"#.utf8)
        return request
    }
    public func decodeLimits(_ data: Data, status: Int) throws -> ConversationFileLimits {
        let value = try response(data, status: status)
        let inline = try integer(value, "inline_decoded_bytes_per_entry")
        let cap: UInt64?
        if value.uniqueValue(named: "upload_cap_bytes_per_file") == .string(ExactText("none")) { cap = nil }
        else { cap = try integer(value, "upload_cap_bytes_per_file") }
        return ConversationFileLimits(inlineDecodedBytes: inline, uploadCap: cap)
    }
    public func discardRequest(_ cleanup: ConversationUploadCleanup) throws -> URLRequest {
        let binding = cleanup.binding
        guard binding.request.accountScope == profile.identity.personID, binding.revision > 0 else {
            throw RelayWireError.invalidFrame
        }
        var request = URLRequest(url: originURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let frame = JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("discard_uploads"))),
            JSONMember("ref", .string(ExactText("native-upload-cleanup"))),
            JSONMember("op_id", .string(ExactText(cleanup.id.uuidString.lowercased()))),
            JSONMember("sender_id", .string(binding.request.senderID)),
            JSONMember("message_id", .string(binding.request.messageID)),
            JSONMember("revision", .number(JSONNumber(lexeme: String(binding.revision))))
        ])
        request.httpBody = Data(frame.jsonString.utf8)
        return request
    }
    public func decodeDiscard(_ data: Data, status: Int) throws -> ConversationUploadDiscardResult {
        let value = try response(data, status: status)
        guard let raw = value.uniqueValue(named: "state")?.stringValue,
              let state = ConversationUploadDiscardResult.State(rawValue: raw.rawValue) else {
            throw RelayWireError.invalidFrame
        }
        return ConversationUploadDiscardResult(state: state, discarded: try integer(value, "discarded"))
    }
    public func uploadRequest(file: ConversationFile, binding: ConversationBinding, operationID: UUID) throws -> URLRequest {
        guard binding.request.accountScope == profile.identity.personID, binding.revision > 0,
              !file.name.rawValue.isEmpty else { throw RelayWireError.invalidFrame }
        var request = URLRequest(url: originURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(file.byteCount), forHTTPHeaderField: "Content-Length")
        request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "X-Harklight-Op-Id")
        request.setValue(binding.request.senderID.rawValue, forHTTPHeaderField: "X-Harklight-Sender-Id")
        request.setValue(binding.request.messageID.rawValue, forHTTPHeaderField: "X-Harklight-Message-Id")
        request.setValue(String(binding.revision), forHTTPHeaderField: "X-Harklight-Request-Revision")
        let encoded = Data(file.name.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        request.setValue(encoded, forHTTPHeaderField: "X-Harklight-File-Name")
        return request
    }
    public func decodeUpload(_ data: Data, status: Int, original: ConversationFile) throws -> ConversationFile {
        let value = try response(data, status: status)
        guard let id = value.uniqueValue(named: "upload_id")?.stringValue, UUID(uuidString: id.rawValue) != nil,
              value.uniqueValue(named: "name") == .string(original.name),
              try integer(value, "size") == original.byteCount,
              value.uniqueValue(named: "sha256") == .string(original.sha256) else { throw ConversationError.fileMismatch }
        return ConversationFile(id: original.id, name: original.name, byteCount: original.byteCount,
            sha256: original.sha256, content: .uploaded(id))
    }
    public func fetchRequest(_ file: ConversationFile) throws -> URLRequest {
        guard case let .uploaded(id) = file.content, UUID(uuidString: id.rawValue) != nil else {
            throw ConversationError.fileMismatch
        }
        return URLRequest(url: originURL.appendingPathComponent("files").appendingPathComponent(id.rawValue))
    }
    public func verify(_ url: URL, file: ConversationFile) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += UInt64(chunk.count)
            hash.update(data: chunk)
        }
        guard count == file.byteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256.rawValue else {
            throw ConversationError.fileMismatch
        }
    }
    private func response(_ data: Data, status: Int) throws -> JSONValue {
        let value = try JSONValue.parse(data)
        guard case .object = value, value.hasUniqueObjectKeys, value.uniqueValue(named: "v")?.integerValue == 1 else {
            throw RelayWireError.invalidFrame
        }
        guard status == 200, value.uniqueValue(named: "type") == .string(ExactText("ok")) else {
            throw ConversationFileTransportError.server(status: status,
                reason: value.uniqueValue(named: "reason")?.stringValue ?? ExactText("Unexpected file service response"))
        }
        return value
    }
    private func integer(_ value: JSONValue, _ key: String) throws -> UInt64 {
        guard case let .number(number)? = value.uniqueValue(named: key), let integer = UInt64(number.lexeme) else {
            throw RelayWireError.invalidFrame
        }
        return integer
    }
}
