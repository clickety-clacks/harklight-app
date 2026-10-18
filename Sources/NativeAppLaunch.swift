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
    private(set) var selectedArchivedAccount: NativeAccountDeparture?
    private(set) var selectedArchivedPresentation: LivePresentationStore?
    private(set) var archiveCatalogWarning: String?
    private(set) var isShowingDisconnectedArchive = false
    private(set) var disconnectMessage: String?
    private(set) var isDisconnectBusy = false
    private(set) var endpointMigrationMessage: String?
    private(set) var isEndpointMigrationBusy = false
    let guidedJoin: NativeGuidedJoinCoordinator
    let diagnostics: NativeClientDiagnosticJournal
    let notificationRouter: NativeNotificationRouter
    private(set) var notificationNavigation: NativeInboxNavigation?
    private(set) var notificationNavigationMessage: String?
    @ObservationIgnored private var notificationSynchronized = false
    @ObservationIgnored private var notificationRefreshFinished = false
    @ObservationIgnored private var handledNotificationSerial: UInt64?
    @ObservationIgnored private var didFinishRestoring = false
    @ObservationIgnored private let refreshOperation: @MainActor () async -> NativeRelayRefreshResult

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
         refreshOperation: @escaping @MainActor () async -> NativeRelayRefreshResult = {
             await NativeRelayLifecycle.shared.refreshResultFromTrustedRelay()
         }) {
        let fixture = arguments.contains("--reset-attention-fixture") || arguments.contains("--attention-fixture")
        let diagnostics = NativeClientDiagnosticJournal()
        self.diagnostics = diagnostics
        self.notificationRouter = notificationRouter
        self.refreshOperation = refreshOperation
        didFinishRestoring = initialState != nil
        enrollment = enrollmentStore ?? NativeEnrollmentStore()
        let joinStore = suppliedJoinStore ?? NativeGuidedJoinStore()
        guidedJoinStore = joinStore
        activeEnrollmentRecord = initialEnrollmentRecord
        archivedAccountDepartures = initialArchivedDepartures
        let savedDeparture = fixture ? nil : (try? joinStore.departure())
        let standaloneDeparture = savedDeparture.flatMap { $0.replacement == nil ? $0 : nil }
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
            disconnectedAccount = standaloneDeparture
        } else {
            state = .enrollmentRequired
        }
        guidedJoin.connectApproved = { [weak self] record in
            guard let self else { return false }
            let material = try self.enrollment.material(from: record)
            self.activeEnrollmentRecord = record
            try await self.activate(material)
            let epoch = self.activationGeneration
            let connect = await NativeRelayLifecycle.shared.confirmForegroundProgress(for: material.context) { [weak self] progress in
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
            let hasNewRegistration = departure.removed &&
                ((attempt.map { $0.deviceID != departure.record.deviceID } ?? false) ||
                 (active.map { $0.isApproved && $0.deviceID != departure.record.deviceID } ?? false))
            if hasNewRegistration {
                if let archive = try? makeDisconnectedPresentation(for: departure) {
                    archive.enterReadOnlyMode()
                    disconnectedArchive = archive
                    state = .disconnected(archive)
                }
                disconnectMessage = nil
                activeEnrollmentRecord = active ?? nil
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
        guard !isDisconnectBusy, !isEndpointMigrationBusy, case let .live(presentation) = state,
              let record = try? enrollment.load(), record.isApproved else { return }
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
            endpointMigrationMessage = "This saved enrollment cannot use the approved server address. Your current connection is unchanged."
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
            endpointMigrationMessage = "The approved server address is saved. This account, device identity, trust certificate and local history are unchanged."
            Task { await refreshLive() }
        } catch {
            guard activationGeneration == generation else { return }
            endpointMigrationMessage = "Gibson could not be verified, so Harklight kept the existing connection and server address. Try again when the new endpoint is available."
        }
    }

    func retryDisconnectRemoval() async {
        guard !isDisconnectBusy, case .disconnected = state,
              let departure = disconnectedAccount,
              departure.replacement == nil, !departure.removed else { return }
        isDisconnectBusy = true
        defer { isDisconnectBusy = false }
        disconnectMessage = nil
        await NativeRelayLifecycle.shared.deactivate()
        do {
            try await guidedJoin.removeStandaloneAccount()
            refreshArchivedAccounts()
            disconnectedAccount = try guidedJoinStore.departure() ?? departure
            disconnectMessage = disconnectedStatusMessage(for: disconnectedAccount ?? departure,
                                                         presentation: disconnectedStore)
        } catch {
            refreshArchivedAccounts()
            disconnectedAccount = (try? guidedJoinStore.departure()) ?? departure
            disconnectMessage = disconnectedStatusMessage(for: disconnectedAccount ?? departure,
                                                         presentation: disconnectedStore)
        }
    }

    func beginReconnect() {
        guard !isDisconnectBusy, disconnectedAccount?.removed == true else { return }
        guidedJoin.beginReconnect()
    }

    func cancelReconnect() {
        guard !isDisconnectBusy, case .disconnected = state else { return }
        guidedJoin.returnToDisconnectedAccount()
    }

    func receiveInvitation(_ url: URL) async {
        if case .disconnected = state, let departure = disconnectedAccount {
            guard departure.removed else {
                disconnectMessage = "Removal is still unconfirmed. Retry it with the original server before connecting again."
                return
            }
            guidedJoin.beginReconnect()
        }
        await guidedJoin.receive(url)
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
            archiveCatalogWarning = nil
        } catch {
            archiveCatalogWarning = "Some previously disconnected accounts could not be loaded. Their saved files have not been deleted."
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
        return try LivePresentationStore(disconnectedStore: store, context: context)
    }

    private var disconnectedStore: LivePresentationStore? {
        if case let .disconnected(presentation) = state { return presentation }
        return nil
    }

    private func disconnectedStatusMessage(for departure: NativeAccountDeparture,
                                           presentation: LivePresentationStore?) -> String {
        let account = departure.record.accountDisplayName ?? "this account"
        let server = departure.record.serverDisplayName ?? departure.record.host
        if departure.removed {
            return "This phone is disconnected from \(account) on \(server). Saved messages, drafts and receipts remain read-only on this phone. Other devices and server history are unchanged."
        }
        let pendingAnswers = presentation?.presentation.requests.filter { $0.lifecycleStatus == .pending }.count ?? 0
        let pending = pendingAnswers > 0
            ? " Pending answers are no longer retrying; some may already have reached the server."
            : ""
        return "This phone is disconnected locally from \(account) on \(server), but server removal is not confirmed. Its original identity and saved messages, drafts and receipts are kept for retry.\(pending)"
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
        let persistence = try FileAttentionStatePersistence.applicationSupport()
        let fileStorage = try ConversationFileStorage(identity: installation.context.identity)
        let store = try AttentionDomainStore(context: installation.context, persistence: persistence,
                                             conversationFileReferences: fileStorage)
        let presentation = try LivePresentationStore(store: store, context: installation.context,
                                                     diagnostics: diagnostics)
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
        presentation.notificationProjectionDidChange = { [weak self] in self?.resolveNotificationNavigation() }
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

    func refreshLive() async {
        guard case let .live(presentation) = state, !presentation.isLocalExample else { return }
        notificationSynchronized = false
        notificationRefreshFinished = false
        let result = await refreshOperation()
        guard case let .live(current) = state, current === presentation else { return }
        presentation.applyRefreshResult(result)
        notificationRefreshFinished = true
        notificationSynchronized = result.relayConfirmed && result.confirmedContext == presentation.notificationContext
        resolveNotificationNavigation()
    }

    func handleNotification() async {
        guard didFinishRestoring, let intent = notificationRouter.intent,
              handledNotificationSerial != intent.serial else { return }
        handledNotificationSerial = intent.serial
        notificationSynchronized = false
        // Leave any archive surface; never activate an archive from a locator.
        selectedArchivedAccount = nil
        selectedArchivedPresentation = nil
        isShowingDisconnectedArchive = false
        notificationNavigation = NativeInboxNavigation(serial: intent.serial, request: nil)
        notificationNavigationMessage = intent.locator == nil ? nil : "Opening notification: checking the current message state."
        if case let .live(presentation) = state, !presentation.isReadOnly, !presentation.isLocalExample {
            presentation.selectRequest(nil)
            if let record = try? enrollment.load(),
               intent.locator?.profile(in: [record]) != nil {
                _ = notificationRouter.resolve(records: [record], context: presentation.notificationContext,
                    requests: [], synchronized: false)
            }
            presentation.notificationProjectionDidChange = { [weak self] in self?.resolveNotificationNavigation() }
            await refreshLive()
        } else {
            notificationRouter.fallback()
            notificationNavigationMessage = nil
        }
    }

    func resolveNotificationNavigation() {
        guard notificationRefreshFinished, let intent = notificationRouter.intent,
              handledNotificationSerial == intent.serial,
              case let .live(presentation) = state, !presentation.isReadOnly, !presentation.isLocalExample else { return }
        let record: NativeEnrollmentRecord?
        do { record = try enrollment.load() }
        catch {
            notificationNavigationMessage = "The notification's account could not be checked. Showing the current inbox."
            return
        }
        if let key = notificationRouter.resolve(records: record.map { [$0] } ?? [],
            context: presentation.notificationContext, requests: presentation.presentation.requests,
            synchronized: notificationSynchronized) {
            presentation.selectRequest(key)
            notificationNavigation = NativeInboxNavigation(serial: intent.serial, request: key)
            notificationNavigationMessage = nil
            notificationRouter.consumed()
        } else if notificationRouter.intent?.locator != nil {
            presentation.selectRequest(nil)
            notificationNavigationMessage = notificationSynchronized
                ? "The notification's exact message is not loaded. Showing the current inbox; it can open when normally loaded."
                : "The notification's current state is not confirmed. Showing the inbox while connection recovery is pending."
        } else {
            presentation.selectRequest(nil)
            notificationNavigationMessage = nil
            notificationRouter.consumed()
        }
    }

    func retryForegroundConnection() async {
        guard case .live = state else { return }
        await guidedJoin.retryApprovedConnection()
    }
}

/// C's admitted presentation is the only live view feed. Its revision stream
/// reflects replay visibility and durable edits without a second H journal.
@MainActor
@Observable
final class LivePresentationStore {
    private(set) var conversationThreads: [RequestKey: ConversationThread]
    private(set) var conversationError: String?
    private(set) var isSendingDiscussion = false
    private(set) var retryingCleanupRequests: Set<RequestKey> = []
    private(set) var presentation: PresentationSnapshot
    private(set) var selectedRequestKey: RequestKey?
    private(set) var observationError: String?
    private(set) var actionError: String?
    private var actionErrorRequest: RequestKey?
    var notificationWarning: String?
    private(set) var pushRegistrationWarning: String?
    var connectionWarning: String?

    @ObservationIgnored private let port: AttentionDomainPort
    private let permitsDelivery: Bool
    @ObservationIgnored private let conversationFiles: ConversationFileStorage?
    @ObservationIgnored private let profileContext: ProfileContext
    var notificationContext: ProfileContext { profileContext }
    @ObservationIgnored var notificationProjectionDidChange: (() -> Void)?
    private(set) var isReadOnly: Bool
    @ObservationIgnored private let diagnostics: NativeClientDiagnosticJournal?
    @ObservationIgnored private var observation: Task<Void, Never>?

    convenience init(store: AttentionDomainStore, context: ProfileContext,
                     diagnostics: NativeClientDiagnosticJournal? = nil) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: true, diagnostics: diagnostics)
    }

    /// Uses the ordinary projection/edit path, but cannot mint an intent or retry transport.
    convenience init(localFixtureStore store: AttentionDomainStore, context: ProfileContext) throws {
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false, isReadOnly: false, diagnostics: nil)
    }

    convenience init(disconnectedStore store: AttentionDomainStore, context: ProfileContext) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false, isReadOnly: true, diagnostics: nil)
    }

    private init(store: AttentionDomainStore, context: ProfileContext,
                 permitsDelivery: Bool, isReadOnly: Bool = false,
                 diagnostics: NativeClientDiagnosticJournal? = nil) throws {
        self.permitsDelivery = permitsDelivery
        self.profileContext = context
        self.isReadOnly = isReadOnly
        self.diagnostics = diagnostics
        _ = try store.snapshot(context: context)
        let port = AttentionDomainPort(store: store)
        let snapshot = try port.observe(context: port.context)
        self.port = port
        self.presentation = snapshot
        self.conversationThreads = try port.conversations(context: port.context).threads
        self.conversationFiles = context.transportMode == .relay ? try ConversationFileStorage(identity: context.identity) : nil
        self.selectedRequestKey = snapshot.requests.first?.key
    }

    /// Read-only real account archives are offline relay data, not fictional
    /// local examples. Delivery permission and data provenance are separate.
    var isLocalExample: Bool { profileContext.transportMode == .fixture }

    func hasAcceptedUpdate(for key: RequestKey) -> Bool {
        conversationThreads[key]?.acceptedUpdates.isEmpty == false
    }
    func isRetracted(_ key: RequestKey) -> Bool { conversationThreads[key]?.isRetracted == true }

    func conversation(for key: RequestKey) -> ConversationThread? { conversationThreads[key] }

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

    func updateConversation(for key: RequestKey, revision: UInt64, text: String? = nil,
                            files: [ConversationFile]? = nil) {
        guard !isReadOnly else { return }
        do {
            if let text, files == nil {
                guard var thread = conversationThreads[key] else { throw ConversationError.missingRequest }
                let binding = ConversationBinding(request: key, revision: revision)
                let updated = try port.updateConversationDraftText(ExactText(text), for: binding,
                    context: port.context)
                thread.drafts[revision] = updated
                conversationThreads[key] = thread
                conversationError = nil
                return
            }
            var draft = conversationDraft(for: key, revision: revision)
            if let text { draft.text = ExactText(text) }
            if let files { draft.files = files }
            draft.disposition = .saved
            try port.saveConversationDraft(draft, context: port.context)
            try refreshFromDurableStore()
            conversationError = nil
        } catch {
            conversationError = "Your discussion edit could not be saved. Its earlier saved draft is retained."
            diagnose(.localStore, .draftSave, .failed, error: error,
                     request: key, revision: revision)
        }
    }

    /// The ordinary inbox calls this only for explicit selection/back navigation.
    /// Rebuilding a detail or losing transport never calls it.
    func navigateMessage(from previous: RequestKey?, to next: RequestKey?) {
        guard previous != next else { return }
        if !isReadOnly, let previous {
            do {
                let pending = try port.abandonConversationUploads(for: previous, context: port.context)
                try refreshFromDurableStore()
                if !pending.isEmpty {
                    if permitsDelivery { Task { await retryUploadCleanup(for: previous) } }
                    else {
                        try port.markConversationCleanupUnknown(for: previous,
                            reason: ExactText("Local example: no service is contacted"), context: port.context)
                        try refreshFromDurableStore()
                    }
                }
            } catch {
                conversationError = "Upload cleanup could not be saved. Return to this message and retry; deletion is not confirmed."
                diagnose(.upload, .uploadCleanup,
                         NativeDiagnosticCauseCode.failureTransition(for: error), error: error,
                         request: previous)
            }
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

    func sendDiscussion(for key: RequestKey, revision: UInt64) {
        guard !isReadOnly else { return }
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
                        try refreshFromDurableStore()
                        switch result {
                        case .accepted: conversationError = nil
                        case let .rejected(reason): conversationError = "Not delivered: " + reason.rawValue + ". Draft and files retained."
                        case .unresolved: conversationError = "Submission unconfirmed. Retry uses the same saved operation."
                        }
                    } catch {
                        diagnose(.conversation, .discussionSubmission,
                                 NativeDiagnosticCauseCode.unresolvedTransition(for: error), error: error,
                                 operationID: discussionOperationID(for: key, revision: revision),
                                 request: key, revision: revision, receiptState: .unknown)
                        do { try refreshFromDurableStore() }
                        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error,
                                         request: key, revision: revision) }
                        if (error as? ConversationError) == .emptyDraft {
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
        presentation.requests.map {
            let lifecycle = isRetracted($0.key) ? "Retracted" :
                String(localized: LiveLifecycleTitle($0.lifecycleStatus).label)
            var statusParts: [String] = []
            if hasAcceptedUpdate(for: $0.key) { statusParts.append("Updated") }
            statusParts.append(lifecycle)
            if let seenStatus = $0.informationalSeenStatus {
                statusParts.append(informationalSeenRowStatus(seenStatus))
            }
            return InboxRequestRow(key: $0.key, title: $0.title?.rawValue ?? $0.key.senderID.rawValue,
                sender: $0.senderAttribution,
                status: statusParts.joined(separator: " · "),
                bodyText: $0.body?.rawValue ?? "",
                symbol: $0.informationalSeenStatus == nil ? "text.bubble" : "info.circle",
                isResolved: $0.isResolved)
        }
    }

    private func informationalSeenRowStatus(_ status: InformationalSeenStatus) -> String {
        switch status {
        case .available: "Seen available"
        case .pending: "Seen pending"
        case .confirmed: "Seen confirmed"
        case .resolvedWithoutSeen: "Seen not confirmed"
        }
    }

    var openRequests: [PresentedRequest] {
        presentation.requests.filter { $0.lifecycleStatus == .open || $0.lifecycleStatus == .pending }
    }

    var resolvedRequests: [PresentedRequest] {
        presentation.requests.filter { $0.lifecycleStatus != .open && $0.lifecycleStatus != .pending }
    }

    var selectedRequest: PresentedRequest? {
        presentation.requests.first { $0.key == selectedRequestKey }
    }

    func request(for key: RequestKey) -> PresentedRequest? {
        presentation.requests.first { $0.key == key }
    }

    func selectRequest(_ key: RequestKey?) {
        guard let key else { selectedRequestKey = nil; clearActionError(); return }
        guard presentation.requests.contains(where: { $0.key == key }) else { return }
        if selectedRequestKey != key { clearActionError() }
        selectedRequestKey = key
    }

    func selectAction(_ action: ExactText, input: ExactText?, for key: RequestKey) {
        editDraft(for: key) { draft in
            if let input {
                draft.inputs[input]?.selectedActionID = action
            } else {
                draft.compatibility.selectedActionID = action
            }
        }
    }

    func updateText(_ text: String, input: ExactText, action: ExactText?, for key: RequestKey) {
        editDraft(for: key) { draft in
            if let action {
                draft.inputs[input]?.textByActionID[action] = ExactText(text)
            } else {
                draft.inputs[input]?.text = ExactText(text)
            }
        }
    }

    func updateCompatibilityText(_ text: String, action: ExactText, for key: RequestKey) {
        editDraft(for: key) { draft in
            draft.compatibility.textByActionID[action] = ExactText(text)
        }
    }

    func setPoint(_ point: PointValue, input: ExactText, for key: RequestKey) {
        editDraft(for: key) { draft in
            draft.inputs[input]?.point = point
            draft.inputs[input]?.horizontalText = ExactText(String(point.x))
            draft.inputs[input]?.verticalText = ExactText(String(point.y))
        }
    }

    func updateLocalExampleAnnotation(_ text: String, point: PointValue?, for key: RequestKey) {
        guard !permitsDelivery, !isReadOnly else { return }
        let input = ExactText("point")
        editDraft(for: key) { draft in
            draft.inputs[ExactText("annotation")]?.text = ExactText(text)
            draft.inputs[input]?.point = point
            draft.inputs[input]?.horizontalText = point.map { ExactText(String($0.x)) }
            draft.inputs[input]?.verticalText = point.map { ExactText(String($0.y)) }
        }
    }

    /// C composes the exact answer and durably stores one original operation
    /// before any network send. A persisted receipt prevents a second intent.
    @discardableResult
    func submit(_ key: RequestKey, explicitCompatibilityAction: ExactText? = nil) throws -> IntentReceipt {
        guard !isReadOnly else { throw LiveReplyError.disconnected }
        guard permitsDelivery else { throw LiveReplyError.localExample }
        let request = try inspectedRequest(key)
        guard request.lifecycleStatus == .open,
              request.intentReceipt == nil,
              let selector = request.selector else {
            throw LiveReplyError.notOpen
        }
        let records = try typedInputs(for: request, explicitCompatibilityAction: explicitCompatibilityAction)
        let receipt = try port.submit(SubmitIntent(context: port.context,
                                                   selector: selector,
                                                   intentID: UUID(),
                                                   inputs: records))
        do { try refreshFromDurableStore() }
        catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
        clearActionError()
        return receipt
    }

    func submitFromUser(_ key: RequestKey, explicitCompatibilityAction: ExactText? = nil) {
        guard permitsDelivery, !isReadOnly else { return }
        do {
            _ = try submit(key, explicitCompatibilityAction: explicitCompatibilityAction)
            retryPendingDelivery()
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
            } else {
                actionErrorRequest = key
                if let current, current.lifecycleStatus != .open {
                    actionError = "This request is no longer open for an answer."
                } else if case .some(.incomplete) = error as? LiveReplyError {
                    actionError = "Complete the response before sending your answer."
                } else {
                    // A thrown save/refresh is not proof of non-delivery.
                    actionError = "Your answer could not be confirmed. Check its saved status before trying again."
                }
            }
        }
    }

    func retryPendingDelivery() {
        guard permitsDelivery, !isReadOnly else { return }
        Task {
            let result = await NativeRelayLifecycle.shared.refreshAfterAnswerStored()
            applyRefreshResult(result)
        }
    }

    func applyRefreshResult(_ result: NativeRelayRefreshResult) {
        connectionWarning = result.relayConfirmed ? nil :
            "The relay could not be refreshed. Saved requests, answers and confirmed receipts remain on this device."
        if result.relayConfirmed {
            pushRegistrationWarning = result.pushRegistration == .unconfirmed ?
                "Notification setup could not be confirmed. Your answer status is shown with each request." : nil
        }
    }

    private func editDraft(for key: RequestKey, _ change: (inout RequestDraft) -> Void) {
        guard !isReadOnly else { return }
        do {
            let request = try inspectedRequest(key)
            guard request.lifecycleStatus == .open,
                  request.intentReceipt == nil,
                  let selector = request.selector else { throw LiveReplyError.notOpen }
            var draft = request.draft
            change(&draft)
            try port.saveDraft(context: port.context, selector: selector, completeDraft: draft)
            do { try refreshFromDurableStore() }
            catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
            clearActionError()
        } catch {
            diagnose(.localStore, .draftSave, .failed, error: error, request: key)
            actionErrorRequest = key
            actionError = "Your edit could not be saved."
            do { try refreshFromDurableStore() }
            catch { diagnose(.localStore, .projectionRefresh, .failed, error: error, request: key) }
        }
    }

    func enterReadOnlyMode() {
        isReadOnly = true
        observation?.cancel()
        observation = nil
    }

    private func inspectedRequest(_ key: RequestKey) throws -> PresentedRequest {
        guard let request = try port.inspect(context: port.context, request: key).requests.first else {
            throw LiveReplyError.notOpen
        }
        return request
    }

    private func typedInputs(for request: PresentedRequest,
                             explicitCompatibilityAction: ExactText? = nil) throws -> [TypedInputRecord] {
        switch request.projection {
        case let .sender(sender):
            return try sender.inputs.map { input in
                guard let draft = request.draft.inputs[input.id] else { throw LiveReplyError.incomplete }
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
            guard let selected = request.draft.compatibility.selectedActionID,
                  let action = actions.first(where: { $0.id == selected }) else {
                throw LiveReplyError.incomplete
            }
            switch action.kind {
            case .value:
                return [.compatibilityValue(action: selected)]
            case .text:
                return [.compatibilityText(action: selected,
                                           text: request.draft.compatibility.textByActionID[selected] ?? ExactText(""))]
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
                    adopt(snapshot)
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
        actionError = nil
        actionErrorRequest = nil
    }

    private func adopt(_ snapshot: PresentationSnapshot) {
        do { conversationThreads = try port.conversations(context: port.context).threads }
        catch {
            observationError = "The local conversation could not be refreshed."
            diagnose(.localStore, .projectionRefresh, .failed, error: error)
        }
        presentation = snapshot
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
