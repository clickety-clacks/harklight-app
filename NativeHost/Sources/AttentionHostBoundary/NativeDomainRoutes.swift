import AttentionDomain
import Foundation

/// HTTP is a presentation adapter. The only mutable answer/draft/intent state
/// lives in AttentionDomainPort; this object retains only pairing sessions.
public final class NativeDomainRoutes: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var activePort: AttentionDomainPort?
    private let gate: HostSessionGate
    private let page = BundledHostPage()

    public init(port: AttentionDomainPort?, gate: HostSessionGate) throws {
        self.gate = gate
        try activate(port)
    }

    /// The trusted native profile owner calls this on switch/logout/removal.
    /// It is serialized with every port call, so no old token can race a new
    /// profile through a previously captured port.
    public func activate(_ port: AttentionDomainPort?) throws {
        lock.lock(); defer { lock.unlock() }
        activePort = nil
        try gate.activate(port.map { Self.account(for: $0.context) })
        activePort = port
    }

    /// Trusted foreground UI/terminal only. The HTTP route cannot mint secrets.
    public func issuePairSecret() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let port = activePort else { throw HostBoundaryError.rejected }
        let account = Self.account(for: port.context)
        return try gate.issuePairSecret(for: account)
    }

    public func reply(_ request: ParsedHTTPRequest, boundary: HostHTTPBoundary) -> HTTPReply {
        lock.lock(); defer { lock.unlock() }
        guard request.head.path.hasPrefix("/api/") else {
            return page.reply(request, boundary: boundary)
        }
        guard (try? boundary.validateAPI(request.head)) != nil else {
            return Self.error(403, "boundary_rejected")
        }
        guard let port = activePort else {
            return Self.error(503, "native_port_unavailable")
        }
        let account = Self.account(for: port.context)
        do {
            let body = try JSONValue.parse(request.body)
            guard body.hasUniqueObjectKeys else { return Self.error(400, "invalid_command") }
            if request.head.path == "/api/pair" {
                guard body.hasExactlyKeys(["secret"]),
                      let secret = body.uniqueValue(named: "secret")?.stringValue?.rawValue else {
                    return Self.error(400, "invalid_command")
                }
                let session = try gate.pair(secret: secret, account: account)
                return Self.json(200, .object([
                    JSONMember("token", .string(ExactText(session.token))),
                    JSONMember("hostGeneration", .string(ExactText(session.hostGeneration)))
                ]))
            }
            let token = try boundary.bearerToken(request.head)
            guard let generation = body.uniqueValue(named: "hostGeneration")?.stringValue?.rawValue,
                  gate.authorize(token: token, account: account, hostGeneration: generation) else {
                return Self.error(403, "session_expired")
            }
            switch request.head.path {
            case "/api/logout":
                guard body.hasExactlyKeys(["hostGeneration"]) else {
                    return Self.error(400, "invalid_command")
                }
                gate.logout(token: token)
                return Self.json(200, .object([JSONMember("disconnected", .bool(true))]))
            case "/api/observe":
                guard body.hasExactlyKeys(["hostGeneration"]) else {
                    return Self.error(400, "invalid_command")
                }
                return Self.json(200, Self.snapshot(try port.observe(context: port.context)))
            case "/api/inspect":
                guard body.hasExactlyKeys(["hostGeneration", "senderID", "messageID"]),
                      let key = Self.requestKey(body, context: port.context) else {
                    return Self.error(400, "invalid_command")
                }
                return Self.json(200, Self.snapshot(try port.inspect(context: port.context, request: key)))
            case "/api/draft":
                guard body.hasExactlyKeys(["hostGeneration", "selector", "input", "edit"]),
                      let selector = Self.selector(body.uniqueValue(named: "selector"), context: port.context),
                      let inputID = body.uniqueValue(named: "input")?.stringValue,
                      let edit = body.uniqueValue(named: "edit"),
                      let presented = try port.observe(context: port.context).requests.first(where: {
                          $0.key == selector.request
                      }),
                      let next = Self.editDraft(presented.draft, inputID: inputID, edit: edit) else {
                    return Self.error(400, "invalid_command")
                }
                try port.saveDraft(context: port.context, selector: selector, completeDraft: next)
                return Self.json(200, .object([JSONMember("saved", .bool(true))]))
            case "/api/cancel-draft":
                guard body.hasExactlyKeys(["hostGeneration", "selector"]),
                      let selector = Self.selector(body.uniqueValue(named: "selector"), context: port.context) else {
                    return Self.error(400, "invalid_command")
                }
                try port.cancelDraft(context: port.context, selector: selector)
                return Self.json(200, Self.snapshot(try port.inspect(context: port.context,
                                                                    request: selector.request)))
            case "/api/submit":
                guard body.hasExactlyKeys(["hostGeneration", "selector", "intentID", "inputs"]),
                      let selector = Self.selector(body.uniqueValue(named: "selector"), context: port.context),
                      let intentText = body.uniqueValue(named: "intentID")?.stringValue?.rawValue,
                      let intentID = UUID(uuidString: intentText),
                      let inputValues = body.uniqueValue(named: "inputs")?.arrayValues,
                      let inputs = Self.inputs(inputValues) else {
                    return Self.error(400, "invalid_command")
                }
                let command = SubmitIntent(context: port.context, selector: selector,
                                           intentID: intentID, inputs: inputs)
                return Self.json(200, Self.receipt(try port.submit(command)))
            case "/api/lookup":
                guard body.hasExactlyKeys(["hostGeneration", "intentID"]),
                      let idText = body.uniqueValue(named: "intentID")?.stringValue?.rawValue,
                      let id = UUID(uuidString: idText) else {
                    return Self.error(400, "invalid_command")
                }
                guard let receipt = try port.lookupIntent(context: port.context, intentID: id) else {
                    return Self.error(404, "intent_missing")
                }
                return Self.json(200, Self.receipt(receipt))
            case "/api/fence-intent":
                guard body.hasExactlyKeys(["hostGeneration", "senderID", "messageID", "intentID"]),
                      let key = Self.requestKey(body, context: port.context),
                      let idText = body.uniqueValue(named: "intentID")?.stringValue?.rawValue,
                      let id = UUID(uuidString: idText) else {
                    return Self.error(400, "invalid_command")
                }
                if let receipt = try port.fenceUncommittedIntent(context: port.context,
                                                                 requestKey: key, intentID: id) {
                    return Self.json(200, Self.receipt(receipt))
                }
                return Self.json(200, .object([JSONMember("fenced", .bool(true))]))
            case "/api/stream":
                guard body.hasExactlyKeys(["hostGeneration", "afterRevision"]),
                      let afterRevision = Self.unsigned(body.uniqueValue(named: "afterRevision")) else {
                    return Self.error(400, "invalid_command")
                }
                return stream(port: port, account: account, token: token,
                              hostGeneration: generation, afterRevision: afterRevision)
            default:
                return Self.error(404, "not_found")
            }
        } catch let error as AttentionStoreError {
            switch error {
            case let .competingIntent(activeID):
                return Self.json(409, .object([
                    JSONMember("error", .string(ExactText("competing_intent"))),
                    JSONMember("activeIntentID", .string(ExactText(activeID.uuidString.lowercased())))
                ]))
            case .intentConflict, .requestClosed, .selectorExpired,
                 .staleProfile, .wrongAccount:
                return Self.error(409, String(describing: error))
            case .persistence:
                return Self.error(503, "durable_store_unavailable")
            default:
                return Self.error(400, String(describing: error))
            }
        } catch {
            return Self.error(403, "request_rejected")
        }
    }

    private func stream(port: AttentionDomainPort, account: HostAccount, token: String,
                        hostGeneration: String, afterRevision: UInt64) -> HTTPReply {
        HTTPReply(status: 200) { send in
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            var lastRevision = afterRevision
            var first = true
            var nextHeartbeat = ProcessInfo.processInfo.systemUptime + 1
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard self.authorizedStream(port: port, account: account, token: token,
                                            hostGeneration: hostGeneration) else { return }
                let snapshot: PresentationSnapshot
                do {
                    snapshot = try port.observe(context: port.context)
                } catch {
                    return
                }
                guard self.authorizedStream(port: port, account: account, token: token,
                                            hostGeneration: hostGeneration) else { return }
                if first || snapshot.revision > lastRevision {
                    let event = JSONValue.object([
                        JSONMember("type", .string(ExactText("snapshot"))),
                        JSONMember("snapshot", Self.snapshot(snapshot))
                    ])
                    guard send(Data((event.jsonString + "\n").utf8)) else { return }
                    first = false
                    lastRevision = snapshot.revision
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now >= nextHeartbeat {
                    // This also detects a disconnected reader when no revision changes.
                    guard self.authorizedStream(port: port, account: account, token: token,
                                                hostGeneration: hostGeneration),
                          send(Data("{\"type\":\"heartbeat\"}\n".utf8)) else { return }
                    nextHeartbeat = now + 1
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private func authorizedStream(port: AttentionDomainPort, account: HostAccount,
                                  token: String, hostGeneration: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activePort === port &&
            gate.authorize(token: token, account: account, hostGeneration: hostGeneration)
    }

    private static func unsigned(_ value: JSONValue?) -> UInt64? {
        guard case let .number(number)? = value,
              !number.lexeme.isEmpty,
              number.lexeme.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return UInt64(number.lexeme)
    }

    private static func account(for context: PortContext) -> HostAccount {
        // Length prefixes prevent delimiter collisions between trusted fields.
        let fields = [context.trustedAccount.relayAuthority.rawValue,
                      context.trustedAccount.personID.rawValue,
                      context.deviceProfileID.rawValue]
        let scope = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return HostAccount(scope: scope, deviceGeneration: context.deviceGeneration.rawValue)
    }

    private static func requestKey(_ value: JSONValue, context: PortContext) -> RequestKey? {
        guard let sender = value.uniqueValue(named: "senderID")?.stringValue,
              let message = value.uniqueValue(named: "messageID")?.stringValue else { return nil }
        return RequestKey(accountScope: context.trustedAccount.personID,
                          senderID: sender, messageID: message)
    }

    private static func selector(_ value: JSONValue?, context: PortContext) -> BoundDocumentSelector? {
        guard let value, value.hasExactlyKeys(["senderID", "messageID", "documentID", "submissionID"]),
              let key = requestKey(value, context: context),
              let document = value.uniqueValue(named: "documentID")?.stringValue,
              let submission = value.uniqueValue(named: "submissionID")?.stringValue else {
            return nil
        }
        return BoundDocumentSelector(request: key, opaqueDocumentID: document,
                                     opaqueSubmissionID: submission)
    }

    private static func inputs(_ values: [JSONValue]) -> [TypedInputRecord]? {
        var records: [TypedInputRecord] = []
        for value in values {
            guard let kind = value.uniqueValue(named: "kind")?.stringValue?.rawValue else {
                return nil
            }
            switch kind {
            case "responseValue", "compatibilityValue":
                let keys = kind == "responseValue" ? ["kind", "input", "action"] : ["kind", "action"]
                guard value.hasExactlyKeys(keys),
                      let action = value.uniqueValue(named: "action")?.stringValue else { return nil }
                if kind == "responseValue" {
                    guard let input = value.uniqueValue(named: "input")?.stringValue else { return nil }
                    records.append(.responseValue(input: input, action: action))
                } else {
                    records.append(.compatibilityValue(action: action))
                }
            case "responseText", "compatibilityText":
                let keys = kind == "responseText" ? ["kind", "input", "action", "text"] : ["kind", "action", "text"]
                guard value.hasExactlyKeys(keys),
                      let action = value.uniqueValue(named: "action")?.stringValue,
                      let text = value.uniqueValue(named: "text")?.stringValue else { return nil }
                if kind == "responseText" {
                    guard let input = value.uniqueValue(named: "input")?.stringValue else { return nil }
                    records.append(.responseText(input: input, action: action, text: text))
                } else {
                    records.append(.compatibilityText(action: action, text: text))
                }
            case "text":
                guard value.hasExactlyKeys(["kind", "input", "text"]),
                      let input = value.uniqueValue(named: "input")?.stringValue,
                      let text = value.uniqueValue(named: "text")?.stringValue else { return nil }
                records.append(.text(input: input, text: text))
            case "point":
                guard value.hasExactlyKeys(["kind", "input", "x", "y"]),
                      let input = value.uniqueValue(named: "input")?.stringValue,
                      let x = value.uniqueValue(named: "x")?.integerValue,
                      let y = value.uniqueValue(named: "y")?.integerValue,
                      (0...1000).contains(x), (0...1000).contains(y) else { return nil }
                records.append(.point(input: input, point: PointValue(x: x, y: y)))
            default:
                return nil
            }
        }
        return records
    }

    private static func editDraft(_ source: RequestDraft, inputID: ExactText,
                                  edit: JSONValue) -> RequestDraft? {
        guard var input = source.inputs[inputID],
              let kind = edit.uniqueValue(named: "kind")?.stringValue?.rawValue else {
            return nil
        }
        switch kind {
        case "response":
            guard edit.hasExactlyKeys(["kind", "action"]) ||
                    edit.hasExactlyKeys(["kind", "action", "text"]),
                  let action = edit.uniqueValue(named: "action")?.stringValue else { return nil }
            input.selectedActionID = action
            if edit.hasExactlyKeys(["kind", "action", "text"]) {
                guard let text = edit.uniqueValue(named: "text")?.stringValue else { return nil }
                input.textByActionID[action] = text
            }
        case "text":
            guard edit.hasExactlyKeys(["kind", "text"]),
                  let text = edit.uniqueValue(named: "text")?.stringValue else { return nil }
            input.text = text
        case "point":
            guard edit.hasExactlyKeys(["kind", "x", "y"]),
                  let x = coordinateText(edit.uniqueValue(named: "x")),
                  let y = coordinateText(edit.uniqueValue(named: "y")) else { return nil }
            input.horizontalText = x
            input.verticalText = y
            if let px = InputDraft.coordinate(x), let py = InputDraft.coordinate(y) {
                input.point = PointValue(x: px, y: py)
            } else if input.point == nil {
                return nil
            }
        default:
            return nil
        }
        var next = source
        next.inputs[inputID] = input
        return next
    }

    private static func coordinateText(_ value: JSONValue?) -> ExactText? {
        if let text = value?.stringValue, text.rawValue.utf8.count <= 16 { return text }
        if let number = value?.integerValue { return ExactText(String(number)) }
        return nil
    }

    private static func snapshot(_ snapshot: PresentationSnapshot) -> JSONValue {
        .object([
            JSONMember("revision", .number(JSONNumber(lexeme: String(snapshot.revision)))),
            JSONMember("cursor", .number(JSONNumber(lexeme: String(snapshot.cursor)))),
            JSONMember("requests", .array(snapshot.requests.map { request in
                var fields = [
                    JSONMember("senderID", .string(request.key.senderID)),
                    JSONMember("messageID", .string(request.key.messageID)),
                    JSONMember("accountID", .string(request.key.accountScope)),
                    JSONMember("acceptanceOrder",
                               .number(JSONNumber(lexeme: String(request.acceptanceOrder)))),
                    JSONMember("status", .string(ExactText(request.lifecycleStatus.rawValue))),
                    JSONMember("originalContentJSON", .string(ExactText(request.originalContentJSON))),
                    JSONMember("draft", NativeDraftJSON.encode(request.draft)),
                    JSONMember("projection", NativeProjectionJSON.encode(request.projection))
                ]
                if let title = request.title { fields.append(JSONMember("title", .string(title))) }
                if let body = request.body { fields.append(JSONMember("body", .string(body))) }
                if let selector = request.selector {
                    fields.append(JSONMember("selector", .object([
                        JSONMember("senderID", .string(selector.request.senderID)),
                        JSONMember("messageID", .string(selector.request.messageID)),
                        JSONMember("documentID", .string(selector.opaqueDocumentID)),
                        JSONMember("submissionID", .string(selector.opaqueSubmissionID))
                    ])))
                }
                if let receipt = request.intentReceipt {
                    fields.append(JSONMember("receipt", Self.receipt(receipt)))
                }
                if let facts = request.receiptFacts {
                    fields.append(JSONMember("receiptFacts", .object([
                        JSONMember("evidence", .string(ExactText(facts.evidenceLabel))),
                        JSONMember("ownOutcome", .string(ExactText(facts.ownOutcome.rawValue))),
                        JSONMember("originalOperationUncertainty",
                                   .bool(facts.originalOperationUncertainty))
                    ])))
                }
                return .object(fields)
            }))
        ])
    }

    private static func receipt(_ receipt: IntentReceipt) -> JSONValue {
        .object([
            JSONMember("intentID", .string(ExactText(receipt.intentID.uuidString.lowercased()))),
            JSONMember("opID", .string(ExactText(receipt.opID.uuidString.lowercased()))),
            JSONMember("senderID", .string(receipt.selector.request.senderID)),
            JSONMember("messageID", .string(receipt.selector.request.messageID)),
            JSONMember("documentID", .string(receipt.selector.opaqueDocumentID)),
            JSONMember("submissionID", .string(receipt.selector.opaqueSubmissionID)),
            JSONMember("exactAnswerJSON", .string(ExactText(receipt.exactAnswerJSON))),
            JSONMember("inputs", .array(receipt.inputs.map(Self.input)))
        ])
    }

    private static func input(_ input: TypedInputRecord) -> JSONValue {
        var members: [JSONMember] = []
        switch input {
        case let .responseValue(id, action):
            members = [JSONMember("kind", .string(ExactText("responseValue"))),
                       JSONMember("input", .string(id)), JSONMember("action", .string(action))]
        case let .responseText(id, action, text):
            members = [JSONMember("kind", .string(ExactText("responseText"))),
                       JSONMember("input", .string(id)), JSONMember("action", .string(action)),
                       JSONMember("text", .string(text))]
        case let .text(id, text):
            members = [JSONMember("kind", .string(ExactText("text"))),
                       JSONMember("input", .string(id)), JSONMember("text", .string(text))]
        case let .point(id, point):
            members = [JSONMember("kind", .string(ExactText("point"))),
                       JSONMember("input", .string(id)),
                       JSONMember("x", .number(JSONNumber(lexeme: String(point.x)))),
                       JSONMember("y", .number(JSONNumber(lexeme: String(point.y))))]
        case let .compatibilityValue(action):
            members = [JSONMember("kind", .string(ExactText("compatibilityValue"))),
                       JSONMember("action", .string(action))]
        case let .compatibilityText(action, text):
            members = [JSONMember("kind", .string(ExactText("compatibilityText"))),
                       JSONMember("action", .string(action)), JSONMember("text", .string(text))]
        }
        return .object(members)
    }

    private static func json(_ status: Int, _ value: JSONValue) -> HTTPReply {
        HTTPReply(status: status, body: Data(value.jsonString.utf8))
    }

    private static func error(_ status: Int, _ code: String) -> HTTPReply {
        json(status, .object([JSONMember("error", .string(ExactText(code)))]))
    }
}
