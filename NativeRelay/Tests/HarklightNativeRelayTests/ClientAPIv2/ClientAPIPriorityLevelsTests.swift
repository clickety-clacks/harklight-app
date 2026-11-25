import AttentionDomain
import Foundation
@testable import HarklightNativeRelay
import XCTest

private func waitForSettings(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

final class ClientAPIAlertsSettingsTests: XCTestCase {
    func testSettingsAlertsDecodesSupportedValuesWithoutRejectingOtherSettings() throws {
        for (field, expected) in [("", nil), (#","alerts":"important""#, APIAlerts.important),
                                  (#","alerts":"all""#, .all), (#","alerts":"future""#, nil)] {
            let data = Data(("{\"rev\":1,\"priority_levels\":[]" + field + "}").utf8)
            let settings = try APISettings(json: JSONValue.parse(data))
            XCTAssertEqual(settings.alerts, expected)
            XCTAssertEqual(settings.priorityLevels, [])
        }
    }

    func testAlertsWriteAndSettingsFeedUseTheSameConfirmedProjection() throws {
        let write = ClientAPIWrites.alerts(.all, ifMatch: "\"settings-1\"")
        XCTAssertEqual(write.target, "settings")
        XCTAssertEqual(write.write.method, .put)
        XCTAssertEqual(write.write.path, "/v2/settings/alerts")
        XCTAssertEqual(write.write.ifMatch, "\"settings-1\"")
        XCTAssertEqual(String(decoding: try XCTUnwrap(write.write.body), as: UTF8.self), #"{"alerts":"all"}"#)

        let model = ServerModelV2Store(fileURL: nil)
        let result = try APIWriteResult(json: JSONValue.parse(Data(#"{"rev":2,"settings":{"rev":2,"alerts":"all"}}"#.utf8)))
        try model.apply(result)
        XCTAssertEqual(model.snapshot.settings?.alerts, .all)
        try model.apply(kind: "settings", rev: 3, data: JSONValue.parse(Data(#"{"rev":3,"alerts":"important"}"#.utf8)))
        XCTAssertEqual(model.snapshot.settings?.alerts, .important)
    }

    func testAlertsUseTheOutboxAndKeepTheConfirmedChoiceOnRefusal() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = PrioritySettingsTransport(featureEnabled: false)
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
            context: context, directory: nil, errors: NoopErrorLog())
        await connection.refreshSettings()
        let unsupported = await connection.alertsState()
        XCTAssertNil(unsupported)

        let gate = AsyncGate()
        defer { gate.release() }
        await transport.enableAlerts(holdingWrite: gate)
        await connection.refreshSettings()
        let initial = await connection.alertsState()
        XCTAssertEqual(initial?.confirmed, .important)
        try await connection.saveAlerts(.all)
        let saving = await connection.alertsState()
        XCTAssertEqual(saving?.confirmed, .important)
        XCTAssertTrue(saving?.isSaving == true)
        gate.release()
        try await waitForSettings { await connection.alertsState()?.hasFailure == true }
        let refused = await connection.alertsState()
        XCTAssertEqual(refused?.confirmed, .important)
        XCTAssertTrue(refused?.hasFailure == true)

        try await connection.saveAlerts(.all)
        try await waitForSettings {
            guard let state = await connection.alertsState() else { return false }
            return state.confirmed == .all && !state.isSaving
        }
        let accepted = await connection.alertsState()
        XCTAssertEqual(accepted?.confirmed, .all)
        XCTAssertFalse(accepted?.hasFailure == true)
        let writes = await transport.puts
        XCTAssertEqual(writes.map(\.ifMatch), ["\"settings-2\"", "\"settings-2\""])
        XCTAssertNotEqual(writes.first?.idempotencyKey, writes.last?.idempotencyKey)
    }
}

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
        try await connection.refreshMe()
        await connection.refreshPriorityLevels()
        XCTAssertTrue(connection.priorityLevelsCanSave)
        let before = try repository.snapshot(context: context).priorityLevels
        XCTAssertEqual(before.confirmedLevels?.map(\.name.rawValue), ["Old"])

        let draft = [PriorityLevelDraftRow(name: "My edit", lowerBound: "0")]
        try repository.savePriorityLevelsDraft(draft, context: context)
        let table = try XCTUnwrap(PriorityLevelsTableValidation.levels(from: draft))
        try await connection.savePriorityLevels(table)
        try await waitForSettings {
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
        try await waitForSettings {
            let state = try repository.snapshot(context: context).priorityLevels
            return state.pendingSave == nil && state.confirmedLevels == table && connection.priorityLevelsCanSave
        }
        let puts = await transport.puts
        XCTAssertEqual(puts.map(\.ifMatch), ["\"settings-1\"", "\"settings-2\""])
        XCTAssertNotEqual(puts.first?.idempotencyKey, puts.last?.idempotencyKey)
        XCTAssertEqual(puts.first?.body, puts.last?.body)
    }

    func testSettingsEventDisablesSaveUntilTheETagForItsRevisionArrives() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let repository = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
        let transport = PrioritySettingsTransport()
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
                                                    context: context, directory: nil, errors: NoopErrorLog())
        let run = Task { await connection.runForeground() }
        let gate = AsyncGate()
        defer { gate.release(); run.cancel() }
        try await waitForSettings { connection.model.heldCursor != nil && transport.base.openFeedCount == 1 }
        try await connection.refreshMe()
        await connection.refreshPriorityLevels()
        XCTAssertTrue(connection.priorityLevelsCanSave)
        let initial = connection.model.settingsPosition

        await transport.advanceSettings(holdingRead: gate)
        try await waitForSettings { await transport.settingsReads == 2 }
        XCTAssertFalse(connection.priorityLevelsCanSave)
        let changed = connection.model.settingsPosition
        XCTAssertEqual(changed.generation, initial.generation)
        XCTAssertEqual(changed.revision, 2)
        let state = try repository.snapshot(context: context).priorityLevels
        XCTAssertEqual(state.confirmedLevels?.first?.name.rawValue, "Updated elsewhere")

        let edit = PriorityLevel(name: ExactText("My edit"), lowerBound: 0, bounceAfterDays: nil)
        do {
            try await connection.savePriorityLevels([edit])
            XCTFail("Save is unavailable while the tag is stale.")
        } catch ClientAPIModelError.invalid("settings.etag") {}
        let beforeRefresh = await transport.puts
        XCTAssertTrue(beforeRefresh.isEmpty)
        gate.release()
        try await waitForSettings { connection.priorityLevelsCanSave }
    }

    func testDisabledFeatureKeepsPersistedPriorityWriteAndDraftWithoutSending() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = MemoryPendingActionPersistence()
        let oldRepository = try ClientRepository(context: context, persistence: persistence)
        let transport = PrioritySettingsTransport(featureEnabled: false)
        let before = try ClientAPIv2Connection(transport: transport, repository: oldRepository,
            context: context, directory: directory, errors: NoopErrorLog(), foregroundOnlyWrites: true)
        let draft = [PriorityLevelDraftRow(name: "My edit", lowerBound: "0")]
        try oldRepository.savePriorityLevelsDraft(draft, context: context)
        let table = try XCTUnwrap(PriorityLevelsTableValidation.levels(from: draft))
        let pending = try oldRepository.beginPriorityLevelsSave(table, context: context, ifMatch: "\"settings-1\"")
        let write = try XCTUnwrap(ClientAPIWrites.priorityLevels(pending))
        try await before.outbox.submit(target: write.target, operation: write.operation,
                                     write: write.write, idempotencyKey: pending.operationID)
        let previousMe = Data(#"{"account":{"state":"active"},"features":{"priority_level_editing":true},"limits":{}}"#.utf8)
        try previousMe.write(to: directory.appendingPathComponent("me-v2.json"))
        let repository = try ClientRepository(context: context, persistence: persistence)
        let disabledRead = expectation(description: "Fresh /me disables priority editing")
        let connection = try ClientAPIv2Connection(transport: transport, repository: repository,
            context: context, directory: directory, errors: NoopErrorLog(), foregroundOnlyWrites: true,
            onMe: { me in
                if me.features["priority_level_editing"] == false { disabledRead.fulfill() }
            })
        let meGate = AsyncGate()
        await transport.holdMe(meGate)
        let run = Task { await connection.runForeground() }
        defer { meGate.release(); run.cancel() }
        try await waitForSettings { transport.base.openFeedCount == 1 }
        await connection.outbox.flush()
        let beforeMe = await transport.puts
        XCTAssertTrue(beforeMe.isEmpty, "A saved true flag cannot authorize a replay before /me.")

        meGate.release()
        await fulfillment(of: [disabledRead], timeout: 3)
        await connection.outbox.flush()
        let disabled = await transport.puts
        let outbox = await connection.outbox.pending
        let state = try repository.snapshot(context: context).priorityLevels
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertFalse(connection.priorityLevelsCanSave)
        XCTAssertEqual(outbox.map(\.id), [pending.operationID])
        XCTAssertEqual(state.pendingSave, pending)
        XCTAssertEqual(state.draftRows, draft)

        await transport.enablePriorityEditing()
        _ = try await connection.refreshMe()
        try await waitForSettings { await transport.puts.count == 1 }
        let reenabled = await transport.puts
        XCTAssertEqual(reenabled.first?.idempotencyKey, pending.operationID)
        XCTAssertEqual(reenabled.first?.ifMatch, pending.ifMatch)
        XCTAssertEqual(reenabled.first?.body, write.write.body)
    }

}

private actor PrioritySettingsTransport: ClientAPITransport {
    nonisolated let base = FakeClientAPIServer()
    private(set) var puts: [APIRequest] = []
    private(set) var settingsReads = 0
    private var revision = 1
    private var name = "Old"
    private var featureEnabled: Bool
    private var settingsGate: AsyncGate?
    private var meGate: AsyncGate?
    private var alerts: APIAlerts?
    private var alertsGate: AsyncGate?

    init(featureEnabled: Bool = true) {
        self.featureEnabled = featureEnabled
    }

    func advanceSettings(holdingRead gate: AsyncGate) {
        revision = 2
        name = "Updated elsewhere"
        settingsGate = gate
        base.commit("settings", settingsObject)
    }

    func holdMe(_ gate: AsyncGate) { meGate = gate }

    func enablePriorityEditing() { featureEnabled = true }

    func enableAlerts(holdingWrite gate: AsyncGate) {
        alerts = .important
        alertsGate = gate
        revision = 2
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        switch (request.method, request.path) {
        case (.get, "/v2/me"):
            let enabled = featureEnabled
            if let meGate { await meGate.wait() }
            let body = #"{"account":{"state":"active"},"features":{"priority_level_editing":\#(enabled)},"limits":{}}"#
            return APIResponse(status: 200, requestID: "me", body: Data(body.utf8))
        case (.get, "/v2/settings"):
            settingsReads += 1
            if let settingsGate { await settingsGate.wait() }
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
        case (.put, "/v2/settings/alerts"):
            puts.append(request)
            if let alertsGate {
                self.alertsGate = nil
                await alertsGate.wait()
                throw APIError(status: 400, token: .invalidField, retryable: false, requestID: "refused")
            }
            revision += 1
            alerts = .all
            return settings(etag: nil)
        default:
            return try await base.send(request)
        }
    }

    private var settingsObject: String {
        let choice = alerts.map { #","alerts":"\#($0.rawValue)""# } ?? ""
        return #"{"rev":\#(revision),"priority_levels":[{"name":"\#(name)","lower_bound":0,"bounce_after_days":null}],"push":{"state":"unconfigured","revision":0}\#(choice)}"#
    }

    private func settings(etag: String?) -> APIResponse {
        let body = #"{"rev":\#(revision),"settings":\#(settingsObject)}"#
        return APIResponse(status: 200, requestID: "settings", body: Data(body.utf8), etag: etag)
    }

    nonisolated func changeFeed(after: Rev) -> AsyncThrowingStream<FeedEvent, any Error> {
        base.changeFeed(after: after)
    }

    func changeBatch(after: Rev) async throws -> FeedBatch {
        try await base.changeBatch(after: after)
    }
}
