import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

final class ClientAPIPriorityLevelsTests: XCTestCase {
    func testStaleSaveRefreshesTheSettingsETagAndConfirmedTableWithoutReplacingDraft() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = PrioritySettingsTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
                                                    context: context, directory: nil, errors: NoopErrorLog())
        XCTAssertFalse(connection.priorityLevelsCanSave)
        await connection.refreshPriorityLevels()
        XCTAssertTrue(connection.priorityLevelsCanSave)
        let before = try repository.snapshot(context: context).priorityLevels
        XCTAssertEqual(before.confirmedLevels?.map(\.name.rawValue), ["Old"])

        let draft = [PriorityLevelDraftRow(name: "My edit", lowerBound: "0")]
        try repository.savePriorityLevelsDraft(draft, context: context)
        let table = try XCTUnwrap(PriorityLevelsTableValidation.levels(from: draft))
        try await connection.savePriorityLevels(table)
        try await waitFor {
            let state = try repository.snapshot(context: context).priorityLevels
            return state.failureReason == "precondition_failed" && state.pendingSave == nil &&
                state.confirmedLevels?.first?.name.rawValue == "Updated elsewhere" && connection.priorityLevelsCanSave
        }
        let stale = try repository.snapshot(context: context).priorityLevels
        XCTAssertEqual(stale.draftRows, draft)
        let stalePuts = await transport.puts
        XCTAssertEqual(stalePuts.count, 1, "A stale write is never replayed under a fresh precondition.")
        XCTAssertEqual(stalePuts.first?.ifMatch, "\"settings-1\"")

        try await connection.savePriorityLevels(table)
        try await waitFor {
            let state = try repository.snapshot(context: context).priorityLevels
            return state.pendingSave == nil && state.confirmedLevels == table && connection.priorityLevelsCanSave
        }
        let puts = await transport.puts
        XCTAssertEqual(puts.map(\.ifMatch), ["\"settings-1\"", "\"settings-2\""])
        XCTAssertNotEqual(puts.first?.idempotencyKey, puts.last?.idempotencyKey)
        XCTAssertEqual(puts.first?.body, puts.last?.body)
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor PrioritySettingsTransport: ClientAPITransport {
    private(set) var puts: [APIRequest] = []
    private var revision = 1
    private var name = "Old"

    func send(_ request: APIRequest) async throws -> APIResponse {
        switch (request.method, request.path) {
        case (.get, "/v2/settings"):
            return settings(etag: "\"settings-\(revision)\"")
        case (.put, "/v2/settings/priority-levels"):
            puts.append(request)
            if puts.count == 1 {
                XCTAssertEqual(request.ifMatch, "\"settings-1\"")
                revision = 2
                name = "Updated elsewhere"
                throw APIError(status: 412, token: .preconditionFailed, retryable: false, requestID: "stale")
            }
            XCTAssertEqual(request.ifMatch, "\"settings-2\"")
            revision = 3
            name = "My edit"
            return settings(etag: nil)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func settings(etag: String?) -> APIResponse {
        let body = #"{"rev":\#(revision),"settings":{"rev":\#(revision),"priority_levels":[{"name":"\#(name)","lower_bound":0,"bounce_after_days":null}],"push":{"state":"unconfigured","revision":0}}}"#
        return APIResponse(status: 200, requestID: "settings", body: Data(body.utf8), etag: etag)
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        FeedBatch(changes: [], rev: after, more: false)
    }
}
