import Foundation
import Observation

@MainActor
@Observable
final class NativeGuidedJoinCoordinator {
    enum Screen: Equatable {
        case welcome, verifying, confirmation, joining, pending, unreachable
        case invitationExpired, invitationUsed, approvalExpired, declined, revoked, refused, cancelled
        case approvedFinishing, connected, notifications, existingAccount, replacementConfirmation
    }

    private(set) var screen: Screen = .welcome
    private(set) var invitation: NativeJoinInvitation?
    private(set) var attempt: NativeJoinAttempt?
    private(set) var currentAccount: NativeEnrollmentRecord?
    private(set) var message: String?
    private(set) var busy = false
    private(set) var isApprovedConnectBusy = false
    private var approvalObservationCurrent = false
    private(set) var isShowing: Bool
    var deviceName: String

    @ObservationIgnored private let store: NativeGuidedJoinStore
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var verificationPending = false
    @ObservationIgnored private var receivedInvitation = false
    @ObservationIgnored var connectApproved: ((NativeEnrollmentRecord) async throws -> Bool)?
    @ObservationIgnored var notificationChoice: ((Bool) async -> Void)?
    @ObservationIgnored var didRemoveCurrentAccount: (() async -> Void)?

    init(store: NativeGuidedJoinStore = NativeGuidedJoinStore(),
         deviceName: String, isShowing: Bool = true) {
        self.store = store
        self.deviceName = deviceName
        self.isShowing = isShowing
    }

    func restore() async {
        guard isShowing, !busy, !receivedInvitation else { return }
        let epoch = generation
        do {
            if let departure = try store.departure() {
                invitation = departure.replacement
                if departure.removed {
                    try store.finishConfirmedDeparture(departure)
                    if try store.loadAttempt() == nil {
                        currentAccount = nil
                        attempt = nil
                        screen = .confirmation
                        return
                    }
                    // A new request was already durable when cleanup was
                    // interrupted. Continue through normal saved-state restore.
                } else {
                    currentAccount = try store.approvedRecord()
                    screen = .replacementConfirmation
                    message = "Removing this device could not yet be confirmed. The original identity is kept so you can try again."
                    return
                }
            }
            attempt = try store.loadAttempt()
            if let record = try store.approvedRecord(), record.isApproved {
                currentAccount = record
                try await finishApproval(record, epoch: epoch, restoring: true)
            } else if let saved = attempt {
                invitation = saved.invitation
                deviceName = saved.deviceLabel
                show(saved)
                if !saved.isTerminal { await retry() }
            }
        } catch {
            if generation == epoch {
                screen = .refused
                message = "The saved join could not be opened. Your existing identity has been kept."
            }
        }
    }

    func holdForDisconnectedAccount(_ departure: NativeAccountDeparture) {
        generation = UUID()
        currentAccount = departure.record
        invitation = nil
        attempt = nil
        message = nil
        isShowing = false
        screen = .welcome
    }

    func restoreAfterStandaloneRemoval() {
        isShowing = true
        receivedInvitation = false
    }

    func prepareStandaloneRemoval(_ record: NativeEnrollmentRecord) throws {
        guard record.isApproved else { throw NativeJoinError.superseded }
        currentAccount = record
        _ = try store.prepareAccountDeparture(record)
    }

    func removeStandaloneAccount() async throws {
        guard let departure = try store.departure(), departure.replacement == nil else {
            throw NativeJoinError.superseded
        }
        try await store.removeCurrentAccount(departure.record)
    }

    func beginReconnect() {
        guard !busy else { return }
        generation = UUID()
        verificationPending = false
        receivedInvitation = false
        invitation = nil
        attempt = nil
        currentAccount = nil
        message = nil
        screen = .welcome
        isShowing = true
    }

    func returnToDisconnectedAccount() {
        guard !busy else { return }
        generation = UUID()
        verificationPending = false
        invitation = nil
        currentAccount = nil
        message = nil
        isShowing = false
        screen = .welcome
    }

    func receive(_ url: URL) async {
        guard !busy else { return }
        if let departure = try? store.departure(), departure.replacement == nil, !departure.removed {
            message = "Removal is still unconfirmed. Retry it with the original server before connecting again."
            return
        }
        let epoch = UUID()
        generation = epoch
        receivedInvitation = true
        approvalObservationCurrent = false
        isShowing = true
        message = nil
        screen = .verifying
        busy = true
        defer { if generation == epoch { busy = false } }
        do {
            if let departure = try store.departure() {
                if departure.removed {
                    if departure.replacement == nil { try store.finishConfirmedDeparture(departure) }
                    else { try store.dismissConfirmedDeparture() }
                }
                else {
                    invitation = departure.replacement
                    currentAccount = try store.approvedRecord()
                    screen = .replacementConfirmation
                    message = "Finish confirming removal with the current server before opening another invitation."
                    return
                }
            }
            currentAccount = try store.approvedRecord()
            let next = try NativeJoinInvitation.decode(url)
            invitation = next
            attempt = nil
            verificationPending = true
            try await store.verifyDestination(next)
            guard generation == epoch else { return }
            try await acceptVerifiedInvitation(epoch: epoch)
        } catch {
            if generation == epoch { explain(error) }
        }
    }

    func join() async {
        guard !busy, screen == .confirmation, let invitation else { return }
        let epoch = generation
        busy = true
        message = nil
        screen = .joining
        defer { if generation == epoch { busy = false } }
        do {
            let prepared = try store.prepare(invitation, deviceLabel: deviceName.trimmingCharacters(in: .whitespacesAndNewlines))
            attempt = prepared
            let result = try await store.submit()
            guard generation == epoch else { return }
            try await accept(result, epoch: epoch)
        } catch {
            if generation == epoch { explain(error) }
        }
    }

    func retry() async {
        guard !busy, !isApprovedConnectBusy else { return }
        approvalObservationCurrent = false
        if verificationPending, let invitation {
            let epoch = generation
            busy = true
            defer { if generation == epoch { busy = false } }
            do {
                try await store.verifyDestination(invitation)
                guard generation == epoch else { return }
                message = nil
                try await acceptVerifiedInvitation(epoch: epoch)
            } catch { if generation == epoch { explain(error) } }
            return
        }
        guard let saved = try? store.loadAttempt(), !saved.isTerminal else { return }
        let epoch = generation
        busy = true
        message = nil
        defer { if generation == epoch { busy = false } }
        do {
            try await refreshSavedAttempt(saved, epoch: epoch)
        } catch {
            if generation == epoch { explain(error) }
        }
    }

    /// The scene poll may continue ordinary approval checks, but an approved
    /// foreground connection that timed out waits for a person to retry it.
    func shouldAutomaticallyRetry(foregroundOutcome: NativeForegroundConnectProgress.Outcome?) -> Bool {
        guard isShowing, !busy, !isApprovedConnectBusy,
              [.pending, .approvalExpired, .unreachable, .approvedFinishing].contains(screen) else {
            return false
        }
        return foregroundOutcome != .timedOut
    }

    /// Runs the same gated retry used by the foreground scene poll. Keeping
    /// the decision and call together lets tests verify a timeout cannot be
    /// bypassed by a caller that forgets the explicit-retry boundary.
    @discardableResult
    func retryAutomaticallyIfNeeded(
        foregroundOutcome: NativeForegroundConnectProgress.Outcome?
    ) async -> Bool {
        guard shouldAutomaticallyRetry(foregroundOutcome: foregroundOutcome) else { return false }
        await retry()
        return true
    }

    /// Reopens only the already-approved record through the existing app
    /// connection owner. It does not create or submit a join request.
    func retryApprovedConnection() async {
        guard !busy, !isApprovedConnectBusy,
              [.approvedFinishing, .connected].contains(screen),
              let record = currentAccount, record.isApproved,
              let connectApproved else { return }
        let epoch = generation
        busy = true
        isApprovedConnectBusy = true
        message = nil
        screen = .approvedFinishing
        defer {
            busy = false
            isApprovedConnectBusy = false
        }
        do {
            let connected = try await connectApproved(record)
            guard generation == epoch else { return }
            if connected {
                screen = .connected
                message = nil
            } else {
                message = "The approved account is still offline. Saved requests and pending answers remain on this device."
            }
        } catch {
            if generation == epoch { explain(error) }
        }
    }

    func invalidateApprovalObservation() { approvalObservationCurrent = false }

    var currentApprovalCode: String? {
        guard approvalObservationCurrent, screen == .pending,
              attempt?.cancellationRequested != true,
              let deadline = attempt?.approvalExpiresAt,
              deadline > Int64(Date().timeIntervalSince1970 * 1000) else { return nil }
        return attempt?.approvalCode
    }

    func cancelRequest() async {
        guard !busy, let saved = try? store.loadAttempt(), !saved.isTerminal else { return }
        let epoch = generation
        busy = true
        message = nil
        defer { if generation == epoch { busy = false } }
        do {
            let result = try await store.cancel()
            guard generation == epoch else { return }
            try await accept(result, epoch: epoch)
        } catch {
            if generation == epoch {
                screen = .unreachable
                message = "Cancellation has not been confirmed. Trying again checks this same request; it is still saved."
            }
        }
    }

    func pasteInvitation(_ text: String) async {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "Paste the full invitation the owner sent you."
            return
        }
        await receive(url)
    }

    var canOpenInvitationEntry: Bool {
        [.invitationExpired, .invitationUsed, .approvalExpired, .declined, .revoked, .refused].contains(screen)
    }

    func openInvitationEntry() {
        guard !busy, canOpenInvitationEntry else { return }
        generation = UUID()
        verificationPending = false
        invitation = nil
        attempt = nil
        message = nil
        screen = .welcome
        // Durable request/account/key remain protected. A fresh invitation
        // still passes the existing pending/approved-account safeguards.
    }

    func continueConnected() {
        guard screen == .connected else { return }
        screen = .notifications
    }

    func chooseNotifications(_ enabled: Bool) async {
        guard screen == .notifications else { return }
        // The foreground inbox is available while the system prompt is open.
        isShowing = false
        await notificationChoice?(enabled)
    }

    func keepCurrentAccount() async {
        guard !busy else { return }
        // Once removal has been sent, its result may already be committed.
        // Keep the recovery route until the old server confirms the outcome.
        if let departure = try? store.departure(), !departure.removed {
            message = "Removal is still unconfirmed. Try again with the current server before keeping or replacing this account."
            return
        }
        do { try store.dismissConfirmedDeparture() }
        catch {
            message = "The confirmed removal could not be saved yet. Try again before opening another invitation."
            return
        }
        verificationPending = false
        invitation = nil
        message = nil
        guard currentAccount?.isApproved == true else {
            screen = .welcome
            return
        }
        generation = UUID()
        invitation = nil
        message = nil
        let epoch = generation
        busy = true
        defer { if generation == epoch { busy = false } }
        do {
            if let currentAccount {
                try await finishApproval(currentAccount, epoch: epoch, restoring: true)
            }
        } catch {
            if generation == epoch { explain(error) }
        }
    }

    private func acceptVerifiedInvitation(epoch: UUID) async throws {
        verificationPending = false
        if currentAccount?.isApproved == true {
            screen = .existingAccount
        } else if let saved = try store.loadAttempt(), !saved.isTerminal {
            let sameAccount = invitation.map { saved.invitation.sameAccount(as: $0) } == true
            attempt = saved
            invitation = saved.invitation
            deviceName = saved.deviceLabel
            show(saved)
            if sameAccount {
                // A new link for this account must not strand the person on
                // stale saved state. Continue the already-deliberate Join.
                try await refreshSavedAttempt(saved, epoch: epoch)
            } else {
                message = "Your earlier join is saved. Finish it before adding another account."
            }
        } else {
            screen = .confirmation
        }
    }

    private func refreshSavedAttempt(_ saved: NativeJoinAttempt, epoch: UUID) async throws {
        if let record = try store.approvedRecord(), record.isApproved {
            try await finishApproval(record, epoch: epoch, restoring: false)
            return
        }
        let result: NativeJoinAttempt
        do { result = saved.cancellationRequested == true ? try await store.cancel() : try await store.checkApproval() }
        catch NativeJoinError.notFound {
            // Only an initial request with no server receipt may need its
            // original POST replayed. An existing approval must never fall
            // back to redeeming an old invitation after its status is lost.
            guard saved.phase == .prepared, saved.approvalCode == nil,
                  saved.cancellationRequested != true,
                  saved.invitation.expiresAt > Int64(Date().timeIntervalSince1970 * 1000) else {
                throw NativeJoinError.unavailable
            }
            result = try await store.submit()
        }
        guard generation == epoch else { return }
        try await accept(result, epoch: epoch)
    }

    func considerReplacement() {
        guard screen == .existingAccount else { return }
        screen = .replacementConfirmation
    }

    func confirmReplacement() async {
        guard !busy, screen == .replacementConfirmation, let old = currentAccount, let invitation else { return }
        let epoch = generation
        busy = true
        message = nil
        defer { if generation == epoch { busy = false } }
        do {
            try await store.removeCurrentAccount(old, replacement: invitation)
            await didRemoveCurrentAccount?()
            guard generation == epoch else { return }
            currentAccount = nil
            attempt = nil
            screen = .confirmation
        } catch {
            if generation == epoch {
                message = "Removal could not be confirmed with the current server. This account has been kept. Try again when it is reachable."
                screen = .replacementConfirmation
            }
        }
    }

    private func accept(_ result: NativeJoinAttempt, epoch: UUID) async throws {
        attempt = result
        invitation = result.invitation
        approvalObservationCurrent = result.phase == .pending
        show(result)
        if result.phase == .approved,
           let record = try store.approvedRecord(), record.isApproved {
            try await finishApproval(record, epoch: epoch, restoring: false)
        }
    }

    private func finishApproval(_ record: NativeEnrollmentRecord, epoch: UUID, restoring: Bool) async throws {
        screen = .approvedFinishing
        currentAccount = record
        // Missing fields identify the earlier approved-installation format.
        // Migrating it must preserve its durable inbox while offline; new
        // guided approvals explicitly store false until each step finishes.
        let alreadyJoined = restoring && record.foregroundRelayConfirmed != false
        if alreadyJoined && record.notificationExplanationSeen != false {
            // An established installation can read and answer its durable
            // inbox offline. Only the first join requires fresh relay proof.
            isShowing = false
        }
        guard let connectApproved else { throw NativeJoinError.unavailable }
        isApprovedConnectBusy = true
        defer { isApprovedConnectBusy = false }
        let connected = try await connectApproved(record)
        guard generation == epoch else { return }
        if connected {
            screen = .connected
            if restoring && record.notificationExplanationSeen != false { isShowing = false }
        } else if alreadyJoined && record.notificationExplanationSeen == false {
            screen = .notifications
        } else {
            message = "The owner approved this device, but the server could not be reached to finish. You are not connected yet."
        }
    }

    private func show(_ result: NativeJoinAttempt) {
        switch result.phase {
        case .prepared: screen = .unreachable
        case .pending: screen = .pending
        case .approved: screen = .approvedFinishing
        case .expired: screen = result.approvalCode == nil ? .invitationExpired : .approvalExpired
        case .declined: screen = .declined
        case .revoked: screen = .revoked
        case .cancelled: screen = .cancelled
        }
    }

    private func explain(_ error: Error) {
        approvalObservationCurrent = false
        switch error {
        case NativeJoinInvitationError.expired:
            screen = .invitationExpired
            message = "This invitation cannot add a device now. Ask the owner for a fresh invitation."
        case NativeJoinError.used:
            screen = .invitationUsed
            message = "Another request used this invitation. If that was not you, tell the owner before asking for another."
        case NativeJoinError.expired:
            screen = .approvalExpired
            message = "Ask the owner for a new invitation. This device keeps the identity it made."
        case NativeJoinError.existingAccount:
            screen = .existingAccount
            currentAccount = try? store.approvedRecord()
        case NativeJoinError.savedRequest:
            attempt = try? store.loadAttempt()
            if let attempt { show(attempt) }
            message = "Finish the saved request before joining a different account."
        case NativeJoinError.unavailable:
            screen = verificationPending ? .unreachable : (currentAccount?.isApproved == true ? .approvedFinishing : .unreachable)
            message = verificationPending ? "The invitation has not been submitted. Try checking the server again." :
                "The server could not be reached. Trying again continues the saved request."
        case let network as URLError:
            if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(network.code) {
                screen = .refused
                message = "The invitation's server identity could not be verified. Ask its owner for help."
            } else {
                screen = verificationPending ? .unreachable : (currentAccount?.isApproved == true ? .approvedFinishing : .unreachable)
                message = verificationPending ? "The invitation has not been submitted. Your current account has been kept." :
                    "The server could not be reached. Your saved request and identity have been kept."
            }
        default:
            screen = .refused
            message = "Joining could not be confirmed. Ask the owner for help; your existing account and identity have been kept."
        }
    }
}
