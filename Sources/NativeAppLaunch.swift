import AttentionDomain
import HarklightNativeRelay
import Foundation
import CryptoKit
import Observation
import Security
import UIKit
import UserNotifications

/// Material supplied only after an enrollment owner has verified the server's
/// approved person/device record. This consumer never infers it from a push or
/// from the bundled fictional fixture.
struct NativeInstallationMaterial {
    let context: ProfileContext
    let relayURL: URL
    let keychainIdentity: SecIdentity
    let trustedRootDER: Data
}

/// In-memory presentation identity for one failed foreground attempt. The
/// profile identity keeps a dismissal from leaking across accounts; the
/// attempt ID lets a later failure surface normally.
struct NativeForegroundConnectFailureKey: Equatable, Hashable {
    let profileAuthority: String
    let personID: String
    let deviceID: String
    let attemptID: UUID

    init?(record: NativeEnrollmentRecord, progress: NativeForegroundConnectProgress) {
        guard progress.outcome == .incomplete || progress.outcome == .timedOut,
              let attemptID = progress.attemptID,
              let personID = record.personID else { return nil }
        profileAuthority = record.profileAuthority
        self.personID = personID
        deviceID = record.deviceID
        self.attemptID = attemptID
    }
}

@MainActor
@Observable
final class NativeAppLaunch {
    enum State {
        case enrollmentRequired
        case enrollmentPending(NativeEnrollmentRecord)
        case fixture(PrototypeStore)
        case live(LivePresentationStore)
        case disconnected(LivePresentationStore?)
    }

    private(set) var state: State
    private(set) var enrollmentMessage: String?
    private(set) var isEnrollmentBusy = false
    private(set) var isEnrollmentExpired = false
    private(set) var foregroundConnectProgress: NativeForegroundConnectProgress?
    private(set) var foregroundConnectDiagnostic: NativeForegroundConnectDiagnostic?
    private(set) var activeEnrollmentRecord: NativeEnrollmentRecord?
    private(set) var disconnectedAccount: NativeAccountDeparture?
    private(set) var disconnectedArchive: LivePresentationStore?
    private(set) var archivedAccountDepartures: [NativeAccountDeparture] = []
    private(set) var unconfirmedAccountDepartures: [NativeAccountDeparture] = []
    private(set) var disconnectRemovalMessages: [String: String] = [:]
    private(set) var selectedArchivedAccount: NativeAccountDeparture?
    private(set) var selectedArchivedPresentation: LivePresentationStore?
    private(set) var archiveCatalogWarning: String?
    private(set) var isShowingDisconnectedArchive = false
    private(set) var disconnectMessage: String?
    private var disconnectRemovalBusyIDs: Set<String> = []
    private(set) var endpointMigrationMessage: String?
    private(set) var isEndpointMigrationBusy = false
    let hasPriorAppState: Bool
    let guidedJoin: NativeGuidedJoinCoordinator
    let diagnostics: NativeClientDiagnosticJournal
    let notificationRouter: NativeNotificationRouter
    private(set) var notificationNavigation: NativeInboxNavigation?
    private(set) var notificationNavigationMessage: String?
    @ObservationIgnored private var notificationSynchronized = false
    @ObservationIgnored private var notificationRefreshFinished = false
    @ObservationIgnored private var handledNotificationSerial: UInt64?
    @ObservationIgnored private var resolvingNotificationSerial: UInt64?
    @ObservationIgnored private var pendingMessageDeepLink: NativeMessageDeepLink?
    @ObservationIgnored private var didFinishRestoring = false
    @ObservationIgnored private var foregroundActivationPushCheckPending = false
    @ObservationIgnored private let refreshOperation: @MainActor (Bool) async -> NativeRelayRefreshResult
    @ObservationIgnored private let fetchInboxPageOperation: (@MainActor (LivePresentationStore) async -> Bool)?

    private var dismissedForegroundConnectFailure: NativeForegroundConnectFailureKey?

    @ObservationIgnored private let enrollment: NativeEnrollmentStore
    @ObservationIgnored private let guidedJoinStore: NativeGuidedJoinStore
    @ObservationIgnored private let notifications = NativeNotificationPermission.system
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var activationGeneration = UUID()

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         enrollmentStore: NativeEnrollmentStore? = nil,
         joinStore suppliedJoinStore: NativeGuidedJoinStore? = nil,
         initialState: State? = nil,
         initialEnrollmentRecord: NativeEnrollmentRecord? = nil,
         initialArchivedDepartures: [NativeAccountDeparture] = [],
         notificationRouter: NativeNotificationRouter = .shared,
         refreshOperation: @escaping @MainActor (Bool) async -> NativeRelayRefreshResult = { checkBlockedPush in
             await NativeRelayLifecycle.shared.refreshResultFromTrustedRelay(
                checkBlockedPush: checkBlockedPush)
         },
         fetchInboxPageOperation: (@MainActor (LivePresentationStore) async -> Bool)? = nil) {
        #if DEBUG
        let fixture = arguments.contains("--reset-attention-fixture") || arguments.contains("--attention-fixture")
        #else
        let fixture = false
        #endif
        let enrollment = enrollmentStore ?? NativeEnrollmentStore()
        let joinStore = suppliedJoinStore ?? NativeGuidedJoinStore()
        self.enrollment = enrollment
        guidedJoinStore = joinStore
        hasPriorAppState = fixture ? false : NativeInstallationHistory.hasPriorAppState(
            enrollment: enrollment, guidedJoin: joinStore)
        let diagnostics = NativeClientDiagnosticJournal()
        self.diagnostics = diagnostics
        self.notificationRouter = notificationRouter
        self.refreshOperation = refreshOperation
        self.fetchInboxPageOperation = fetchInboxPageOperation
        didFinishRestoring = initialState != nil
        activeEnrollmentRecord = initialEnrollmentRecord
        archivedAccountDepartures = initialArchivedDepartures
        unconfirmedAccountDepartures = fixture ? [] : ((try? joinStore.unconfirmedDepartures()) ?? [])
        let savedDeparture = fixture ? nil : (try? joinStore.departure())
        let standaloneDeparture = savedDeparture.flatMap { $0.replacement == nil ? $0 : nil }
        disconnectedAccount = standaloneDeparture
        guidedJoin = NativeGuidedJoinCoordinator(store: joinStore,
                                                 deviceName: UIDevice.current.name,
                                                 isShowing: !fixture && standaloneDeparture == nil,
                                                 diagnostics: diagnostics)
        if let initialState {
            state = initialState
        } else if fixture {
            state = .fixture(PrototypeStore.loadFromBundle())
        } else if let standaloneDeparture {
            state = .disconnected(nil)
        } else {
            state = .enrollmentRequired
        }
        guidedJoin.departureRecordsDidChange = { [weak self] in
            self?.refreshArchivedAccounts()
        }
        guidedJoin.connectApproved = { [weak self] record in
            guard let self else { return false }
            let material = try self.enrollment.material(from: record)
            self.activeEnrollmentRecord = record
            try await self.activate(material)
            let epoch = self.activationGeneration
            let checkBlockedPush = self.takeForegroundActivationPushCheck()
            let connect = await NativeRelayLifecycle.shared.confirmForegroundProgress(
                for: material.context, checkBlockedPush: checkBlockedPush) { [weak self] progress in
                guard let self else { return }
                self.recordForegroundConnectProgress(
                    progress,
                    operationSnapshot: NativeRelayLifecycle.shared.foregroundOperationDiagnostics(for: material.context))
                if case let .live(presentation) = self.state {
                    presentation.connectionWarning = progress.outcome == .confirmed ? nil : progress.message
                }
            }
            guard self.activationGeneration == epoch else {
                if let attemptID = connect.attemptID,
                   self.foregroundConnectProgress?.attemptID == attemptID {
                    var invalidated = connect
                    invalidated.markGenerationInvalidated()
                    let operationSnapshot = self.foregroundConnectDiagnostic?.operationSnapshot ?? .unavailable
                    self.foregroundConnectProgress = invalidated
                    self.foregroundConnectDiagnostic = NativeForegroundConnectDiagnostic(
                        progress: invalidated, operationSnapshot: operationSnapshot)
                }
                self.diagnostics.record([
                    NativeClientDiagnosticEvent(area: .connection, phase: .foregroundGenerationValidation,
                        transition: .cancelled, causeCode: "foreground_generation_invalidated",
                        terminalReason: NativeDiagnosticTerminalReason.generationInvalidated,
                        attemptID: connect.attemptID, transportAttemptID: connect.transportAttemptID),
                    NativeClientDiagnosticEvent(area: .connection, phase: .foregroundCompletion,
                        transition: .cancelled, causeCode: "foreground_generation_invalidated",
                        terminalReason: NativeDiagnosticTerminalReason.generationInvalidated,
                        postAckBoundary: connect.lastCompletedPostAckBoundary.journalValue,
                        postAckDrainTransition: connect.postAckDrainTransition,
                        attemptID: connect.attemptID, transportAttemptID: connect.transportAttemptID)
                ])
                return false
            }
            let reached = connect.outcome == .confirmed
            if reached { try self.enrollment.markForegroundRelayConfirmed(for: record.deviceID) }
            if case let .live(presentation) = self.state {
                presentation.connectionWarning = reached ? nil : connect.message
            }
            return reached
        }
        guidedJoin.notificationChoice = { [weak self] enabled in
            await self?.chooseNotifications(enabled)
        }
        guidedJoin.didRemoveCurrentAccount = { [weak self] in
            guard let self else { return }
            self.activationGeneration = UUID()
            if case let .live(previous) = self.state {
                previous.stopObserving()
            }
            self.state = .enrollmentRequired
            self.activeEnrollmentRecord = nil
            await NativeRelayLifecycle.shared.deactivate()
            self.clearForegroundConnectionDetails()
            // Replacement removal commits the old account into the archive
            // catalog before this callback. Refresh now so Settings can expose
            // it in this process without waiting for another launch.
            self.refreshArchivedAccounts()
        }
    }

    func restoreInstallation() async {
        guard !didRestore else { return }
        didRestore = true
        defer { didFinishRestoring = true }
        if case .fixture = state { return }
        refreshArchivedAccounts()
        if let departure = try? guidedJoinStore.departure(),
           departure.replacement == nil {
            disconnectedAccount = departure
            let attempt = try? guidedJoinStore.loadAttempt()
            let active = try? enrollment.load()
            let hasNewRegistration =
                (attempt.map { $0.deviceID != departure.record.deviceID } ?? false) ||
                (active.map { $0.isApproved && $0.deviceID != departure.record.deviceID } ?? false)
            if hasNewRegistration {
                if let archive = try? makeDisconnectedPresentation(for: departure) {
                    archive.enterReadOnlyMode()
                    disconnectedArchive = archive
                    state = .disconnected(archive)
                }
                disconnectMessage = nil
                activeEnrollmentRecord = active.flatMap {
                    $0.isApproved && $0.deviceID != departure.record.deviceID ? $0 : nil
                }
                guidedJoin.restoreAfterStandaloneRemoval()
                await guidedJoin.restore()
                return
            }
            if departure.removed {
                try? guidedJoinStore.finishConfirmedDeparture(departure)
                disconnectedAccount = try? guidedJoinStore.departure() ?? departure
            }
            let archive = try? makeDisconnectedPresentation(for: departure)
            archive?.enterReadOnlyMode()
            disconnectedArchive = archive
            isShowingDisconnectedArchive = archive != nil
            if case let .live(previous) = state { previous.stopObserving() }
            activeEnrollmentRecord = nil
            state = .disconnected(archive)
            disconnectMessage = disconnectedStatusMessage(for: departure, presentation: archive)
            guidedJoin.holdForDisconnectedAccount(departure)
            await NativeRelayLifecycle.shared.deactivate()
            return
        }
        await guidedJoin.restore()
    }

    func disconnectCurrentAccount() async {
        guard !isEndpointMigrationBusy, case let .live(presentation) = state,
              let record = try? enrollment.load(), record.isApproved,
              !isDisconnectBusy(for: NativeAccountDeparture(
                record: record, replacement: nil, removed: false)) else { return }
        disconnectMessage = nil
        do {
            try guidedJoin.prepareStandaloneRemoval(record)
            refreshArchivedAccounts()
            let departure = try guidedJoinStore.departure() ??
                NativeAccountDeparture(record: record, replacement: nil, removed: false)
            disconnectedAccount = departure
            disconnectedArchive = presentation
            isShowingDisconnectedArchive = true
            presentation.enterReadOnlyMode()
            if case let .live(current) = state, current === presentation {
                state = .disconnected(presentation)
            }
            activeEnrollmentRecord = nil
            activationGeneration = UUID()
            await NativeRelayLifecycle.shared.deactivate()
            clearForegroundConnectionDetails()
            await retryDisconnectRemoval()
        } catch {
            disconnectMessage = "Harklight could not save the removal request. Nothing was sent; this account is still connected. Try again."
        }
    }

    var canMigrateDirectEndpointToGibson: Bool {
        guard case .live = state, !isEndpointMigrationBusy,
              let record = activeEnrollmentRecord,
              (try? NativeEndpointMigrationPolicy.candidate(from: record)) != nil,
              hasNoRecordedDeparture else { return false }
        return true
    }

    private var hasNoRecordedDeparture: Bool {
        do {
            switch try guidedJoinStore.departure() {
            case .none: return true
            case .some: return false
            }
        } catch {
            // A storage error must not make endpoint migration appear safe
            // while an uncertain removal may still be recorded.
            return false
        }
    }

    func canApplyPersistedEndpointMigration(from original: NativeEnrollmentRecord,
                                            to migrated: NativeEnrollmentRecord) -> Bool {
        activeEnrollmentRecord == original && hasNoRecordedDeparture &&
            guidedJoin.canAdoptEndpointMigration(from: original, to: migrated)
    }

    /// Keep the active account and the ordinary inbox Retry authority aligned
    /// immediately after the validated enrollment record is persisted.
    func applyPersistedEndpointMigration(_ migrated: NativeEnrollmentRecord) {
        activeEnrollmentRecord = migrated
        guidedJoin.adoptPersistedEndpointMigration(migrated)
    }

    /// Switches only the approved endpoint. The current relay remains active
    /// until the new hostname passes the same CA and device-identity checks.
    func migrateDirectEndpointToGibson() async {
        guard canMigrateDirectEndpointToGibson,
              let record = try? enrollment.load(), record == activeEnrollmentRecord,
              let migrated = try? NativeEndpointMigrationPolicy.candidate(from: record),
              let relayURL = URL(string: "wss://\(NativeEndpointMigrationPolicy.gibsonHost):\(NativeEndpointMigrationPolicy.gibsonRelayPort)/relay") else {
            endpointMigrationMessage = "This saved connection cannot switch to the new server address. Your current connection is unchanged."
            return
        }
        let generation = activationGeneration
        isEndpointMigrationBusy = true
        endpointMigrationMessage = nil
        defer { isEndpointMigrationBusy = false }
        do {
            try await NativeRelayLifecycle.shared.migrateEndpoint(to: relayURL) {
                guard self.activationGeneration == generation,
                      self.canApplyPersistedEndpointMigration(from: record, to: migrated) else {
                    throw NativeRelayCoreError.inactive
                }
                try self.enrollment.commitGibsonEndpointMigration(from: record, to: migrated)
                self.applyPersistedEndpointMigration(migrated)
            }
            guard activationGeneration == generation else { return }
            endpointMigrationMessage = "The new server address is saved. This account, device identity, trust certificate and local history are unchanged."
            Task { await refreshLive() }
        } catch {
            guard activationGeneration == generation else { return }
            endpointMigrationMessage = "Harklight could not switch to the new server. Your current connection and saved server address are unchanged. Try again later."
        }
    }

    func retryDisconnectRemoval(for requestedDeparture: NativeAccountDeparture? = nil) async {
        guard let departure = requestedDeparture ?? disconnectedAccount,
              !isDisconnectBusy(for: departure),
              canRetryUnconfirmedDisconnectRemoval(for: departure) else { return }
        let isConnectedToAnotherAccount: Bool
        if case .live = state {
            isConnectedToAnotherAccount = activeEnrollmentRecord?.deviceID != departure.record.deviceID
        } else {
            isConnectedToAnotherAccount = false
        }
        let isCurrentReplacementFlow = departure.replacement != nil &&
            guidedJoin.screen == .replacementConfirmation &&
            guidedJoin.currentAccount?.deviceID == departure.record.deviceID &&
            guidedJoin.invitation == departure.replacement
        disconnectRemovalBusyIDs.insert(departure.archiveID)
        defer { disconnectRemovalBusyIDs.remove(departure.archiveID) }
        disconnectMessage = nil
        if !isConnectedToAnotherAccount, case .disconnected = state {
            await NativeRelayLifecycle.shared.deactivate()
        }
        do {
            if isCurrentReplacementFlow {
                await guidedJoin.confirmReplacement()
            } else {
                try await guidedJoin.removeStandaloneAccount(departure)
            }
            refreshArchivedAccounts()
            let confirmed = !unconfirmedAccountDepartures.contains { $0.archiveID == departure.archiveID }
            let account = departure.record.savedAccountName ?? "this account"
            let result = confirmed
                ? "The server confirmed removal for \(account)."
                : "The server did not confirm removal for \(account). You can retry."
            disconnectRemovalMessages[departure.archiveID] = result
            if !isConnectedToAnotherAccount && disconnectedAccount?.archiveID == departure.archiveID {
                disconnectMessage = disconnectedStatusMessage(for: disconnectedAccount ?? departure,
                                                             presentation: disconnectedStore)
            }
        } catch {
            refreshArchivedAccounts()
            let account = departure.record.savedAccountName ?? "this account"
            let result = "The server did not confirm removal for \(account). You can retry."
            disconnectRemovalMessages[departure.archiveID] = result
            if !isConnectedToAnotherAccount && disconnectedAccount?.archiveID == departure.archiveID {
                disconnectedAccount = (try? guidedJoinStore.departure()) ?? departure
                disconnectMessage = disconnectedStatusMessage(for: disconnectedAccount ?? departure,
                                                             presentation: disconnectedStore)
            }
        }
    }

    var canRetryUnconfirmedDisconnectRemoval: Bool {
        unconfirmedAccountDepartures.contains { canRetryUnconfirmedDisconnectRemoval(for: $0) }
    }

    func canRetryUnconfirmedDisconnectRemoval(for departure: NativeAccountDeparture) -> Bool {
        !departure.removed && unconfirmedAccountDepartures.contains { $0.archiveID == departure.archiveID }
    }

    var unconfirmedDisconnectWarning: String? {
        if let departure = disconnectedAccount,
           let warning = unconfirmedDisconnectWarning(for: departure) {
            return warning
        }
        return unconfirmedAccountDepartures.first.flatMap(unconfirmedDisconnectWarning(for:))
    }

    func unconfirmedDisconnectWarning(for departure: NativeAccountDeparture) -> String? {
        guard !departure.removed else { return nil }
        let account = departure.record.savedAccountName ?? "this account"
        let server = departure.record.serverDisplayName ?? departure.record.host
        return "The server, \(server), may still list this phone as registered for \(account). You can continue with another invitation and retry this removal later. Saved messages, drafts and pending answers stay with this account and will not be shown or sent through another account."
    }

    func disconnectRemovalMessage(for departure: NativeAccountDeparture) -> String? {
        disconnectRemovalMessages[departure.archiveID]
    }

    func isDisconnectBusy(for departure: NativeAccountDeparture) -> Bool {
        let replacementIsBeingRemoved = guidedJoin.busy &&
            guidedJoin.screen == .replacementConfirmation &&
            guidedJoin.currentAccount?.deviceID == departure.record.deviceID
        return disconnectRemovalBusyIDs.contains(departure.archiveID) || replacementIsBeingRemoved
    }

    func beginReconnect() {
        guard let departure = disconnectedAccount, departure.removed,
              !isDisconnectBusy(for: departure) else { return }
        guidedJoin.beginReconnect()
    }

    func cancelReconnect() {
        guard case .disconnected = state,
              disconnectedAccount.map({ !isDisconnectBusy(for: $0) }) ?? true else { return }
        guidedJoin.returnToDisconnectedAccount()
    }

    func receiveInvitation(_ url: URL) async {
        if NativeMessageDeepLink.recognizes(url) {
            notificationRouter.consumed()
            guard let deepLink = NativeMessageDeepLink(url: url) else {
                pendingMessageDeepLink = nil
                notificationNavigationMessage = "This message link couldn't be opened."
                return
            }
            await receiveMessageDeepLink(deepLink)
            return
        }
        if case .disconnected = state,
           let departure = disconnectedAccount,
           departure.replacement == nil {
            guidedJoin.beginReconnect()
        }
        await guidedJoin.receive(url)
    }

    private func receiveMessageDeepLink(_ deepLink: NativeMessageDeepLink) async {
        pendingMessageDeepLink = deepLink
        notificationSynchronized = false
        notificationRefreshFinished = false
        notificationNavigationMessage = nil
        guard case let .live(presentation) = state,
              !presentation.isReadOnly, !presentation.isLocalExample else { return }

        let key = messageKey(for: deepLink, in: presentation)
        navigateToMessage(key, in: presentation)
        if presentation.isRetracted(key) {
            pendingMessageDeepLink = nil
            notificationNavigationMessage = "The sender retracted this message."
        } else if presentation.request(for: key) != nil {
            pendingMessageDeepLink = nil
            notificationNavigationMessage = nil
        } else {
            notificationNavigationMessage = "Looking for this message."
            await refreshLive()
        }
    }

    private func messageKey(for deepLink: NativeMessageDeepLink,
                            in presentation: LivePresentationStore) -> RequestKey {
        RequestKey(accountScope: presentation.notificationContext.identity.personID,
                   senderID: ExactText(deepLink.senderID),
                   messageID: ExactText(deepLink.messageID))
    }

    private func navigateToMessage(_ key: RequestKey, in presentation: LivePresentationStore) {
        let serial = max(notificationNavigation?.serial ?? 0,
                         notificationRouter.intent?.serial ?? 0) &+ 1
        notificationNavigation = NativeInboxNavigation(serial: serial, request: key)
        if presentation.request(for: key) != nil {
            presentation.selectRequest(key)
        } else {
            // Clear the prior selection when this link is opened. Repeating
            // this during refresh would also clear the user's action warning.
            presentation.selectRequest(nil)
        }
    }

    var canReturnToDisconnectedAccount: Bool {
        if case .disconnected = state { return disconnectedAccount?.removed == true }
        return false
    }

    var canOpenDisconnectedArchive: Bool {
        disconnectedArchive != nil && disconnectedAccount?.removed == true && activeEnrollmentRecord != nil
    }

    /// All confirmed account archives, including the current disconnected
    /// profile until it is superseded by a later removal.
    var availableDisconnectedAccounts: [NativeAccountDeparture] {
        var values = archivedAccountDepartures
        if let disconnectedAccount, disconnectedAccount.removed,
           !values.contains(where: { $0.archiveID == disconnectedAccount.archiveID }) {
            values.append(NativeAccountDeparture(record: disconnectedAccount.record,
                                                 replacement: nil, removed: true))
        }
        return values
    }

    var displayedArchiveDeparture: NativeAccountDeparture? {
        if let selectedArchivedAccount { return selectedArchivedAccount }
        if isShowingDisconnectedArchive { return disconnectedAccount }
        if case .disconnected = state { return disconnectedAccount }
        return nil
    }

    var inboxPresentation: LivePresentationStore? {
        switch state {
        case let .live(presentation): presentation
        case let .disconnected(presentation): presentation
        default: nil
        }
    }

    func showDisconnectedArchive() {
        guard canOpenDisconnectedArchive else { return }
        selectedArchivedAccount = nil
        selectedArchivedPresentation = nil
        isShowingDisconnectedArchive = true
    }

    func showArchivedAccount(_ departure: NativeAccountDeparture) {
        guard departure.removed,
              availableDisconnectedAccounts.contains(where: { $0.archiveID == departure.archiveID }) else { return }
        do {
            let presentation = try makeDisconnectedPresentation(for: departure)
            presentation.enterReadOnlyMode()
            selectedArchivedAccount = departure
            selectedArchivedPresentation = presentation
            isShowingDisconnectedArchive = false
        } catch {
            disconnectMessage = "The saved messages for this account could not be opened. Its original account identity remains on this phone."
        }
    }

    func leaveSelectedArchive() {
        selectedArchivedAccount = nil
        selectedArchivedPresentation = nil
        isShowingDisconnectedArchive = activeEnrollmentRecord == nil && disconnectedArchive != nil
    }

    private func refreshArchivedAccounts() {
        do {
            archivedAccountDepartures = try guidedJoinStore.archivedDepartures()
            unconfirmedAccountDepartures = try guidedJoinStore.unconfirmedDepartures()
            for departure in unconfirmedAccountDepartures {
                disconnectRemovalMessages.removeValue(forKey: departure.archiveID)
            }
            if let current = try guidedJoinStore.departure() {
                disconnectedAccount = current
            } else if case .disconnected = state {
                // Keep the read-only profile visible after a confirmed removal.
            } else {
                disconnectedAccount = nil
            }
            archiveCatalogWarning = nil
        } catch {
            archiveCatalogWarning = "Some saved account removal details could not be loaded. Their saved files have not been deleted."
        }
    }

    func showCurrentAccount() {
        guard activeEnrollmentRecord != nil else { return }
        selectedArchivedAccount = nil
        selectedArchivedPresentation = nil
        isShowingDisconnectedArchive = false
    }

    private func makeDisconnectedPresentation(for departure: NativeAccountDeparture) throws -> LivePresentationStore {
        guard let personID = departure.record.personID else { throw NativeEnrollmentError.invalidIdentity }
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText(departure.record.profileAuthority),
            personID: ExactText(personID),
            deviceID: ExactText(departure.record.deviceID)), transportMode: .relay)
        let persistence = try FileAttentionStatePersistence.applicationSupport()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        return try LivePresentationStore(disconnectedStore: store, context: context,
                                        newMessageAreaDefaults: .standard)
    }

    private var disconnectedStore: LivePresentationStore? {
        if case let .disconnected(presentation) = state { return presentation }
        return nil
    }

    private func disconnectedStatusMessage(for departure: NativeAccountDeparture,
                                           presentation: LivePresentationStore?) -> String {
        let account = departure.record.savedAccountName ?? "this account"
        let server = departure.record.serverDisplayName ?? departure.record.host
        if departure.removed {
            return "This phone is disconnected from \(account) on \(server). Saved messages, drafts and receipts remain read-only on this phone. Other devices and server history are unchanged."
        }
        let pendingAnswers = presentation?.presentation.requests.filter { $0.lifecycleStatus == .pending }.count ?? 0
        let pending = pendingAnswers > 0
            ? " Pending answers are no longer retrying; some may already have reached the server."
            : ""
        return "This phone is disconnected locally from \(account) on \(server). The previous server may still list this phone as registered. Its original identity and saved messages, drafts and receipts are kept for retry.\(pending)"
    }

    func beginEnrollment(host: String,
                         enrollmentPort: Int,
                         relayPort: Int,
                         rootPEM: String,
                         label: String,
                         pkcs12: Data,
                         password: String) async {
        guard !isEnrollmentBusy else { return }
        let generation = UUID()
        activationGeneration = generation
        let attemptID = UUID()
        diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .began,
                           attemptID: attemptID)
        isEnrollmentBusy = true
        defer { isEnrollmentBusy = false }
        enrollmentMessage = nil
        do {
            let settings = try NativeEnrollmentSettings(host: host,
                                                        enrollmentPort: enrollmentPort,
                                                        relayPort: relayPort,
                                                        rootPEM: rootPEM,
                                                        label: label)
            let record = try await enrollment.begin(settings: settings,
                                                    pkcs12: pkcs12,
                                                    password: password,
                                                    onPreparedCleanupFailure: { error in
                                                        self.diagnostics.record(area: .localStore,
                                                            phase: .enrollmentCleanup, transition: .failed,
                                                            error: error, attemptID: attemptID)
                                                    })
            guard activationGeneration == generation else { return }
            isEnrollmentExpired = false
            state = .enrollmentPending(record)
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .completed,
                               attemptID: attemptID)
        } catch NativeEnrollmentError.keyPending {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .unresolved,
                               causeCode: "enrollment_key_pending", attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "This identity already has a request pending on the server. Keep the same identity file and retry after its code expires, or ask the server owner to check it."
            }
        } catch NativeEnrollmentError.keyInUse {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .rejected,
                               causeCode: "enrollment_key_in_use", attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "This identity is already enrolled. Ask the server owner to recover its approved profile; do not replace the device identity."
            }
        } catch NativeEnrollmentError.preparedIdentityMismatch {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .failed,
                               causeCode: "enrollment_identity_mismatch", attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "A prior request used a different identity or server. Reimport the same identity with the same server settings, or ask the server owner for help."
            }
        } catch NativeEnrollmentError.invalidSettings {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .failed,
                               error: NativeEnrollmentError.invalidSettings, attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "Check the server settings, CA certificate and identity file."
            }
        } catch NativeEnrollmentError.invalidIdentity {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .failed,
                               error: NativeEnrollmentError.invalidIdentity, attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "Check the server settings, CA certificate and identity file."
            }
        } catch {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .failed,
                               error: error, attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "Enrollment could not be confirmed. Keep this identity file; retry with the same file after ten minutes or ask the server owner to check it."
            }
        }
    }

    func retryExpiredEnrollment() async {
        guard !isEnrollmentBusy else { return }
        let generation = activationGeneration
        let attemptID = UUID()
        diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .retrying,
                           attemptID: attemptID)
        isEnrollmentBusy = true
        defer { isEnrollmentBusy = false }
        enrollmentMessage = nil
        do {
            let record = try await enrollment.retryExpired()
            guard activationGeneration == generation else { return }
            isEnrollmentExpired = false
            state = .enrollmentPending(record)
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .completed,
                               attemptID: attemptID)
        } catch NativeEnrollmentError.keyPending {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .unresolved,
                               causeCode: "enrollment_key_pending", attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "The server still has a request pending for this identity. Try again after its code expires."
            }
        } catch NativeEnrollmentError.keyInUse {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .rejected,
                               causeCode: "enrollment_key_in_use", attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "This identity is already enrolled. Ask the server owner to recover its approved profile."
            }
        } catch {
            diagnostics.record(area: .enrollment, phase: .enrollmentSubmission, transition: .failed,
                               error: error, attemptID: attemptID)
            if activationGeneration == generation {
                enrollmentMessage = "A new code could not be confirmed. Keep this device identity and try again or ask the server owner."
            }
        }
    }

    func checkEnrollmentApproval() async {
        guard !isEnrollmentBusy else { return }
        let generation = activationGeneration
        let attemptID = UUID()
        diagnostics.record(area: .enrollment, phase: .approvalCheck, transition: .began,
                           attemptID: attemptID)
        isEnrollmentBusy = true
        defer { isEnrollmentBusy = false }
        enrollmentMessage = nil
        var approvalConfirmed = false
        do {
            let record = try await enrollment.checkApproval()
            guard activationGeneration == generation else { return }
            approvalConfirmed = true
            isEnrollmentExpired = false
            try await activate(enrollment.material(from: record))
        } catch NativeEnrollmentError.approvalPending {
            diagnostics.record(area: .enrollment, phase: .approvalCheck, transition: .unresolved,
                               error: NativeEnrollmentError.approvalPending, attemptID: attemptID)
            if activationGeneration == generation { enrollmentMessage = "Waiting for server-owner approval." }
        } catch NativeEnrollmentError.approvalExpired {
            diagnostics.record(area: .enrollment, phase: .approvalCheck, transition: .failed,
                               error: NativeEnrollmentError.approvalExpired, attemptID: attemptID)
            if activationGeneration == generation {
                isEnrollmentExpired = true
                enrollmentMessage = "This approval code expired. Request a new code for the same device identity."
            }
        } catch {
            diagnostics.record(area: .enrollment, phase: .approvalCheck, transition: .failed,
                               error: error, attemptID: attemptID)
            if approvalConfirmed || activationGeneration == generation {
                enrollmentMessage = "Approval could not be verified with the trusted server."
            }
        }
    }

    /// The same C store drives relay apply/outbox and the visible presentation.
    /// No fixture request is registered on this path.
    func activate(_ installation: NativeInstallationMaterial) async throws {
        guard installation.context.transportMode == .relay else {
            throw AttentionStoreError.fixtureOnlyOperation
        }
        let generation = UUID()
        activationGeneration = generation
        notificationNavigation = nil
        notificationSynchronized = false
        notificationRefreshFinished = false
        disconnectMessage = nil
        isEnrollmentExpired = false
        if case let .live(previous) = state { previous.stopObserving() }
        state = .enrollmentRequired
        await NativeRelayLifecycle.shared.deactivate()
        guard activationGeneration == generation else { return }
        let context = installation.context
        let (store, fileStorage) = try await Task.detached(priority: .userInitiated) {
            let persistence = try FileAttentionStatePersistence.applicationSupport()
            let fileStorage = try ConversationFileStorage(identity: context.identity)
            let store = try AttentionDomainStore(context: context, persistence: persistence,
                                                 conversationFileReferences: fileStorage)
            return (store, fileStorage)
        }.value
        guard activationGeneration == generation else { return }
        let activation = try await LivePresentationStore.makeForActivation(
            store: store, context: context, diagnostics: diagnostics,
            newMessageAreaDefaults: .standard, conversationFiles: fileStorage)
        guard activationGeneration == generation else { return }
        let presentation = activation.presentation
        do {
            try await NativeRelayLifecycle.shared.activate(store: store,
                                                           context: installation.context,
                                                           relayURL: installation.relayURL,
                                                           clientIdentity: installation.keychainIdentity,
                                                           trustedRootDER: installation.trustedRootDER,
                                                           diagnostics: diagnostics)
        } catch {
            if activationGeneration != generation { return }
            diagnostics.record(area: .connection, phase: .approvedConnection, transition: .failed,
                               error: error)
            throw error
        }
        guard activationGeneration == generation else { return }
        presentation.notificationProjectionDidChange = { [weak self] in
            Task { await self?.resolveNotificationNavigation() }
        }
        presentation.confirmedRelayRefresh = { [weak self, weak presentation] in
            guard let self, let presentation,
                  case let .live(current) = self.state, current === presentation,
                  self.foregroundConnectProgress?.outcome != .confirmed else { return }
            self.clearForegroundConnectionDetails()
        }
        presentation.startObserving()
        state = .live(presentation)
        isShowingDisconnectedArchive = false
        Task { [weak self] in
            guard let self else { return }
            await notifications.resume { self.activationGeneration == generation }
        }
        // A person can leave the notification permission prompt unanswered.
        // Start the authenticated replay immediately so foreground requests
        // still appear; the later token callback schedules its own pass.
        Task { await refreshLive() }
    }

    private func chooseNotifications(_ enabled: Bool) async {
        guard case let .live(presentation) = state else { return }
        let record: NativeEnrollmentRecord?
        do { record = try enrollment.load() }
        catch {
            diagnostics.record(area: .localStore, phase: .projectionRefresh,
                               transition: NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            return
        }
        guard let record, record.isApproved else { return }
        let epoch = activationGeneration
        diagnostics.record(area: .notifications, phase: .pushRegistration, transition: .began)
        do {
            try enrollment.markNotificationExplanationSeen(for: record.deviceID)
            let allowed = try await notifications.choose(enabled) { self.activationGeneration == epoch }
            guard activationGeneration == epoch else { return }
            if allowed {
                presentation.notificationWarning = nil
                diagnostics.record(area: .notifications, phase: .pushRegistration, transition: .completed)
            } else {
                presentation.notificationWarning = "Notifications are off. You will see new requests when you open Harklight. Turn them on in Settings."
                diagnostics.record(area: .notifications, phase: .pushRegistration, transition: .unresolved,
                                   causeCode: "notification_permission_not_granted")
            }
        } catch {
            diagnostics.record(area: .notifications, phase: .pushRegistration,
                               transition: NativeDiagnosticCauseCode.failureTransition(for: error),
                               error: error)
            if activationGeneration == epoch {
                presentation.notificationWarning = "Notification permission could not be checked. Foreground requests still work."
            }
        }
    }

    func deactivate() async {
        activationGeneration = UUID()
        foregroundActivationPushCheckPending = false
        isEnrollmentExpired = false
        if case let .live(previous) = state { previous.stopObserving() }
        state = .enrollmentRequired
        await NativeRelayLifecycle.shared.deactivate()
        clearForegroundConnectionDetails()
    }

    private func clearForegroundConnectionDetails() {
        foregroundConnectProgress = nil
        foregroundConnectDiagnostic = nil
        dismissedForegroundConnectFailure = nil
    }

    var foregroundConnectFailureKey: NativeForegroundConnectFailureKey? {
        guard let activeEnrollmentRecord, let foregroundConnectProgress else { return nil }
        return NativeForegroundConnectFailureKey(record: activeEnrollmentRecord,
                                                  progress: foregroundConnectProgress)
    }

    func shouldPresentForegroundConnectFailure(_ key: NativeForegroundConnectFailureKey) -> Bool {
        dismissedForegroundConnectFailure != key
    }

    func dismissForegroundConnectFailure(_ key: NativeForegroundConnectFailureKey) {
        guard foregroundConnectFailureKey == key else { return }
        dismissedForegroundConnectFailure = key
    }

    func reopenForegroundConnectFailure(_ key: NativeForegroundConnectFailureKey) {
        guard foregroundConnectFailureKey == key,
              dismissedForegroundConnectFailure == key else { return }
        dismissedForegroundConnectFailure = nil
    }

    func recordForegroundConnectProgress(_ progress: NativeForegroundConnectProgress,
                                         operationSnapshot: NativeForegroundOperationSnapshot) {
        foregroundConnectProgress = progress
        foregroundConnectDiagnostic = NativeForegroundConnectDiagnostic(
            progress: progress, operationSnapshot: operationSnapshot)
    }

    func refreshForForegroundActivation() async {
        foregroundActivationPushCheckPending = true
        await refreshLive()
    }

    func refreshLive() async {
        guard case let .live(presentation) = state, !presentation.isLocalExample else { return }
        presentation.beginRefresh()
        defer { presentation.endRefresh() }
        let checkBlockedPush = takeForegroundActivationPushCheck()
        notificationSynchronized = false
        notificationRefreshFinished = false
        let result = await refreshOperation(checkBlockedPush)
        guard case let .live(current) = state, current === presentation else { return }
        presentation.applyRefreshResult(result)
        notificationRefreshFinished = true
        notificationSynchronized = result.relayConfirmed && result.confirmedContext == presentation.notificationContext
        await resolveNotificationNavigation()
        await resolveMessageDeepLink(synchronized: notificationSynchronized)
    }

    private func resolveMessageDeepLink(synchronized: Bool) async {
        guard let deepLink = pendingMessageDeepLink,
              case let .live(presentation) = state,
              !presentation.isReadOnly, !presentation.isLocalExample else { return }
        let key = messageKey(for: deepLink, in: presentation)
        if presentation.isRetracted(key) {
            navigateToMessage(key, in: presentation)
            pendingMessageDeepLink = nil
            notificationNavigationMessage = "The sender retracted this message."
        } else if presentation.request(for: key) != nil {
            navigateToMessage(key, in: presentation)
            pendingMessageDeepLink = nil
            notificationNavigationMessage = nil
        } else {
            if notificationNavigation?.request != key {
                navigateToMessage(key, in: presentation)
            }
            var pageAvailability = presentation.inboxPageAvailability()
            while synchronized, pageAvailability == .more {
                guard pendingMessageDeepLink == deepLink else { return }
                let revisionBeforePage = presentation.presentation.revision
                let fetched: Bool
                if let fetchInboxPageOperation {
                    fetched = await fetchInboxPageOperation(presentation)
                } else {
                    fetched = await presentation.fetchNextInboxPage()
                }
                guard pendingMessageDeepLink == deepLink,
                      case let .live(current) = state, current === presentation else { return }
                if presentation.isRetracted(key) {
                    navigateToMessage(key, in: presentation)
                    pendingMessageDeepLink = nil
                    notificationNavigationMessage = "The sender retracted this message."
                    return
                }
                if presentation.request(for: key) != nil {
                    navigateToMessage(key, in: presentation)
                    pendingMessageDeepLink = nil
                    notificationNavigationMessage = nil
                    return
                }
                pageAvailability = presentation.inboxPageAvailability()
                guard fetched, presentation.presentation.revision != revisionBeforePage else { break }
            }
            let confirmed = synchronized && notificationSynchronized
            notificationNavigationMessage = confirmed && pageAvailability == .exhausted
                ? "This message was never sent to this Harklight inbox."
                : "This message hasn't arrived yet. Harklight will keep checking while it's open."
        }
    }

    private func takeForegroundActivationPushCheck() -> Bool {
        let shouldCheck = foregroundActivationPushCheckPending
        foregroundActivationPushCheckPending = false
        return shouldCheck
    }

    func openForegroundChatIndicator(id: UUID) async {
        guard let indicator = notificationRouter.consumeForegroundChatIndicator(id: id) else { return }
        notificationRouter.receive(indicator.payload, opened: true)
        await handleNotification()
    }

    func notificationChatRouteWasOpened(serial: UInt64) {
        guard let route = notificationNavigation, route.serial == serial, route.opensChat,
              let request = route.request else { return }
        notificationNavigation = NativeInboxNavigation(serial: route.serial, request: request)
    }

    func handleNotification() async {
        guard didFinishRestoring, let intent = notificationRouter.intent,
              handledNotificationSerial != intent.serial else { return }
        handledNotificationSerial = intent.serial
        pendingMessageDeepLink = nil
        notificationSynchronized = false
        // Leave any archive surface; never activate an archive from a locator.
        selectedArchivedAccount = nil
        selectedArchivedPresentation = nil
        isShowingDisconnectedArchive = false
        notificationNavigation = NativeInboxNavigation(serial: intent.serial, request: nil)
        notificationNavigationMessage = intent.locator == nil ? nil : "Checking this notification."
        if case let .live(presentation) = state, !presentation.isReadOnly, !presentation.isLocalExample {
            presentation.selectRequest(nil)
            if let record = try? enrollment.load(),
               intent.locator?.profile(in: [record]) != nil {
                _ = notificationRouter.resolve(records: [record], context: presentation.notificationContext,
                    requests: [], synchronized: false)
            }
            presentation.notificationProjectionDidChange = { [weak self] in
                Task { await self?.resolveNotificationNavigation() }
            }
            await refreshLive()
        } else {
            notificationRouter.fallback()
            notificationNavigationMessage = nil
        }
    }

    func resolveNotificationNavigation() async {
        guard notificationRefreshFinished, let intent = notificationRouter.intent,
              handledNotificationSerial == intent.serial,
              case let .live(presentation) = state, !presentation.isReadOnly, !presentation.isLocalExample,
              resolvingNotificationSerial != intent.serial else { return }
        resolvingNotificationSerial = intent.serial
        defer {
            if resolvingNotificationSerial == intent.serial {
                resolvingNotificationSerial = nil
            }
        }
        let record: NativeEnrollmentRecord?
        do { record = try enrollment.load() }
        catch {
            notificationNavigationMessage = "Could not check this notification's account."
            return
        }
        let records = record.map { [$0] } ?? []
        if let key = notificationRouter.resolve(records: records,
            context: presentation.notificationContext, requests: presentation.presentation.requests,
            synchronized: notificationSynchronized) {
            presentation.selectRequest(key)
            let opensChat = notificationRouter.intent?.locator?.target == "chat"
            notificationNavigation = NativeInboxNavigation(serial: intent.serial, request: key,
                                                            opensChat: opensChat)
            notificationNavigationMessage = nil
            notificationRouter.consumed()
            return
        }
        guard let locator = notificationRouter.intent?.locator else {
            presentation.selectRequest(nil)
            notificationNavigationMessage = nil
            notificationRouter.consumed()
            return
        }

        presentation.selectRequest(nil)
        guard notificationSynchronized else {
            notificationNavigationMessage = "Could not verify notification. Checking again while open."
            return
        }

        var pageAvailability = presentation.inboxPageAvailability()
        while pageAvailability == .more {
            guard notificationRouter.intent?.serial == intent.serial,
                  notificationRouter.intent?.locator != nil,
                  notificationSynchronized, notificationRefreshFinished,
                  case let .live(current) = state, current === presentation else { return }
            // A present identity with a different acceptance sequence is stale;
            // older pages cannot make it current.
            if presentation.presentation.requests.contains(where: { $0.key == locator.request }) {
                break
            }

            let revisionBeforePage = presentation.presentation.revision
            let fetched: Bool
            if let fetchInboxPageOperation {
                fetched = await fetchInboxPageOperation(presentation)
            } else {
                fetched = await presentation.fetchNextInboxPage()
            }
            guard notificationRouter.intent?.serial == intent.serial,
                  notificationRouter.intent?.locator != nil,
                  notificationSynchronized, notificationRefreshFinished,
                  case let .live(current) = state, current === presentation else { return }

            if let key = notificationRouter.resolve(records: records,
                context: presentation.notificationContext,
                requests: presentation.presentation.requests, synchronized: true) {
                presentation.selectRequest(key)
                let opensChat = notificationRouter.intent?.locator?.target == "chat"
                notificationNavigation = NativeInboxNavigation(serial: intent.serial, request: key,
                                                                opensChat: opensChat)
                notificationNavigationMessage = nil
                notificationRouter.consumed()
                return
            }
            guard notificationRouter.intent?.locator != nil else {
                presentation.selectRequest(nil)
                notificationNavigationMessage = nil
                notificationRouter.consumed()
                return
            }
            if presentation.presentation.requests.contains(where: { $0.key == locator.request }) {
                break
            }

            pageAvailability = presentation.inboxPageAvailability()
            guard fetched, presentation.presentation.revision != revisionBeforePage else { break }
        }
        guard notificationRouter.intent?.serial == intent.serial,
              notificationRouter.intent?.locator != nil else { return }
        notificationNavigationMessage = "This notification's message has not loaded yet."
    }

    func retryForegroundConnection() async {
        guard case .live = state else { return }
        await guidedJoin.retryApprovedConnection()
    }
}

/// C's admitted presentation is the only live view feed. Its revision stream
/// reflects replay visibility and durable edits without a second H journal.
struct StaleAnswerDialog: Identifiable, Equatable, Sendable {
    var id: UUID { operationID }
    let operationID: UUID
    let requestKey: RequestKey
    let submittedRevision: UInt64
    let currentRevision: UInt64
    let title: String
    let body: String

    var latestContent: String { body.isEmpty ? title : "\(title)\n\n\(body)" }

    var message: String {
        "The message changed after you saw version \(submittedRevision). The new version (\(currentRevision)) is shown here:\n\n\(latestContent)\n\nReview it and answer again."
    }

    var localizedMessage: LocalizedStringResource {
        "The message changed after you saw version \(submittedRevision). The new version (\(currentRevision)) is shown here:\n\n\(latestContent)\n\nReview it and answer again."
    }
}

private struct NoReplyRoutingState: Sendable {
    let requestRevision: UInt64
    let isNoReply: Bool
    let route: NativeDiagnosticNoReplyRoute?
}

private struct PreparedNoReplyRoutingChange: Sendable {
    let request: RequestKey
    let revision: UInt64
    let operationID: UUID?
    let route: NativeDiagnosticNoReplyRoute
}

private struct PreparedLivePresentationInitialState: Sendable {
    let port: AttentionDomainPort
    let snapshot: PresentationSnapshot
    let conversationThreads: [RequestKey: ConversationThread]
    let conversationFiles: ConversationFileStorage?
    let messageLedger: NewMessageAreaLedger
    let replyLedger: ReplyItemLedger
    let preparedMessageArea: PreparedNewMessageAreaReconciliation
    let preparedReplyArea: PreparedReplyItemAreaReconciliation
    let failedResponseWarnings: [RequestKey: LivePresentationStore.FailedResponseWarning]
    let staleAnswerDialog: StaleAnswerDialog?
}

private struct VersionedPreparedNewMessageAreaReconciliation: Sendable {
    let value: PreparedNewMessageAreaReconciliation
    let generation: UInt64
}

private struct VersionedPreparedReplyItemAreaReconciliation: Sendable {
    let value: PreparedReplyItemAreaReconciliation
    let generation: UInt64
}

private struct PreparedLivePresentationUpdate: Sendable {
    let conversationThreads: [RequestKey: ConversationThread]
    let messageArea: VersionedPreparedNewMessageAreaReconciliation?
    let replyItemArea: VersionedPreparedReplyItemAreaReconciliation?
    let failedResponseWarnings: [RequestKey: LivePresentationStore.FailedResponseWarning]
    let warningGeneration: UInt64
    let noReplyRoutingChanges: [PreparedNoReplyRoutingChange]
    let staleAnswerDialog: StaleAnswerDialog?
    let requestKeys: Set<RequestKey>
    let firstRequestKey: RequestKey?
    let actionErrorRequest: RequestKey?
    let shouldClearActionError: Bool
}

@MainActor
@Observable
final class LivePresentationStore {
    struct FailedResponseWarning: Equatable, Sendable {
        let requestRevision: UInt64
        let failedOperationID: UUID?
        let answerKind: SubmissionAnswerKind
        let submittedInputs: [TypedInputRecord]
        let answerDraft: RequestDraft?
        let detail: LocalizedStringResource
        var retryOperationID: UUID?

        var summary: LocalizedStringResource {
            answerKind == .noComment
                ? "Your No comment response was not delivered."
                : "Your response was not delivered."
        }

        var canRetry: Bool {
            failedOperationID != nil && answerDraft != nil
        }
    }

    struct SkippedMessageWarning: Equatable {
        let eventID: UUID
        let requestRevision: UInt64
        let conversationSequence: UInt64
    }

    enum InboxPageAvailability: Equatable {
        case more
        case exhausted
        case unknown
    }

    private struct DraftBufferKey: Hashable {
        let request: RequestKey
        let revision: UInt64
    }

    private struct ConversationReadKey: Hashable, Sendable {
        let request: RequestKey
        let turnID: ExactText
    }

    private(set) var conversationThreads: [RequestKey: ConversationThread]
    private(set) var priorityLevelsState = PriorityLevelsStoreState.empty
    private(set) var priorityLevelsLocalError: LocalizedStringResource?
    private(set) var priorityLevelsRelayConfirmed = false
    @ObservationIgnored private var pendingConversationTextByBinding: [ConversationBinding: String] = [:]
    private(set) var conversationError: String?
    @ObservationIgnored private let conversationAvailability: NativeConversationAvailability
    var conversationAvailabilityState: NativeConversationAvailability.State {
        if isLocalExample { return .available }
        guard permitsDelivery, !isReadOnly else { return .unconfirmed }
        return conversationAvailability.state(for: profileContext)
    }
    var canCheckConversationAvailability: Bool { permitsDelivery && !isReadOnly }
    var conversationUnavailableMessage: String? {
        guard permitsDelivery, !isReadOnly else { return nil }
        return conversationAvailability.message(for: profileContext)
    }
    private(set) var isSendingDiscussion = false
    private(set) var retryingCleanupRequests: Set<RequestKey> = []
    private(set) var presentation: PresentationSnapshot
    private(set) var retractionVisibilityTime = Date()
    private(set) var selectedRequestKey: RequestKey?
    private var activeRefreshCount = 0
    var isRefreshing: Bool { activeRefreshCount > 0 }
    var staleAnswerDialog: StaleAnswerDialog?
    private(set) var observationError: String?
    private(set) var actionError: String?
    private var actionErrorRequest: RequestKey?
    var notificationWarning: String?
    private(set) var pushRegistrationWarning: String?
    var connectionWarning: String?
    private(set) var failedResponseWarnings: [RequestKey: FailedResponseWarning] = [:]

    /// Present while any send from this device remains unresolved; nil once
    /// every such send resolves, which also clears the inbox warning indicator.
    var unresolvedSendWarning: String? {
        Self.unresolvedSendWarning(unresolvedSendCount: presentation.requests.filter {
            Self.sendIsUnresolved(lifecycleStatus: $0.lifecycleStatus,
                                  ownOutcome: $0.receiptFacts?.ownOutcome,
                                  answeredFromThisDevice: $0.intentReceipt != nil)
        }.count)
    }

    /// A send is unresolved when this device answered, the request closed,
    /// and the server never confirmed a result for the answer. An in-flight
    /// send (open or pending request) is not unresolved: it carries its own
    /// status line and may still resolve normally. A server-resolved request
    /// (answered or no comment) has its result.
    static func sendIsUnresolved(lifecycleStatus: AppLifecycleStatus,
                                 ownOutcome: OwnOutcome?,
                                 answeredFromThisDevice: Bool) -> Bool {
        guard answeredFromThisDevice, ownOutcome == .unconfirmed else { return false }
        return switch lifecycleStatus {
        case .cleared, .expired, .superseded: true
        case .open, .pending, .answered, .noComment: false
        }
    }

    static func unresolvedSendWarning(unresolvedSendCount: Int) -> String? {
        switch unresolvedSendCount {
        case 0: nil
        case 1: "A request closed without a confirmed result for your answer. Your answer stays saved on this device."
        default: "\(unresolvedSendCount) requests closed without a confirmed result for your answers. Your answers stay saved on this device."
        }
    }

    @ObservationIgnored private let port: AttentionDomainPort
    @ObservationIgnored private let attentionStore: AttentionDomainStore
    private let permitsDelivery: Bool
    @ObservationIgnored private let conversationFiles: ConversationFileStorage?
    @ObservationIgnored private let profileContext: ProfileContext
    var notificationContext: ProfileContext { profileContext }
    @ObservationIgnored var notificationProjectionDidChange: (() -> Void)?
    @ObservationIgnored var confirmedRelayRefresh: (() -> Void)?
    private(set) var isReadOnly: Bool
    @ObservationIgnored private let diagnostics: NativeClientDiagnosticJournal?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var locallyReconciledConversationReadRevisions = Set<UInt64>()
    @ObservationIgnored private var failedResponseWarningGeneration: UInt64 = 0
    @ObservationIgnored private var pendingConversationReadUpdates = Set<ConversationReadKey>()
    @ObservationIgnored private var conversationProjectionRevision: UInt64?
    @ObservationIgnored private let messageAreaStore: NewMessageAreaStore?
    @ObservationIgnored private let replyAreaStore: ReplyItemAreaStore?
    @ObservationIgnored private var pendingDrafts: [DraftBufferKey: RequestDraft] = [:]
    @ObservationIgnored private var pendingDraftSaveTasks: [DraftBufferKey: Task<Void, Never>] = [:]
    // Reply edits remain local until submission, but must outlive a detail view
    // recreated by ordinary navigation in this app session.
    @ObservationIgnored private var replyEditorSessions: [RequestKey: ReplyEditorDraftSession] = [:]
    // Clearing a retracted row is list state on this device only: no frame is
    // sent and the retracted record stays intact in the durable store.
    private(set) var clearedRetractions: Set<RequestKey> = []
#if DEBUG
    @ObservationIgnored private var pendingRetractionExpiryAdvance: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var retractionExpiryAdvanceRequested = false
#endif
    @ObservationIgnored private let clearedRetractionDefaults: UserDefaults
    private static let clearedRetractionsDefaultsKey = "harklight.cleared-retracted-requests"
    private static let retractedRowVisibilityDuration: TimeInterval = 24 * 60 * 60
    @ObservationIgnored private var presentedStaleAnswerOperationIDs = Set<UUID>()

    convenience init(store: AttentionDomainStore, context: ProfileContext,
                     conversationAvailability: NativeConversationAvailability = NativeRelayLifecycle.shared.conversationAvailability,
                     diagnostics: NativeClientDiagnosticJournal? = nil,
                     clearedRetractionDefaults: UserDefaults = .standard,
                     newMessageAreaDefaults: UserDefaults? = nil) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: true, diagnostics: diagnostics,
                      conversationAvailability: conversationAvailability,
                      clearedRetractionDefaults: clearedRetractionDefaults,
                      newMessageAreaDefaults: newMessageAreaDefaults)
    }

    /// Uses the ordinary projection/edit path, but cannot mint an intent or retry transport.
    convenience init(localFixtureStore store: AttentionDomainStore, context: ProfileContext,
                     newMessageAreaDefaults: UserDefaults? = nil) throws {
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false, isReadOnly: false,
                      diagnostics: nil, newMessageAreaDefaults: newMessageAreaDefaults)
    }

    convenience init(disconnectedStore store: AttentionDomainStore, context: ProfileContext,
                     newMessageAreaDefaults: UserDefaults? = nil) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false, isReadOnly: true,
                      diagnostics: nil, newMessageAreaDefaults: newMessageAreaDefaults)
    }

    static func makeForActivation(
        store: AttentionDomainStore,
        context: ProfileContext,
        conversationAvailability: NativeConversationAvailability = NativeRelayLifecycle.shared.conversationAvailability,
        diagnostics: NativeClientDiagnosticJournal? = nil,
        clearedRetractionDefaults: UserDefaults = .standard,
        newMessageAreaDefaults: UserDefaults? = nil,
        conversationFiles suppliedConversationFiles: ConversationFileStorage? = nil
    ) async throws -> (presentation: LivePresentationStore,
                        mainActorWorkMilliseconds: Double,
                        activationPreparationMilliseconds: Double) {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        let activationStartedAt = DispatchTime.now().uptimeNanoseconds
        var mainActorWorkNanoseconds: UInt64 = 0
        var mainActorSegmentStartedAt = DispatchTime.now().uptimeNanoseconds
        let messageLedgerData = newMessageAreaDefaults?.data(forKey: NewMessageAreaStore.defaultsKey)
        let replyLedgerData = newMessageAreaDefaults?.data(forKey: ReplyItemAreaStore.defaultsKey)
        let diagnosticEvents = diagnostics?.events ?? []
        mainActorWorkNanoseconds += DispatchTime.now().uptimeNanoseconds - mainActorSegmentStartedAt
        let initial = try await Task.detached(priority: .userInitiated) {
            let port = AttentionDomainPort(store: store)
            let snapshot = try port.observe(context: port.context)
            let conversationThreads = try port.conversations(context: port.context).threads
            let attentionSnapshot = try store.snapshot(context: context)
            let messageLedger = messageLedgerData.flatMap {
                try? JSONDecoder().decode(NewMessageAreaLedger.self, from: $0)
            } ?? NewMessageAreaLedger()
            let replyLedger = replyLedgerData.flatMap {
                try? JSONDecoder().decode(ReplyItemLedger.self, from: $0)
            } ?? ReplyItemLedger()
            let messages = Self.newMessageObservations(for: snapshot.requests)
            let revisions = Dictionary(uniqueKeysWithValues: snapshot.requests.map {
                ($0.key, $0.requestRevision)
            })
            let replyObservations = Self.replyObservations(
                in: conversationThreads,
                account: context.identity.personID,
                ledger: replyLedger)
            let now = Date()
            let preparedMessageArea = NewMessageAreaStore.prepareReconciliation(
                ledger: messageLedger, messages: messages, revisions: revisions,
                accountScopes: [context.identity.personID], now: now)
            let preparedReplyArea = ReplyItemAreaStore.prepareReconciliation(
                ledger: replyLedger, observations: replyObservations.observations,
                accountScopes: [context.identity.personID],
                parentScope: replyObservations.parentScope, now: now)
            let failedResponseWarnings = Self.prepareFailedResponseWarnings(
                previous: [:], requests: snapshot.requests, attentionSnapshot: attentionSnapshot,
                diagnosticEvents: diagnosticEvents)
            let staleAnswerDialog = Self.staleAnswerDialog(in: snapshot, presentedIDs: [])
            let conversationFiles = try suppliedConversationFiles ??
                ConversationFileStorage(identity: context.identity)
            return PreparedLivePresentationInitialState(
                port: port, snapshot: snapshot, conversationThreads: conversationThreads,
                conversationFiles: conversationFiles,
                messageLedger: messageLedger, replyLedger: replyLedger,
                preparedMessageArea: preparedMessageArea, preparedReplyArea: preparedReplyArea,
                failedResponseWarnings: failedResponseWarnings,
                staleAnswerDialog: staleAnswerDialog)
        }.value

        mainActorSegmentStartedAt = DispatchTime.now().uptimeNanoseconds
        let presentation = try LivePresentationStore(
            store: store, context: context, permitsDelivery: true,
            diagnostics: diagnostics, conversationAvailability: conversationAvailability,
            clearedRetractionDefaults: clearedRetractionDefaults,
            newMessageAreaDefaults: newMessageAreaDefaults, preparedInitialState: initial)
        mainActorWorkNanoseconds += DispatchTime.now().uptimeNanoseconds - mainActorSegmentStartedAt
        let activationPreparationNanoseconds = DispatchTime.now().uptimeNanoseconds - activationStartedAt
        return (presentation, Double(mainActorWorkNanoseconds) / 1_000_000,
                Double(activationPreparationNanoseconds) / 1_000_000)
    }

    private init(store: AttentionDomainStore, context: ProfileContext,
                 permitsDelivery: Bool, isReadOnly: Bool = false,
                 diagnostics: NativeClientDiagnosticJournal? = nil,
                 conversationAvailability: NativeConversationAvailability = NativeRelayLifecycle.shared.conversationAvailability,
                 clearedRetractionDefaults: UserDefaults = .standard,
                 newMessageAreaDefaults: UserDefaults? = nil,
                 preparedInitialState: PreparedLivePresentationInitialState? = nil) throws {
        self.clearedRetractionDefaults = clearedRetractionDefaults
        let areaStore = newMessageAreaDefaults.map {
            NewMessageAreaStore(defaults: $0, initialLedger: preparedInitialState?.messageLedger)
        }
        self.messageAreaStore = areaStore
        let replyStore = newMessageAreaDefaults.map {
            ReplyItemAreaStore(defaults: $0, initialLedger: preparedInitialState?.replyLedger)
        }
        self.replyAreaStore = replyStore
        self.conversationAvailability = conversationAvailability
        self.permitsDelivery = permitsDelivery
        self.profileContext = context
        self.isReadOnly = isReadOnly
        self.diagnostics = diagnostics
        if let preparedInitialState {
            self.failedResponseWarnings = preparedInitialState.failedResponseWarnings
            self.staleAnswerDialog = preparedInitialState.staleAnswerDialog
        }
        let port = preparedInitialState?.port ?? AttentionDomainPort(store: store)
        let snapshot: PresentationSnapshot
        let conversationThreads: [RequestKey: ConversationThread]
        let conversationFiles: ConversationFileStorage?
        if let preparedInitialState {
            snapshot = preparedInitialState.snapshot
            conversationThreads = preparedInitialState.conversationThreads
            conversationFiles = preparedInitialState.conversationFiles
        } else {
            snapshot = try port.observe(context: port.context)
            conversationThreads = try port.conversations(context: port.context).threads
            conversationFiles = context.transportMode == .relay
                ? try ConversationFileStorage(identity: context.identity) : nil
        }
        self.port = port
        self.attentionStore = store
        self.priorityLevelsState = try store.snapshot(context: context).priorityLevels
        self.priorityLevelsRelayConfirmed = NativeRelayLifecycle.shared.hasConfirmedPriorityLevelsRelay(for: context)
        self.presentation = snapshot
        self.conversationThreads = conversationThreads
        self.conversationProjectionRevision = snapshot.revision
        self.conversationFiles = conversationFiles
        self.selectedRequestKey = snapshot.requests.first?.key
        if let preparedInitialState {
            _ = areaStore?.applyPreparedReconciliation(preparedInitialState.preparedMessageArea,
                                                        basedOn: 0)
            _ = replyStore?.applyPreparedReconciliation(preparedInitialState.preparedReplyArea,
                                                        basedOn: 0)
        } else {
            reconcileNewMessageArea(snapshot.requests, using: areaStore)
            reconcileReplyItemArea(using: replyStore)
        }
        if let data = clearedRetractionDefaults.data(forKey: Self.clearedRetractionsDefaultsKey),
           let cleared = try? JSONDecoder().decode(Set<RequestKey>.self, from: data) {
            clearedRetractions = cleared
        }
        if preparedInitialState == nil {
            refreshFailedResponseWarnings(for: snapshot.requests)
            presentStaleAnswerIfAvailable(in: snapshot)
        }
    }

    /// Read-only real account archives are offline relay data, not fictional
    /// local examples. Delivery permission and data provenance are separate.
    var isLocalExample: Bool { profileContext.transportMode == .fixture }

    var priorityLevelsDraftRows: [PriorityLevelDraftRow] {
        priorityLevelsState.displayedRows
    }

    var priorityLevelsValidationMessage: LocalizedStringResource? {
        PriorityLevelsTableValidation.message(for: priorityLevelsDraftRows)
    }

    var canSavePriorityLevels: Bool {
        guard permitsDelivery, !isReadOnly, priorityLevelsRelayConfirmed,
              NativeRelayLifecycle.shared.hasConfirmedPriorityLevelsRelay(for: profileContext),
              priorityLevelsState.pendingSave == nil,
              priorityLevelsState.failureReason != "unknown_type",
              priorityLevelsState.failureReason != "forbidden" else { return false }
        return PriorityLevelsTableValidation.levels(from: priorityLevelsDraftRows) != nil
    }

    func updatePriorityLevelsDraft(_ rows: [PriorityLevelDraftRow]) {
        guard !isReadOnly, profileContext.transportMode == .relay else { return }
        do {
            try attentionStore.savePriorityLevelsDraft(rows, context: profileContext)
            priorityLevelsLocalError = nil
            refreshPriorityLevelsProjection()
        } catch {
            priorityLevelsLocalError = "This edit could not be saved on this phone. Your previous draft is unchanged."
        }
    }

    func openPriorityLevelsEditor() async {
        guard permitsDelivery, !isReadOnly, profileContext.transportMode == .relay else { return }
        do {
            try attentionStore.markPriorityLevelsEditorOpened(context: profileContext)
            priorityLevelsLocalError = nil
            refreshPriorityLevelsProjection()
        } catch {
            priorityLevelsLocalError = "Priority levels could not be prepared on this phone."
            return
        }
        refreshPriorityLevelsRelayStatus()
        await NativeRelayLifecycle.shared.refreshPriorityLevels(expected: profileContext)
        refreshPriorityLevelsRelayStatus()
        refreshPriorityLevelsProjection()
    }

    func savePriorityLevels() async {
        refreshPriorityLevelsRelayStatus()
        guard canSavePriorityLevels,
              let table = PriorityLevelsTableValidation.levels(from: priorityLevelsDraftRows) else { return }
        do {
            _ = try attentionStore.beginPriorityLevelsSave(table, context: profileContext)
            priorityLevelsLocalError = nil
            refreshPriorityLevelsProjection()
            await NativeRelayLifecycle.shared.sendPendingPriorityLevelsSave(expected: profileContext)
            refreshPriorityLevelsProjection()
        } catch {
            priorityLevelsLocalError = "This save could not be started. Your local edits are unchanged."
            refreshPriorityLevelsProjection()
        }
    }

    func refreshPriorityLevelsRelayStatus() {
        priorityLevelsRelayConfirmed = permitsDelivery && !isReadOnly &&
            NativeRelayLifecycle.shared.hasConfirmedPriorityLevelsRelay(for: profileContext)
    }

    func refreshPriorityLevelsProjection() {
        refreshPriorityLevelsRelayStatus()
        do {
            priorityLevelsState = try attentionStore.snapshot(context: profileContext).priorityLevels
        } catch {
            priorityLevelsLocalError = "Priority levels could not be read from this phone."
        }
    }

    func hasAcceptedUpdate(for key: RequestKey) -> Bool {
        conversationThreads[key]?.acceptedUpdates.isEmpty == false
    }
    func isRetracted(_ key: RequestKey) -> Bool {
        if conversationThreads[key]?.isRetracted == true { return true }
        if let outcome = request(for: key)?.intentReceipt?.relayOutcome,
           case .refusedByRetraction = outcome { return true }
        return false
    }

    func retractionDate(_ key: RequestKey) -> Date? {
        let thread = conversationThreads[key]
        let timestamp = thread?.retraction?.retractedAtMilliseconds ?? thread?.reportedRetractedAtMilliseconds ?? {
            guard let outcome = request(for: key)?.intentReceipt?.relayOutcome,
                  case let .refusedByRetraction(retractedAtMilliseconds) = outcome else { return nil }
            return retractedAtMilliseconds
        }()
        guard let timestamp else { return nil }
        return Date(timeIntervalSince1970: Double(timestamp) / 1_000)
    }

    private func retractionDate(_ request: PresentedRequest) -> Date? {
        let thread = conversationThreads[request.key]
        let timestamp = thread?.retraction?.retractedAtMilliseconds ?? thread?.reportedRetractedAtMilliseconds ?? {
            guard let outcome = request.intentReceipt?.relayOutcome,
                  case let .refusedByRetraction(retractedAtMilliseconds) = outcome else { return nil }
            return retractedAtMilliseconds
        }()
        guard let timestamp else { return nil }
        return Date(timeIntervalSince1970: Double(timestamp) / 1_000)
    }

    static func retractionExpiryDate(for retractionDate: Date?) -> Date? {
        retractionDate?.addingTimeInterval(retractedRowVisibilityDuration)
    }

    static func isRetractionExpired(retractionDate: Date?, at now: Date) -> Bool {
        guard let expiry = retractionExpiryDate(for: retractionDate) else { return false }
        return now >= expiry
    }

    func refreshRetractionVisibility(at now: Date = Date()) {
        retractionVisibilityTime = now
    }

    func waitForNextRetractionExpiry() async {
        guard let expiry = nextRetractionExpiry else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-server-retraction") {
            await waitForRetractionExpiryAdvance()
            guard !Task.isCancelled else { return }
            refreshRetractionVisibility(at: expiry)
            return
        }
#endif
        while !Task.isCancelled {
            let remaining = expiry.timeIntervalSince(retractionVisibilityTime)
            guard remaining > 0 else { break }
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            refreshRetractionVisibility()
        }
        guard !Task.isCancelled else { return }
        refreshRetractionVisibility()
    }

#if DEBUG
    func advanceRetractionExpiryForTesting() {
        if let continuation = pendingRetractionExpiryAdvance {
            pendingRetractionExpiryAdvance = nil
            continuation.resume()
        } else {
            retractionExpiryAdvanceRequested = true
        }
    }

    private func waitForRetractionExpiryAdvance() async {
        if retractionExpiryAdvanceRequested {
            retractionExpiryAdvanceRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            pendingRetractionExpiryAdvance = continuation
        }
    }
#endif

    func retractionLabel(_ key: RequestKey) -> String {
        guard let date = retractionDate(key) else { return "Retracted" }
        return "Retracted · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    func isRetractionCleared(_ key: RequestKey) -> Bool {
        clearedRetractions.contains(key)
    }

    func clearRetracted(_ key: RequestKey) {
        guard isRetracted(key), !clearedRetractions.contains(key) else { return }
        clearedRetractions.insert(key)
        if let data = try? JSONEncoder().encode(clearedRetractions) {
            clearedRetractionDefaults.set(data, forKey: Self.clearedRetractionsDefaultsKey)
        }
    }

    func conversation(for key: RequestKey) -> ConversationThread? { conversationThreads[key] }

    func hasUnreadAgentReply(_ key: RequestKey) -> Bool {
        conversationThreads[key]?.hasUnreadAgentReply == true
    }

    private func listChatUnread(_ key: RequestKey) -> Bool? {
        guard let thread = conversationThreads[key],
              thread.turns.contains(where: { turn in
                  switch turn.kind {
                  case .none, .some(.discussion), .some(.reply):
                      return true // Older chat turns have no kind.
                  case .some(.revision), .some(.result), .some(.terminal):
                      return false
                  }
              }) else { return nil }
        return thread.hasUnreadAgentReply
    }

    func markConversationRead(_ key: RequestKey) {
        guard !isReadOnly, let latest = conversationThreads[key]?.latestAgentReply else { return }
        markConversationRead(key, through: latest.id)
    }

    /// Chat calls this when the reply crosses the visible threshold. The durable
    /// position stops at that reply, so later offscreen replies stay unread.
    func markConversationRead(_ key: RequestKey, through turnID: ExactText) {
        guard !isReadOnly,
              conversationThreads[key]?.turns.contains(where: {
                  $0.id == turnID && $0.kind == .reply && $0.author == .origin
              }) == true else { return }
        let readKey = ConversationReadKey(request: key, turnID: turnID)
        guard pendingConversationReadUpdates.insert(readKey).inserted else { return }
        let port = self.port
        let context = port.context
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let update = try port.markConversationReadAndProject(key, through: turnID,
                                                                     context: context)
                await self?.finishConversationRead(readKey, update: update)
            } catch {
                await self?.finishConversationRead(
                    readKey, errorDescription: String(describing: error))
            }
        }
    }

    private func finishConversationRead(_ readKey: ConversationReadKey,
                                        update: ConversationReadUpdate? = nil,
                                        errorDescription: String? = nil) {
        pendingConversationReadUpdates.remove(readKey)
        guard !isReadOnly else { return }
        guard let update else {
            UIDiagnostics.shared.record(
                "store.markConversationRead \(UIDiagnostics.describe(readKey.request)) error=\(errorDescription ?? "unknown")")
            return
        }
        if let currentRevision = conversationProjectionRevision,
           currentRevision > update.revision { return }

        let canSkipObservedRefresh = update.didCommit &&
            update.previousRevision == presentation.revision &&
            conversationProjectionRevision == update.previousRevision &&
            observation != nil
        if conversationThreads[readKey.request] != update.thread {
            conversationThreads[readKey.request] = update.thread
            reconcileReplyItemArea(for: readKey.request)
        }
        if conversationProjectionRevision == update.previousRevision {
            conversationProjectionRevision = update.revision
        }
        if canSkipObservedRefresh {
            locallyReconciledConversationReadRevisions.insert(update.revision)
        }
        if permitsDelivery, update.pendingPosition != nil {
            let expected = profileContext
            Task {
                await NativeRelayLifecycle.shared.sendPendingConversationReadPositions(expected: expected)
            }
        }
    }

    func historicalAnswerDraft(for key: RequestKey, revision: UInt64) -> PresentedRequest? {
        do { return try port.inspectAnswerDraft(context: port.context, request: key, revision: revision) }
        catch {
            diagnose(.localStore, .draftLoad,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                     request: key, revision: revision)
            return nil
        }
    }

    func prepareConversationPreview(_ file: ConversationFile,
                                    for request: RequestKey? = nil,
                                    revision: UInt64? = nil) async throws -> URL {
        guard let files = conversationFiles else { throw AttentionStoreError.fixtureOnlyOperation }
        do {
            if let cached = try files.cachedPreview(for: file) { return cached }
            guard permitsDelivery, !isReadOnly else { throw AttentionStoreError.fixtureOnlyOperation }
            let destination = try files.previewDestination(for: file)
            try await NativeRelayLifecycle.shared.fetchConversationFile(file, to: destination, expected: profileContext)
            try files.verify(destination, for: file)
            return destination
        } catch {
            diagnose(.fileAccess, .filePreview,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                     request: request, revision: revision)
            throw error
        }
    }

    func hasCachedConversationPreview(_ file: ConversationFile) -> Bool {
        guard let conversationFiles else { return false }
        return (try? conversationFiles.cachedPreview(for: file)) != nil
    }

    func reportConversationImportError(_ error: Error, for key: RequestKey, revision: UInt64) {
        conversationError = "The selected file could not be opened: " + error.localizedDescription + ". Your saved draft is retained."
        diagnose(.fileAccess, .fileRetention,
                 NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                 request: key, revision: revision)
    }

    func conversationDraft(for key: RequestKey, revision: UInt64) -> ConversationDraft {
        conversationThreads[key]?.drafts[revision] ?? ConversationDraft(binding: ConversationBinding(request: key, revision: revision))
    }

    func unsavedConversationText(for binding: ConversationBinding) -> String? {
        pendingConversationTextByBinding[binding]
    }

    @discardableResult
    func updateConversation(for key: RequestKey, revision: UInt64, text: String? = nil,
                            files: [ConversationFile]? = nil) -> Bool {
        guard !isReadOnly else { return false }
        do {
            if let text, files == nil {
                guard var thread = conversationThreads[key] else { throw ConversationError.missingRequest }
                let binding = ConversationBinding(request: key, revision: revision)
                let updated = try port.updateConversationDraftText(ExactText(text), for: binding,
                    context: port.context)
                thread.drafts[revision] = updated
                conversationThreads[key] = thread
                pendingConversationTextByBinding.removeValue(forKey: binding)
                conversationError = nil
                return true
            }
            var draft = conversationDraft(for: key, revision: revision)
            if let text { draft.text = ExactText(text) }
            if let files { draft.files = files }
            draft.disposition = .saved
            try port.saveConversationDraft(draft, context: port.context)
            try refreshFromDurableStore()
            conversationError = nil
            return true
        } catch {
            if let text { pendingConversationTextByBinding[ConversationBinding(request: key, revision: revision)] = text }
            conversationError = "Your latest discussion edit could not be saved. It remains in this session; the earlier saved draft is unchanged."
            diagnose(.localStore, .draftSave, .failed, error: error,
                     request: key, revision: revision)
            return false
        }
    }

    /// The ordinary inbox calls this only for explicit selection/back navigation.
    /// Rebuilding a detail or losing transport never calls it.
    func navigateMessage(from previous: RequestKey?, to next: RequestKey?) {
        guard previous != next else { return }
        if let previous { flushPendingDraft(for: previous) }
        if !isReadOnly, let previous {
            do {
                let pending = try port.abandonConversationUploads(for: previous, context: port.context)
                try refreshFromDurableStore()
                UIDiagnostics.shared.record("store.navigate \(UIDiagnostics.describe(previous))->\(UIDiagnostics.describe(next)) local=\(self.isLocalExample) pending=\(pending.count)")
                if !pending.isEmpty {
                    if permitsDelivery { Task { await retryUploadCleanup(for: previous) } }
                    else {
                        try port.markConversationCleanupUnknown(for: previous,
                            reason: ExactText("Local example: no service is contacted"), context: port.context)
                        try refreshFromDurableStore()
                    }
                }
            } catch {
                UIDiagnostics.shared.record("store.navigate \(UIDiagnostics.describe(previous))->\(UIDiagnostics.describe(next)) error=\(error)")
                conversationError = "Upload cleanup could not be saved. Return to this message and retry; deletion is not confirmed."
                diagnose(.upload, .uploadCleanup,
                         NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                         request: previous)
            }
        } else {
            UIDiagnostics.shared.record("store.navigate \(UIDiagnostics.describe(previous))->\(UIDiagnostics.describe(next)) local=\(self.isLocalExample) readOnly=\(self.isReadOnly)")
        }
        selectRequest(next)
    }

    func hasPendingUploadCleanup(for key: RequestKey, revision: UInt64) -> Bool {
        (conversationThreads[key]?.uploadCleanups ?? [:]).values.contains {
            guard $0.binding.revision == revision else { return false }
            if case .acknowledged = $0.outcome { return false }; return true
        }
    }

    func hasAbandonedDiscussion(for key: RequestKey, revision: UInt64) -> Bool {
        let draft = conversationDraft(for: key, revision: revision)
        let operation: UUID
        switch draft.disposition {
        case let .submitting(id), let .outcomeUnknown(id): operation = id
        default: return false
        }
        return conversationThreads[key]?.uploadGroups?[operation]?.cleanupID != nil
    }

    func refreshDiscussionHistory() async {
        guard permitsDelivery else { return }
        _ = await NativeRelayLifecycle.shared.refreshFromTrustedRelay()
        do { try refreshFromDurableStore() }
        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error) }
    }

    @discardableResult
    func fetchNextInboxPage() async -> Bool {
        guard permitsDelivery, !isReadOnly else { return false }
        let fetched = await NativeRelayLifecycle.shared.fetchNextInboxPage()
        if fetched {
            do { try refreshFromDurableStore() }
            catch { diagnose(.localStore, .projectionRefresh, .failed, error: error) }
        }
        return fetched
    }

    func inboxPageAvailability() -> InboxPageAvailability {
        guard let checkpoint = try? attentionStore.snapshot(context: profileContext).inboxCheckpoint,
              checkpoint.checkpointAccepted, checkpoint.hasInitialPage else { return .unknown }
        return checkpoint.nextCursor == nil ? .exhausted : .more
    }

    func uploadNeedsReselection(_ file: ConversationFile, for key: RequestKey, revision: UInt64) -> Bool {
        (conversationThreads[key]?.uploadGroups ?? [:]).values.contains {
            $0.binding.revision == revision && $0.cleanupID != nil && $0.originals.contains(where: { $0.id == file.id })
        }
    }

    func hasUnreadyUploadReference(for key: RequestKey, revision: UInt64) -> Bool {
        conversationDraft(for: key, revision: revision).files.contains {
            uploadNeedsReselection($0, for: key, revision: revision)
        }
    }

    func uploadHistoryNeedsReconciliation(for key: RequestKey, revision: UInt64) -> Bool {
        hasUnreadyUploadReference(for: key, revision: revision) &&
        (conversationThreads[key]?.uploadCleanups ?? [:]).values.contains {
            guard $0.binding.revision == revision, case let .acknowledged(result) = $0.outcome else { return false }
            return result.state == .committed
        }
    }

    func retryUploadCleanup(for key: RequestKey) async {
        guard permitsDelivery, retryingCleanupRequests.insert(key).inserted else { return }
        defer { retryingCleanupRequests.remove(key) }
        do {
            try await NativeRelayLifecycle.shared.discardAbandonedUploads(for: key, expected: profileContext)
        } catch {
            diagnose(.upload, .uploadCleanup,
                     NativeDiagnosticCauseCode.failureTransition(for: error), error: error, request: key)
            do {
                try port.markConversationCleanupUnknown(for: key,
                    reason: ExactText("Cleanup not confirmed: \(error)"), context: port.context)
            } catch {
                diagnose(.localStore, .draftSave, .failed, error: error, request: key)
            }
        }
        do { try refreshFromDurableStore() }
        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
    }

    func sendDiscussion(for key: RequestKey, revision: UInt64,
                        onResult: ((Bool) -> Void)? = nil) {
        guard !isReadOnly, conversationUnavailableMessage == nil else { return }
        do {
            let binding = ConversationBinding(request: key, revision: revision)
            guard !hasPendingUploadCleanup(for: key, revision: revision),
                  !hasUnreadyUploadReference(for: key, revision: revision) else {
                conversationError = "Upload files are not ready to resend. Reconcile cleanup/history or remove and reselect them; your text draft is retained."
                return
            }
            if permitsDelivery {
                guard !isSendingDiscussion, let files = conversationFiles else { return }
                isSendingDiscussion = true
                conversationError = nil
                Task { [weak self] in
                    guard let self else { return }
                    defer { isSendingDiscussion = false }
                    do {
                        let result = try await NativeRelayLifecycle.shared.submitDiscussion(binding, expected: profileContext) { file in
                            try files.fileURL(for: file)
                        }
                        do { try refreshFromDurableStore() }
                        catch {
                            diagnose(.localStore, .projectionRefresh, .failed, error: error,
                                     request: key, revision: revision)
                        }
                        switch result {
                        case .accepted:
                            conversationError = nil
                            onResult?(true)
                        case let .rejected(reason):
                            conversationError = "Not delivered: " + reason.rawValue + ". Draft and files retained."
                            onResult?(false)
                        case .unresolved:
                            conversationError = "Submission unconfirmed. Retry uses the same saved operation."
                            onResult?(false)
                        }
                    } catch {
                        diagnose(.conversation, .discussionSubmission,
                                 NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                                 operationID: discussionOperationID(for: key, revision: revision),
                                 request: key, revision: revision, receiptState: .unknown)
                        do { try refreshFromDurableStore() }
                        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error,
                                         request: key, revision: revision) }
                        if case InstallationTransportError.conversationsUnavailable = error {
                            conversationError = nil // The conversation surface shows the capability message.
                        } else if (error as? ConversationError) == .emptyDraft {
                            conversationError = "Add a message before sending these files. Your draft is retained."
                        } else {
                            conversationError = "Discussion could not be confirmed (\(error)). Your saved text and files are retained."
                        }
                    }
                }
                return
            }
            try port.appendFixtureDiscussion(binding, context: port.context)
            try refreshFromDurableStore()
            conversationError = nil
            onResult?(true)
        } catch {
            conversationError = "Not delivered: the discussion could not be submitted. Your draft is retained."
            diagnose(.conversation, .discussionSubmission, .failed, error: error,
                     operationID: discussionOperationID(for: key, revision: revision),
                     request: key, revision: revision, receiptState: .unknown)
        }
    }

    func addLocalAttachment(_ name: String, for key: RequestKey, revision: UInt64) {
        guard !permitsDelivery, !isReadOnly else { return }
        let bytes = Data(("Fictional local attachment: " + name).utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = ConversationFile(id: ExactText(UUID().uuidString.lowercased()), name: ExactText(name),
            byteCount: UInt64(bytes.count), sha256: ExactText(digest), content: .inline(bytes))
        var files = conversationDraft(for: key, revision: revision).files
        files.append(file)
        updateConversation(for: key, revision: revision, files: files)
    }

    func importConversationFiles(_ urls: [URL], for key: RequestKey, revision: UInt64) async {
        guard permitsDelivery, let conversationFiles else { return }
        var files = conversationDraft(for: key, revision: revision).files
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try await Task.detached { try conversationFiles.retain(url) }.value
                files.append(file)
                updateConversation(for: key, revision: revision, files: files)
            } catch {
                conversationError = "\(url.lastPathComponent): the file could not be retained. Your text and other selected files remain saved."
                diagnose(.fileAccess, .fileRetention, .failed, error: error,
                         request: key, revision: revision)
            }
        }
    }

    var inboxRows: [InboxRequestRow] {
        let skippedMessageRequestTags = completedSkippedMessageRequestTags
        return presentation.requests
            .filter { $0.lifecycleStatus != .superseded }
            .filter { request in
                guard isRetracted(request) else { return true }
                return !Self.isRetractionExpired(
                    retractionDate: retractionDate(request), at: retractionVisibilityTime)
            }
            .compactMap { makeInboxRow(for: $0, skippedMessageRequestTags: skippedMessageRequestTags) }
    }

    var expiredRetractionSearchRows: [InboxRequestRow] {
        let skippedMessageRequestTags = completedSkippedMessageRequestTags
        return presentation.requests
            .filter { $0.lifecycleStatus != .superseded }
            .filter { request in
                isRetracted(request) &&
                    Self.isRetractionExpired(
                        retractionDate: retractionDate(request), at: retractionVisibilityTime)
            }
            .compactMap { makeInboxRow(for: $0, skippedMessageRequestTags: skippedMessageRequestTags) }
    }

    var nextRetractionExpiry: Date? {
        presentation.requests.compactMap { request -> Date? in
            guard request.lifecycleStatus != .superseded,
                  isRetracted(request),
                  !clearedRetractions.contains(request.key),
                  let expiry = Self.retractionExpiryDate(for: retractionDate(request)),
                  expiry > retractionVisibilityTime else { return nil }
            return expiry
        }.min()
    }

    var newMessageAreaStore: NewMessageAreaStore? { messageAreaStore }

    var replyItemAreaStore: ReplyItemAreaStore? { replyAreaStore }

    private func reconcileNewMessageArea(_ requests: [PresentedRequest],
                                         using store: NewMessageAreaStore? = nil) {
        guard let store = store ?? messageAreaStore else { return }
        let messages = Self.newMessageObservations(for: requests)
        let revisions = Dictionary(uniqueKeysWithValues: requests.map { ($0.key, $0.requestRevision) })
        store.reconcile(messages, revisions: revisions,
                        accountScopes: [profileContext.identity.personID])
    }

    private nonisolated static func newMessageObservations(
        for requests: [PresentedRequest]
    ) -> [NewMessageAreaMessage] {
        requests.map {
            NewMessageAreaMessage(key: $0.key, acceptanceOrder: $0.acceptanceOrder,
                                  isResolved: $0.isResolved,
                                  hasSubmittedAnswer: $0.intentReceipt != nil)
        }
    }

    private nonisolated static func replyObservations(
        in conversationThreads: [RequestKey: ConversationThread],
        account: ExactText,
        ledger: ReplyItemLedger,
        request: RequestKey? = nil
    ) -> (observations: [ReplyItemObservation], parentScope: Set<RequestKey>?) {
        // A partial conversation view cannot establish the account's first-run
        // baseline. Fall back to the full snapshot until that baseline exists.
        let scopedRequest = request.flatMap {
            ledger.baselineEstablishedAccounts.contains(account) ? $0 : nil
        }
        var observations: [ReplyItemObservation] = []
        for (key, thread) in conversationThreads where scopedRequest == nil || key == scopedRequest {
            let legacyReadIndex = thread.readThroughTurn.flatMap { readTurn in
                thread.turns.firstIndex { $0.id == readTurn }
            }
            for (index, turn) in thread.turns.enumerated()
                where turn.kind == .reply && turn.author == .origin {
                let isSeen: Bool
                if let cursor = thread.accountReadThroughConversationSequence,
                   let sequence = turn.conversationSequence {
                    isSeen = sequence <= cursor
                } else if let legacyReadIndex {
                    isSeen = index <= legacyReadIndex
                } else {
                    isSeen = false
                }
                observations.append(ReplyItemObservation(parent: key,
                                                         turnID: turn.id,
                                                         conversationSequence: turn.conversationSequence,
                                                         isSeen: isSeen,
                                                         text: turn.text.rawValue))
            }
        }
        return (observations, scopedRequest.map { Set([$0]) })
    }

    private func reconcileReplyItemArea(for request: RequestKey? = nil,
                                        using store: ReplyItemAreaStore? = nil) {
        guard let store = store ?? replyAreaStore else { return }
        let account = profileContext.identity.personID
        let preparedInput = Self.replyObservations(in: conversationThreads, account: account,
                                                   ledger: store.ledger, request: request)
        store.reconcile(preparedInput.observations, accountScopes: [account],
                        parentScope: preparedInput.parentScope)
    }

    func inboxRow(for key: RequestKey) -> InboxRequestRow? {
        guard let request = presentation.requests.first(where: { $0.key == key }) else { return nil }
        return makeInboxRow(for: request, skippedMessageRequestTags: completedSkippedMessageRequestTags)
    }

    private func makeInboxRow(for request: PresentedRequest,
                              skippedMessageRequestTags: Set<String>) -> InboxRequestRow? {
        let retracted = isRetracted(request)
        if retracted, clearedRetractions.contains(request.key) { return nil }
        let hasKnownDeliveryFailure = failedResponseWarning(for: request) != nil
        let hasDeliveryWarning = hasKnownDeliveryFailure || request.staleAnswerRevision != nil
        let hasMessageLoadWarning = requestTag(for: request.key)
            .map(skippedMessageRequestTags.contains) ?? false
        let hasUnconfirmedOwnSubmission = request.intentReceipt != nil &&
            request.receiptFacts?.ownOutcome == .unconfirmed &&
            request.lifecycleStatus != .pending
        let serverReportedFinalResponse = request.inboxStateIsCurrent &&
            (request.lifecycleStatus == .answered || request.lifecycleStatus == .noComment)
        let hasAcceptedOwnSubmission = request.receiptFacts?.ownOutcome == .accepted
        let receiptStatus = request.answerNotDelivered ? .some(.failed) :
            InboxRequestRow.responseReceiptStatus(
            request.intentReceipt,
            hasUnconfirmedOutcome: hasUnconfirmedOwnSubmission,
            serverReportedFinalResponse: serverReportedFinalResponse,
            hasAcceptedOwnSubmission: hasAcceptedOwnSubmission)
        var statusParts: [String] = []
        if request.inboxStateIsCurrent {
            if hasAcceptedUpdate(for: request.key) { statusParts.append("Updated") }
            let lifecycle = retracted ? retractionLabel(for: request) :
                request.defaultAnswerStatusText ??
                    String(localized: LiveLifecycleTitle(request.lifecycleStatus).label)
            if request.lifecycleStatus != .open || retracted || request.defaultAnswerStatusText != nil {
                statusParts.append(lifecycle)
            }
            if let seenStatus = request.informationalSeenStatus, seenStatus != .available {
                statusParts.append(informationalSeenRowStatus(seenStatus))
            }
        } else {
            if !hasKnownDeliveryFailure, !request.answerNotDelivered,
               let localStatus = cachedOperationStatus(request.intentReceipt?.localState) {
                statusParts.append(localStatus)
            }
            if let defaultStatus = request.defaultAnswerStatusText {
                statusParts.append(defaultStatus)
            }
            statusParts.append("Cached history · status not refreshed")
        }
        let localStatus: String?
        if request.answerNotDelivered || hasKnownDeliveryFailure {
            localStatus = nil
        } else if receiptStatus == .failed {
            localStatus = request.receiptFacts?.ownOutcome == .unconfirmed
                ? "Answer sent · result not confirmed"
                : cachedOperationStatus(request.intentReceipt?.localState)
        } else {
            localStatus = nil
        }
        let row = InboxRequestRow(key: request.key, requestRevision: request.requestRevision,
            title: request.title?.rawValue ?? "Message",
            sender: request.key.senderID.rawValue,
            status: statusParts.joined(separator: " · "),
            senderDisplayName: request.senderDisplayName?.rawValue,
            bodyText: request.body?.rawValue,
            symbol: request.informationalSeenStatus == nil ? "envelope" : "info.circle",
            isResolved: request.answerNotDelivered || receiptStatus == .failed || hasDeliveryWarning
                ? false : request.isResolved,
            createdAt: request.createdAt,
            localStatus: localStatus,
            informationalSeenStatus: request.informationalSeenStatus,
            declaredMessageType: request.messageType,
            declaredMessageKind: request.messageKind,
            canMarkSeen: !isReadOnly &&
                !retracted && request.lifecycleStatus == .open &&
                request.intentReceipt == nil && request.informationalSeenStatus == .available,
            canNoComment: canNoComment(request, isRetracted: retracted),
            noCommentUnavailable: request.noCommentUnavailable,
            hasUserAction: receiptStatus == .pendingOrAccepted ||
                request.lifecycleStatus == .answered ||
                request.lifecycleStatus == .noComment,
            hasFailedResponse: receiptStatus == .failed || hasDeliveryWarning,
            hasDeliveryWarning: hasDeliveryWarning,
            hasMessageLoadWarning: hasMessageLoadWarning,
            isRetracted: retracted,
            chatUnread: listChatUnread(request.key),
            tier: .middle,
            inboxScore: request.inboxScore,
            inboxReplyScores: request.inboxReplyScores,
            thread: request.inboxThread,
            hasInboxViewEntry: request.hasInboxViewEntry,
            duePhrase: request.inboxDueAtMilliseconds.map { InboxDuePhrase.presentation(for: $0) },
            orderingReason: request.inboxReason?.rawValue,
            defaultAnswerStatus: request.defaultAnswerStatusText)
        return row
    }

    private func isRetracted(_ request: PresentedRequest) -> Bool {
        if conversationThreads[request.key]?.isRetracted == true { return true }
        if let outcome = request.intentReceipt?.relayOutcome,
           case .refusedByRetraction = outcome { return true }
        return false
    }

    private func retractionLabel(for request: PresentedRequest) -> String {
        let thread = conversationThreads[request.key]
        let timestamp = thread?.retraction?.retractedAtMilliseconds ?? thread?.reportedRetractedAtMilliseconds ?? {
            guard let outcome = request.intentReceipt?.relayOutcome,
                  case let .refusedByRetraction(retractedAtMilliseconds) = outcome else { return nil }
            return retractedAtMilliseconds
        }()
        guard let timestamp else { return "Retracted" }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        return "Retracted · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    private func canNoComment(_ request: PresentedRequest, isRetracted: Bool) -> Bool {
        guard !isReadOnly, !isRetracted,
              request.lifecycleStatus == .open, request.intentReceipt == nil,
              request.informationalSeenStatus == nil else { return false }
        // No comment is its own wire answer and does not depend on the
        // request's typed-answer interface being understood by this client.
        return true
    }

    private func cachedOperationStatus(_ state: LocalIntentState?) -> String? {
        guard let state else { return nil }
        return switch state {
        case .durable, .queuedForRelay: "Answer pending on this device"
        case .accepted: "Answer accepted"
        case .refusedByRetraction: "Answer refused · request retracted"
        case .terminalUnconfirmed: "Answer sent · result not confirmed"
        case .notDelivered: "Answer not delivered"
        case .unsupported: "No comment was not accepted"
        case .repairRequired: "Answer needs recovery"
        }
    }

    private func informationalSeenRowStatus(_ status: InformationalSeenStatus) -> String {
        switch status {
        case .available: "Seen available"
        case .pending: "Seen pending"
        case .confirmed: "Seen"
        case .resolvedWithoutSeen: "Seen not confirmed"
        }
    }

    var openRequests: [PresentedRequest] {
        presentation.requests.filter { $0.lifecycleStatus == .open || $0.lifecycleStatus == .pending }
    }

    var resolvedRequests: [PresentedRequest] {
        presentation.requests.filter {
            $0.lifecycleStatus != .open && $0.lifecycleStatus != .pending &&
                $0.lifecycleStatus != .superseded
        }
    }

    var selectedRequest: PresentedRequest? {
        presentation.requests.first { $0.key == selectedRequestKey }
    }

    func request(for key: RequestKey) -> PresentedRequest? {
        presentation.requests.first { $0.key == key }
    }

    /// Records only an explicit detail-content navigation. The durable
    /// operation is stored before any best-effort relay send; a reconnect will
    /// retry it with the same message identity and revision.
    func reportMessageContentOpened(_ request: PresentedRequest) {
        guard permitsDelivery, !isReadOnly, !isLocalExample,
              request.requestRevision > 0 else { return }
        do {
            _ = try attentionStore.enqueueMessageOpen(request.key,
                                                       requestRevision: request.requestRevision,
                                                       context: profileContext)
        } catch {
            // Opening remains available when the local report cannot be saved.
            // Without a durable outbox entry, no relay report is attempted.
            diagnostics?.record(area: .localStore, phase: .messageOpen, transition: .failed,
                                error: error, request: request.key,
                                requestRevision: request.requestRevision,
                                receiptState: .unknown)
            return
        }
        Task { await NativeRelayLifecycle.shared.sendPendingMessageOpens() }
    }

    func failedResponseWarning(for key: RequestKey,
                               revision: UInt64? = nil) -> FailedResponseWarning? {
        guard let request = request(for: key),
              revision == nil || request.requestRevision == revision else { return nil }
        return failedResponseWarning(for: request)
    }

    func skippedMessageWarning(for request: RequestKey) -> SkippedMessageWarning? {
        guard let diagnostics, let requestTag = requestTag(for: request) else { return nil }
        guard let event = diagnostics.events.reversed().first(where: {
            Self.isCompletedSkippedMessage($0) && $0.requestTag == requestTag
        }), let requestRevision = event.requestRevision,
           let conversationSequence = event.conversationSequence else { return nil }
        return SkippedMessageWarning(eventID: event.id,
                                     requestRevision: requestRevision,
                                     conversationSequence: conversationSequence)
    }

    func skippedMessageDiagnosticText(for warning: SkippedMessageWarning) -> String? {
        guard let diagnostics,
              diagnostics.events.contains(where: { $0.id == warning.eventID }) else { return nil }
        return diagnostics.shareText
    }

    private var completedSkippedMessageRequestTags: Set<String> {
        Set((diagnostics?.events ?? []).compactMap { event in
            guard Self.isCompletedSkippedMessage(event) else { return nil }
            return event.requestTag
        })
    }

    private static func isCompletedSkippedMessage(_ event: NativeClientDiagnosticEvent) -> Bool {
        // A rejection can be logged before a cursor write fails; only this
        // post-commit event marks a message as actually skipped.
        event.area == .conversation &&
            event.phase == .conversationReplay &&
            event.transition == .observed &&
            event.causeCode == "conversation_message_skipped" &&
            event.requestRevision != nil &&
            event.conversationSequence != nil
    }

    private func requestTag(for request: RequestKey) -> String? {
        NativeClientDiagnosticEvent(area: .conversation,
                                    phase: .conversationReplay,
                                    transition: .observed,
                                    request: request).requestTag
    }

    private func failedResponseWarning(for request: PresentedRequest) -> FailedResponseWarning? {
        guard request.informationalSeenStatus == nil,
              request.staleAnswerRevision == nil else { return nil }
        if let warning = failedResponseWarnings[request.key],
           warning.requestRevision == request.requestRevision {
            return warning
        }
        guard request.answerNotDelivered || request.noCommentUnavailable else { return nil }
        return Self.makeFailedResponseWarning(for: request, submission: nil,
            retryOperationID: nil, diagnosticEvents: diagnostics?.events ?? [])
    }

    func canRetryFailedResponse(for key: RequestKey) -> Bool {
        guard permitsDelivery, !isReadOnly,
              let request = request(for: key),
              let warning = failedResponseWarning(for: key, revision: request.requestRevision),
              warning.canRetry,
              request.lifecycleStatus == .open,
              request.informationalSeenStatus == nil,
              request.staleAnswerRevision == nil,
              !isRetracted(key) else { return false }
        if let receipt = request.intentReceipt {
            return warning.retryOperationID == receipt.opID &&
                Self.matches(receipt: receipt, warning: warning)
        }
        return warning.retryOperationID == nil
    }

    /// Reuses the exact typed response retained by the failed durable submission.
    /// If that retry is already pending, only the same operation is replayed.
    @discardableResult
    func retryFailedResponse(for key: RequestKey) -> Bool {
        guard canRetryFailedResponse(for: key),
              let request = request(for: key),
              let warning = failedResponseWarning(for: key, revision: request.requestRevision) else {
            return false
        }
        if request.intentReceipt != nil {
            retryPendingDelivery()
            return true
        }
        guard let answerDraft = warning.answerDraft else { return false }
        do {
            let receipt = try submit(key, answerDraft: answerDraft,
                                    requestRevision: warning.requestRevision)
            if var current = failedResponseWarnings[key],
               current.failedOperationID == warning.failedOperationID {
                current.retryOperationID = receipt.opID
                failedResponseWarnings[key] = current
                failedResponseWarningGeneration &+= 1
            }
            retryPendingDelivery()
            return true
        } catch {
            diagnose(.localStore, .draftSave, .failed, error: error,
                     request: key, revision: warning.requestRevision,
                     receiptState: .unknown)
            actionErrorRequest = key
            actionError = "The saved response could not be retried. Review the latest message and try again."
            return false
        }
    }

    func draft(for key: RequestKey, revision: UInt64? = nil) -> RequestDraft? {
        // Binding reads use the revision already displayed by the observer.
        // Historical revisions still need an explicit inspection.
        if let current = request(for: key),
           revision == nil || revision == current.requestRevision {
            let bufferKey = DraftBufferKey(request: key, revision: current.requestRevision)
            return pendingDrafts[bufferKey] ?? current.draft
        }
        guard let revision,
              let presented = try? inspectedRequest(key, revision: revision) else { return nil }
        let bufferKey = DraftBufferKey(request: key, revision: presented.requestRevision)
        return pendingDrafts[bufferKey] ?? presented.draft
    }

    func replyEditorSession(for request: PresentedRequest) -> ReplyEditorDraftSession {
        if let session = replyEditorSessions[request.key],
           session.requestRevision == request.requestRevision {
            return session
        }
        let session = ReplyEditorDraftSession(request: request, canSubmitFromSnapshot: true)
        replyEditorSessions[request.key] = session
        return session
    }

    func discardReplyEditorSession(for key: RequestKey) {
        replyEditorSessions.removeValue(forKey: key)
    }

    func selectRequest(_ key: RequestKey?) {
        guard let key else { selectedRequestKey = nil; clearActionError(); return }
        guard presentation.requests.contains(where: { $0.key == key }) else { return }
        if selectedRequestKey != key { clearActionError() }
        selectedRequestKey = key
    }

    func selectAction(_ action: ExactText, input: ExactText?, for key: RequestKey,
                      requestRevision: UInt64? = nil) {
        editDraft(for: key, revision: requestRevision) { draft in
            draft.noCommentSelected = false
            if let input {
                draft.inputs[input]?.selectedActionID = action
            } else {
                draft.compatibility.selectedActionID = action
            }
        }
    }

    func selectNoComment(for key: RequestKey, requestRevision: UInt64? = nil) {
        editDraft(for: key, revision: requestRevision) { draft in
            draft.noCommentSelected = true
            draft.compatibility.selectedActionID = nil
            for inputID in Array(draft.inputs.keys) {
                draft.inputs[inputID]?.selectedActionID = nil
            }
        }
    }

    func updateText(_ text: String, input: ExactText, action: ExactText?, for key: RequestKey,
                    requestRevision: UInt64? = nil) {
        let update: (inout RequestDraft) -> Void = { draft in
            draft.noCommentSelected = false
            if let action {
                draft.inputs[input]?.textByActionID[action] = ExactText(text)
            } else {
                draft.inputs[input]?.text = ExactText(text)
            }
        }
        if permitsDelivery {
            stageDraftText(for: key, revision: requestRevision, update)
        } else {
            editDraft(for: key, revision: requestRevision, update)
        }
    }

    func stageText(_ text: String, input: ExactText, action: ExactText?, for key: RequestKey,
                   requestRevision: UInt64? = nil) {
        let currentDraft = draft(for: key, revision: requestRevision)
        let currentText: ExactText?
        if let action {
            currentText = currentDraft?.inputs[input]?.textByActionID[action]
        } else {
            currentText = currentDraft?.inputs[input]?.text
        }
        let textChanged = (currentText?.rawValue ?? "") != text
        let update: (inout RequestDraft) -> Void = { draft in
            if textChanged { draft.noCommentSelected = false }
            if let action {
                draft.inputs[input]?.textByActionID[action] = ExactText(text)
            } else {
                draft.inputs[input]?.text = ExactText(text)
            }
        }
        stageDraftText(for: key, revision: requestRevision, update)
    }

    func updateCompatibilityText(_ text: String, action: ExactText, for key: RequestKey,
                                requestRevision: UInt64? = nil) {
        let update: (inout RequestDraft) -> Void = { draft in
            draft.noCommentSelected = false
            draft.compatibility.textByActionID[action] = ExactText(text)
        }
        if permitsDelivery {
            stageDraftText(for: key, revision: requestRevision, update)
        } else {
            editDraft(for: key, revision: requestRevision, update)
        }
    }

    func stageCompatibilityText(_ text: String, action: ExactText, for key: RequestKey,
                                requestRevision: UInt64? = nil) {
        let currentText = draft(for: key, revision: requestRevision)?
            .compatibility.textByActionID[action]?.rawValue ?? ""
        let textChanged = currentText != text
        stageDraftText(for: key, revision: requestRevision) { draft in
            if textChanged { draft.noCommentSelected = false }
            draft.compatibility.textByActionID[action] = ExactText(text)
        }
    }

    func setPoint(_ point: PointValue, input: ExactText, for key: RequestKey,
                  requestRevision: UInt64? = nil) {
        editDraft(for: key, revision: requestRevision) { draft in
            draft.noCommentSelected = false
            draft.inputs[input]?.point = point
            draft.inputs[input]?.horizontalText = ExactText(String(point.x))
            draft.inputs[input]?.verticalText = ExactText(String(point.y))
        }
    }

    func updateLocalExampleAnnotation(_ text: String, point: PointValue?, for key: RequestKey) {
        guard !permitsDelivery, !isReadOnly else { return }
        let input = ExactText("point")
        editDraft(for: key) { draft in
            draft.noCommentSelected = false
            draft.inputs[ExactText("annotation")]?.text = ExactText(text)
            draft.inputs[input]?.point = point
            draft.inputs[input]?.horizontalText = point.map { ExactText(String($0.x)) }
            draft.inputs[input]?.verticalText = point.map { ExactText(String($0.y)) }
        }
    }

    /// C composes the exact answer and durably stores one original operation
    /// before any network send. A persisted receipt prevents a second intent.
    @discardableResult
    func submit(_ key: RequestKey,
                explicitCompatibilityAction: ExactText? = nil,
                requestRevision: UInt64? = nil) throws -> IntentReceipt {
        try submit(key,
                   answerDraftOverride: nil,
                   explicitCompatibilityAction: explicitCompatibilityAction,
                   requestRevision: requestRevision)
    }

    /// Submits the Reply box's in-memory contents without first saving them as
    /// a resumable draft. The displayed revision is still checked by the same
    /// submit path before the answer is committed.
    @discardableResult
    func submit(_ key: RequestKey,
                answerDraft: RequestDraft,
                requestRevision: UInt64) throws -> IntentReceipt {
        try submit(key,
                   answerDraftOverride: answerDraft,
                   explicitCompatibilityAction: nil,
                   requestRevision: requestRevision)
    }

    private func submit(_ key: RequestKey,
                        answerDraftOverride: RequestDraft?,
                        explicitCompatibilityAction: ExactText?,
                        requestRevision: UInt64?) throws -> IntentReceipt {
        guard !isReadOnly else { throw LiveReplyError.disconnected }
        guard permitsDelivery else { throw LiveReplyError.localExample }
        let inspected = try inspectedRequest(key, revision: requestRevision)
        let revision = inspected.requestRevision
        let bufferKey = DraftBufferKey(request: key, revision: revision)
        let answerDraft = answerDraftOverride ?? pendingDrafts[bufferKey] ?? inspected.draft
        guard !isRetracted(key), inspected.lifecycleStatus == .open,
              inspected.intentReceipt == nil,
              let selector = inspected.selector else {
            throw LiveReplyError.notOpen
        }
        if answerDraft.noCommentSelected {
            if answerDraftOverride == nil {
                try persistPendingDraft(for: bufferKey)
            }
            return try submitNoComment(key,
                                       request: inspected,
                                       discardDraft: answerDraftOverride != nil)
        }

        let records = try typedInputs(for: inspected, draft: answerDraft,
                                      explicitCompatibilityAction: explicitCompatibilityAction)
        let hasAnswerContent = records.contains { record in
            switch record {
            case let .responseText(_, _, text), let .text(_, text), let .compatibilityText(_, text):
                // Whitespace-only text is as incomplete as empty text; real text
                // still goes out exactly as typed, surrounding spaces included.
                return text.rawValue.contains { !$0.isWhitespace }
            case .responseValue, .point, .compatibilityValue:
                return true
            }
        }
        guard hasAnswerContent else { throw LiveReplyError.incomplete }

        if answerDraftOverride == nil {
            try persistPendingDraft(for: bufferKey)
            let request = try inspectedRequest(key, revision: revision)
            guard !isRetracted(bufferKey.request), request.lifecycleStatus == .open,
                  request.intentReceipt == nil else {
                throw LiveReplyError.notOpen
            }
        }
        let receipt = try port.submit(SubmitIntent(context: port.context,
                                                   selector: selector,
                                                   intentID: UUID(),
                                                   inputs: records,
                                                   persistAnswerDraft: answerDraftOverride == nil))
        do { try refreshFromDurableStore() }
        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
        clearActionError()
        return receipt
    }

    /// Returns whether an intent for this request now exists, so callers can
    /// avoid treating a validation refusal as a submission.
    @discardableResult
    func submitFromUser(_ key: RequestKey,
                        explicitCompatibilityAction: ExactText? = nil,
                        requestRevision: UInt64? = nil) -> Bool {
        guard permitsDelivery, !isReadOnly else { return false }
        let selectedNoComment: Bool
        guard let request = try? inspectedRequest(key, revision: requestRevision) else { return false }
        let bufferKey = DraftBufferKey(request: key, revision: request.requestRevision)
        selectedNoComment = (pendingDrafts[bufferKey] ?? request.draft).noCommentSelected
        if selectedNoComment {
            return submitNoCommentFromUser(key, requestRevision: requestRevision)
        }
        return submitAnswerFromUser(key,
                                    answerDraftOverride: nil,
                                    explicitCompatibilityAction: explicitCompatibilityAction,
                                    requestRevision: requestRevision)
    }

    /// Commits a Reply box session directly, without reading or saving the
    /// shared draft buffer first.
    @discardableResult
    func submitFromUser(_ key: RequestKey,
                        answerDraft: RequestDraft,
                        requestRevision: UInt64) -> Bool {
        guard permitsDelivery, !isReadOnly else { return false }
        if answerDraft.noCommentSelected {
            return submitNoCommentFromUser(key, requestRevision: requestRevision,
                                           selectionIsLocal: true)
        }
        return submitAnswerFromUser(key,
                                    answerDraftOverride: answerDraft,
                                    explicitCompatibilityAction: nil,
                                    requestRevision: requestRevision)
    }

    private func submitAnswerFromUser(_ key: RequestKey,
                                      answerDraftOverride: RequestDraft?,
                                      explicitCompatibilityAction: ExactText?,
                                      requestRevision: UInt64?) -> Bool {
        do {
            if let answerDraftOverride {
                guard let requestRevision else { return false }
                _ = try submit(key, answerDraft: answerDraftOverride,
                               requestRevision: requestRevision)
            } else {
                _ = try submit(key, explicitCompatibilityAction: explicitCompatibilityAction,
                               requestRevision: requestRevision)
            }
            retryPendingDelivery()
            return true
        } catch {
            diagnose(.localStore, .draftSave, .failed, error: error, request: key,
                     receiptState: .unknown)
            do { try refreshFromDurableStore() }
            catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
            // A stale Send callback can arrive after the original intent or
            // its receipt. Never mint another intent or contradict that fact.
            let current: PresentedRequest?
            do { current = try inspectedRequest(key) }
            catch {
                diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key)
                current = nil
            }
            if let current, current.intentReceipt != nil {
                clearActionError()
                return true
            } else {
                actionErrorRequest = key
                if let current, current.lifecycleStatus != .open {
                    actionError = "This request is no longer open for an answer."
                } else if let requestRevision, let current,
                          current.requestRevision != requestRevision {
                    actionError = "This message changed. Review the latest version before answering."
                } else if case .some(.incomplete) = error as? LiveReplyError {
                    actionError = "Complete the response before sending your answer."
                } else {
                    // A thrown save/refresh is not proof of non-delivery.
                    actionError = "Your answer could not be confirmed. Check its saved status before trying again."
                }
                return false
            }
        }
    }

    /// Returns whether an intent for this request now exists, so callers can
    /// avoid treating a validation refusal as a submission.
    @discardableResult
    func submitNoCommentFromUser(_ key: RequestKey,
                                 requestRevision: UInt64? = nil,
                                 selectionIsLocal: Bool = false) -> Bool {
        guard permitsDelivery, !isReadOnly else { return false }
        let revision: UInt64?
        if !selectionIsLocal {
            guard let request = try? inspectedRequest(key, revision: requestRevision),
                  !isRetracted(key), request.lifecycleStatus == .open,
                  request.intentReceipt == nil, request.informationalSeenStatus == nil else { return false }
            revision = request.requestRevision
            selectNoComment(for: key, requestRevision: revision)
            guard flushPendingDraft(for: key, requestRevision: revision) else { return false }
        } else {
            revision = requestRevision
        }
        do {
            _ = try submitNoComment(key,
                                    requestRevision: revision,
                                    discardDraft: selectionIsLocal)
            retryPendingDelivery()
            return true
        } catch {
            diagnose(.localStore, .draftSave, .failed, error: error, request: key,
                     receiptState: .unknown)
            do { try refreshFromDurableStore() }
            catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
            let current: PresentedRequest?
            do { current = try inspectedRequest(key) }
            catch {
                diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key)
                current = nil
            }
            if current?.intentReceipt != nil {
                clearActionError()
                return true
            } else {
                actionErrorRequest = key
                if let current, current.lifecycleStatus != .open {
                    actionError = "This request is no longer open for an answer."
                } else if let revision, let current, current.requestRevision != revision {
                    actionError = "This message changed. Review the latest version before answering."
                } else {
                    actionError = "No comment could not be confirmed. Check its saved status before trying again."
                }
                return false
            }
        }
    }

    @discardableResult
    private func submitNoComment(_ key: RequestKey,
                                 requestRevision: UInt64? = nil,
                                 discardDraft: Bool = false) throws -> IntentReceipt {
        let request = try inspectedRequest(key, revision: requestRevision)
        return try submitNoComment(key, request: request, discardDraft: discardDraft)
    }

    @discardableResult
    private func submitNoComment(_ key: RequestKey,
                                 request: PresentedRequest,
                                 discardDraft: Bool = false) throws -> IntentReceipt {
        guard !isRetracted(key),
              request.lifecycleStatus == .open, request.intentReceipt == nil,
              request.informationalSeenStatus == nil,
              let selector = request.selector,
              canSubmitNoComment(request) else { throw LiveReplyError.notOpen }
        let receipt = try port.submitNoComment(context: port.context,
                                               selector: selector,
                                               intentID: UUID(),
                                               discardDraft: discardDraft)
        do { try refreshFromDurableStore() }
        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
        clearActionError()
        return receipt
    }

    private func canSubmitNoComment(_ request: PresentedRequest) -> Bool {
        request.informationalSeenStatus == nil
    }

    func retryPendingDelivery() {
        guard permitsDelivery, !isReadOnly else { return }
        Task {
            beginRefresh()
            defer { endRefresh() }
            let result = await NativeRelayLifecycle.shared.refreshAfterAnswerStored()
            applyRefreshResult(result)
        }
    }

    func applyRefreshResult(_ result: NativeRelayRefreshResult) {
        let confirmedForCurrentContext = result.confirms(
            notificationContext, transportAttemptID: result.confirmedTransportAttemptID)
        refreshPriorityLevelsRelayStatus()
        connectionWarning = confirmedForCurrentContext ? nil :
            result.failureMessage ??
                "The relay could not be refreshed. Saved requests, answers and confirmed receipts remain on this device."
        if confirmedForCurrentContext {
            confirmedRelayRefresh?()
            pushRegistrationWarning = result.pushRegistration == .unconfirmed ?
                "Notification setup could not be confirmed. Your answer status is shown with each request." : nil
        }
    }

    func beginRefresh() { activeRefreshCount += 1 }

    func endRefresh() { activeRefreshCount = max(0, activeRefreshCount - 1) }

    func dismissStaleAnswerDialog() {
        if let staleAnswerDialog {
            presentedStaleAnswerOperationIDs.insert(staleAnswerDialog.operationID)
        }
        staleAnswerDialog = nil
    }

    private func editDraft(for key: RequestKey, revision: UInt64? = nil,
                           _ change: (inout RequestDraft) -> Void) {
        guard !isReadOnly else { return }
        do {
            let request = try inspectedRequest(key, revision: revision)
            guard !isRetracted(key), request.lifecycleStatus == .open,
                  request.intentReceipt == nil,
                  let selector = request.selector else { throw LiveReplyError.notOpen }
            let bufferKey = DraftBufferKey(request: key, revision: request.requestRevision)
            var draft = pendingDrafts[bufferKey] ?? request.draft
            change(&draft)
            try port.saveDraft(context: port.context, selector: selector, completeDraft: draft)
            do {
                try refreshFromDurableStore()
                pendingDrafts.removeValue(forKey: bufferKey)
                pendingDraftSaveTasks[bufferKey]?.cancel()
                pendingDraftSaveTasks[bufferKey] = nil
            } catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
            clearActionError()
        } catch {
            diagnose(.localStore, .draftSave, .failed, error: error, request: key)
            actionErrorRequest = key
            actionError = "Your edit could not be saved."
            do { try refreshFromDurableStore() }
            catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
        }
    }

    private func stageDraftText(for key: RequestKey, revision: UInt64? = nil,
                                _ change: (inout RequestDraft) -> Void) {
        // Staging is local and tentative. The debounced save and any submit
        // inspect the durable revision before writing or sending.
        guard !isReadOnly,
              let request = request(for: key),
              revision == nil || revision == request.requestRevision,
              !isRetracted(key), request.lifecycleStatus == .open,
              request.intentReceipt == nil else { return }
        let bufferKey = DraftBufferKey(request: key, revision: request.requestRevision)
        var draft = pendingDrafts[bufferKey] ?? request.draft
        change(&draft)
        pendingDrafts[bufferKey] = draft
        clearActionError()
        scheduleDraftPersistence(for: bufferKey)
    }

    private func scheduleDraftPersistence(for bufferKey: DraftBufferKey) {
        pendingDraftSaveTasks[bufferKey]?.cancel()
        pendingDraftSaveTasks[bufferKey] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            guard let self else { return }
            self.pendingDraftSaveTasks[bufferKey] = nil
            do { try self.persistPendingDraft(for: bufferKey) }
            catch { self.recordDraftSaveFailure(error, for: bufferKey.request) }
        }
    }

    private func persistPendingDraft(for bufferKey: DraftBufferKey) throws {
        guard let draft = pendingDrafts[bufferKey] else { return }
        let request = try inspectedRequest(bufferKey.request, revision: bufferKey.revision)
        guard !isRetracted(bufferKey.request), request.lifecycleStatus == .open,
              request.intentReceipt == nil,
              let selector = request.selector else { throw LiveReplyError.notOpen }
        try port.saveDraft(context: port.context, selector: selector, completeDraft: draft)
        do {
            try refreshFromDurableStore()
            if pendingDrafts[bufferKey] == draft {
                pendingDrafts.removeValue(forKey: bufferKey)
                pendingDraftSaveTasks[bufferKey]?.cancel()
                pendingDraftSaveTasks[bufferKey] = nil
            }
        } catch {
            diagnose(.localStore, .projectionRefresh, .failed, error: error, request: bufferKey.request)
            throw error
        }
        clearActionError()
    }

    @discardableResult
    func flushPendingDraft(for key: RequestKey, requestRevision: UInt64? = nil) -> Bool {
        let bufferKeys: [DraftBufferKey]
        if let requestRevision {
            bufferKeys = [DraftBufferKey(request: key, revision: requestRevision)]
        } else {
            bufferKeys = pendingDrafts.keys.filter { $0.request == key }
        }
        for bufferKey in bufferKeys {
            pendingDraftSaveTasks[bufferKey]?.cancel()
            pendingDraftSaveTasks[bufferKey] = nil
            do { try persistPendingDraft(for: bufferKey) }
            catch {
                recordDraftSaveFailure(error, for: key)
                return false
            }
        }
        return true
    }

    func flushPendingDrafts() {
        for bufferKey in Array(pendingDrafts.keys) {
            flushPendingDraft(for: bufferKey.request, requestRevision: bufferKey.revision)
        }
    }

    private func recordDraftSaveFailure(_ error: Error, for key: RequestKey) {
        diagnose(.localStore, .draftSave, .failed, error: error, request: key)
        actionErrorRequest = key
        actionError = "Your edit could not be saved."
    }

    func enterReadOnlyMode() {
        isReadOnly = true
        observation?.cancel()
        observation = nil
    }

    private func inspectedRequest(_ key: RequestKey, revision: UInt64? = nil) throws -> PresentedRequest {
        let snapshot: PresentationSnapshot
        if let revision {
            snapshot = try port.inspect(context: port.context, request: key, revision: revision)
        } else {
            snapshot = try port.inspect(context: port.context, request: key)
        }
        guard let request = snapshot.requests.first else {
            throw LiveReplyError.notOpen
        }
        return request
    }

    private func typedInputs(for request: PresentedRequest,
                             draft answerDraft: RequestDraft,
                             explicitCompatibilityAction: ExactText? = nil) throws -> [TypedInputRecord] {
        try Self.resolvedTypedInputs(for: request, draft: answerDraft,
                                     explicitCompatibilityAction: explicitCompatibilityAction)
    }

    private nonisolated static func resolvedTypedInputs(
        for request: PresentedRequest,
        draft answerDraft: RequestDraft,
        explicitCompatibilityAction: ExactText? = nil
    ) throws -> [TypedInputRecord] {
        switch request.projection {
        case let .sender(sender):
            return try sender.inputs.map { input in
                guard let draft = answerDraft.inputs[input.id] else { throw LiveReplyError.incomplete }
                switch input.kind {
                case let .response(actions):
                    guard let selected = draft.selectedActionID,
                          let action = actions.first(where: { $0.id == selected }) else {
                        throw LiveReplyError.incomplete
                    }
                    switch action.kind {
                    case .value:
                        return .responseValue(input: input.id, action: selected)
                    case .text:
                        return .responseText(input: input.id,
                                             action: selected,
                                             text: draft.textByActionID[selected] ?? ExactText(""))
                    }
                case .text:
                    return .text(input: input.id, text: draft.text ?? ExactText(""))
                case .point:
                    guard let point = draft.effectivePoint else { throw LiveReplyError.incomplete }
                    return .point(input: input.id, point: point)
                }
            }
        case let .compatibility(actions):
            if let explicitCompatibilityAction {
                guard request.informationalSeenStatus == .available,
                      request.informationalSeenStatus != nil,
                      explicitCompatibilityAction == ExactText("seen"),
                      actions.count == 1,
                      let action = actions.first,
                      action.id == explicitCompatibilityAction,
                      action.kind == .value else {
                    throw LiveReplyError.unsupported
                }
                return [.compatibilityValue(action: explicitCompatibilityAction)]
            }
            guard let selected = answerDraft.compatibility.selectedActionID,
                  let action = actions.first(where: { $0.id == selected }) else {
                throw LiveReplyError.incomplete
            }
            switch action.kind {
            case .value:
                return [.compatibilityValue(action: selected)]
            case .text:
                return [.compatibilityText(action: selected,
                                           text: answerDraft.compatibility.textByActionID[selected] ?? ExactText(""))]
            }
        case .unsupported:
            throw LiveReplyError.unsupported
        }
    }

    func startObserving() {
        guard observation == nil else { return }
        observation = Task { @MainActor in
            do {
                let updates = try port.snapshots(context: port.context,
                                                 afterRevision: presentation.revision)
                for try await snapshot in updates {
                    _ = try await adoptForLiveUpdates(snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                observationError = "The local request view could not be refreshed."
                diagnose(.localStore, .projectionRefresh,
                         NativeDiagnosticCauseCode.failureTransition(for: error), error: error)
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    func refreshFromDurableStore() throws {
        let snapshot = try port.observe(context: port.context)
        adopt(snapshot)
    }

    private func clearActionError() {
        guard actionError != nil || actionErrorRequest != nil else { return }
        actionError = nil
        actionErrorRequest = nil
    }

    private func adopt(_ snapshot: PresentationSnapshot) {
        refreshPriorityLevelsProjection()
        let previousRoutingStates = noReplyRoutingStates(for: presentation.requests)
        let locallyReconciledRead = locallyReconciledConversationReadRevisions.remove(snapshot.revision) != nil
        locallyReconciledConversationReadRevisions = Set(
            locallyReconciledConversationReadRevisions.filter { $0 > snapshot.revision })
        if !locallyReconciledRead {
            do {
                conversationThreads = try port.conversations(context: port.context).threads
                conversationProjectionRevision = snapshot.revision
            }
            catch {
                conversationProjectionRevision = nil
                observationError = "The local conversation could not be refreshed."
                diagnose(.localStore, .projectionRefresh, .failed, error: error)
            }
        }
        presentation = snapshot
        reconcileNewMessageArea(snapshot.requests)
        if !locallyReconciledRead { reconcileReplyItemArea() }
        refreshFailedResponseWarnings(for: snapshot.requests)
        recordNoReplyRoutingChanges(from: previousRoutingStates, in: snapshot.requests)
        presentStaleAnswerIfAvailable(in: snapshot)
        if let key = actionErrorRequest,
           let current = snapshot.requests.first(where: { $0.key == key }),
           current.intentReceipt != nil || current.lifecycleStatus != .open {
            clearActionError()
        }
        if let selectedRequestKey,
           !snapshot.requests.contains(where: { $0.key == selectedRequestKey }) {
            self.selectedRequestKey = snapshot.requests.first?.key
        } else if selectedRequestKey == nil {
            self.selectedRequestKey = snapshot.requests.first?.key
        }
        notificationProjectionDidChange?()
    }

    func adoptForLiveUpdates(_ firstSnapshot: PresentationSnapshot) async throws -> Double {
        var snapshot = firstSnapshot
        let port = self.port
        let store = attentionStore
        let context = profileContext
        let account = context.identity.personID
        var mainActorWorkNanoseconds: UInt64 = 0

        while !Task.isCancelled {
            guard presentation.revision <= snapshot.revision else {
                return Double(mainActorWorkNanoseconds) / 1_000_000
            }
            let messageSeed = messageAreaStore?.reconciliationSeed()
            let replySeed = replyAreaStore?.reconciliationSeed()
            let previousRequests = presentation.requests
            let previousWarnings = failedResponseWarnings
            let warningGeneration = failedResponseWarningGeneration
            let diagnosticEvents = diagnostics?.events ?? []
            let shouldRecordNoReplyRouting = diagnostics != nil
            let presentedStaleIDs = presentedStaleAnswerOperationIDs
            let capturedActionErrorRequest = actionErrorRequest
            let updateSnapshot = snapshot
            var mainActorSegmentStartedAt = DispatchTime.now().uptimeNanoseconds
            let preparation = Task.detached(priority: .userInitiated) {
                let conversationThreads = try port.conversations(context: port.context).threads
                let attentionSnapshot = try store.snapshot(context: context)
                let messages = Self.newMessageObservations(for: updateSnapshot.requests)
                let revisions = Dictionary(uniqueKeysWithValues: updateSnapshot.requests.map {
                    ($0.key, $0.requestRevision)
                })
                let messageArea = messageSeed.map { seed in
                    VersionedPreparedNewMessageAreaReconciliation(
                        value: NewMessageAreaStore.prepareReconciliation(
                            ledger: seed.ledger, messages: messages, revisions: revisions,
                            accountScopes: [account]),
                        generation: seed.generation)
                }
                let replyItemArea = replySeed.map { seed in
                    let observations = Self.replyObservations(
                        in: conversationThreads, account: account, ledger: seed.ledger)
                    return VersionedPreparedReplyItemAreaReconciliation(
                        value: ReplyItemAreaStore.prepareReconciliation(
                            ledger: seed.ledger, observations: observations.observations,
                            accountScopes: [account], parentScope: observations.parentScope),
                        generation: seed.generation)
                }
                let failedResponseWarnings = Self.prepareFailedResponseWarnings(
                    previous: previousWarnings, requests: updateSnapshot.requests,
                    attentionSnapshot: attentionSnapshot, diagnosticEvents: diagnosticEvents)
                let previousRoutingStates = Self.noReplyRoutingStates(
                    for: previousRequests, failedResponseWarnings: previousWarnings)
                let currentRoutingStates = Self.noReplyRoutingStates(
                    for: updateSnapshot.requests, failedResponseWarnings: failedResponseWarnings)
                let noReplyRoutingChanges = shouldRecordNoReplyRouting
                    ? Self.noReplyRoutingChanges(from: previousRoutingStates,
                        currentStates: currentRoutingStates, in: updateSnapshot.requests)
                    : []
                let staleAnswerDialog = Self.staleAnswerDialog(
                    in: updateSnapshot, presentedIDs: presentedStaleIDs)
                let requestsByKey = Dictionary(uniqueKeysWithValues: updateSnapshot.requests.map {
                    ($0.key, $0)
                })
                let shouldClearActionError = capturedActionErrorRequest.flatMap { key in
                    requestsByKey[key].map {
                        $0.intentReceipt != nil || $0.lifecycleStatus != .open
                    }
                } ?? false
                return PreparedLivePresentationUpdate(
                    conversationThreads: conversationThreads,
                    messageArea: messageArea, replyItemArea: replyItemArea,
                    failedResponseWarnings: failedResponseWarnings,
                    warningGeneration: warningGeneration,
                    noReplyRoutingChanges: noReplyRoutingChanges,
                    staleAnswerDialog: staleAnswerDialog,
                    requestKeys: Set(updateSnapshot.requests.map(\.key)),
                    firstRequestKey: updateSnapshot.requests.first?.key,
                    actionErrorRequest: capturedActionErrorRequest,
                    shouldClearActionError: shouldClearActionError)
            }
            mainActorWorkNanoseconds += DispatchTime.now().uptimeNanoseconds - mainActorSegmentStartedAt
            let prepared = try await preparation.value
            mainActorSegmentStartedAt = DispatchTime.now().uptimeNanoseconds

            guard presentation.revision <= snapshot.revision else {
                mainActorWorkNanoseconds += DispatchTime.now().uptimeNanoseconds - mainActorSegmentStartedAt
                return Double(mainActorWorkNanoseconds) / 1_000_000
            }
            let locallyReconciledRead = locallyReconciledConversationReadRevisions
                .contains(snapshot.revision)
            let messageSeedIsCurrent = prepared.messageArea.map {
                messageAreaStore?.reconciliationSeed().generation == $0.generation
            } ?? true
            let replySeedIsCurrent = locallyReconciledRead || (prepared.replyItemArea.map {
                replyAreaStore?.reconciliationSeed().generation == $0.generation
            } ?? true)
            guard messageSeedIsCurrent && replySeedIsCurrent &&
                    failedResponseWarningGeneration == prepared.warningGeneration else {
                mainActorWorkNanoseconds += DispatchTime.now().uptimeNanoseconds - mainActorSegmentStartedAt
                let refresh = Task.detached(priority: .userInitiated) {
                    try port.observe(context: port.context)
                }
                snapshot = try await refresh.value
                mainActorSegmentStartedAt = DispatchTime.now().uptimeNanoseconds
                continue
            }

            if let messageArea = prepared.messageArea {
                _ = messageAreaStore?.applyPreparedReconciliation(
                    messageArea.value, basedOn: messageArea.generation)
            }
            if !locallyReconciledRead, let replyItemArea = prepared.replyItemArea {
                _ = replyAreaStore?.applyPreparedReconciliation(
                    replyItemArea.value, basedOn: replyItemArea.generation)
            }
            if locallyReconciledRead {
                locallyReconciledConversationReadRevisions.remove(snapshot.revision)
            } else {
                conversationThreads = prepared.conversationThreads
                conversationProjectionRevision = snapshot.revision
            }
            locallyReconciledConversationReadRevisions = Set(
                locallyReconciledConversationReadRevisions.filter { $0 > snapshot.revision })
            presentation = snapshot
            failedResponseWarnings = prepared.failedResponseWarnings
            failedResponseWarningGeneration &+= 1
            recordNoReplyRoutingChanges(prepared.noReplyRoutingChanges)
            if staleAnswerDialog == nil, let candidate = prepared.staleAnswerDialog,
               !presentedStaleAnswerOperationIDs.contains(candidate.operationID) {
                staleAnswerDialog = candidate
            }
            if prepared.shouldClearActionError,
               actionErrorRequest == prepared.actionErrorRequest {
                clearActionError()
            }
            if selectedRequestKey.map(prepared.requestKeys.contains) != true {
                selectedRequestKey = prepared.firstRequestKey
            }
            notificationProjectionDidChange?()
            mainActorWorkNanoseconds += DispatchTime.now().uptimeNanoseconds - mainActorSegmentStartedAt
            return Double(mainActorWorkNanoseconds) / 1_000_000
        }
        return Double(mainActorWorkNanoseconds) / 1_000_000
    }

    private func refreshFailedResponseWarnings(
        for requests: [PresentedRequest],
        attentionSnapshot suppliedSnapshot: AttentionStoreSnapshot? = nil
    ) {
        let snapshot: AttentionStoreSnapshot
        if let suppliedSnapshot {
            snapshot = suppliedSnapshot
        } else {
            guard let loaded = try? attentionStore.snapshot(context: profileContext) else { return }
            snapshot = loaded
        }
        failedResponseWarnings = Self.prepareFailedResponseWarnings(
            previous: failedResponseWarnings, requests: requests, attentionSnapshot: snapshot,
            diagnosticEvents: diagnostics?.events ?? [])
        failedResponseWarningGeneration &+= 1
    }

    private nonisolated static func prepareFailedResponseWarnings(
        previous: [RequestKey: FailedResponseWarning],
        requests: [PresentedRequest],
        attentionSnapshot snapshot: AttentionStoreSnapshot,
        diagnosticEvents: [NativeClientDiagnosticEvent]
    ) -> [RequestKey: FailedResponseWarning] {
        let submissionsByID = Dictionary(grouping: snapshot.intents.values, by: \.operationID)
            .compactMapValues { $0.first }
        let submissionsByRequest = Dictionary(grouping: snapshot.intents.values, by: \.requestKey)
        let requestsByKey = Dictionary(uniqueKeysWithValues: requests.map { ($0.key, $0) })
        var refreshed = previous

        for (key, warning) in previous {
            guard let retryOperationID = warning.retryOperationID,
                  let retry = submissionsByID[retryOperationID] else { continue }
            switch retry.disposition {
            case .accepted, .terminal:
                refreshed.removeValue(forKey: key)
            case .failed, .unsupported:
                refreshed.removeValue(forKey: key)
            default:
                if let request = requestsByKey[key],
                   request.intentReceipt?.opID == retryOperationID,
                   request.receiptFacts?.ownOutcome == .accepted {
                    refreshed.removeValue(forKey: key)
                }
            }
        }

        for request in requests {
            guard request.informationalSeenStatus == nil,
                  request.staleAnswerRevision == nil else {
                refreshed.removeValue(forKey: request.key)
                continue
            }
            let serverReportedAcceptedResponse = request.inboxStateIsCurrent &&
                (request.lifecycleStatus == .answered || request.lifecycleStatus == .noComment)
            if request.receiptFacts?.ownOutcome == .accepted || serverReportedAcceptedResponse {
                refreshed.removeValue(forKey: request.key)
                continue
            }
            if refreshed[request.key]?.requestRevision != request.requestRevision {
                refreshed.removeValue(forKey: request.key)
            }
            let candidates = (submissionsByRequest[request.key] ?? []).filter {
                ($0.requestRevision ?? 1) == request.requestRevision &&
                    isDefinitiveFailure($0.disposition)
            }

            if request.answerNotDelivered || request.noCommentUnavailable {
                if let failed = failureSubmission(for: request, among: candidates,
                                                  diagnosticEvents: diagnosticEvents) {
                    let retryOperationID = refreshed[request.key].flatMap {
                        $0.failedOperationID == failed.operationID ? $0.retryOperationID : nil
                    }
                    refreshed[request.key] = makeFailedResponseWarning(
                        for: request, submission: failed, retryOperationID: retryOperationID,
                        diagnosticEvents: diagnosticEvents)
                } else if refreshed[request.key]?.requestRevision != request.requestRevision {
                    refreshed[request.key] = makeFailedResponseWarning(
                        for: request, submission: nil, retryOperationID: nil,
                        diagnosticEvents: diagnosticEvents)
                }
                continue
            }

            if let receipt = request.intentReceipt,
               request.receiptFacts?.ownOutcome != .accepted,
               let failed = failureSubmission(for: request,
                    among: candidates.filter { matches(receipt: receipt, submission: $0) },
                    diagnosticEvents: diagnosticEvents) {
                refreshed[request.key] = makeFailedResponseWarning(
                    for: request, submission: failed, retryOperationID: receipt.opID,
                    diagnosticEvents: diagnosticEvents)
                continue
            }
            let serverReportedTerminal = request.inboxStateIsCurrent &&
                request.lifecycleStatus != .open && request.lifecycleStatus != .pending
            if !serverReportedTerminal && request.inboxStateIsCurrent {
                refreshed.removeValue(forKey: request.key)
            }
        }

        return refreshed
    }

    private nonisolated static func failureSubmission(
        for request: PresentedRequest,
        among candidates: [Submission],
        diagnosticEvents: [NativeClientDiagnosticEvent]
    ) -> Submission? {
        guard !candidates.isEmpty else { return nil }
        let candidateIDs = Set(candidates.map(\.operationID))
        for event in diagnosticEvents.reversed()
        where event.area == .answer && event.phase == .originalOperationDelivery &&
            event.transition == .rejected {
            if let operationID = event.operationID, candidateIDs.contains(operationID),
               event.requestRevision == nil || event.requestRevision == request.requestRevision {
                return candidates.first { $0.operationID == operationID }
            }
        }
        if candidates.count == 1 { return candidates.first }
        guard let first = candidates.first,
              candidates.dropFirst().allSatisfy({ Self.matches($0, response: first) }) else { return nil }
        return first
    }

    private nonisolated static func makeFailedResponseWarning(
        for request: PresentedRequest,
        submission: Submission?,
        retryOperationID: UUID?,
        diagnosticEvents: [NativeClientDiagnosticEvent]
    ) -> FailedResponseWarning {
        let answerKind: SubmissionAnswerKind = submission?.isNoComment == true ||
            (submission == nil && request.noCommentUnavailable) ? .noComment : .answer
        return FailedResponseWarning(
            requestRevision: request.requestRevision,
            failedOperationID: submission?.operationID,
            answerKind: answerKind,
            submittedInputs: submission?.typedInputs ?? [],
            answerDraft: submission.flatMap { retryDraft(for: $0, request: request) },
            detail: submission.map { failureDetail(for: $0, diagnosticEvents: diagnosticEvents) }
                ?? "No additional safe failure detail was retained.",
            retryOperationID: retryOperationID)
    }

    private nonisolated static func retryDraft(for submission: Submission,
                                               request: PresentedRequest) -> RequestDraft? {
        let blankInputs: [ExactText: InputDraft]
        if case let .sender(sender) = request.projection {
            blankInputs = Dictionary(uniqueKeysWithValues: sender.inputs.map { ($0.id, InputDraft()) })
        } else {
            blankInputs = [:]
        }
        var draft = RequestDraft(inputs: blankInputs)
        if submission.isNoComment {
            draft.noCommentSelected = true
            return draft
        }

        for input in submission.typedInputs {
            switch input {
            case let .responseValue(inputID, action):
                guard var field = draft.inputs[inputID] else { return nil }
                field.selectedActionID = action
                draft.inputs[inputID] = field
            case let .responseText(inputID, action, text):
                guard var field = draft.inputs[inputID] else { return nil }
                field.selectedActionID = action
                field.textByActionID[action] = text
                draft.inputs[inputID] = field
            case let .text(inputID, text):
                guard var field = draft.inputs[inputID] else { return nil }
                field.text = text
                draft.inputs[inputID] = field
            case let .point(inputID, point):
                guard var field = draft.inputs[inputID] else { return nil }
                field.point = point
                field.horizontalText = ExactText(String(point.x))
                field.verticalText = ExactText(String(point.y))
                draft.inputs[inputID] = field
            case let .compatibilityValue(action):
                draft.compatibility.selectedActionID = action
            case let .compatibilityText(action, text):
                draft.compatibility.selectedActionID = action
                draft.compatibility.textByActionID[action] = text
            }
        }
        guard let rebuilt = try? resolvedTypedInputs(for: request, draft: draft),
              rebuilt == submission.typedInputs else { return nil }
        return draft
    }

    private nonisolated static func failureDetail(
        for submission: Submission,
        diagnosticEvents: [NativeClientDiagnosticEvent]
    ) -> LocalizedStringResource {
        let events = diagnosticEvents.filter { $0.operationID == submission.operationID }
        if submission.isNoComment,
           let responseClass = events.last(where: {
               $0.phase == .noReplyResponseDecode && $0.transition == .completed
           })?.noReplyResponseClass {
            switch responseClass {
            case .unsupportedRefusal:
                return "The app classified the server reply as an unsupported refusal."
            case .serverError:
                if let code = meaningfulFailureCode(in: events) { return failureDescription(for: code) }
                return "The app classified the reply as a server error."
            case .unknownFrame:
                return "The reply did not match a response the app recognizes."
            case .unparseableFrame:
                return "A reply arrived, but the app could not read it."
            case .noResponse:
                return "No reply was recorded."
            default:
                break
            }
        }
        if let code = meaningfulFailureCode(in: events) {
            return failureDescription(for: code)
        }
        return "No additional safe failure detail was retained."
    }

    private nonisolated static func meaningfulFailureCode(in events: [NativeClientDiagnosticEvent]) -> String? {
        events.reversed().compactMap(\.causeCode).first {
            !["answer_not_delivered", "no_comment_unsupported", "unknown_error"].contains($0)
        }
    }

    private nonisolated static func failureDescription(for code: String) -> LocalizedStringResource {
        switch code {
        case "server_invalid_request": "The server reported that the request was invalid."
        case "server_revision_mismatch": "The server reported that the message revision did not match."
        case "server_unauthorized": "The server did not authorize the request."
        case "server_forbidden": "The server did not allow the request."
        case "server_not_found": "The server could not find the requested item."
        case "server_request_closed": "The server reported that the request was closed."
        case "server_conflict": "The server reported a conflict."
        case "server_expired": "The server reported that the request had expired."
        case "server_too_large": "The server reported that the response was too large."
        case "server_upload_discarded": "The server reported that an uploaded file was discarded."
        case "unknown_server_reason": "The server returned a reason the app does not recognize."
        case "unexpected_relay_frame", "unknown_no_comment_response_frame":
            "The reply did not match a response the app recognizes."
        case "relay_server_rejected": "The server rejected the response."
        default: "The app recorded error code \(code)."
        }
    }

    private nonisolated static func isDefinitiveFailure(_ disposition: IntentDisposition) -> Bool {
        switch disposition {
        case .failed, .unsupported: true
        default: false
        }
    }

    private nonisolated static func matches(receipt: IntentReceipt,
                                            warning: FailedResponseWarning) -> Bool {
        receipt.inputs == warning.submittedInputs &&
            (receipt.answerKind ?? .answer) == warning.answerKind
    }

    private nonisolated static func matches(receipt: IntentReceipt, submission: Submission) -> Bool {
        receipt.inputs == submission.typedInputs &&
            (receipt.answerKind ?? .answer) == (submission.answerKind ?? .answer)
    }

    private nonisolated static func matches(_ candidate: Submission, response: Submission) -> Bool {
        candidate.typedInputs == response.typedInputs &&
            (candidate.answerKind ?? .answer) == (response.answerKind ?? .answer)
    }

    private func noReplyRoutingStates(for requests: [PresentedRequest]) -> [RequestKey: NoReplyRoutingState] {
        Self.noReplyRoutingStates(for: requests, failedResponseWarnings: failedResponseWarnings)
    }

    private nonisolated static func noReplyRoutingStates(
        for requests: [PresentedRequest],
        failedResponseWarnings: [RequestKey: FailedResponseWarning]
    ) -> [RequestKey: NoReplyRoutingState] {
        var states: [RequestKey: NoReplyRoutingState] = [:]
        for request in requests {
            let isNoReply = request.intentReceipt?.answerKind == .noComment ||
                request.lifecycleStatus == .noComment || request.noCommentUnavailable
            let hasKnownDeliveryFailure = request.informationalSeenStatus == nil &&
                request.staleAnswerRevision == nil &&
                (failedResponseWarnings[request.key]?.requestRevision == request.requestRevision ||
                 request.answerNotDelivered || request.noCommentUnavailable)
            let hasDeliveryWarning = hasKnownDeliveryFailure || request.staleAnswerRevision != nil
            let hasUnconfirmedOwnSubmission = request.intentReceipt != nil &&
                request.receiptFacts?.ownOutcome == .unconfirmed &&
                request.lifecycleStatus != .pending
            let serverReportedFinalResponse = request.inboxStateIsCurrent &&
                (request.lifecycleStatus == .answered || request.lifecycleStatus == .noComment)
            let hasAcceptedOwnSubmission = request.receiptFacts?.ownOutcome == .accepted
            let receiptStatus = request.answerNotDelivered ? .some(InboxResponseReceiptStatus.failed) :
                InboxRequestRow.responseReceiptStatus(request.intentReceipt,
                    hasUnconfirmedOutcome: hasUnconfirmedOwnSubmission,
                    serverReportedFinalResponse: serverReportedFinalResponse,
                    hasAcceptedOwnSubmission: hasAcceptedOwnSubmission)
            let hasFailedResponse = receiptStatus == .failed || hasDeliveryWarning
            let hasUserAction = receiptStatus == .pendingOrAccepted ||
                request.lifecycleStatus == .answered || request.lifecycleStatus == .noComment
            let belongsToReplied = !hasFailedResponse &&
                (hasUserAction || request.informationalSeenStatus == .pending ||
                 request.informationalSeenStatus == .confirmed)
            let route = isNoReply
                ? (belongsToReplied ? NativeDiagnosticNoReplyRoute.replied : .inbox)
                : nil
            states[request.key] = NoReplyRoutingState(requestRevision: request.requestRevision,
                isNoReply: isNoReply, route: route)
        }
        return states
    }

    private func recordNoReplyRoutingChanges(from previousStates: [RequestKey: NoReplyRoutingState],
                                             in requests: [PresentedRequest]) {
        recordNoReplyRoutingChanges(from: previousStates,
            currentStates: Self.noReplyRoutingStates(for: requests,
                failedResponseWarnings: failedResponseWarnings), in: requests)
    }

    private func recordNoReplyRoutingChanges(from previousStates: [RequestKey: NoReplyRoutingState],
                                             currentStates: [RequestKey: NoReplyRoutingState],
                                             in requests: [PresentedRequest]) {
        recordNoReplyRoutingChanges(Self.noReplyRoutingChanges(from: previousStates,
            currentStates: currentStates, in: requests))
    }

    private func recordNoReplyRoutingChanges(_ changes: [PreparedNoReplyRoutingChange]) {
        guard let diagnostics else { return }
        for change in changes {
            diagnostics.recordNoReplyRoutingIfChanged(request: change.request,
                revision: change.revision, operationID: change.operationID, route: change.route)
        }
    }

    private nonisolated static func noReplyRoutingChanges(
        from previousStates: [RequestKey: NoReplyRoutingState],
        currentStates: [RequestKey: NoReplyRoutingState],
        in requests: [PresentedRequest]
    ) -> [PreparedNoReplyRoutingChange] {
        var changes: [PreparedNoReplyRoutingChange] = []
        for request in requests {
            // A row newly appearing in a projection may be old paged history, not
            // a routing transition observed by this client.
            guard let previous = previousStates[request.key],
                  let current = currentStates[request.key], current.isNoReply,
                  let route = current.route else { continue }
            let changed = previous.requestRevision != current.requestRevision ||
                !previous.isNoReply || previous.route != route
            guard changed else { continue }
            changes.append(PreparedNoReplyRoutingChange(request: request.key,
                revision: request.requestRevision,
                operationID: request.intentReceipt?.answerKind == .noComment
                    ? request.intentReceipt?.opID : nil,
                route: route))
        }
        return changes
    }

    private func presentStaleAnswerIfAvailable(in snapshot: PresentationSnapshot) {
        guard staleAnswerDialog == nil,
              let prepared = Self.staleAnswerDialog(in: snapshot,
                  presentedIDs: presentedStaleAnswerOperationIDs) else { return }
        staleAnswerDialog = prepared
    }

    private nonisolated static func staleAnswerDialog(
        in snapshot: PresentationSnapshot,
        presentedIDs: Set<UUID>
    ) -> StaleAnswerDialog? {
        guard let stale = snapshot.requests.first(where: { request in
            guard let notice = request.staleAnswerRevision else { return false }
            return !presentedIDs.contains(notice.operationID)
        }), let notice = stale.staleAnswerRevision else { return nil }
        return StaleAnswerDialog(operationID: notice.operationID,
            requestKey: stale.key, submittedRevision: notice.submittedRevision,
            currentRevision: notice.currentRevision,
            title: stale.title?.rawValue ?? "Message",
            body: stale.body?.rawValue ?? "")
    }

    private func discussionOperationID(for request: RequestKey, revision: UInt64) -> UUID? {
        switch conversationDraft(for: request, revision: revision).disposition {
        case let .submitting(id), let .outcomeUnknown(id), let .acceptedPendingReplay(id, _): id
        default: nil
        }
    }

    private func diagnose(_ area: NativeDiagnosticArea,
                          _ phase: NativeDiagnosticPhase,
                          _ transition: NativeDiagnosticTransition,
                          error: Error? = nil,
                          causeCode: String? = nil,
                          operationID: UUID? = nil,
                          request: RequestKey? = nil,
                          revision: UInt64? = nil,
                          receiptState: NativeDiagnosticReceiptState? = nil) {
        guard permitsDelivery else { return }
        diagnostics?.record(area: area, phase: phase, transition: transition, error: error,
            causeCode: causeCode, operationID: operationID, request: request,
            requestRevision: revision, receiptState: receiptState)
    }
}

enum LiveReplyError: Error {
    case localExample
    case disconnected
    case notOpen
    case incomplete
    case unsupported
}

extension AttentionTier {
    var inboxRowStyleTier: InboxAttentionTier {
        switch self {
        case .top: .top
        case .middle: .middle
        case .low: .low
        }
    }
}
