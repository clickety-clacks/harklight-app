import AttentionDomain
@testable import AttentionHostBoundary
import Darwin
import Foundation
import XCTest

final class NativeDomainRoutesTests: XCTestCase {
    private let boundary = HostHTTPBoundary(port: 43127)

    func testNativeDraftEditsAndCancelUseBoundSelector() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("fictional-sample-account"),
                                       deviceID: ExactText("fixture-device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let original = try fixtureRequest(account: identity.personID)
        try store.registerFixtureRequests([original], context: context)
        let routes = try NativeDomainRoutes(port: AttentionDomainPort(store: store),
                                            gate: HostSessionGate())
        let token = try pair(routes)
        let initial = try payload(routes.reply(request("/api/inspect", token: token, body: object([
            "hostGeneration": string(token.generation),
            "senderID": string(original.key.senderID.rawValue),
            "messageID": string(original.key.messageID.rawValue)
        ])), boundary: boundary))
        let selector = try XCTUnwrap(initial.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "selector"))
        XCTAssertEqual(initial.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "accountID")?.stringValue?.rawValue,
                       identity.personID.rawValue)
        let point = object(["hostGeneration": string(token.generation), "selector": selector,
                            "input": string("location"),
                            "edit": object(["kind": string("point"), "x": number(240), "y": number(610)])])
        XCTAssertEqual(routes.reply(request("/api/draft", token: token, body: point),
                                   boundary: boundary).status, 200)
        let note = object(["hostGeneration": string(token.generation), "selector": selector,
                           "input": string("note"),
                           "edit": object(["kind": string("text"), "text": string("Keep exact text")])])
        XCTAssertEqual(routes.reply(request("/api/draft", token: token, body: note),
                                   boundary: boundary).status, 200)
        let edited = try payload(routes.reply(request("/api/inspect", token: token, body: object([
            "hostGeneration": string(token.generation),
            "senderID": string(original.key.senderID.rawValue),
            "messageID": string(original.key.messageID.rawValue)
        ])), boundary: boundary))
        let entries = try XCTUnwrap(edited.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "draft")?.uniqueValue(named: "inputs")?.arrayValues)
        let location = try XCTUnwrap(entries.first(where: { $0.uniqueValue(named: "id")?.stringValue?.rawValue == "location" }))
        let savedNote = try XCTUnwrap(entries.first(where: { $0.uniqueValue(named: "id")?.stringValue?.rawValue == "note" }))
        XCTAssertEqual(location.uniqueValue(named: "point")?.uniqueValue(named: "x")?.integerValue, 240)
        XCTAssertEqual(savedNote.uniqueValue(named: "text")?.stringValue?.rawValue, "Keep exact text")

        let stale = object(["hostGeneration": string("stale"), "selector": selector,
                            "input": string("note"),
                            "edit": object(["kind": string("text"), "text": string("wrong")])])
        XCTAssertEqual(routes.reply(request("/api/draft", token: token, body: stale),
                                   boundary: boundary).status, 403)
        let cancelled = try payload(routes.reply(request("/api/cancel-draft", token: token,
            body: object(["hostGeneration": string(token.generation), "selector": selector])),
            boundary: boundary))
        let resetEntries = try XCTUnwrap(cancelled.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "draft")?.uniqueValue(named: "inputs")?.arrayValues)
        let resetLocation = try XCTUnwrap(resetEntries.first(where: {
            $0.uniqueValue(named: "id")?.stringValue?.rawValue == "location"
        }))
        let resetNote = try XCTUnwrap(resetEntries.first(where: {
            $0.uniqueValue(named: "id")?.stringValue?.rawValue == "note"
        }))
        XCTAssertEqual(resetLocation.uniqueValue(named: "point"), .null)
        XCTAssertEqual(resetNote.uniqueValue(named: "text")?.stringValue?.rawValue, "")
    }

    func testDroppedSubmitResponseRecoversOneNativeReceiptAfterRestart() throws {
        let persistence = MemoryAttentionStatePersistence()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("fictional-sample-account"),
                                       deviceID: ExactText("fixture-device"))
        let original = try fixtureRequest(account: identity.personID)
        let context1 = ProfileContext(identity: identity, transportMode: .fixture)
        let store1 = try AttentionDomainStore(context: context1, persistence: persistence)
        try store1.registerFixtureRequests([original], context: context1)
        let port1 = AttentionDomainPort(store: store1)
        let first = try NativeDomainRoutes(port: port1, gate: HostSessionGate())
        let token1 = try pair(first)

        let inspected = try payload(first.reply(request("/api/inspect", token: token1, body: object([
            "hostGeneration": string(token1.generation),
            "senderID": string(original.key.senderID.rawValue),
            "messageID": string(original.key.messageID.rawValue)
        ])), boundary: boundary))
        let selector = try XCTUnwrap(inspected.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "selector"))
        let intent = UUID()
        let inputs: JSONValue = .array([
            object(["kind": string("point"), "input": string("location"),
                    "x": number(240), "y": number(610)]),
            object(["kind": string("text"), "input": string("note"),
                    "text": string("  Near the door\n  ")])
        ])
        let command = object(["hostGeneration": string(token1.generation), "selector": selector,
                              "intentID": string(intent.uuidString), "inputs": inputs])
        let lostResponse = first.reply(request("/api/submit", token: token1, body: command),
                                       boundary: boundary)
        XCTAssertEqual(lostResponse.status, 200)
        // Deliberately do not parse the response: this is the lost guest reply.
        store1.invalidate()

        let context2 = ProfileContext(identity: identity, transportMode: .fixture)
        let store2 = try AttentionDomainStore(context: context2, persistence: persistence)
        let port2 = AttentionDomainPort(store: store2)
        let restarted = try NativeDomainRoutes(port: port2, gate: HostSessionGate())
        let token2 = try pair(restarted)
        let lookup = restarted.reply(request("/api/lookup", token: token2, body: object([
            "hostGeneration": string(token2.generation),
            "intentID": string(intent.uuidString)
        ])), boundary: boundary)
        XCTAssertEqual(lookup.status, 200)
        let recovered = try payload(lookup)
        let committed = try XCTUnwrap(port2.lookupIntent(context: port2.context, intentID: intent))
        XCTAssertEqual(recovered.uniqueValue(named: "opID")?.stringValue?.rawValue,
                       committed.opID.uuidString.lowercased())
        XCTAssertEqual(recovered.uniqueValue(named: "exactAnswerJSON")?.stringValue?.rawValue,
                       committed.exactAnswerJSON)
        XCTAssertTrue(committed.exactAnswerJSON.contains("9007199254740993"))
        XCTAssertTrue(committed.exactAnswerJSON.contains("  Near the door\\n  "))

        let currentSelector = try XCTUnwrap(port2.inspect(context: port2.context, request: original.key)
            .requests.first?.selector)
        let repeatIntent = SubmitIntent(context: port2.context, selector: currentSelector,
                                        intentID: intent, inputs: committed.inputs)
        XCTAssertEqual(try port2.submit(repeatIntent).opID, committed.opID)
        let changed = object(["hostGeneration": string(token2.generation),
                              "selector": object([
                                "senderID": string(original.key.senderID.rawValue),
                                "messageID": string(original.key.messageID.rawValue),
                                "documentID": string(currentSelector.opaqueDocumentID.rawValue),
                                "submissionID": string(currentSelector.opaqueSubmissionID.rawValue)
                              ]),
                              "intentID": string(intent.uuidString),
                              "inputs": .array([
                                object(["kind": string("point"), "input": string("location"),
                                        "x": number(240), "y": number(610)]),
                                object(["kind": string("text"), "input": string("note"),
                                        "text": string("changed")])
                              ])])
        XCTAssertEqual(restarted.reply(request("/api/submit", token: token2, body: changed),
                                       boundary: boundary).status, 409)
        XCTAssertEqual(try port2.lookupIntent(context: port2.context, intentID: intent)?.opID,
                       committed.opID)

        let competitor = object(["hostGeneration": string(token2.generation),
                                 "selector": try XCTUnwrap(changed.uniqueValue(named: "selector")),
                                 "intentID": string(UUID().uuidString), "inputs": inputs])
        let blocked = restarted.reply(request("/api/submit", token: token2, body: competitor),
                                      boundary: boundary)
        XCTAssertEqual(blocked.status, 409)
        let conflict = try payload(blocked)
        XCTAssertEqual(conflict.uniqueValue(named: "error")?.stringValue?.rawValue,
                       "competing_intent")
        XCTAssertEqual(conflict.uniqueValue(named: "activeIntentID")?.stringValue?.rawValue,
                       intent.uuidString.lowercased())
    }

    func testFenceRouteOrdersAbsentLookupBeforeLateSubmit() throws {
        let persistence = MemoryAttentionStatePersistence()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("fictional-sample-account"),
                                       deviceID: ExactText("fixture-device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let original = try fixtureRequest(account: identity.personID)
        try store.registerFixtureRequests([original], context: context)
        let routes = try NativeDomainRoutes(port: AttentionDomainPort(store: store),
                                            gate: HostSessionGate())
        let token = try pair(routes)
        let selector = try XCTUnwrap(payload(routes.reply(request("/api/inspect", token: token,
            body: object(["hostGeneration": string(token.generation),
                          "senderID": string(original.key.senderID.rawValue),
                          "messageID": string(original.key.messageID.rawValue)])), boundary: boundary))
            .uniqueValue(named: "requests")?.arrayValues?.first?.uniqueValue(named: "selector"))
        let intentID = UUID()
        let fence = object(["hostGeneration": string(token.generation),
                            "senderID": string(original.key.senderID.rawValue),
                            "messageID": string(original.key.messageID.rawValue),
                            "intentID": string(intentID.uuidString)])
        XCTAssertEqual(routes.reply(request("/api/lookup", token: token,
            body: object(["hostGeneration": string(token.generation),
                          "intentID": string(intentID.uuidString)])), boundary: boundary).status, 404)
        let fenced = routes.reply(request("/api/fence-intent", token: token, body: fence),
                                  boundary: boundary)
        XCTAssertEqual(fenced.status, 200)
        XCTAssertEqual(try payload(fenced).uniqueValue(named: "fenced"), .bool(true))
        XCTAssertEqual(routes.reply(request("/api/fence-intent", token: token, body: fence),
                                   boundary: boundary).status, 200)
        let late = object(["hostGeneration": string(token.generation), "selector": selector,
                           "intentID": string(intentID.uuidString),
                           "inputs": .array([
                            object(["kind": string("point"), "input": string("location"),
                                    "x": number(240), "y": number(610)]),
                            object(["kind": string("text"), "input": string("note"),
                                    "text": string("Original note")])
                           ])])
        XCTAssertEqual(routes.reply(request("/api/submit", token: token, body: late),
                                   boundary: boundary).status, 409)
    }

    func testIncompleteOriginalHTTPBodyCannotCommitAfterFenceAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-host-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("fictional-sample-account"),
                                       deviceID: ExactText("fixture-device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let original = try fixtureRequest(account: identity.personID)
        try store.registerFixtureRequests([original], context: context)
        let routes = try NativeDomainRoutes(port: AttentionDomainPort(store: store),
                                            gate: HostSessionGate())
        let secret = try routes.issuePairSecret()
        let server = LoopbackHTTPServer { request, boundary in
            routes.reply(request, boundary: boundary)
        }
        let port = try server.start()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(port)"
        let paired = try await post(origin + "/api/pair", origin: origin,
                                    body: object(["secret": string(secret)]))
        XCTAssertEqual(paired.0, 200)
        let session = try JSONValue.parse(paired.1)
        let token = try XCTUnwrap(session.uniqueValue(named: "token")?.stringValue?.rawValue)
        let generation = try XCTUnwrap(session.uniqueValue(named: "hostGeneration")?.stringValue?.rawValue)
        let inspected = try await post(origin + "/api/inspect", origin: origin,
            body: object(["hostGeneration": string(generation),
                          "senderID": string(original.key.senderID.rawValue),
                          "messageID": string(original.key.messageID.rawValue)]), token: token)
        let selector = try XCTUnwrap(JSONValue.parse(inspected.1).uniqueValue(named: "requests")?
            .arrayValues?.first?.uniqueValue(named: "selector"))
        let originalID = UUID()
        let originalCommand = object(["hostGeneration": string(generation), "selector": selector,
            "intentID": string(originalID.uuidString), "inputs": .array([
                object(["kind": string("point"), "input": string("location"),
                        "x": number(240), "y": number(610)]),
                object(["kind": string("text"), "input": string("note"),
                        "text": string("Original exact note")])
            ])])
        let body = Data(originalCommand.jsonString.utf8)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        guard socket >= 0 else { return }
        defer { Darwin.close(socket) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, $0,
                              socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        guard connected == 0 else { return }
        let headers = "POST /api/submit HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" +
            "Origin: \(origin)\r\nAuthorization: Bearer \(token)\r\n" +
            "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        var heldRequest = Data(headers.utf8)
        heldRequest.append(body.dropLast())
        var sent = 0
        while sent < heldRequest.count {
            let count = heldRequest.withUnsafeBytes { bytes in
                Darwin.send(socket, bytes.baseAddress!.advanced(by: sent),
                            heldRequest.count - sent, 0)
            }
            XCTAssertGreaterThan(count, 0)
            guard count > 0 else { return }
            sent += count
        }

        // This socket cannot enter NativeDomainRoutes.reply until its last body
        // byte arrives. Independent authenticated connections must win the fence.
        let lookup = try await post(origin + "/api/lookup", origin: origin,
            body: object(["hostGeneration": string(generation),
                          "intentID": string(originalID.uuidString)]), token: token)
        XCTAssertEqual(lookup.0, 404)
        let fence = try await post(origin + "/api/fence-intent", origin: origin,
            body: object(["hostGeneration": string(generation),
                          "senderID": string(original.key.senderID.rawValue),
                          "messageID": string(original.key.messageID.rawValue),
                          "intentID": string(originalID.uuidString)]), token: token)
        XCTAssertEqual(fence.0, 200)
        XCTAssertEqual(try JSONValue.parse(fence.1).uniqueValue(named: "fenced"), .bool(true))
        let changed = try await post(origin + "/api/draft", origin: origin,
            body: object(["hostGeneration": string(generation), "selector": selector,
                          "input": string("note"),
                          "edit": object(["kind": string("text"),
                                          "text": string("Changed after fence")])]), token: token)
        XCTAssertEqual(changed.0, 200)
        let lastByte = Data(body.suffix(1))
        let released = lastByte.withUnsafeBytes { bytes in
            Darwin.send(socket, bytes.baseAddress!, lastByte.count, 0)
        }
        XCTAssertEqual(released, 1)
        var replyBytes = [UInt8](repeating: 0, count: 4096)
        let received = Darwin.recv(socket, &replyBytes, replyBytes.count, 0)
        XCTAssertGreaterThan(received, 0)
        if received > 0 {
            XCTAssertTrue(String(decoding: replyBytes[..<received], as: UTF8.self)
                .hasPrefix("HTTP/1.1 409"))
        }
        server.stop()
        store.invalidate()

        let reopenedContext = ProfileContext(identity: identity, transportMode: .fixture)
        let reopenedStore = try AttentionDomainStore(context: reopenedContext,
                                                      persistence: persistence)
        let reopenedPort = AttentionDomainPort(store: reopenedStore)
        let reopenedRoutes = try NativeDomainRoutes(port: reopenedPort, gate: HostSessionGate())
        let reopenedToken = try pair(reopenedRoutes)
        let reopenedInspect = try payload(reopenedRoutes.reply(request("/api/inspect",
            token: reopenedToken, body: object([
                "hostGeneration": string(reopenedToken.generation),
                "senderID": string(original.key.senderID.rawValue),
                "messageID": string(original.key.messageID.rawValue)
            ])), boundary: boundary))
        let reopenedRequest = try XCTUnwrap(reopenedInspect.uniqueValue(named: "requests")?
            .arrayValues?.first)
        let draftInputs = try XCTUnwrap(reopenedRequest.uniqueValue(named: "draft")?
            .uniqueValue(named: "inputs")?.arrayValues)
        XCTAssertEqual(draftInputs.first(where: {
            $0.uniqueValue(named: "id")?.stringValue?.rawValue == "note"
        })?.uniqueValue(named: "text")?.stringValue?.rawValue, "Changed after fence")
        let newID = UUID()
        let newSubmit = reopenedRoutes.reply(request("/api/submit", token: reopenedToken,
            body: object(["hostGeneration": string(reopenedToken.generation),
                          "selector": try XCTUnwrap(reopenedRequest.uniqueValue(named: "selector")),
                          "intentID": string(newID.uuidString), "inputs": .array([
                            object(["kind": string("point"), "input": string("location"),
                                    "x": number(625), "y": number(500)]),
                            object(["kind": string("text"), "input": string("note"),
                                    "text": string("Changed after fence")])
                          ])])), boundary: boundary)
        XCTAssertEqual(newSubmit.status, 200)
        XCTAssertNil(try reopenedPort.lookupIntent(context: reopenedPort.context,
                                                    intentID: originalID))
        XCTAssertEqual(try reopenedPort.lookupIntent(context: reopenedPort.context,
                                                     intentID: newID)?.inputs.last,
                       .text(input: ExactText("note"), text: ExactText("Changed after fence")))
        XCTAssertEqual(try reopenedStore.snapshot(context: reopenedContext).outbox.count, 1)
    }

    func testTokenAndOriginFenceBeforeNativeRead() throws {
        let persistence = MemoryAttentionStatePersistence()
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("A"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        try store.registerFixtureRequests([fixtureRequest(account: identity.personID)], context: context)
        let port = AttentionDomainPort(store: store)
        let routes = try NativeDomainRoutes(port: port, gate: HostSessionGate())
        let token = try pair(routes)
        let command = object(["hostGeneration": string(token.generation)])
        let correct = routes.reply(request("/api/observe", token: token, body: command), boundary: boundary)
        XCTAssertEqual(correct.status, 200)
        let badOrigin = routes.reply(request("/api/observe", token: token, body: command,
                                             origin: "null"), boundary: boundary)
        XCTAssertEqual(badOrigin.status, 403)
        let badHost = routes.reply(request("/api/observe", token: token, body: command,
                                           host: "localhost:43127"), boundary: boundary)
        XCTAssertEqual(badHost.status, 403)
        let wrongGeneration = object(["hostGeneration": string("old-generation")])
        XCTAssertEqual(routes.reply(request("/api/observe", token: token, body: wrongGeneration),
                                    boundary: boundary).status, 403)
        let logout = routes.reply(request("/api/logout", token: token, body: command), boundary: boundary)
        XCTAssertEqual(logout.status, 200)
        XCTAssertEqual(routes.reply(request("/api/observe", token: token, body: command),
                                    boundary: boundary).status, 403)
    }

    func testProfileSwitchHidesOriginalIntentUntilNewAuthorizedPairing() throws {
        let persistence = MemoryAttentionStatePersistence()
        let identityA = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                        personID: ExactText("A"), deviceID: ExactText("device-a"))
        let identityB = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                        personID: ExactText("B"), deviceID: ExactText("device-b"))
        let contextA = ProfileContext(identity: identityA, transportMode: .fixture)
        let contextB = ProfileContext(identity: identityB, transportMode: .fixture)
        let storeA = try AttentionDomainStore(context: contextA, persistence: persistence)
        let storeB = try AttentionDomainStore(context: contextB, persistence: persistence)
        let requestA = try fixtureRequest(account: identityA.personID)
        let requestB = try fixtureRequest(account: identityB.personID)
        try storeA.registerFixtureRequests([requestA], context: contextA)
        try storeB.registerFixtureRequests([requestB], context: contextB)
        let portA = AttentionDomainPort(store: storeA)
        let portB = AttentionDomainPort(store: storeB)
        let routes = try NativeDomainRoutes(port: portA, gate: HostSessionGate())
        let aToken = try pair(routes)
        let inspected = try payload(routes.reply(request("/api/inspect", token: aToken, body: object([
            "hostGeneration": string(aToken.generation),
            "senderID": string(requestA.key.senderID.rawValue),
            "messageID": string(requestA.key.messageID.rawValue)
        ])), boundary: boundary))
        let selector = try XCTUnwrap(inspected.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "selector"))
        let intent = UUID()
        let sent = routes.reply(request("/api/submit", token: aToken, body: object([
            "hostGeneration": string(aToken.generation),
            "selector": selector,
            "intentID": string(intent.uuidString),
            "inputs": .array([
                object(["kind": string("point"), "input": string("location"),
                        "x": number(240), "y": number(610)]),
                object(["kind": string("text"), "input": string("note"),
                        "text": string("A only")])
            ])
        ])), boundary: boundary)
        XCTAssertEqual(sent.status, 200)
        let aReceipt = try payload(sent)

        try routes.activate(portB)
        let bToken = try pair(routes)
        let lookupB = routes.reply(request("/api/lookup", token: bToken, body: object([
            "hostGeneration": string(bToken.generation),
            "intentID": string(intent.uuidString)
        ])), boundary: boundary)
        XCTAssertEqual(lookupB.status, 404)
        let staleA = routes.reply(request("/api/observe", token: aToken, body: object([
            "hostGeneration": string(aToken.generation)
        ])), boundary: boundary)
        XCTAssertEqual(staleA.status, 403)
        let observedB = try payload(routes.reply(request("/api/observe", token: bToken, body: object([
            "hostGeneration": string(bToken.generation)
        ])), boundary: boundary))
        XCTAssertNil(observedB.uniqueValue(named: "requests")?.arrayValues?.first?
            .uniqueValue(named: "receipt"))

        try routes.activate(portA)
        let newAToken = try pair(routes)
        let recoveredA = try payload(routes.reply(request("/api/lookup", token: newAToken, body: object([
            "hostGeneration": string(newAToken.generation),
            "intentID": string(intent.uuidString)
        ])), boundary: boundary))
        XCTAssertEqual(recoveredA.uniqueValue(named: "opID"), aReceipt.uniqueValue(named: "opID"))
    }

    func testNativePortPairAndObserveOverRealLoopbackHTTP() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("fictional-sample-account"),
                                       deviceID: ExactText("fixture-device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        try store.registerFixtureRequests([fixtureRequest(account: identity.personID)], context: context)
        let routes = try NativeDomainRoutes(port: AttentionDomainPort(store: store),
                                            gate: HostSessionGate())
        let secret = try routes.issuePairSecret()
        let server = LoopbackHTTPServer { request, boundary in
            routes.reply(request, boundary: boundary)
        }
        let port = try server.start()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(port)"
        let pair = try await post(origin + "/api/pair", origin: origin,
                                  body: object(["secret": string(secret)]))
        XCTAssertEqual(pair.0, 200)
        let paired = try JSONValue.parse(pair.1)
        let token = try XCTUnwrap(paired.uniqueValue(named: "token")?.stringValue?.rawValue)
        let generation = try XCTUnwrap(paired.uniqueValue(named: "hostGeneration")?.stringValue?.rawValue)
        let observeBody = object(["hostGeneration": string(generation)])
        let observed = try await post(origin + "/api/observe", origin: origin,
                                      body: observeBody, token: token)
        XCTAssertEqual(observed.0, 200)
        let requests = try JSONValue.parse(observed.1).uniqueValue(named: "requests")?.arrayValues
        XCTAssertEqual(requests?.count, 1)
        XCTAssertEqual(requests?.first?.uniqueValue(named: "messageID")?.stringValue?.rawValue,
                       "facilities-01")
        let foreign = try await post(origin + "/api/observe", origin: "null",
                                     body: observeBody, token: token)
        XCTAssertEqual(foreign.0, 403)
    }

    func testNativeStreamStopsAfterProfileRemovalBetweenSnapshots() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: ExactText("A"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let store = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        try store.registerFixtureRequests([fixtureRequest(account: identity.personID)], context: context)
        let routes = try NativeDomainRoutes(port: AttentionDomainPort(store: store),
                                            gate: HostSessionGate())
        let token = try pair(routes)
        let response = routes.reply(request("/api/stream", token: token, body: object([
            "hostGeneration": string(token.generation),
            "afterRevision": number(0)
        ])), boundary: boundary)
        XCTAssertEqual(response.status, 200)
        let produce = try XCTUnwrap(response.stream)
        let first = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let capture = StreamCapture()
        DispatchQueue.global().async {
            produce { chunk in
                capture.append(chunk)
                first.signal()
                _ = release.wait(timeout: .now() + 3)
                return true
            }
            finished.signal()
        }
        XCTAssertEqual(first.wait(timeout: .now() + 3), .success)
        try routes.activate(nil)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertTrue(String(decoding: capture.events[0], as: UTF8.self)
            .contains("\"type\":\"snapshot\""))
    }

    func testHTTPProjectionCarriesAuthorizedPointButNoUnknownClosurePoint() throws {
        for confirmed in [true, false] {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                           personID: ExactText("fictional-sample-account"),
                                           deviceID: ExactText(confirmed ? "known" : "unknown"))
            let context = ProfileContext(identity: identity, transportMode: .fixture)
            let store = try AttentionDomainStore(context: context,
                                                 persistence: MemoryAttentionStatePersistence())
            let original = try fixtureRequest(account: identity.personID)
            try store.registerFixtureRequests([original], context: context)
            let port = AttentionDomainPort(store: store)
            let selector = try XCTUnwrap(port.inspect(context: port.context,
                                                      request: original.key).requests.first?.selector)
            let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
                                                       intentID: UUID(), inputs: [
                .point(input: ExactText("location"), point: PointValue(x: 240, y: 610)),
                .text(input: ExactText("note"), text: ExactText("One note"))
            ]))
            let terminal = FixtureTerminal(state: .answered,
                                           evidenceLabel: confirmed ? "accepted fixture answer" : "unconfirmed fixture closure",
                                           authorizedAnswer: confirmed ? receipt.exactAnswer : nil,
                                           ownOutcome: confirmed ? .accepted : .unconfirmed)
            try store.recordFixtureTerminal(terminal, for: original.key, context: context)
            let routes = try NativeDomainRoutes(port: port, gate: HostSessionGate())
            let token = try pair(routes)
            let snapshot = try payload(routes.reply(request("/api/observe", token: token, body: object([
                "hostGeneration": string(token.generation)
            ])), boundary: boundary))
            let item = try XCTUnwrap(snapshot.uniqueValue(named: "requests")?.arrayValues?.first)
            XCTAssertEqual(item.uniqueValue(named: "status")?.stringValue?.rawValue, "answered")
            let projection = try XCTUnwrap(item.uniqueValue(named: "projection"))
            let resources = try XCTUnwrap(projection.uniqueValue(named: "illustrations")?.arrayValues)
            XCTAssertFalse(resources.isEmpty)
            let scene = try XCTUnwrap(projection.uniqueValue(named: "scene"))
            let points = resultPoints(in: scene)
            XCTAssertEqual(points.count, confirmed ? 1 : 0)
            if confirmed {
                XCTAssertEqual(points.first?.uniqueValue(named: "point")?.uniqueValue(named: "x")?.integerValue, 240)
                XCTAssertEqual(points.first?.uniqueValue(named: "point")?.uniqueValue(named: "y")?.integerValue, 610)
            }
            XCTAssertEqual(item.uniqueValue(named: "receiptFacts")?
                .uniqueValue(named: "originalOperationUncertainty"), .bool(!confirmed))
        }
    }

    private func fixtureRequest(account: ExactText) throws -> StoredRequest {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "attention-client-m2-fixtures",
                                                   withExtension: "json", subdirectory: "Fixtures"))
        let root = try JSONValue.parse(Data(contentsOf: url))
        let raw = try XCTUnwrap(root.uniqueValue(named: "requests")?.arrayValues?.first(where: {
            $0.uniqueValue(named: "message_id")?.stringValue?.rawValue == "facilities-01"
        }))
        return StoredRequest(key: RequestKey(accountScope: account,
                                             senderID: ExactText("fixture:Facilities"),
                                             messageID: ExactText("facilities-01")),
                             originalPayload: raw)
    }

    private func pair(_ routes: NativeDomainRoutes) throws -> (token: String, generation: String) {
        let secret = try routes.issuePairSecret()
        let reply = routes.reply(request("/api/pair", body: object(["secret": string(secret)])),
                                 boundary: boundary)
        XCTAssertEqual(reply.status, 200)
        let value = try payload(reply)
        return (try XCTUnwrap(value.uniqueValue(named: "token")?.stringValue?.rawValue),
                try XCTUnwrap(value.uniqueValue(named: "hostGeneration")?.stringValue?.rawValue))
    }

    private func request(_ path: String, token: (token: String, generation: String)? = nil,
                         body: JSONValue, origin: String? = nil,
                         host: String? = nil) -> ParsedHTTPRequest {
        var headers = ["Host": [host ?? boundary.host],
                       "Origin": [origin ?? boundary.origin],
                       "Content-Type": ["application/json"]]
        if let token { headers["Authorization"] = ["Bearer \(token.token)"] }
        return ParsedHTTPRequest(head: HTTPRequestHead(method: "POST", path: path, headers: headers),
                                 body: Data(body.jsonString.utf8))
    }

    private func payload(_ reply: HTTPReply) throws -> JSONValue {
        try JSONValue.parse(reply.body)
    }

    private func resultPoints(in node: JSONValue) -> [JSONValue] {
        if node.uniqueValue(named: "kind")?.stringValue?.rawValue == "result-point" {
            return [node]
        }
        return (node.uniqueValue(named: "children")?.arrayValues ?? []).flatMap(resultPoints(in:))
    }

    private func post(_ address: String, origin: String, body: JSONValue,
                      token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(body.jsonString.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data)
    }

    private func object(_ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.map { JSONMember($0.key, $0.value) })
    }
    private func string(_ value: String) -> JSONValue { .string(ExactText(value)) }
    private func number(_ value: Int) -> JSONValue { .number(JSONNumber(lexeme: String(value))) }
}

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(chunk)
    }

    var events: [Data] {
        lock.lock(); defer { lock.unlock() }
        return chunks
    }
}
