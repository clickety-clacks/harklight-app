import XCTest
@testable import AttentionClientDuoPrototype
import AttentionDomain

final class ReplyDraftUpdateLatencyTests: XCTestCase {
    @MainActor
    func testApplicationReplyDraftUpdateLatencyFor256Keystrokes() throws {
        let fixtures = try FixtureSet.loadBundled(from: Bundle(for: ReplyDraftUpdateLatencyTests.self))
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else {
            return XCTFail("Expected the reply fixture's sender document.")
        }
        let input = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reply-draft-latency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let requestKey = RequestKey(accountScope: context.identity.personID,
                                    senderID: fixture.key.senderID,
                                    messageID: fixture.key.messageID)
        _ = try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: requestKey, originalPayload: fixture.originalPayload), .message)),
            context: context)
        let editor = try LivePresentationStore(store: store, context: context)

        var reply = ""
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<256 {
            reply.append("a")
            editor.updateText(reply, input: input.id, action: nil, for: requestKey)
        }
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000

        let measurement = """
        scenario=live reply draft update path
        characters=\(reply.count)
        elapsed_ms=\(String(format: "%.2f", elapsedMilliseconds))
        average_ms_per_character=\(String(format: "%.4f", elapsedMilliseconds / Double(reply.count)))
        """
        let attachment = XCTAttachment(data: Data(measurement.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "reply-draft-update-latency"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
