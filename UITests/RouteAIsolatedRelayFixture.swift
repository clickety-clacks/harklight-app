import Foundation
import Network
import Security
import XCTest

/// An in-process localhost relay for the live-app UI tests. It speaks only the
/// Route A replay, projection and answer frames exercised by these cases.
final class RouteAIsolatedRelayFixture {
    private let relay: Relay
    let personID = "routea-ui-\(UUID().uuidString.lowercased())"

    init() throws {
        relay = try Relay()
    }

    func start() async throws {
        try await relay.start()
    }

    @MainActor
    func configure(_ app: XCUIApplication) {
        app.launchArguments = ["--harklight-routea-isolated-relay"]
        app.launchEnvironment["HARKLIGHT_ROUTEA_TEST_PERSON_ID"] = personID
        app.launchEnvironment["HARKLIGHT_ROUTEA_TEST_RELAY_PORT"] = String(relay.port)
        app.launchEnvironment["HARKLIGHT_ROUTEA_TEST_ROOT_DER"] = relay.rootDER.base64EncodedString()
    }

    var answerOperationCount: Int { relay.answerOperationCount }
    var requestSummary: String { relay.requestSummary }

    func waitForAcceptedAnswer(timeout: TimeInterval) -> String? {
        relay.waitForAcceptedAnswer(timeout: timeout)
    }

    func waitForTerminalAcknowledgement(timeout: TimeInterval) -> Bool {
        relay.waitForTerminalAcknowledgement(timeout: timeout)
    }

    func stop() {
        relay.stop()
    }

    private final class Relay: @unchecked Sendable {
        private let queue = DispatchQueue(label: "routea-isolated-relay")
        private let condition = NSCondition()
        private let credential: ServerCredential
        private let listener: NWListener
        private var readyContinuation: CheckedContinuation<UInt16, any Error>?
        private var readyPort: UInt16?
        private var startupError: (any Error)?
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var acceptedOperationID: String?
        private var answerOperations: [String] = []
        private var receivedFrameTypes: [String: Int] = [:]
        private var answerFrameRejection: String?
        private var terminalPublished = false
        private var terminalRefreshCount = 0
        private var stopped = false

        let rootDER: Data

        var port: UInt16 {
            condition.lock()
            defer { condition.unlock() }
            return readyPort ?? 0
        }

        var answerOperationCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return answerOperations.count
        }

        var acknowledgementCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return (receivedFrameTypes["ack"] ?? 0) +
                (receivedFrameTypes["conversation_ack"] ?? 0)
        }

        var requestSummary: String {
            condition.lock()
            defer { condition.unlock() }
            let types = receivedFrameTypes.keys.sorted().map {
                "\($0):\(receivedFrameTypes[$0] ?? 0)"
            }.joined(separator: ",")
            return "types=[\(types)] answer_gate=\(answerFrameRejection ?? "not-rejected") " +
                "terminal_refreshes=\(terminalRefreshCount)"
        }

        init() throws {
            let credential = try ServerCredential.create()
            let tls = NWProtocolTLS.Options()
            guard let localIdentity = sec_identity_create(credential.identity) else {
                throw FixtureError.identityUnavailable
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            parameters.allowLocalEndpointReuse = true
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            let listener = try NWListener(using: parameters, on: .any)
            self.credential = credential
            self.rootDER = credential.certificateDER
            self.listener = listener
        }

        func start() async throws {
            let _: UInt16 = try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                if let readyPort {
                    condition.unlock()
                    continuation.resume(returning: readyPort)
                    return
                }
                if let startupError {
                    condition.unlock()
                    continuation.resume(throwing: startupError)
                    return
                }
                readyContinuation = continuation
                condition.unlock()

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port?.rawValue else {
                            self.completeStart(.failure(FixtureError.listenerMissingPort))
                            return
                        }
                        self.completeStart(.success(port))
                    case let .failed(error):
                        self.completeStart(.failure(error))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }

        private func completeStart(_ result: Result<UInt16, any Error>) {
            condition.lock()
            switch result {
            case let .success(port): readyPort = port
            case let .failure(error): startupError = error
            }
            let continuation = readyContinuation
            readyContinuation = nil
            condition.broadcast()
            condition.unlock()
            switch result {
            case let .success(port): continuation?.resume(returning: port)
            case let .failure(error): continuation?.resume(throwing: error)
            }
        }

        private func accept(_ connection: NWConnection) {
            let identifier = ObjectIdentifier(connection)
            condition.lock()
            connections[identifier] = connection
            condition.unlock()
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.condition.lock()
                    self.connections.removeValue(forKey: identifier)
                    self.condition.unlock()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        private func receive(on connection: NWConnection) {
            connection.receiveMessage { [weak self, weak connection] data, _, _, error in
                guard let self, let connection else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                if let data, !data.isEmpty { self.handle(data, on: connection) }
                self.receive(on: connection)
            }
        }

        private func handle(_ data: Data, on connection: NWConnection) {
            guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = frame["type"] as? String else { return }
            condition.lock()
            receivedFrameTypes[type, default: 0] += 1
            condition.unlock()
            switch type {
            case "resync":
                replyToResync(on: connection)
            case "ack", "conversation_ack":
                // Route A sends neither event nor conversation acknowledgments.
                // The frame summary lets the UI test detect either violation.
                break
            case "conversation_open":
                send(["v": 1, "type": "ok", "ref": "native-conversation-sync",
                      "origin_https_port": 9443], on: connection)
                send(["v": 1, "type": "conversation_resynced", "conversation_seq": 0],
                     on: connection)
            case "conversation_ack":
                let sequence = (frame["conversation_seq"] as? NSNumber)?.uint64Value ?? 0
                send(["v": 1, "type": "ok", "ref": "native-conversation-ack",
                      "conversation_seq": sequence], on: connection)
            case "message_open":
                send(["v": 1, "type": "ok", "ref": "native-message-open",
                      "op_id": frame["op_id"] as? String ?? "",
                      "sender_id": frame["sender_id"] as? String ?? "",
                      "message_id": frame["message_id"] as? String ?? "",
                      "request_revision": frame["request_revision"] as? Int ?? 1,
                      "opened": true], on: connection)
            case "view_get":
                send(["v": 1, "type": "error", "ref": frame["ref"] as? String ?? "",
                      "reason": "unknown_type"], on: connection)
            case "answer":
                acceptAnswer(frame, on: connection)
            default:
                if let ref = frame["ref"] as? String {
                    send(["v": 1, "type": "error", "ref": ref, "reason": "unknown_type"],
                         on: connection)
                }
            }
        }

        private func replyToResync(on connection: NWConnection) {
            let events = currentEvents()
            let highWater = events.compactMap { ($0["seq"] as? NSNumber)?.uint64Value }.max() ?? 0
            if events.contains(where: { ($0["type"] as? String) == "lifecycle" }) {
                condition.lock()
                terminalRefreshCount += 1
                condition.broadcast()
                condition.unlock()
            }
            send(["v": 1, "type": "ok", "ref": "native-sync"], on: connection)
            for event in events { send(event, on: connection) }
            send(["v": 1, "type": "resynced", "seq": highWater], on: connection)
        }

        private func acceptAnswer(_ frame: [String: Any], on connection: NWConnection) {
            guard let operationID = frame["op_id"] as? String else {
                rejectAnswer("missing-operation-id", on: connection)
                return
            }
            guard UUID(uuidString: operationID) != nil else {
                rejectAnswer("invalid-operation-id", on: connection)
                return
            }
            guard frame["sender_id"] as? String == "routea-ui-author" else {
                rejectAnswer("unexpected-sender", on: connection)
                return
            }
            guard frame["message_id"] as? String == "review-01" else {
                rejectAnswer("unexpected-message", on: connection)
                return
            }
            condition.lock()
            answerOperations.append(operationID)
            if acceptedOperationID == nil || acceptedOperationID == operationID {
                acceptedOperationID = operationID
                terminalPublished = true
                condition.broadcast()
                condition.unlock()
                send(["v": 1, "type": "ok", "seq": 3], on: connection)
            } else {
                condition.unlock()
                send(["v": 1, "type": "error", "reason": "operation_conflict"], on: connection)
            }
        }

        private func rejectAnswer(_ reason: String, on connection: NWConnection) {
            condition.lock()
            answerFrameRejection = reason
            condition.unlock()
            send(["v": 1, "type": "error", "reason": "invalid_operation"], on: connection)
        }

        private func currentEvents() -> [[String: Any]] {
            condition.lock()
            let hasTerminal = terminalPublished
            condition.unlock()
            var events = [Self.reviewDelivery(), Self.facilitiesDelivery()]
            if hasTerminal { events.append(Self.confirmedAnswer()) }
            return events
        }

        func waitForAcceptedAnswer(timeout: TimeInterval) -> String? {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while acceptedOperationID == nil, condition.wait(until: deadline) {}
            return acceptedOperationID
        }

        func waitForTerminalLifecycleRefresh(timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while terminalRefreshCount == 0, condition.wait(until: deadline) {}
            return terminalRefreshCount > 0
        }

        func stop() {
            condition.lock()
            guard !stopped else {
                condition.unlock()
                return
            }
            stopped = true
            let activeConnections = Array(connections.values)
            connections.removeAll()
            condition.unlock()
            listener.cancel()
            activeConnections.forEach { $0.cancel() }
        }

        private func send(_ object: [String: Any], on connection: NWConnection) {
            guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return
            }
            data.append(0x0a)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "routea-relay-response",
                                                       metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }

        private static func reviewDelivery() -> [String: Any] {
            [
                "v": 1,
                "type": "delivery",
                "seq": 1,
                "sender_id": "routea-ui-author",
                "message_id": "review-01",
                "origin": "routea-ui-source-device",
                "as": "message",
                "message": [
                    "created_at": 1_791_792_000_000,
                    "title": "Studio review",
                    "body": "Choose a cover or send a note.",
                    "answer_ui": [
                        "schema": "attention-client.ui/1",
                        "requires": ["scene/1", "result/1", "response/1"],
                        "illustrations": [],
                        "inputs": [[
                            "kind": "response",
                            "id": "review",
                            "label": "Studio response",
                            "actions": [
                                ["id": "cover-a", "label": "Cover A", "kind": "value", "value": "a"],
                                ["id": "cover-b", "label": "Cover B", "kind": "value", "value": "b"]
                            ]
                        ]],
                        "open": ["kind": "input", "id": "review", "layout": "cards"],
                        "resolved": ["kind": "text", "text": "Answered.", "style": "body"],
                        "submission": [
                            "label": "Send",
                            "result": ["kind": "object", "members": [[
                                "name": "response",
                                "value": ["kind": "input", "id": "review"]
                            ]]]
                        ]
                    ]
                ],
                "event_id": "routea-delivery-review",
                "session_handle": "routea-session-review",
                "request_revision": 1
            ]
        }

        private static func facilitiesDelivery() -> [String: Any] {
            [
                "v": 1,
                "type": "delivery",
                "seq": 2,
                "sender_id": "routea-ui-author",
                "message_id": "facilities-01",
                "origin": "routea-ui-source-device",
                "as": "message",
                "message": [
                    "created_at": 1_791_792_000_001,
                    "title": "Facilities desk",
                    "body": "Add a short note for the facilities desk.",
                    "answer_ui": [
                        "schema": "attention-client.ui/1",
                        "requires": ["scene/1", "result/1", "text/1"],
                        "illustrations": [],
                        "inputs": [["kind": "text", "id": "note", "label": "Reply"]],
                        "open": ["kind": "input", "id": "note", "layout": "editor"],
                        "resolved": ["kind": "text", "text": "Answered.", "style": "body"],
                        "submission": [
                            "label": "Send",
                            "result": ["kind": "object", "members": [[
                                "name": "note",
                                "value": ["kind": "input", "id": "note"]
                            ]]]
                        ]
                    ]
                ],
                "event_id": "routea-delivery-facilities",
                "session_handle": "routea-session-facilities",
                "request_revision": 1
            ]
        }

        private static func confirmedAnswer() -> [String: Any] {
            [
                "v": 1,
                "type": "lifecycle",
                "seq": 3,
                "sender_id": "routea-ui-author",
                "message_id": "review-01",
                "origin": "routea-ui-source-device",
                "state": "answered",
                "answer_outcome": ["kind": "default", "value": "a"],
                "event_id": "routea-answer-confirmed",
                "request_revision": 1
            ]
        }
    }

    private struct ServerCredential {
        let identity: SecIdentity
        let certificateDER: Data

        static func create() throws -> ServerCredential {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048
            ]
            var keyError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
                let detail = keyError.map { String(describing: $0.takeRetainedValue()) } ?? "no Security error detail"
                throw FixtureError.keyCreation(detail)
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw FixtureError.publicKeyUnavailable
            }
            var publicKeyError: Unmanaged<CFError>?
            guard let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &publicKeyError) as Data? else {
                let detail = publicKeyError.map { String(describing: $0.takeRetainedValue()) } ?? "no Security error detail"
                throw FixtureError.publicKeyExport(detail)
            }
            let certificateDER = try Self.selfSignedLocalhostCertificate(
                publicKeyDER: publicKeyDER, privateKey: privateKey)
            guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
                throw FixtureError.certificateCreation
            }
            guard let identity = SecIdentityCreate(kCFAllocatorDefault, certificate, privateKey) else {
                throw FixtureError.identityUnavailable
            }
            return ServerCredential(identity: identity, certificateDER: certificateDER)
        }

        private static func selfSignedLocalhostCertificate(publicKeyDER: Data,
                                                             privateKey: SecKey) throws -> Data {
            let rsa = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]), DER.null)
            let signature = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]), DER.null)
            let name = DER.sequence(DER.value(0x31, DER.sequence(
                DER.oid([0x55, 4, 3]), DER.value(0x0c, Data("localhost".utf8)))))
            var serial = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
                throw FixtureError.certificateCreation
            }
            serial[0] |= 1
            let now = Date()
            let validity = DER.sequence(DER.time(now.addingTimeInterval(-300)),
                                        DER.time(now.addingTimeInterval(7 * 24 * 60 * 60)))
            let subjectPublicKey = DER.sequence(rsa, DER.bitString(publicKeyDER))
            let basicConstraints = DER.sequence(
                DER.oid([0x55, 0x1d, 0x13]), DER.value(1, Data([0xff])),
                DER.value(4, DER.sequence(DER.value(1, Data([0xff])))))
            let keyUsage = DER.sequence(
                DER.oid([0x55, 0x1d, 0x0f]), DER.value(1, Data([0xff])),
                DER.value(4, DER.value(3, Data([2, 0xa4]))))
            let serverAuth = DER.sequence(
                DER.oid([0x55, 0x1d, 0x25]),
                DER.value(4, DER.sequence(DER.oid([0x2b, 6, 1, 5, 5, 7, 3, 1]))))
            let localhostName = DER.sequence(
                DER.oid([0x55, 0x1d, 0x11]),
                DER.value(4, DER.sequence(DER.value(0x82, Data("localhost".utf8)))))
            let extensions = DER.value(0xa3, DER.sequence(basicConstraints, keyUsage,
                                                           serverAuth, localhostName))
            let tbs = DER.sequence(DER.value(0xa0, DER.value(2, Data([2]))),
                                   DER.integer(Data(serial)), signature, name, validity, name,
                                   subjectPublicKey, extensions)
            var signatureError: Unmanaged<CFError>?
            guard let signed = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                      tbs as CFData, &signatureError) as Data? else {
                throw FixtureError.certificateCreation
            }
            return DER.sequence(tbs, signature, DER.bitString(signed))
        }
    }

    private enum DER {
        static let null = Data([5, 0])

        static func value(_ tag: UInt8, _ content: Data) -> Data {
            var length = content.count
            var bytes: [UInt8] = []
            if length < 128 {
                bytes = [UInt8(length)]
            } else {
                while length > 0 {
                    bytes.insert(UInt8(length & 0xff), at: 0)
                    length >>= 8
                }
                bytes.insert(0x80 | UInt8(bytes.count), at: 0)
            }
            return Data([tag] + bytes) + content
        }

        static func sequence(_ items: Data...) -> Data {
            value(0x30, items.reduce(Data(), +))
        }

        static func integer(_ content: Data) -> Data {
            var bytes = Array(content)
            while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
            if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
            return value(2, Data(bytes))
        }

        static func oid(_ bytes: [UInt8]) -> Data { value(6, Data(bytes)) }
        static func bitString(_ data: Data) -> Data { value(3, Data([0]) + data) }

        static func time(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let year = formatter.calendar.component(.year, from: date)
            formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
            return value(year < 2050 ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
        }
    }

    private enum FixtureError: Error, LocalizedError {
        case identityUnavailable
        case listenerMissingPort
        case keyCreation(String)
        case publicKeyUnavailable
        case publicKeyExport(String)
        case certificateCreation

        var errorDescription: String? {
            switch self {
            case let .keyCreation(detail): "Temporary signing-key creation failed: \(detail)"
            case .publicKeyUnavailable: "The temporary signing key had no public key."
            case let .publicKeyExport(detail): "Temporary public-key export failed: \(detail)"
            default: nil
            }
        }
    }
}
