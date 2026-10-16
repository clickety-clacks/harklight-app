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

@MainActor
@Observable
final class NativeAppLaunch {
    enum State {
        case enrollmentRequired
        case enrollmentPending(NativeEnrollmentRecord)
        case fixture(PrototypeStore)
        case live(LivePresentationStore)
    }

    private(set) var state: State
    private(set) var enrollmentMessage: String?
    private(set) var isEnrollmentBusy = false
    private(set) var isEnrollmentExpired = false
    let guidedJoin: NativeGuidedJoinCoordinator

    @ObservationIgnored private let enrollment = NativeEnrollmentStore()
    @ObservationIgnored private let notifications = NativeNotificationPermission.system
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var activationGeneration = UUID()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let fixture = arguments.contains("--reset-attention-fixture") || arguments.contains("--attention-fixture")
        #if DEBUG
        let conversationFixture = arguments.contains("--conversation-fixture")
        #else
        let conversationFixture = false
        #endif
        guidedJoin = NativeGuidedJoinCoordinator(deviceName: UIDevice.current.name, isShowing: !fixture && !conversationFixture)
        if conversationFixture {
            // Exercise the ordinary app root with an isolated model. No enrollment restore or relay activation.
            do {
                let local = try SampleFixtureDomain()
                try local.populate()
                state = .live(local.viewModel)
            } catch {
                state = .enrollmentRequired
                enrollmentMessage = "The local conversation fixture could not be loaded."
            }
            didRestore = true
        } else if fixture {
            state = .fixture(PrototypeStore.loadFromBundle())
        } else {
            state = .enrollmentRequired
        }
        guidedJoin.connectApproved = { [weak self] record in
            guard let self else { return false }
            let material = try self.enrollment.material(from: record)
            try await self.activate(material)
            let epoch = self.activationGeneration
            let reached = await NativeRelayLifecycle.shared.confirmForegroundProgress(for: material.context)
            guard self.activationGeneration == epoch else { return false }
            if reached { try self.enrollment.markForegroundRelayConfirmed(for: record.deviceID) }
            if case let .live(presentation) = self.state {
                presentation.connectionWarning = reached ? nil : "The server cannot be reached. Saved requests and answers remain on this device."
            }
            return reached
        }
        guidedJoin.notificationChoice = { [weak self] enabled in
            await self?.chooseNotifications(enabled)
        }
        guidedJoin.didRemoveCurrentAccount = { [weak self] in
            guard let self else { return }
            self.activationGeneration = UUID()
            if case let .live(previous) = self.state { previous.stopObserving() }
            self.state = .enrollmentRequired
            await NativeRelayLifecycle.shared.deactivate()
        }
    }

    func restoreInstallation() async {
        guard !didRestore else { return }
        didRestore = true
        if case .fixture = state { return }
        await guidedJoin.restore()
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
                                                    password: password)
            guard activationGeneration == generation else { return }
            isEnrollmentExpired = false
            state = .enrollmentPending(record)
        } catch NativeEnrollmentError.keyPending {
            if activationGeneration == generation {
                enrollmentMessage = "This identity already has a request pending on the server. Keep the same identity file and retry after its code expires, or ask the server owner to check it."
            }
        } catch NativeEnrollmentError.keyInUse {
            if activationGeneration == generation {
                enrollmentMessage = "This identity is already enrolled. Ask the server owner to recover its approved profile; do not replace the device identity."
            }
        } catch NativeEnrollmentError.preparedIdentityMismatch {
            if activationGeneration == generation {
                enrollmentMessage = "A prior request used a different identity or server. Reimport the same identity with the same server settings, or ask the server owner for help."
            }
        } catch NativeEnrollmentError.invalidSettings, NativeEnrollmentError.invalidIdentity {
            if activationGeneration == generation {
                enrollmentMessage = "Check the server settings, CA certificate and identity file."
            }
        } catch {
            if activationGeneration == generation {
                enrollmentMessage = "Enrollment could not be confirmed. Keep this identity file; retry with the same file after ten minutes or ask the server owner to check it."
            }
        }
    }

    func retryExpiredEnrollment() async {
        guard !isEnrollmentBusy else { return }
        let generation = activationGeneration
        isEnrollmentBusy = true
        defer { isEnrollmentBusy = false }
        enrollmentMessage = nil
        do {
            let record = try await enrollment.retryExpired()
            guard activationGeneration == generation else { return }
            isEnrollmentExpired = false
            state = .enrollmentPending(record)
        } catch NativeEnrollmentError.keyPending {
            if activationGeneration == generation {
                enrollmentMessage = "The server still has a request pending for this identity. Try again after its code expires."
            }
        } catch NativeEnrollmentError.keyInUse {
            if activationGeneration == generation {
                enrollmentMessage = "This identity is already enrolled. Ask the server owner to recover its approved profile."
            }
        } catch {
            if activationGeneration == generation {
                enrollmentMessage = "A new code could not be confirmed. Keep this device identity and try again or ask the server owner."
            }
        }
    }

    func checkEnrollmentApproval() async {
        guard !isEnrollmentBusy else { return }
        let generation = activationGeneration
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
            if activationGeneration == generation { enrollmentMessage = "Waiting for server-owner approval." }
        } catch NativeEnrollmentError.approvalExpired {
            if activationGeneration == generation {
                isEnrollmentExpired = true
                enrollmentMessage = "This approval code expired. Request a new code for the same device identity."
            }
        } catch {
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
        isEnrollmentExpired = false
        if case let .live(previous) = state { previous.stopObserving() }
        state = .enrollmentRequired
        await NativeRelayLifecycle.shared.deactivate()
        guard activationGeneration == generation else { return }
        let persistence = try FileAttentionStatePersistence.applicationSupport()
        let store = try AttentionDomainStore(context: installation.context, persistence: persistence)
        let presentation = try LivePresentationStore(store: store, context: installation.context)
        do {
            try await NativeRelayLifecycle.shared.activate(store: store,
                                                           context: installation.context,
                                                           relayURL: installation.relayURL,
                                                           clientIdentity: installation.keychainIdentity,
                                                           trustedRootDER: installation.trustedRootDER)
        } catch {
            if activationGeneration != generation { return }
            throw error
        }
        guard activationGeneration == generation else { return }
        presentation.startObserving()
        state = .live(presentation)
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
        guard case let .live(presentation) = state, let record = try? enrollment.load(), record.isApproved else { return }
        let epoch = activationGeneration
        do {
            try enrollment.markNotificationExplanationSeen(for: record.deviceID)
            let allowed = try await notifications.choose(enabled) { self.activationGeneration == epoch }
            guard activationGeneration == epoch else { return }
            if allowed {
                presentation.notificationWarning = nil
            } else {
                presentation.notificationWarning = "Notifications are off. You will see new requests when you open Harklight. Turn them on in Settings."
            }
        } catch {
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
    }

    func refreshLive() async {
        guard case let .live(presentation) = state, !presentation.isLocalExample else { return }
        let result = await NativeRelayLifecycle.shared.refreshResultFromTrustedRelay()
        guard case let .live(current) = state, current === presentation else { return }
        presentation.applyRefreshResult(result)
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
    @ObservationIgnored private var observation: Task<Void, Never>?

    convenience init(store: AttentionDomainStore, context: ProfileContext) throws {
        guard context.transportMode == .relay else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: true)
    }

    /// Uses the ordinary projection/edit path, but cannot mint an intent or retry transport.
    convenience init(localFixtureStore store: AttentionDomainStore, context: ProfileContext) throws {
        guard context.transportMode == .fixture else { throw AttentionStoreError.fixtureOnlyOperation }
        try self.init(store: store, context: context, permitsDelivery: false)
    }

    private init(store: AttentionDomainStore, context: ProfileContext, permitsDelivery: Bool) throws {
        self.permitsDelivery = permitsDelivery
        self.profileContext = context
        _ = try store.snapshot(context: context)
        let port = AttentionDomainPort(store: store)
        let snapshot = try port.observe(context: port.context)
        self.port = port
        self.presentation = snapshot
        self.conversationThreads = try port.conversations(context: port.context).threads
        self.conversationFiles = context.transportMode == .relay ? try ConversationFileStorage(identity: context.identity) : nil
        self.selectedRequestKey = snapshot.requests.first?.key
    }

    var isLocalExample: Bool { !permitsDelivery }

    func conversation(for key: RequestKey) -> ConversationThread? { conversationThreads[key] }

    func historicalAnswerDraft(for key: RequestKey, revision: UInt64) -> PresentedRequest? {
        try? port.inspectAnswerDraft(context: port.context, request: key, revision: revision)
    }

    func reportConversationImportError(_ error: String) {
        conversationError = "The selected file could not be opened: " + error + ". Your saved draft is retained."
    }

    func conversationDraft(for key: RequestKey, revision: UInt64) -> ConversationDraft {
        conversationThreads[key]?.drafts[revision] ?? ConversationDraft(binding: ConversationBinding(request: key, revision: revision))
    }

    func updateConversation(for key: RequestKey, revision: UInt64, text: String? = nil,
                            files: [ConversationFile]? = nil) {
        do {
            var draft = conversationDraft(for: key, revision: revision)
            if let text { draft.text = ExactText(text) }
            if let files { draft.files = files }
            draft.disposition = .saved
            try port.saveConversationDraft(draft, context: port.context)
            try refreshFromDurableStore()
            conversationError = nil
        } catch {
            conversationError = "Your discussion edit could not be saved. Its earlier saved draft is retained."
        }
    }

    func sendDiscussion(for key: RequestKey, revision: UInt64) {
        do {
            let binding = ConversationBinding(request: key, revision: revision)
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
                        try? refreshFromDurableStore()
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
        }
    }

    func addLocalAttachment(_ name: String, for key: RequestKey, revision: UInt64) {
        guard !permitsDelivery else { return }
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
            }
        }
    }

    var inboxRows: [InboxRequestRow] {
        presentation.requests.map {
            InboxRequestRow(key: $0.key, title: $0.title?.rawValue ?? $0.key.senderID.rawValue,
                sender: $0.key.senderID.rawValue,
                status: String(localized: LiveLifecycleTitle($0.lifecycleStatus).label),
                bodyText: $0.body?.rawValue ?? "")
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
        guard !permitsDelivery else { return }
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
    func submit(_ key: RequestKey) throws -> IntentReceipt {
        guard permitsDelivery else { throw LiveReplyError.localExample }
        let request = try inspectedRequest(key)
        guard request.lifecycleStatus == .open,
              request.intentReceipt == nil,
              let selector = request.selector else {
            throw LiveReplyError.notOpen
        }
        let records = try typedInputs(for: request)
        let receipt = try port.submit(SubmitIntent(context: port.context,
                                                   selector: selector,
                                                   intentID: UUID(),
                                                   inputs: records))
        try? refreshFromDurableStore()
        clearActionError()
        return receipt
    }

    func submitFromUser(_ key: RequestKey) {
        guard permitsDelivery else { return }
        do {
            _ = try submit(key)
            retryPendingDelivery()
        } catch {
            try? refreshFromDurableStore()
            // A stale Send callback can arrive after the original intent or
            // its receipt. Never mint another intent or contradict that fact.
            if let current = try? inspectedRequest(key), current.intentReceipt != nil {
                clearActionError()
            } else {
                actionErrorRequest = key
                if let current = try? inspectedRequest(key), current.lifecycleStatus != .open {
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
        guard permitsDelivery else { return }
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
        do {
            let request = try inspectedRequest(key)
            guard request.lifecycleStatus == .open,
                  request.intentReceipt == nil,
                  let selector = request.selector else { throw LiveReplyError.notOpen }
            var draft = request.draft
            change(&draft)
            try port.saveDraft(context: port.context, selector: selector, completeDraft: draft)
            try? refreshFromDurableStore()
            clearActionError()
        } catch {
            actionErrorRequest = key
            actionError = "Your edit could not be saved."
            try? refreshFromDurableStore()
        }
    }

    private func inspectedRequest(_ key: RequestKey) throws -> PresentedRequest {
        guard let request = try port.inspect(context: port.context, request: key).requests.first else {
            throw LiveReplyError.notOpen
        }
        return request
    }

    private func typedInputs(for request: PresentedRequest) throws -> [TypedInputRecord] {
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
        catch { observationError = "The local conversation could not be refreshed." }
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
    }
}

private enum LiveReplyError: Error {
    case localExample
    case notOpen
    case incomplete
    case unsupported
}
