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
    let hasPriorAppState: Bool
    let guidedJoin: NativeGuidedJoinCoordinator
    let diagnostics: NativeClientDiagnosticJournal
    let notificationRouter: NativeNotificationRouter
    private(set) var notificationNavigation: NativeInboxNavigation?
    private(set) var notificationNavigationMessage: String?
    @ObservationIgnored private var notificationSynchronized = false
    @ObservationIgnored private var notificationRefreshFinished = false
    @ObservationIgnored private var handledNotificationSerial: UInt64?
    @ObservationIgnored private var pendingMessageDeepLink: NativeMessageDeepLink?
    @ObservationIgnored private var didFinishRestoring = false
    @ObservationIgnored private var foregroundActivationPushCheckPending = false
    @ObservationIgnored private let refreshOperation: @MainActor (Bool) async -> NativeRelayRefreshResult

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
         }) {
        let fixture = arguments.contains("--reset-attention-fixture") || arguments.contains("--attention-fixture")
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
        didFinishRestoring = initialState != nil
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
        if case .disconnected = state, let departure = disconnectedAccount {
            guard departure.removed else {
                disconnectMessage = "Removal is still unconfirmed. Retry it with the original server before connecting again."
                return
            }
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
        presentation.selectRequest(key)
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
        let account = departure.record.savedAccountName ?? "this account"
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
        resolveNotificationNavigation()
        resolveMessageDeepLink(synchronized: notificationSynchronized)
    }

    private func resolveMessageDeepLink(synchronized: Bool) {
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
            notificationNavigationMessage = synchronized
                ? "This message was never sent to this Harklight inbox."
                : "This message hasn't arrived yet. Harklight will keep checking while it's open."
        }
    }

    private func takeForegroundActivationPushCheck() -> Bool {
        let shouldCheck = foregroundActivationPushCheckPending
        foregroundActivationPushCheckPending = false
        return shouldCheck
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
            notificationNavigationMessage = "Could not check this notification's account."
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
                ? "This notification's message has not loaded yet."
                : "Could not verify notification. Checking again while open."
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
struct StaleAnswerDialog: Identifiable, Equatable {
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

@MainActor
@Observable
final class LivePresentationStore {
    private struct DraftBufferKey: Hashable {
        let request: RequestKey
        let revision: UInt64
    }

    private(set) var conversationThreads: [RequestKey: ConversationThread]
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
    private let permitsDelivery: Bool
    @ObservationIgnored private let conversationFiles: ConversationFileStorage?
    @ObservationIgnored private let profileContext: ProfileContext
    var notificationContext: ProfileContext { profileContext }
    @ObservationIgnored var notificationProjectionDidChange: (() -> Void)?
    @ObservationIgnored var confirmedRelayRefresh: (() -> Void)?
    private(set) var isReadOnly: Bool
    @ObservationIgnored private let diagnostics: NativeClientDiagnosticJournal?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var pendingDrafts: [DraftBufferKey: RequestDraft] = [:]
    @ObservationIgnored private var pendingDraftSaveTasks: [DraftBufferKey: Task<Void, Never>] = [:]
    // Clearing a retracted row is list state on this device only: no frame is
    // sent and the retracted record stays intact in the durable store.
    private(set) var clearedRetractions: Set<RequestKey> = []
    @ObservationIgnored private let clearedRetractionDefaults: UserDefaults
    private static let clearedRetractionsDefaultsKey = "harklight.cleared-retracted-requests"
    @ObservationIgnored private var presentedStaleAnswerOperationIDs = Set<UUID>()

    convenience init(store: AttentionDomainStore, context: ProfileContext,
                     conversationAvailability: NativeConversationAvailability = NativeRelayLifecycle.shared.conversationAvailability,
                     diagnostics: NativeClientDiagnosticJournal? = nil,
                     clearedRetractionDefaults: UserDefaults = .standard) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: true, diagnostics: diagnostics,
                      conversationAvailability: conversationAvailability,
                      clearedRetractionDefaults: clearedRetractionDefaults)
    }

    /// Uses the ordinary projection/edit path, but cannot mint an intent or retry transport.
    convenience init(localFixtureStore store: AttentionDomainStore, context: ProfileContext) throws {
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false, isReadOnly: false,
                      diagnostics: nil)
    }

    convenience init(disconnectedStore store: AttentionDomainStore, context: ProfileContext) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false, isReadOnly: true, diagnostics: nil)
    }

    private init(store: AttentionDomainStore, context: ProfileContext,
                 permitsDelivery: Bool, isReadOnly: Bool = false,
                 diagnostics: NativeClientDiagnosticJournal? = nil,
                 conversationAvailability: NativeConversationAvailability = NativeRelayLifecycle.shared.conversationAvailability,
                 clearedRetractionDefaults: UserDefaults = .standard) throws {
        self.clearedRetractionDefaults = clearedRetractionDefaults
        self.conversationAvailability = conversationAvailability
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
        if let data = clearedRetractionDefaults.data(forKey: Self.clearedRetractionsDefaultsKey),
           let cleared = try? JSONDecoder().decode(Set<RequestKey>.self, from: data) {
            clearedRetractions = cleared
        }
        presentStaleAnswerIfAvailable(in: snapshot)
    }

    /// Read-only real account archives are offline relay data, not fictional
    /// local examples. Delivery permission and data provenance are separate.
    var isLocalExample: Bool { profileContext.transportMode == .fixture }

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

    /// Chat calls this while it is on screen. The mark is durable, so a reply
    /// replayed after a relaunch or background wake stays unread until shown.
    func markConversationRead(_ key: RequestKey) {
        guard !isReadOnly, var thread = conversationThreads[key], thread.hasUnreadAgentReply else { return }
        do {
            try port.markConversationRead(key, context: port.context)
            thread.readThroughTurn = thread.latestAgentReply?.id
            conversationThreads[key] = thread
        } catch {
            UIDiagnostics.shared.record("store.markConversationRead \(UIDiagnostics.describe(key)) error=\(error)")
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
        presentation.requests.compactMap { makeInboxRow(for: $0) }
    }

    func inboxRow(for key: RequestKey) -> InboxRequestRow? {
        guard let request = presentation.requests.first(where: { $0.key == key }) else { return nil }
        return makeInboxRow(for: request)
    }

    private func makeInboxRow(for request: PresentedRequest) -> InboxRequestRow? {
        let retracted = isRetracted(request)
        if retracted, clearedRetractions.contains(request.key) { return nil }
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
                String(localized: LiveLifecycleTitle(request.lifecycleStatus).label)
            statusParts.append(lifecycle)
            if request.answerNotDelivered { statusParts.append("Answer not delivered") }
            if request.noCommentUnavailable, receiptStatus != .failed,
               !serverReportedFinalResponse {
                statusParts.append("No comment not delivered · unsupported by this server")
            }
            if let seenStatus = request.informationalSeenStatus, seenStatus != .available {
                statusParts.append(informationalSeenRowStatus(seenStatus))
            }
        } else {
            if let localStatus = cachedOperationStatus(request.intentReceipt?.localState) {
                statusParts.append(localStatus)
            }
            statusParts.append("Cached history · status not refreshed")
        }
        return InboxRequestRow(key: request.key, requestRevision: request.requestRevision,
            title: request.title?.rawValue ?? "Message",
            sender: request.key.senderID.rawValue,
            status: statusParts.joined(separator: " · "),
            bodyText: request.body?.rawValue,
            symbol: request.informationalSeenStatus == nil ? "text.bubble" : "info.circle",
            isResolved: request.answerNotDelivered || receiptStatus == .failed ? false :
                request.isResolved, createdAt: request.createdAt,
            localStatus: request.answerNotDelivered ? "Answer not delivered" : receiptStatus == .failed
                ? (request.noCommentUnavailable
                    ? "No comment not delivered · unsupported by this server"
                    : request.receiptFacts?.ownOutcome == .unconfirmed
                        ? "Answer sent · result not confirmed"
                        : cachedOperationStatus(request.intentReceipt?.localState))
                : nil,
            informationalSeenStatus: request.informationalSeenStatus,
            canMarkSeen: !isReadOnly &&
                !retracted && request.lifecycleStatus == .open &&
                request.intentReceipt == nil && request.informationalSeenStatus == .available,
            canNoComment: canNoComment(request, isRetracted: retracted),
            noCommentUnavailable: request.noCommentUnavailable,
            hasUserAction: receiptStatus == .pendingOrAccepted ||
                request.lifecycleStatus == .answered ||
                request.lifecycleStatus == .noComment,
            hasFailedResponse: receiptStatus == .failed,
            isRetracted: retracted,
            tier: request.attentionTier.inboxRowStyleTier)
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
        case .unsupported: "No comment is unsupported by this server"
        case .repairRequired: "Answer needs recovery"
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

    func draft(for key: RequestKey, revision: UInt64? = nil) -> RequestDraft? {
        let presented: PresentedRequest?
        if let revision {
            presented = try? inspectedRequest(key, revision: revision)
        } else {
            presented = request(for: key)
        }
        guard let presented else { return nil }
        let bufferKey = DraftBufferKey(request: key, revision: presented.requestRevision)
        return pendingDrafts[bufferKey] ?? presented.draft
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
        guard !isReadOnly else { throw LiveReplyError.disconnected }
        guard permitsDelivery else { throw LiveReplyError.localExample }
        let inspected = try inspectedRequest(key, revision: requestRevision)
        let revision = inspected.requestRevision
        let bufferKey = DraftBufferKey(request: key, revision: revision)
        let answerDraft = pendingDrafts[bufferKey] ?? inspected.draft
        guard !isRetracted(key), inspected.lifecycleStatus == .open,
              inspected.intentReceipt == nil,
              let selector = inspected.selector else {
            throw LiveReplyError.notOpen
        }
        if answerDraft.noCommentSelected {
            try persistPendingDraft(for: bufferKey)
            return try submitNoComment(key, requestRevision: revision)
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

        try persistPendingDraft(for: bufferKey)
        let request = try inspectedRequest(key, revision: revision)
        guard !isRetracted(bufferKey.request), request.lifecycleStatus == .open,
              request.intentReceipt == nil else {
            throw LiveReplyError.notOpen
        }
        let receipt = try port.submit(SubmitIntent(context: port.context,
                                                   selector: selector,
                                                   intentID: UUID(),
                                                   inputs: records))
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
        do {
            _ = try submit(key, explicitCompatibilityAction: explicitCompatibilityAction,
                           requestRevision: requestRevision)
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
    func submitNoCommentFromUser(_ key: RequestKey, requestRevision: UInt64? = nil) -> Bool {
        guard permitsDelivery, !isReadOnly,
              let request = try? inspectedRequest(key, revision: requestRevision),
              !isRetracted(key), request.lifecycleStatus == .open,
              request.intentReceipt == nil, request.informationalSeenStatus == nil else { return false }
        let revision = request.requestRevision
        selectNoComment(for: key, requestRevision: revision)
        guard flushPendingDraft(for: key, requestRevision: revision) else { return false }
        do {
            _ = try submitNoComment(key, requestRevision: revision)
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
                actionError = "No comment could not be confirmed. Check its saved status before trying again."
                return false
            }
        }
    }

    @discardableResult
    private func submitNoComment(_ key: RequestKey, requestRevision: UInt64? = nil) throws -> IntentReceipt {
        let request = try inspectedRequest(key, revision: requestRevision)
        guard !isRetracted(key),
              request.lifecycleStatus == .open, request.intentReceipt == nil,
              request.informationalSeenStatus == nil,
              let selector = request.selector,
              canSubmitNoComment(request) else { throw LiveReplyError.notOpen }
        let receipt = try port.submitNoComment(context: port.context,
                                               selector: selector,
                                               intentID: UUID())
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
        guard !isReadOnly,
              let request = try? inspectedRequest(key, revision: revision),
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
        guard actionError != nil || actionErrorRequest != nil else { return }
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

    private func presentStaleAnswerIfAvailable(in snapshot: PresentationSnapshot) {
        guard staleAnswerDialog == nil,
              let stale = snapshot.requests.first(where: { request in
                  guard let stale = request.staleAnswerRevision else { return false }
                  return !presentedStaleAnswerOperationIDs.contains(stale.operationID)
              }),
              let notice = stale.staleAnswerRevision else { return }
            staleAnswerDialog = StaleAnswerDialog(operationID: notice.operationID,
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
