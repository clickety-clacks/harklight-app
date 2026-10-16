import AttentionDomain
import Foundation
import HarklightNativeRelay
import Security

struct NativeRelayRefreshResult: Equatable, Sendable {
    enum PushRegistration: Equatable, Sendable {
        case notAttempted
        case confirmed
        case unconfirmed
    }

    let relayConfirmed: Bool
    let pushRegistration: PushRegistration
    static let unavailable = Self(relayConfirmed: false, pushRegistration: .notAttempted)

    // No pending registration is not proof of notification permission/delivery.
    var completedWithoutError: Bool { relayConfirmed && pushRegistration != .unconfirmed }

    @MainActor
    static func afterConfirmedRelay(
        _ registration: @MainActor () async throws -> PushRegistration
    ) async -> Self {
        do { return Self(relayConfirmed: true, pushRegistration: try await registration()) }
        catch { return Self(relayConfirmed: true, pushRegistration: .unconfirmed) }
    }
}

/// App-owned wake boundary. A future enrollment/profile owner supplies the
/// authenticated installation material and the SAME C store used by live UI.
/// Fixture launch deliberately leaves this unconfigured.
@MainActor
final class NativeRelayLifecycle {
    static let shared = NativeRelayLifecycle()

    private var core: NativeRelayCore?
    private var transport: URLSessionInstallationSession?
    private var context: ProfileContext?
    private var confirmedRelayContext: ProfileContext?
    private var configuration: (store: AttentionDomainStore,
                                context: ProfileContext,
                                relayURL: URL,
                                identity: SecIdentity,
                                rootDER: Data)?
    private var refreshGeneration = UUID()
    private lazy var refreshFlights = RelayRefreshFlights(inactive: NativeRelayRefreshResult.unavailable) { [weak self] in
        guard let self else { return .unavailable }
        return await self.performRefresh(generation: self.refreshGeneration)
    }
    private let enrollment = NativeEnrollmentStore()

    private init() {}

    func activate(store: AttentionDomainStore,
                  context: ProfileContext,
                  relayURL: URL,
                  clientIdentity: SecIdentity,
                  trustedRootDER: Data) async throws {
        _ = try store.snapshot(context: context)
        let nextTransport = try URLSessionInstallationSession(profile: context,
                                                              relayURL: relayURL,
                                                              clientIdentity: TrustedKeychainIdentity(clientIdentity),
                                                              trustedRootDER: trustedRootDER)
        let nextCore: NativeRelayCore
        do {
            nextCore = try NativeRelayCore(store: store, context: context, session: nextTransport)
        } catch {
            await nextTransport.close()
            throw error
        }
        let generation = UUID()
        refreshGeneration = generation
        refreshFlights.reset()
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        self.context = nil
        confirmedRelayContext = nil
        configuration = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
        guard refreshGeneration == generation else {
            await nextCore.deactivate()
            await nextTransport.close()
            throw NativeRelayCoreError.inactive
        }
        transport = nextTransport
        core = nextCore
        self.context = context
        configuration = (store, context, relayURL, clientIdentity, trustedRootDER)
    }

    func deactivate() async {
        refreshGeneration = UUID()
        refreshFlights.reset()
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        context = nil
        confirmedRelayContext = nil
        configuration = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
    }

    /// APNs data is a wake hint only. The payload cannot choose account,
    /// sender, message, cursor, operation or answer.
    @discardableResult
    func refreshFromTrustedRelay() async -> Bool {
        await refreshResultFromTrustedRelay().relayConfirmed
    }

    func refreshResultFromTrustedRelay() async -> NativeRelayRefreshResult {
        await refreshFlights.coalesced()
    }

    /// Enrollment readiness is actual authenticated replay progress. A later
    /// push-register failure must not hide a working foreground connection.
    func confirmForegroundProgress(for expected: ProfileContext) async -> Bool {
        guard context == expected else { return false }
        let epoch = refreshGeneration
        _ = await refreshFromTrustedRelay()
        return refreshGeneration == epoch && context == expected && confirmedRelayContext == expected
    }

    /// A token callback can arrive after an in-flight resync has already read
    /// the protected address. Queue one more authenticated pass in that case.
    @discardableResult
    func refreshAfterPushAddressStored() async -> Bool {
        await refreshFlights.afterCurrent().completedWithoutError
    }

    /// The current flight may already have read C's outbox before the person
    /// committed this answer. A later pass must see that original operation.
    func refreshAfterAnswerStored() async -> NativeRelayRefreshResult {
        await refreshFlights.afterCurrent()
    }

    func submitDiscussion(_ binding: ConversationBinding, expected: ProfileContext,
                          retainedFile: @Sendable (ConversationFile) async throws -> URL) async throws -> DiscussionOperationResult {
        guard context == expected, let configuration else { throw NativeRelayCoreError.inactive }
        let pending = try configuration.store.conversationSnapshot(context: expected).threads[binding.request]?.drafts[binding.revision]
        let operation: UUID?
        switch pending?.disposition {
        case let .submitting(id), let .outcomeUnknown(id), let .acceptedPendingReplay(id, _): operation = id
        default: operation = nil
        }
        _ = await refreshFlights.coalesced()
        guard context == expected, let core else { throw NativeRelayCoreError.inactive }
        // Refresh may already have joined the uncertain operation. Do not turn
        // that successful reconciliation into a new send or a missing-draft error.
        if let operation, let accepted = try configuration.store.conversationSnapshot(context: expected)
            .threads[binding.request]?.turns.first(where: { $0.operationID == operation }) {
            return .accepted(turnID: accepted.id)
        }
        return try await core.submitDiscussion(binding, retainedFile: retainedFile)
    }

    func fetchConversationFile(_ file: ConversationFile, to destination: URL, expected: ProfileContext) async throws {
        guard context == expected else { throw NativeRelayCoreError.inactive }
        _ = await refreshFlights.coalesced()
        guard context == expected, let core, let transport,
              let endpoint = try await core.conversationOriginURL() else {
            throw ConversationError.uploadRequired(file.name)
        }
        try await transport.fetchConversationFile(file, to: destination, originURL: endpoint)
        guard context == expected else { throw NativeRelayCoreError.inactive }
    }

    private func performRefresh(generation: UUID) async -> NativeRelayRefreshResult {
        guard refreshGeneration == generation else { return .unavailable }
        // A past replay is not proof that this connection attempt worked.
        confirmedRelayContext = nil
        do {
            let result = try await refreshOnce(generation: generation)
            return refreshGeneration == generation ? result : .unavailable
        } catch {
            guard refreshGeneration == generation else { return .unavailable }
            // Retire an ambiguous WebSocket before retrying C's exact durable
            // outbox and cursor once on a fresh authenticated session.
            do {
                try await reconnect(generation: generation)
                guard refreshGeneration == generation else { return .unavailable }
                let result = try await refreshOnce(generation: generation)
                return refreshGeneration == generation ? result : .unavailable
            } catch {
                return .unavailable
            }
        }
    }

    private func refreshOnce(generation: UUID) async throws -> NativeRelayRefreshResult {
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        guard let core, let transport, let context else { throw NativeRelayCoreError.inactive }
        _ = try await core.resyncAndDrainOutbox()
        guard refreshGeneration == generation, self.context == context else { throw NativeRelayCoreError.inactive }
        confirmedRelayContext = context
        // Notification setup is a separate fact from the replay/answer receipt
        // already committed above. Its refusal cannot undo that success.
        return await NativeRelayRefreshResult.afterConfirmedRelay {
            if let address = try DevelopmentPushRegistration.addressStore().load(),
               let binding = try enrollment.pendingPushRegistration(address: address,
                                                                     for: context.identity.deviceID.rawValue) {
                try await transport.registerPush(address: binding.address,
                                                 operationID: binding.operationID,
                                                 revision: binding.revision)
                guard self.refreshGeneration == generation, self.context == context else {
                    throw NativeRelayCoreError.inactive
                }
                try enrollment.markPushAccepted(binding, for: context.identity.deviceID.rawValue)
                return .confirmed
            }
            return .notAttempted
        }
    }

    private func reconnect(generation: UUID) async throws {
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        guard let configuration else { throw NativeRelayCoreError.inactive }
        let priorCore = core
        let priorTransport = transport
        core = nil
        transport = nil
        if let priorCore { await priorCore.deactivate() }
        if let priorTransport { await priorTransport.close() }
        guard refreshGeneration == generation else { throw NativeRelayCoreError.inactive }
        let nextTransport = try URLSessionInstallationSession(profile: configuration.context,
                                                              relayURL: configuration.relayURL,
                                                              clientIdentity: TrustedKeychainIdentity(configuration.identity),
                                                              trustedRootDER: configuration.rootDER)
        let nextCore: NativeRelayCore
        do {
            nextCore = try NativeRelayCore(store: configuration.store,
                                           context: configuration.context,
                                           session: nextTransport)
        } catch {
            await nextTransport.close()
            throw error
        }
        guard refreshGeneration == generation else {
            await nextCore.deactivate()
            await nextTransport.close()
            throw NativeRelayCoreError.inactive
        }
        self.transport = nextTransport
        self.core = nextCore
    }
}

/// Normal foreground/push wakes share a flight. A newly stored APNs address
/// must be checked *after* the current flight, even when it arrived during it.
@MainActor
final class RelayRefreshFlights<Output: Sendable> {
    private let inactive: Output
    private let operation: @MainActor () async -> Output
    private var latest: Task<Output, Never>?
    private var latestID: UUID?
    private var generation = UUID()

    init(inactive: Output, operation: @escaping @MainActor () async -> Output) {
        self.inactive = inactive
        self.operation = operation
    }

    func coalesced() async -> Output {
        if let latest { return await latest.value }
        return await start(after: nil)
    }

    func afterCurrent() async -> Output {
        await start(after: latest)
    }

    func reset() {
        generation = UUID()
        latest = nil
        latestID = nil
    }

    private func start(after previous: Task<Output, Never>?) async -> Output {
        let requestedGeneration = generation
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { _ = await previous.value }
            guard generation == requestedGeneration else { return inactive }
            let result = await operation()
            if generation == requestedGeneration && latestID == id {
                latest = nil
                latestID = nil
            }
            return result
        }
        latest = task
        latestID = id
        return await task.value
    }
}
