import AttentionDomain
import CryptoKit
import Foundation
import Security

public enum InstallationTransportError: Error, Sendable {
    case invalidEndpoint
    case invalidTrustAnchor
    case wrongDeviceIdentity
    case invalidServerTrust
    case unexpectedServerFrame
    case serverRejected
    case conversationsUnavailable
    case acknowledgementBehind
}

/// Observable transport facts for a foreground connection attempt. Offering a
/// client identity is deliberately distinct from evidence that the peer
/// accepted it; a successful WebSocket open is the next observable boundary.
public enum NativeRelayProgressEvent: Equatable, Sendable {
    case serverTrustValidated
    case serverTrustRejected
    case clientIdentityOffered
    case clientIdentityChallengeRejected
    case webSocketOpened
    case relayAdmitted
    /// The client is about to request replay; this does not prove the relay
    /// received or admitted that request.
    case nativeSyncReplayRequested
    case nativeSyncResynced
    case nativeSyncAcknowledged
    case postAckDrainBegan
    case postAckDrainFinished(NativeDiagnosticTransition)
}

/// Security.framework keychain identities are immutable references usable by
/// URLSession's delegate queue. The native enrollment owner retains custody of
/// the private key; only this reference crosses the actor boundary.
public struct TrustedKeychainIdentity: @unchecked Sendable {
    let value: SecIdentity

    public init(_ value: SecIdentity) { self.value = value }
}

/// A keychain-backed installation certificate and an enrollment-approved relay
/// CA are supplied by the native profile owner. No PEM/key bytes enter this API.
/// URLSession presents the identity only to this exact `wss:/relay` endpoint.
public actor URLSessionInstallationSession: AuthenticatedConversationCleanupSession,
    AuthenticatedInboxEventStreamSession, AuthenticatedConversationEventSession {
    public nonisolated let authenticatedIdentity: ProfileIdentity
    public nonisolated let relayEndpointHost: String
    public nonisolated let supportsPostCheckpointInboxEvents = true
    private let delegate: DeviceTLSDelegate
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask
    private let profileContext: ProfileContext
    private let onProgress: @Sendable (NativeRelayProgressEvent) -> Void
    private let onDiagnostic: NativeClientDiagnosticSink
    private let attemptID: UUID?
    private var postCheckpointReader: Task<Void, Never>?
    private var responseFrames: [Data] = []
    private var responseWaiters: [CheckedContinuation<Data, any Error>] = []
    // One queued event bounds native-side memory while the core catches up.
    private var postCheckpointEventFrame: Data?
    private var postCheckpointEventWaiters: [CheckedContinuation<Data, any Error>] = []
    private var postCheckpointEventSpaceWaiters: [CheckedContinuation<Void, any Error>] = []
    private var postCheckpointReadFailure: (any Error)?
    // Coalesced: one pending signal covers every entry after the core's cursor.
    private var liveConversationSignalled = false
    /// True only while a conversation replay holds the socket exchange gate.
    /// Live conversation frames are routed to readers only then.
    private var conversationReplayReading = false
    // A replay frame waits for the queue to empty, so catch-up holds one frame here.
    private var conversationReplaySpaceWaiters: [CheckedContinuation<Void, any Error>] = []
    private var liveConversationWaiters: [CheckedContinuation<Void, any Error>] = []
    private let socketExchangeGate = RelaySocketExchangeGate()
    /// Tests read this to check that a replay's catch-up stays bounded.
    var queuedResponseFrameCount: Int { responseFrames.count }

    public init(profile: ProfileContext,
                relayURL: URL,
                clientIdentity: TrustedKeychainIdentity,
                trustedRootDER: Data,
                attemptID: UUID? = nil,
                onProgress: @escaping @Sendable (NativeRelayProgressEvent) -> Void = { _ in },
                onDiagnostic: @escaping NativeClientDiagnosticSink = { _ in }) throws {
        guard profile.transportMode == .relay,
              relayURL.scheme == "wss",
              relayURL.path == "/relay",
              relayURL.query == nil,
              relayURL.fragment == nil,
              relayURL.user == nil,
              relayURL.password == nil,
              let host = relayURL.host,
              !host.isEmpty,
              host == profile.identity.trustedRelayAuthority.rawValue ||
                HarklightDirectEndpointMigration.allows(profile: profile.identity,
                                                        endpointHost: host.lowercased(),
                                                        trustedRootDER: trustedRootDER) else {
            throw InstallationTransportError.invalidEndpoint
        }
        guard let root = SecCertificateCreateWithData(nil, trustedRootDER as CFData) else {
            throw InstallationTransportError.invalidTrustAnchor
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(clientIdentity.value, &certificate) == errSecSuccess,
              let certificate,
              DeviceCertificateBinding.matches(SecCertificateCopyData(certificate) as Data,
                                               expectedDeviceID: profile.identity.deviceID.rawValue) else {
            throw InstallationTransportError.wrongDeviceIdentity
        }
        authenticatedIdentity = profile.identity
        relayEndpointHost = host.lowercased()
        profileContext = profile
        self.onProgress = onProgress
        self.attemptID = attemptID
        self.onDiagnostic = onDiagnostic
        let delegate = DeviceTLSDelegate(host: host, identity: clientIdentity.value, root: root,
                                         attemptID: attemptID, onProgress: onProgress,
                                         onDiagnostic: onDiagnostic)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        urlSession = session
        task = session.webSocketTask(with: relayURL, protocols: ["attention-relay/1"])
        task.resume()
    }

    public func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await replay(request, ref: "native-sync", event: "delivery", end: "resynced", consume: consume)
    }

    /// Reads one correlated paging or receipt response on the enrolled relay
    /// socket. It never starts replay or sends a mutation.
    public func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        do {
            try await send(request)
            while true {
                let frame = try await receive()
                guard let value = try? JSONValue.parse(frame),
                      case .object = value,
                      value.hasUniqueObjectKeys else {
                    throw InstallationTransportError.unexpectedServerFrame
                }
                let kind = value.uniqueValue(named: "type")?.stringValue?.rawValue
                if kind == "ok" || kind == "error" {
                    guard value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref else {
                        throw InstallationTransportError.unexpectedServerFrame
                    }
                    return frame
                }
                throw InstallationTransportError.unexpectedServerFrame
            }
        } catch {
            close()
            throw error
        }
    }

    /// Opens only the explicit replay half of a confirmed paging checkpoint.
    /// The accepted reply is delivered first, followed by ordinary projections
    /// through `resynced`; the caller owns contiguous validation and ACK.
    public func attachInboxReplay(_ request: Data, ref: String,
                                  consume: @Sendable (Data) async throws -> Void) async throws {
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        do {
            try await send(request)
            var accepted = false
            while true {
                let frame = try await receive()
                guard let value = try? JSONValue.parse(frame),
                      case .object = value,
                      value.hasUniqueObjectKeys,
                      value.uniqueValue(named: "v")?.integerValue == 1 else {
                    throw InstallationTransportError.unexpectedServerFrame
                }
                let kind = value.uniqueValue(named: "type")?.stringValue?.rawValue
                if !accepted {
                    if kind == "error" {
                        guard value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref else {
                            throw InstallationTransportError.unexpectedServerFrame
                        }
                        diagnose(.relay, .ordinaryReplay, .rejected,
                                 causeCode: NativeDiagnosticCauseCode.serverReason(
                                    value.uniqueValue(named: "reason")?.stringValue?.rawValue))
                        throw InstallationTransportError.serverRejected
                    }
                    guard kind == "ok",
                          value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref,
                          value.uniqueValue(named: "paging_version")?.integerValue == 1,
                          value.uniqueValue(named: "checkpoint_accepted") == .bool(true),
                          value.uniqueValue(named: "replay_started") == .bool(true) else {
                        throw InstallationTransportError.unexpectedServerFrame
                    }
                    accepted = true
                    onProgress(.relayAdmitted)
                    diagnose(.connection, .relayAdmission, .completed)
                    try await consume(frame)
                    continue
                }
                if kind == "error" {
                    diagnose(.relay, .ordinaryReplay, .rejected,
                             causeCode: NativeDiagnosticCauseCode.serverReason(
                                value.uniqueValue(named: "reason")?.stringValue?.rawValue))
                    throw InstallationTransportError.serverRejected
                }
                guard kind == "delivery" || kind == "lifecycle" || kind == "resynced" else {
                    throw InstallationTransportError.unexpectedServerFrame
                }
                try await consume(frame)
                if kind == "resynced" {
                    startPostCheckpointReader()
                    return
                }
            }
        } catch {
            diagnose(.relay, .ordinaryReplay,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            close()
            throw error
        }
    }

    public func openConversation(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        // This replay starts at the core's durable cursor, so it already covers
        // every live entry signalled before it.
        liveConversationSignalled = false
        try await replay(request, ref: "native-conversation-sync", event: "conversation", end: "conversation_resynced", consume: consume)
    }

    /// Confirms the candidate TLS/WebSocket endpoint without sending an app
    /// frame. Endpoint migration uses this before replacing a working session.
    public func verifyEndpoint() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func replay(_ request: Data, ref: String, event: String, end: String,
                        consume: @Sendable (Data) async throws -> Void) async throws {
        await socketExchangeGate.enter()
        if event == "conversation" { conversationReplayReading = true }
        defer {
            if event == "conversation" { endConversationReplayReading() }
            socketExchangeGate.leave()
        }
        let area: NativeDiagnosticArea = event == "conversation" ? .conversation : .relay
        let phase: NativeDiagnosticPhase = event == "conversation" ? .conversationReplay : .ordinaryReplay
        do {
            try await send(request)
            var accepted = false
            while true {
                let frame = try await receive()
                let value = try JSONValue.parse(frame)
                let kind = value.uniqueValue(named: "type")?.stringValue?.rawValue
                if kind == "error" {
                    let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue
                    diagnose(area, phase, .rejected, causeCode: NativeDiagnosticCauseCode.serverReason(reason))
                    // Only refusal of this unopened projection means the server
                    // lacks chat. Other refusals still fail confirmation.
                    if event == "conversation", !accepted, reason == "unknown_type",
                       try JSONValue.parse(request).uniqueValue(named: "type")?.stringValue?.rawValue == "conversation_open",
                       value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref {
                        throw InstallationTransportError.conversationsUnavailable
                    }
                    throw InstallationTransportError.serverRejected
                }
                let ordinary = kind == "delivery" || kind == "lifecycle"
                let conversation = kind == "conversation"
                if !accepted {
                    // Incidental known projection frames remain in their own durable
                    // replay journal. This read cannot advance or ACK either cursor.
                    if ordinary || conversation { continue }
                    guard kind == "ok", value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref else {
                        throw InstallationTransportError.unexpectedServerFrame
                    }
                    accepted = true
                    if ref == "native-sync" {
                        onProgress(.relayAdmitted)
                        diagnose(.connection, .relayAdmission, .completed)
                    }
                } else if (event == "conversation" && ordinary) || (event == "delivery" && conversation) {
                    continue
                }
                try await consume(frame)
                if kind == end { return }
            }
        } catch InstallationTransportError.conversationsUnavailable {
            throw InstallationTransportError.conversationsUnavailable
        } catch {
            diagnose(area, phase, NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            throw error
        }
    }

    public func acknowledgeConversation(_ request: Data) async throws {
        try await acknowledgeProjection(request, field: "conversation_seq", ref: "native-conversation-ack")
    }

    public func acknowledge(_ request: Data) async throws {
        try await acknowledgeProjection(request, field: "seq", ref: "native-ack")
    }

    private func acknowledgeProjection(_ request: Data, field: String, ref: String) async throws {
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        let area: NativeDiagnosticArea = field == "conversation_seq" ? .conversation : .relay
        do {
            let requestValue = try JSONValue.parse(request)
            guard case let .number(expectedNumber)? = requestValue.uniqueValue(named: field),
                  let expected = UInt64(expectedNumber.lexeme) else {
                throw InstallationTransportError.unexpectedServerFrame
            }
            try await send(request)
            while true {
                let value = try JSONValue.parse(try await receive())
                switch value.uniqueValue(named: "type")?.stringValue?.rawValue {
                case "ok" where value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref:
                    guard case let .number(actualNumber)? = value.uniqueValue(named: field),
                          UInt64(actualNumber.lexeme) == expected else {
                        throw InstallationTransportError.unexpectedServerFrame
                    }
                    diagnose(area, .acknowledgement, .completed)
                    return
                case "error":
                    let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue
                    if value.uniqueValue(named: "ref")?.stringValue?.rawValue == ref,
                       reason == "invalid_cursor" {
                        diagnose(area, .acknowledgement, .retrying,
                                 causeCode: NativeDiagnosticCauseCode.serverReason(reason))
                        throw InstallationTransportError.acknowledgementBehind
                    }
                    diagnose(area, .acknowledgement, .rejected,
                             causeCode: NativeDiagnosticCauseCode.serverReason(reason))
                    throw InstallationTransportError.serverRejected
                case "delivery", "lifecycle", "conversation":
                    // These remain on the server's replay journal until a future
                    // durable resync. They are never ACKed by this incidental read.
                    continue
                default:
                    throw InstallationTransportError.unexpectedServerFrame
                }
            }
        } catch {
            diagnose(area, .acknowledgement, NativeDiagnosticCauseCode.failureTransition(for: error),
                     error: error)
            throw error
        }
    }

    public func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        do { try await send(frame) }
        catch {
            diagnose(.answer, .originalOperationDelivery,
                     NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                     operationID: operationID, receipt: .unknown)
            close()
            return .unresolved
        }
        while true {
            let frame: Data
            let value: JSONValue
            do {
                frame = try await receive()
                value = try JSONValue.parse(frame)
            }
            catch {
                // The response could still arrive later. Retire this socket
                // so a stale uncorrelated `ok` cannot confirm a later send.
                diagnose(.answer, .originalOperationDelivery,
                         NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                         operationID: operationID, receipt: .unknown)
                close()
                return .unresolved
            }
            switch value.uniqueValue(named: "type")?.stringValue?.rawValue {
            case "ok":
                guard case let .number(number)? = value.uniqueValue(named: "seq"),
                      let sequence = UInt64(number.lexeme), sequence > 0 else {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             causeCode: "invalid_acceptance_sequence", operationID: operationID,
                             receipt: .unknown)
                    close()
                    return .unresolved
                }
                diagnose(.answer, .originalOperationDelivery, .accepted,
                         operationID: operationID, receipt: .acceptedAwaitingReplay)
                return .accepted(operationID: operationID, terminalSequence: sequence)
            case "error":
                let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue
                do {
                    if let result = try RelayWire(profile: profileContext)
                        .decodeAnswerRefusal(frame, operationID: operationID) {
                        diagnose(.answer, .originalOperationDelivery, .rejected,
                                 causeCode: NativeDiagnosticCauseCode.serverReason("retracted"),
                                 operationID: operationID, receipt: .terminal)
                        return result
                    }
                } catch {
                    diagnose(.answer, .originalOperationDelivery, .unresolved,
                             error: error, causeCode: "invalid_retraction_refusal",
                             operationID: operationID, receipt: .unknown)
                    close()
                    return .unresolved
                }
                diagnose(.answer, .originalOperationDelivery, .unresolved,
                         causeCode: NativeDiagnosticCauseCode.serverReason(reason),
                         operationID: operationID, receipt: .unknown)
                return .unresolved
            case "delivery", "lifecycle", "conversation":
                continue
            default:
                diagnose(.answer, .originalOperationDelivery, .unresolved,
                         causeCode: "unexpected_relay_frame", operationID: operationID,
                         receipt: .unknown)
                close()
                return .unresolved
            }
        }
    }

    /// A send response is not a replay ACK and cannot advance either cursor.
    public func sendDiscussion(_ frame: Data, operationID: UUID) async -> DiscussionOperationResult {
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        do {
            let outgoing = try JSONValue.parse(frame)
            guard outgoing.uniqueValue(named: "type") == .string(ExactText("discussion")),
                  outgoing.uniqueValue(named: "op_id")?.stringValue?.rawValue == operationID.uuidString.lowercased() else {
                diagnose(.conversation, .discussionSubmission, .rejected,
                         causeCode: "saved_operation_frame_mismatch", operationID: operationID,
                         receipt: .repairRequired)
                return .rejected(reason: ExactText("The saved discussion operation does not match its frame"))
            }
            try await send(frame)
            let wire = try ConversationWire(profile: profileContext, endpointHost: relayEndpointHost)
            while true {
                let incoming = try await receive()
                let kind = try JSONValue.parse(incoming).uniqueValue(named: "type")?.stringValue?.rawValue
                if kind == "delivery" || kind == "lifecycle" || kind == "conversation" { continue }
                let result = try wire.decodeDiscussionResult(incoming)
                switch result {
                case .accepted:
                    diagnose(.conversation, .discussionSubmission, .accepted,
                             operationID: operationID, receipt: .acceptedAwaitingReplay)
                case let .rejected(reason):
                    diagnose(.conversation, .discussionSubmission, .rejected,
                             causeCode: NativeDiagnosticCauseCode.serverReason(reason.rawValue),
                             operationID: operationID, receipt: .pendingUnconfirmed)
                case .unresolved:
                    diagnose(.conversation, .discussionSubmission, .unresolved,
                             operationID: operationID, receipt: .unknown)
                }
                return result
            }
        } catch {
            diagnose(.conversation, .discussionSubmission,
                     NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                     operationID: operationID, receipt: .unknown)
            close()
            return .unresolved
        }
    }

    /// The APNs address is a separate device binding, never answer content.
    /// The caller durably owns the operation ID and revision across retries.
    public func registerPush(address: String, operationID: UUID, revision: UInt64) async throws -> String {
        guard address.count == 64,
              address.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              revision > 0, revision < UInt64(Int64.max) else {
            throw InstallationTransportError.unexpectedServerFrame
        }
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        let frame = Data(("{\"v\":1,\"type\":\"push_register\",\"ref\":\"native-push\",\"op_id\":\"\(operationID.uuidString.lowercased())\",\"revision\":\(revision),\"profile_id\":\"harklight-sandbox\",\"address_kind\":\"apns_token\",\"address\":\"\(address)\"}\n").utf8)
        do {
            try await send(frame)
            while true {
                let value = try JSONValue.parse(try await receive())
                switch value.uniqueValue(named: "type")?.stringValue?.rawValue {
                case "ok" where value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-push":
                    return try PushBindingReply.registration(value, revision: revision)
                case "delivery", "lifecycle", "conversation":
                    continue
                case "error":
                    throw InstallationTransportError.serverRejected
                default:
                    throw InstallationTransportError.unexpectedServerFrame
                }
            }
        } catch {
            // A late `ok` on this socket must never confirm a different op.
            diagnose(.notifications, .pushRegistration,
                     NativeDiagnosticCauseCode.failureTransition(for: error),
                     error: error, operationID: operationID)
            close()
            throw error
        }
    }

    /// Recover legacy accepted registrations only on this authenticated session.
    public func currentPushBindingID(revision: UInt64) async throws -> String? {
        await socketExchangeGate.enter()
        defer { socketExchangeGate.leave() }
        do {
            try await send(Data("{\"v\":1,\"type\":\"push_status\",\"ref\":\"native-push-status\"}\n".utf8))
            while true {
                let value = try JSONValue.parse(try await receive())
                switch value.uniqueValue(named: "type")?.stringValue?.rawValue {
                case "delivery", "lifecycle", "conversation": continue
                case "error": throw InstallationTransportError.serverRejected
                default: return try PushBindingReply.status(value, revision: revision)
                }
            }
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        postCheckpointReader?.cancel()
        postCheckpointReader = nil
        failPostCheckpointReader(InstallationTransportError.unexpectedServerFrame)
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }

    public func nextLiveConversationSignal() async throws {
        if liveConversationSignalled {
            liveConversationSignalled = false
            return
        }
        if let postCheckpointReadFailure { throw postCheckpointReadFailure }
        try await withCheckedThrowingContinuation { continuation in
            liveConversationWaiters.append(continuation)
        }
    }

    public func nextPostCheckpointInboxEvent() async throws -> Data {
        if let frame = postCheckpointEventFrame {
            postCheckpointEventFrame = nil
            if !postCheckpointEventSpaceWaiters.isEmpty {
                postCheckpointEventSpaceWaiters.removeFirst().resume()
            }
            return frame
        }
        if let postCheckpointReadFailure { throw postCheckpointReadFailure }
        return try await withCheckedThrowingContinuation { continuation in
            postCheckpointEventWaiters.append(continuation)
        }
    }

    public func discardConversationUploads(_ cleanup: ConversationUploadCleanup,
                                           originURL: URL) async throws -> ConversationUploadDiscardResult {
        diagnose(.upload, .uploadCleanup, .began, operationID: cleanup.id,
                 request: cleanup.binding.request, revision: cleanup.binding.revision)
        do {
            let wire = try ConversationFileWire(profile: profileContext, originURL: originURL,
                                            endpointHost: relayEndpointHost)
            let (data, response) = try await urlSession.data(for: wire.discardRequest(cleanup))
            guard let http = response as? HTTPURLResponse else { throw InstallationTransportError.unexpectedServerFrame }
            let result = try wire.decodeDiscard(data, status: http.statusCode)
            diagnose(.upload, .uploadCleanup, .completed, operationID: cleanup.id,
                     request: cleanup.binding.request, revision: cleanup.binding.revision)
            return result
        } catch {
            diagnose(.upload, .uploadCleanup, NativeDiagnosticCauseCode.failureTransition(for: error),
                     error: error, operationID: cleanup.id, request: cleanup.binding.request,
                     revision: cleanup.binding.revision, receipt: .unknown)
            throw error
        }
    }

    public func conversationFileLimits(originURL: URL) async throws -> ConversationFileLimits {
        do {
            let wire = try ConversationFileWire(profile: profileContext, originURL: originURL,
                                            endpointHost: relayEndpointHost)
            let (data, response) = try await urlSession.data(for: wire.limitsRequest())
            guard let http = response as? HTTPURLResponse else { throw InstallationTransportError.unexpectedServerFrame }
            return try wire.decodeLimits(data, status: http.statusCode)
        } catch {
            diagnose(.upload, .uploadTransfer, NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            throw error
        }
    }

    /// Reuses the enrolled certificate/CA session and streams the retained file;
    /// no discussion is submitted by a successful upload.
    public func uploadConversationFile(_ file: ConversationFile, from source: URL,
                                       binding: ConversationBinding, operationID: UUID,
                                       limits: ConversationFileLimits, originURL: URL) async throws -> ConversationFile {
        diagnose(.upload, .uploadTransfer, .began, operationID: operationID,
                 request: binding.request, revision: binding.revision)
        do {
            if let cap = limits.uploadCap, file.byteCount > cap {
                throw ConversationError.uploadCapExceeded(file: file.name, cap: cap)
            }
            let wire = try ConversationFileWire(profile: profileContext, originURL: originURL,
                                            endpointHost: relayEndpointHost)
            try wire.verify(source, file: file)
            let request = try wire.uploadRequest(file: file, binding: binding, operationID: operationID)
            let (data, response) = try await urlSession.upload(for: request, fromFile: source)
            guard let http = response as? HTTPURLResponse else { throw InstallationTransportError.unexpectedServerFrame }
            let uploaded = try wire.decodeUpload(data, status: http.statusCode, original: file)
            diagnose(.upload, .uploadTransfer, .completed, operationID: operationID,
                     request: binding.request, revision: binding.revision)
            return uploaded
        } catch {
            diagnose(.upload, .uploadTransfer, NativeDiagnosticCauseCode.failureTransition(for: error),
                     error: error, operationID: operationID, request: binding.request,
                     revision: binding.revision, receipt: .unknown)
            throw error
        }
    }

    public func fetchConversationFile(_ file: ConversationFile, to destination: URL, originURL: URL) async throws {
        do {
            let wire = try ConversationFileWire(profile: profileContext, originURL: originURL,
                                            endpointHost: relayEndpointHost)
            let (temporary, response) = try await urlSession.download(for: wire.fetchRequest(file))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw InstallationTransportError.unexpectedServerFrame }
            guard http.statusCode == 200 else {
                throw ConversationFileTransportError.server(status: http.statusCode, reason: ExactText("File could not be fetched"))
            }
            guard http.value(forHTTPHeaderField: "Content-Length") == String(file.byteCount),
                  http.value(forHTTPHeaderField: "X-Harklight-Sha256") == file.sha256.rawValue else {
                throw ConversationError.fileMismatch
            }
            try wire.verify(temporary, file: file)
            try FileManager.default.copyItem(at: temporary, to: destination)
        } catch {
            diagnose(.fileAccess, .fileDownload, NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            throw error
        }
    }

    private func send(_ frame: Data) async throws {
        guard let text = String(data: frame, encoding: .utf8), text.hasSuffix("\n") else {
            throw InstallationTransportError.unexpectedServerFrame
        }
        try await task.send(.string(text))
    }

    private func receive() async throws -> Data {
        if postCheckpointReader != nil {
            if !responseFrames.isEmpty {
                let frame = responseFrames.removeFirst()
                resumeConversationReplaySpaceWaiters()
                return frame
            }
            if let postCheckpointReadFailure { throw postCheckpointReadFailure }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                responseWaiters.append(continuation)
            }
        }
        return try await receiveTaskFrame()
    }

    private func receiveTaskFrame() async throws -> Data {
        switch try await task.receive() {
        case let .string(text): return Data(text.utf8)
        case .data: throw InstallationTransportError.unexpectedServerFrame
        @unknown default: throw InstallationTransportError.unexpectedServerFrame
        }
    }

    private func startPostCheckpointReader() {
        guard postCheckpointReader == nil else { return }
        postCheckpointReadFailure = nil
        postCheckpointReader = Task { [weak self] in
            await self?.readPostCheckpointFrames()
        }
    }

    private func readPostCheckpointFrames() async {
        do {
            while !Task.isCancelled {
                let frame = try await receiveTaskFrame()
                let kind = Self.frameType(frame)
                if kind == "conversation" {
                    signalLiveConversation()
                    // Outside a conversation replay no reader wants this frame,
                    // and another exchange would treat it as fatal. The server
                    // keeps it in the conversation journal, so the replay the
                    // signal starts reads it again from the durable cursor.
                    guard conversationReplayReading else { continue }
                    // Not reading the socket while the replay commits each entry
                    // keeps a long catch-up from piling up here.
                    while conversationReplayReading && !responseFrames.isEmpty {
                        try await withCheckedThrowingContinuation { continuation in
                            conversationReplaySpaceWaiters.append(continuation)
                        }
                    }
                    guard conversationReplayReading else { continue }
                }
                if kind == "delivery" || kind == "lifecycle" {
                    try await enqueuePostCheckpointInboxEvent(frame)
                } else if !responseWaiters.isEmpty {
                    responseWaiters.removeFirst().resume(returning: frame)
                } else {
                    responseFrames.append(frame)
                }
            }
        } catch {
            failPostCheckpointReader(error)
        }
    }

    private func enqueuePostCheckpointInboxEvent(_ frame: Data) async throws {
        while postCheckpointEventFrame != nil {
            if let postCheckpointReadFailure { throw postCheckpointReadFailure }
            try await withCheckedThrowingContinuation { continuation in
                postCheckpointEventSpaceWaiters.append(continuation)
            }
        }
        if let postCheckpointReadFailure { throw postCheckpointReadFailure }
        if !postCheckpointEventWaiters.isEmpty {
            postCheckpointEventWaiters.removeFirst().resume(returning: frame)
        } else {
            postCheckpointEventFrame = frame
        }
    }

    private func failPostCheckpointReader(_ error: any Error) {
        postCheckpointReadFailure = error
        let responseWaiters = self.responseWaiters
        self.responseWaiters.removeAll(keepingCapacity: false)
        responseWaiters.forEach { $0.resume(throwing: error) }
        let eventWaiters = postCheckpointEventWaiters
        postCheckpointEventWaiters.removeAll(keepingCapacity: false)
        eventWaiters.forEach { $0.resume(throwing: error) }
        let spaceWaiters = postCheckpointEventSpaceWaiters
        postCheckpointEventSpaceWaiters.removeAll(keepingCapacity: false)
        spaceWaiters.forEach { $0.resume(throwing: error) }
        let conversationWaiters = liveConversationWaiters
        liveConversationWaiters.removeAll(keepingCapacity: false)
        conversationWaiters.forEach { $0.resume(throwing: error) }
        let replaySpaceWaiters = conversationReplaySpaceWaiters
        conversationReplaySpaceWaiters.removeAll(keepingCapacity: false)
        replaySpaceWaiters.forEach { $0.resume(throwing: error) }
    }

    /// Frames buffered after the replay read its end are already signalled
    /// and come back in the next replay.
    private func endConversationReplayReading() {
        conversationReplayReading = false
        responseFrames.removeAll { Self.frameType($0) == "conversation" }
        resumeConversationReplaySpaceWaiters()
    }

    private func resumeConversationReplaySpaceWaiters() {
        let waiters = conversationReplaySpaceWaiters
        conversationReplaySpaceWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func signalLiveConversation() {
        if liveConversationWaiters.isEmpty {
            liveConversationSignalled = true
        } else {
            liveConversationWaiters.removeFirst().resume()
        }
    }

    private static func frameType(_ frame: Data) -> String? {
        guard let value = try? JSONValue.parse(frame) else { return nil }
        return value.uniqueValue(named: "type")?.stringValue?.rawValue
    }

    private func diagnose(_ area: NativeDiagnosticArea,
                          _ phase: NativeDiagnosticPhase,
                          _ transition: NativeDiagnosticTransition,
                          error: Error? = nil,
                          causeCode: String? = nil,
                          operationID: UUID? = nil,
                          request: RequestKey? = nil,
                          revision: UInt64? = nil,
                          receipt: NativeDiagnosticReceiptState? = nil) {
        onDiagnostic(NativeClientDiagnosticEvent(area: area, phase: phase, transition: transition,
            causeCode: causeCode ?? error.map { NativeDiagnosticCauseCode.forError($0) },
            attemptID: attemptID, transportAttemptID: attemptID,
            operationID: operationID, request: request,
            requestRevision: revision, receiptState: receipt))
    }
}

/// The server identifies a device by lowercase SHA-256 of its certificate's
/// DER SubjectPublicKeyInfo, not by certificate subject or an app-supplied ID.
public enum DeviceCertificateBinding {
    public static func fingerprint(_ certificate: Data) -> String? {
        guard let key = subjectPublicKeyInfo(certificate) else { return nil }
        return SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ certificate: Data, expectedDeviceID: String) -> Bool {
        guard expectedDeviceID.count == 64,
              expectedDeviceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let actual = fingerprint(certificate) else { return false }
        return actual == expectedDeviceID
    }

    private static func subjectPublicKeyInfo(_ certificate: Data) -> Data? {
        let bytes = Array(certificate)
        guard let outer = read(bytes, at: 0), outer.tag == 0x30,
              outer.end == bytes.count,
              let tbs = read(bytes, at: outer.content), tbs.tag == 0x30 else { return nil }
        var offset = tbs.content
        if let version = read(bytes, at: offset), version.tag == 0xa0 { offset = version.end }
        for tag: UInt8 in [0x02, 0x30, 0x30, 0x30, 0x30] {
            guard let field = read(bytes, at: offset), field.tag == tag,
                  field.end <= tbs.end else { return nil }
            offset = field.end
        }
        guard let key = read(bytes, at: offset), key.tag == 0x30,
              key.end <= tbs.end else { return nil }
        return Data(bytes[offset..<key.end])
    }

    private static func read(_ bytes: [UInt8], at start: Int) -> (tag: UInt8, content: Int, end: Int)? {
        guard start >= 0, start + 2 <= bytes.count else { return nil }
        let tag = bytes[start]
        let first = bytes[start + 1]
        var length = Int(first)
        var content = start + 2
        if first & 0x80 != 0 {
            let width = Int(first & 0x7f)
            guard width > 0, width <= 4, content + width <= bytes.count else { return nil }
            length = 0
            for byte in bytes[content..<(content + width)] {
                guard length <= (Int.max - Int(byte)) / 256 else { return nil }
                length = length * 256 + Int(byte)
            }
            content += width
        }
        guard length <= bytes.count - content else { return nil }
        return (tag, content, content + length)
    }
}

private final class DeviceTLSDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let host: String
    private let identity: SecIdentity
    private let root: SecCertificate
    private let attemptID: UUID?
    private let onProgress: @Sendable (NativeRelayProgressEvent) -> Void
    private let onDiagnostic: NativeClientDiagnosticSink

    init(host: String, identity: SecIdentity, root: SecCertificate,
         attemptID: UUID?,
         onProgress: @escaping @Sendable (NativeRelayProgressEvent) -> Void,
         onDiagnostic: @escaping NativeClientDiagnosticSink) {
        self.host = host
        self.identity = identity
        self.root = root
        self.attemptID = attemptID
        self.onProgress = onProgress
        self.onDiagnostic = onDiagnostic
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onProgress(.webSocketOpened)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Authentication belongs only to the original pinned relay endpoint.
        onDiagnostic(NativeClientDiagnosticEvent(area: .connection, phase: .relayAdmission,
            transition: .rejected, causeCode: "relay_redirect_refused", attemptID: attemptID,
            transportAttemptID: attemptID))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard challenge.protectionSpace.host == host else {
                onProgress(.clientIdentityChallengeRejected)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // This reports the local credential choice only; it is not remote
            // evidence that the peer accepted the identity.
            onProgress(.clientIdentityOffered)
            completionHandler(.useCredential,
                              URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard challenge.protectionSpace.host == host,
                  let trust = challenge.protectionSpace.serverTrust,
                  SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                onProgress(.serverTrustRejected)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            onProgress(.serverTrustValidated)
            completionHandler(.useCredential, URLCredential(trust: trust))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
