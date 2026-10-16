import AttentionDomain
import AttentionHostBoundary
import Darwin
import Foundation

// A real profile/relay owner has not been installed. Default invocation keeps
// API closed; the explicit fictional fixture mode exercises C's durable port.
private func fixturePort(jsonURL: URL, stateDirectoryURL: URL) throws -> AttentionDomainPort {
    let fixture = try JSONValue.parse(Data(contentsOf: jsonURL))
    guard fixture.uniqueValue(named: "account")?.stringValue?.rawValue == "fictional-sample-account",
          let payloads = fixture.uniqueValue(named: "requests")?.arrayValues,
          !payloads.isEmpty, payloads.count <= 16 else {
        throw HostBoundaryError.rejected
    }
    let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:attention"),
                                   personID: ExactText("fictional-sample-account"),
                                   deviceID: ExactText("foreground-host-fixture"))
    let context = ProfileContext(identity: identity, transportMode: .fixture)
    let persistence = FileAttentionStatePersistence(directoryURL: stateDirectoryURL)
    let store = try AttentionDomainStore(context: context, persistence: persistence)
    let requests = try payloads.map { payload -> StoredRequest in
        guard payload.hasUniqueObjectKeys,
              let sender = payload.uniqueValue(named: "sender_id")?.stringValue,
              let message = payload.uniqueValue(named: "message_id")?.stringValue else {
            throw HostBoundaryError.rejected
        }
        let key = RequestKey(accountScope: identity.personID, senderID: sender, messageID: message)
        return StoredRequest(key: key, originalPayload: payload)
    }
    try store.registerFixtureRequests(requests, context: context)
    return AttentionDomainPort(store: store)
}

do {
    let arguments = CommandLine.arguments
    let page = BundledHostPage()
    let server: LoopbackHTTPServer
    if arguments.count == 5, arguments[1] == "--fixture",
       arguments[3] == "--state-dir" {
        let port = try fixturePort(jsonURL: URL(fileURLWithPath: arguments[2]),
                                   stateDirectoryURL: URL(fileURLWithPath: arguments[4]))
        let routes = try NativeDomainRoutes(port: port, gate: HostSessionGate())
        let secret = try routes.issuePairSecret()
        server = LoopbackHTTPServer { request, boundary in routes.reply(request, boundary: boundary) }
        let selectedPort = try server.start()
        print("Fictional Harklight fixture: http://127.0.0.1:\(selectedPort)/")
        print("Pairing code: \(secret)")
        print("Fixture data is local to this Mac; no relay or source is connected.")
    } else if arguments.count == 1 {
        server = LoopbackHTTPServer { request, boundary in page.reply(request, boundary: boundary) }
        let selectedPort = try server.start()
        print("Harklight foreground page: http://127.0.0.1:\(selectedPort)/")
        print("Native profile owner unavailable; all API requests fail closed.")
    } else {
        throw HostBoundaryError.rejected
    }
    while true { RunLoop.current.run(until: Date().addingTimeInterval(3600)) }
} catch {
    FileHandle.standardError.write(Data("Unable to start literal-loopback Harklight host.\n".utf8))
    exit(1)
}
