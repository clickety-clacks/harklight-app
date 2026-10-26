import CryptoKit
import Foundation
import HarklightNativeRelay
import Security

enum NativeJoinError: Error {
    case existingAccount
    case savedRequest
    case superseded
    case expired
    case used
    case refused
    case notFound
    case unavailable
    case invalidResponse
    case wrongApproval
}

struct NativeJoinAttempt: Codable, Equatable {
    enum Phase: String, Codable { case prepared, pending, approved, expired, declined, revoked, cancelled }
    let id: UUID
    let invitation: NativeJoinInvitation
    let identityLabel: String
    let deviceID: String
    let certificateDER: Data
    let deviceLabel: String
    let statusSecret: String
    var phase: Phase
    var approvalCode: String?
    var approvalExpiresAt: Int64?
    var statusExpiresAt: Int64?
    var lastCheckedAt: Date?
    var cancellationRequested: Bool?
    var requestGeneration: Int64?

    // A lost first reply may have left no approval code. Only the bound server
    // response can establish whether the original request still exists.
    var canRecoverApproval: Bool { phase == .expired && cancellationRequested != true }
    var isTerminal: Bool {
        phase == .declined || phase == .revoked || phase == .cancelled
    }
}

struct NativeAccountDeparture: Codable {
    let record: NativeEnrollmentRecord
    let replacement: NativeJoinInvitation?
    var removed: Bool

    /// Stable within the local account authority, even after a transport
    /// hostname migration changes the enrollment endpoint.
    var archiveID: String {
        [record.profileAuthority, record.personID ?? "", record.deviceID].joined(separator: "|")
    }
}

struct NativeJoinResponse {
    let statusCode: Int
    let data: Data
}

@MainActor
protocol NativeJoinTransport {
    func request(_ url: URL, method: String, body: Data?, rootDER: Data) async throws -> NativeJoinResponse
    func remove(_ url: URL, body: Data, rootDER: Data, identity: SecIdentity) async throws -> NativeJoinResponse
}

extension NativeJoinTransport {
    func remove(_ url: URL, body: Data, rootDER: Data, identity: SecIdentity) async throws -> NativeJoinResponse {
        throw NativeJoinError.unavailable
    }
}

@MainActor
struct PinnedNativeJoinTransport: NativeJoinTransport {
    func request(_ url: URL, method: String, body: Data?, rootDER: Data) async throws -> NativeJoinResponse {
        try await send(url, method: method, body: body, rootDER: rootDER, identity: nil)
    }

    func remove(_ url: URL, body: Data, rootDER: Data, identity: SecIdentity) async throws -> NativeJoinResponse {
        try await send(url, method: "POST", body: body, rootDER: rootDER, identity: identity)
    }

    private func send(_ url: URL, method: String, body: Data?, rootDER: Data,
                      identity: SecIdentity?) async throws -> NativeJoinResponse {
        guard url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw NativeJoinError.refused }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let exchange = BoundedNativeJoinExchange(url: url, rootDER: rootDER, identity: identity)
        let session = URLSession(configuration: configuration,
                                 delegate: exchange,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await exchange.run(session: session, request: request)
    }
}

/// The saved attempt is the retry authority. Every network completion is fenced
/// by that attempt's identity, preventing a superseded reply from enrolling an
/// account selected by an earlier invitation.
@MainActor
final class NativeGuidedJoinStore {
    private let namespace: String
    private let transport: any NativeJoinTransport
    private let enrollment: NativeEnrollmentStore

    init(namespace: String = "co.clicketyclacks.Harklight.native-enrollment",
         transport: any NativeJoinTransport = PinnedNativeJoinTransport()) {
        self.namespace = namespace
        self.transport = transport
        self.enrollment = NativeEnrollmentStore(service: namespace)
    }

    func verifyDestination(_ invitation: NativeJoinInvitation) async throws {
        try invitation.validate(now: Date())
        // Any response from this endpoint proves the pinned TLS name. The
        // invitation secret is neither in the URL nor in this read-only probe.
        let response = try await transport.request(invitation.enrollmentURL, method: "GET", body: nil,
                                                   rootDER: invitation.trustedRootDER)
        guard !(300..<400).contains(response.statusCode) else { throw NativeJoinError.refused }
    }

    func loadAttempt() throws -> NativeJoinAttempt? {
        var value: CFTypeRef?
        var query = itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw NativeEnrollmentError.identityStorage }
        let attempt = try JSONDecoder().decode(NativeJoinAttempt.self, from: data)
        try attempt.invitation.validate()
        guard DeviceCertificateBinding.matches(attempt.certificateDER, expectedDeviceID: attempt.deviceID),
              (attempt.requestGeneration ?? 0) >= 0,
              attempt.statusSecret.utf8.count == 64,
              attempt.statusSecret.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NativeJoinError.invalidResponse
        }
        return attempt
    }

    func prepare(_ invitation: NativeJoinInvitation, deviceLabel: String) throws -> NativeJoinAttempt {
        try invitation.validate()
        var unconfirmedDeparture: NativeAccountDeparture?
        if let departure = try departure() {
            if departure.removed {
                try finishConfirmedDeparture(departure)
            } else {
                unconfirmedDeparture = departure
                if departure.replacement != invitation {
                    let updated = NativeAccountDeparture(record: departure.record,
                                                        replacement: invitation,
                                                        removed: false)
                    try saveData(JSONEncoder().encode(updated), account: "guided-departure")
                    unconfirmedDeparture = updated
                }
            }
        }
        let currentEnrollment = try enrollment.load()
        let keepsDisconnectedEnrollment: Bool
        if let unconfirmedDeparture, let currentEnrollment {
            keepsDisconnectedEnrollment = sameInstallation(currentEnrollment, unconfirmedDeparture.record)
        } else {
            keepsDisconnectedEnrollment = false
        }
        guard currentEnrollment?.isApproved != true || keepsDisconnectedEnrollment else {
            throw NativeJoinError.existingAccount
        }
        let prior = try loadAttempt()
        if let prior {
            if prior.invitation == invitation { return prior }
            let isApprovedAttemptForDisconnectedAccount =
                unconfirmedDeparture?.record.deviceID == prior.deviceID && prior.phase == .approved
            guard prior.isTerminal || isApprovedAttemptForDisconnectedAccount else {
                throw NativeJoinError.savedRequest
            }
        }
        try invitation.validate(now: Date())
        guard !deviceLabel.isEmpty, deviceLabel.utf8.count <= 256 else { throw NativeJoinError.refused }
        // Fresh installations get a fresh key. An interrupted/expired request
        // for the same account retains its original identity; a removed key
        // must never silently become the next installation's identity.
        let retained = prior.flatMap { $0.invitation.sameAccount(as: invitation) ? $0.identityLabel : nil }
        let keyNamespace = retained.map { String($0.dropLast(".certificate".count)) } ??
            namespace + ".key." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: keyNamespace).loadOrCreate()
        var secret = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
            throw NativeEnrollmentError.identityStorage
        }
        let attempt = NativeJoinAttempt(id: UUID(), invitation: invitation, identityLabel: identity.label,
                                        deviceID: identity.deviceID, certificateDER: identity.certificateDER,
                                        deviceLabel: deviceLabel,
                                        statusSecret: secret.map { String(format: "%02x", $0) }.joined(),
                                        phase: .prepared)
        try save(attempt)
        return attempt
    }

    func submit() async throws -> NativeJoinAttempt {
        guard let attempt = try loadAttempt() else { throw NativeEnrollmentError.noPendingEnrollment }
        guard attempt.phase == .prepared || attempt.phase == .pending else { throw NativeJoinError.expired }
        let certificate = "-----BEGIN CERTIFICATE-----\n" +
            attempt.certificateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) +
            "\n-----END CERTIFICATE-----\n"
        let body = try JSONSerialization.data(withJSONObject: [
            "invite_token": attempt.invitation.inviteToken,
            "public_certificate": certificate,
            "label": attempt.deviceLabel,
            "status_secret": attempt.statusSecret
        ], options: [.sortedKeys])
        let reply = try await transport.request(attempt.invitation.enrollmentURL, method: "POST", body: body,
                                                rootDER: attempt.invitation.trustedRootDER)
        try assertCurrent(attempt)
        if reply.statusCode == 410 {
            let current = try currentAttempt(matching: attempt)
            guard current == attempt else { return current }
            var expired = current
            expired.phase = .expired
            try save(expired)
            return expired
        }
        try acceptStatus(reply.statusCode, data: reply.data)
        let response = try JSONDecoder().decode(EnrollmentReply.self, from: reply.data)
        guard let code = response.approvalCode, code.utf8.count == 10,
              code.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }),
              let deadline = response.expiresAt, deadline > 0,
              let statusDeadline = response.statusExpiresAt, statusDeadline > deadline else {
            throw NativeJoinError.invalidResponse
        }
        var next = attempt
        next.approvalCode = code
        next.approvalExpiresAt = deadline
        next.statusExpiresAt = statusDeadline
        return try apply(response, to: next)
    }

    func checkApproval() async throws -> NativeJoinAttempt {
        guard let attempt = try loadAttempt() else { throw NativeEnrollmentError.noPendingEnrollment }
        if attempt.isTerminal { return attempt }
        if attempt.cancellationRequested != true,
           attempt.canRecoverApproval || (attempt.requestGeneration ?? 0) > 0 ||
            (attempt.phase == .pending && (attempt.approvalExpiresAt ?? Int64.max) <= Int64(Date().timeIntervalSince1970 * 1000)) {
            return try await resumeApproval(attempt)
        }
        let body = try JSONSerialization.data(withJSONObject: ["status_secret": attempt.statusSecret])
        let statusURL = attempt.invitation.enrollmentURL.deletingLastPathComponent().appendingPathComponent("enroll/status")
        let reply = try await transport.request(statusURL, method: "POST", body: body,
                                                rootDER: attempt.invitation.trustedRootDER)
        try assertCurrent(attempt)
        if attempt.cancellationRequested != true, reply.statusCode == 404 {
            if attempt.phase == .prepared, attempt.approvalCode == nil,
               attempt.invitation.expiresAt > Int64(Date().timeIntervalSince1970 * 1000) {
                // While the original invitation still authorizes this exact
                // deliberate Join, its idempotent initial POST can be retried.
                // After expiry, prepared may instead mean a lost first reply:
                // only bound resume can recover that retained request.
                throw NativeJoinError.notFound
            }
            // The status lookup can have aged out while the original bound
            // Join remains resumable. Only the server can authorize recovery.
            return try await resumeApproval(attempt)
        }
        try acceptStatus(reply.statusCode, data: reply.data)
        let response = try JSONDecoder().decode(EnrollmentReply.self, from: reply.data)
        if response.state == "expired", attempt.cancellationRequested != true {
            return try await resumeApproval(attempt)
        }
        // A lost initial reply can still be recovered after owner approval:
        // the secret was durable before the first request, so no code is needed
        // to check the exact existing request and save the approved identity.
        if response.state == "pending", response.approvalCode == nil, attempt.approvalCode == nil {
            return try await submit()
        }
        return try apply(response, to: attempt)
    }

    private func resumeApproval(_ attempt: NativeJoinAttempt) async throws -> NativeJoinAttempt {
        let attempt = try currentAttempt(matching: attempt)
        guard attempt.cancellationRequested != true,
              !attempt.isTerminal else {
            return attempt
        }
        let certificate = "-----BEGIN CERTIFICATE-----\n" +
            attempt.certificateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) +
            "\n-----END CERTIFICATE-----\n"
        let body = try JSONSerialization.data(withJSONObject: [
            "status_secret": attempt.statusSecret,
            "public_certificate": certificate,
            "label": attempt.deviceLabel
        ], options: [.sortedKeys])
        let url = attempt.invitation.enrollmentURL.deletingLastPathComponent().appendingPathComponent("enroll/resume")
        let reply = try await transport.request(url, method: "POST", body: body,
                                                rootDER: attempt.invitation.trustedRootDER)
        try assertCurrent(attempt)
        if reply.statusCode == 404 {
            // An unsupported route and an unknown recovery capability can
            // both refuse. Neither proves expiry or permits a fresh Join.
            throw NativeJoinError.unavailable
        }
        try acceptStatus(reply.statusCode, data: reply.data)
        let response = try JSONDecoder().decode(EnrollmentReply.self, from: reply.data)
        if response.state == "pending" || response.state == "approved" {
            guard NativeAuthorityBinding.samePerson(response.personID, attempt.invitation.personID),
                  response.deviceID == attempt.deviceID else { throw NativeJoinError.wrongApproval }
        }
        if response.state == "pending" || response.state == "approved" {
            // A renewal cannot display an earlier generation's tuple by
            // filling absent response fields from stale local metadata.
            guard response.approvalCode != nil, response.expiresAt != nil,
                  response.statusExpiresAt != nil,
                  let generation = response.requestGeneration, generation > 0 else { throw NativeJoinError.invalidResponse }
        }
        return try apply(response, to: attempt)
    }

    func approvedRecord() throws -> NativeEnrollmentRecord? { try enrollment.load() }

    func cancel() async throws -> NativeJoinAttempt {
        guard var attempt = try loadAttempt() else { throw NativeEnrollmentError.noPendingEnrollment }
        if attempt.isTerminal || attempt.phase == .approved {
            return attempt
        }
        attempt.cancellationRequested = true
        try save(attempt)
        let url = attempt.invitation.enrollmentURL.deletingLastPathComponent().appendingPathComponent("enroll/cancel")
        // A lost first reply may have left no code. The secret/key still
        // identify this logical request: a well-formed deliberately stale
        // tuple asks E4 for current metadata without renewing it. It is never
        // represented as an observed approval tuple or sent to an owner.
        var currentCode = attempt.approvalCode ?? String(repeating: "A", count: 10)
        var currentDeadline = attempt.approvalExpiresAt ?? 1
        // A concurrent renewal can make the saved tuple stale. Reconcile the
        // current tuple under the same secret and retry cancellation once;
        // never renew as a way of fulfilling cancellation intent.
        for retry in 0...1 {
            let body = try JSONSerialization.data(withJSONObject: [
                "status_secret": attempt.statusSecret, "approval_code": currentCode,
                "expected_device_id": attempt.deviceID, "expected_expires_at": currentDeadline
            ], options: [.sortedKeys])
            let reply = try await transport.request(url, method: "POST", body: body,
                                                    rootDER: attempt.invitation.trustedRootDER)
            try assertCurrent(attempt)
            if reply.statusCode == 409,
               let conflict = try? JSONDecoder().decode(CancellationConflict.self, from: reply.data),
               conflict.error == "stale_request",
               conflict.current.state == "pending" || conflict.current.state == "expired" {
                let response = conflict.current
                guard NativeAuthorityBinding.samePerson(response.personID, attempt.invitation.personID),
                      response.deviceID == attempt.deviceID,
                      response.approvalCode != nil, response.expiresAt != nil,
                      response.statusExpiresAt != nil, (response.requestGeneration ?? 0) > 0 else {
                    throw NativeJoinError.invalidResponse
                }
                attempt = try apply(response, to: attempt)
                guard attempt.phase == .pending || attempt.phase == .expired, let code = attempt.approvalCode,
                      let deadline = attempt.approvalExpiresAt else { return attempt }
                currentCode = code
                currentDeadline = deadline
                if retry == 1 { return attempt }
                continue
            }
            try acceptStatus(reply.statusCode, data: reply.data)
            return try apply(JSONDecoder().decode(EnrollmentReply.self, from: reply.data), to: attempt)
        }
        return attempt
    }

    func departure() throws -> NativeAccountDeparture? {
        guard let data = try loadData(account: "guided-departure") else { return nil }
        let value = try JSONDecoder().decode(NativeAccountDeparture.self, from: data)
        try value.replacement?.validate()
        return value
    }

    /// Previously disconnected profiles and their removal state stay available
    /// after a later account begins its own Disconnect operation.
    func archivedDepartures() throws -> [NativeAccountDeparture] {
        try priorDepartures().filter(\.removed)
    }

    func unconfirmedDepartures() throws -> [NativeAccountDeparture] {
        var values = try priorDepartures().filter { !$0.removed }
        if let current = try departure(), !current.removed {
            if let index = values.firstIndex(where: { $0.archiveID == current.archiveID }) {
                values[index] = current
            } else {
                values.append(current)
            }
        }
        return values
    }

    private func priorDepartures() throws -> [NativeAccountDeparture] {
        guard let data = try loadData(account: "guided-departure-archives") else { return [] }
        let decoded = try JSONDecoder().decode([NativeAccountDeparture].self, from: data)
        guard decoded.allSatisfy({ $0.replacement == nil }) else {
            throw NativeEnrollmentError.identityStorage
        }
        var values: [NativeAccountDeparture] = []
        for value in decoded {
            if let index = values.firstIndex(where: { $0.archiveID == value.archiveID }) {
                values[index] = value
            } else {
                values.append(value)
            }
        }
        return values
    }

    private func savePriorDeparture(_ departure: NativeAccountDeparture) throws {
        guard departure.replacement == nil else { throw NativeJoinError.superseded }
        var values = try priorDepartures()
        if let index = values.firstIndex(where: { $0.archiveID == departure.archiveID }) {
            if values[index].removed && !departure.removed { return }
            values[index] = departure
        } else {
            values.append(departure)
        }
        try saveData(JSONEncoder().encode(values), account: "guided-departure-archives")
    }

    private func removePriorDeparture(_ archiveID: String) throws {
        var values = try priorDepartures()
        values.removeAll { $0.archiveID == archiveID }
        if values.isEmpty {
            try deleteData(account: "guided-departure-archives")
        } else {
            try saveData(JSONEncoder().encode(values), account: "guided-departure-archives")
        }
    }

    private func retainConfirmedDeparture(_ departure: NativeAccountDeparture) throws {
        guard departure.removed else { throw NativeJoinError.superseded }
        try savePriorDeparture(NativeAccountDeparture(record: departure.record,
                                                      replacement: nil, removed: true))
    }

    private func retainPendingStandaloneDeparture(_ departure: NativeAccountDeparture) throws {
        guard !departure.removed, departure.replacement == nil else { throw NativeJoinError.superseded }
        try savePriorDeparture(departure)
    }

    private func savedDeparture(for record: NativeEnrollmentRecord) throws -> NativeAccountDeparture? {
        if let current = try departure(), current.archiveID == NativeAccountDeparture(
            record: record, replacement: nil, removed: false).archiveID {
            return current
        }
        return try priorDepartures().first {
            $0.archiveID == NativeAccountDeparture(record: record, replacement: nil, removed: false).archiveID
        }
    }

    private func saveDeparture(_ departure: NativeAccountDeparture) throws {
        if let current = try self.departure(), current.archiveID == departure.archiveID {
            try saveData(JSONEncoder().encode(departure), account: "guided-departure")
        } else {
            try savePriorDeparture(NativeAccountDeparture(record: departure.record,
                                                          replacement: nil,
                                                          removed: departure.removed))
        }
    }

    /// Writes the exact original installation before local transport is stopped
    /// or a removal request can reach the server.
    func prepareAccountDeparture(_ record: NativeEnrollmentRecord,
                                 replacement: NativeJoinInvitation? = nil) throws -> NativeAccountDeparture {
        try replacement?.validate()
        let current = try enrollment.load()
        guard let current, current.isApproved, sameInstallation(current, record) else {
            throw NativeJoinError.superseded
        }
        if let saved = try self.departure() {
            if sameInstallation(saved.record, record) {
                if saved.removed, saved.replacement == replacement { return saved }
                if !saved.removed {
                    let updated = NativeAccountDeparture(record: saved.record,
                                                        replacement: replacement,
                                                        removed: false)
                    try saveData(JSONEncoder().encode(updated), account: "guided-departure")
                    return updated
                }
                try retainConfirmedDeparture(saved)
                try deleteData(account: "guided-departure")
            } else if saved.removed {
                try retainConfirmedDeparture(saved)
                try deleteData(account: "guided-departure")
            } else {
                try retainPendingStandaloneDeparture(NativeAccountDeparture(record: saved.record,
                                                                            replacement: nil,
                                                                            removed: false))
                try deleteData(account: "guided-departure")
            }
        }
        if let saved = try savedDeparture(for: record) {
            guard !saved.removed else { throw NativeJoinError.superseded }
            let updated = NativeAccountDeparture(record: saved.record,
                                                replacement: replacement,
                                                removed: false)
            if try self.departure()?.archiveID != saved.archiveID {
                try removePriorDeparture(saved.archiveID)
            }
            try saveData(JSONEncoder().encode(updated), account: "guided-departure")
            return updated
        }
        let departure = NativeAccountDeparture(record: record, replacement: replacement, removed: false)
        try saveData(JSONEncoder().encode(departure), account: "guided-departure")
        return departure
    }

    func removeCurrentAccount(_ record: NativeEnrollmentRecord,
                              replacement: NativeJoinInvitation? = nil) async throws {
        let existing = try savedDeparture(for: record)
        var departure: NativeAccountDeparture
        if let existing, existing.removed || existing.replacement == replacement {
            departure = existing
        } else {
            departure = try prepareAccountDeparture(record, replacement: replacement)
        }
        guard departure.replacement == replacement else { throw NativeJoinError.superseded }
        if !departure.removed {
            let material = try enrollment.material(from: record)
            guard let url = URL(string: "https://\(record.host):\(record.enrollmentPort)/device/remove") else {
                throw NativeJoinError.invalidResponse
            }
            let body = try JSONSerialization.data(withJSONObject: ["expected_device_id": record.deviceID])
            let reply = try await transport.remove(url, body: body, rootDER: record.trustedRootDER,
                                                  identity: material.keychainIdentity)
            guard let operation = try savedDeparture(for: record), !operation.removed else {
                throw NativeJoinError.superseded
            }
            if let latest = try enrollment.load(), !sameInstallation(latest, record) {
                // A confirmed old removal must not overwrite or clear a newer
                // approved account that was connected while it was pending.
                guard latest.isApproved else { throw NativeJoinError.superseded }
                _ = try enrollment.material(from: latest)
            }
            try acceptStatus(reply.statusCode, data: reply.data)
            let receipt = try JSONDecoder().decode(RemovalReply.self, from: reply.data)
            guard receipt.state == "removed", NativeAuthorityBinding.samePerson(receipt.personID, record.personID),
                  receipt.deviceID == record.deviceID, receipt.enrollmentRevision > 0 else {
                throw NativeJoinError.wrongApproval
            }
            var confirmedDeparture = try savedDeparture(for: record) ?? departure
            confirmedDeparture.removed = true
            try saveDeparture(confirmedDeparture)
            departure = confirmedDeparture
        }
        try finishConfirmedDeparture(departure)
    }

    func finishConfirmedDeparture(_ departure: NativeAccountDeparture) throws {
        guard departure.removed, let saved = try savedDeparture(for: departure.record), saved.removed,
              sameInstallation(saved.record, departure.record),
              saved.replacement == departure.replacement else {
            throw NativeJoinError.superseded
        }
        try retainConfirmedDeparture(departure)
        if let attempt = try loadAttempt(), attempt.deviceID == departure.record.deviceID {
            try deleteData(account: "guided-request")
        }
        if let current = try enrollment.load(), sameInstallation(current, departure.record) {
            try enrollment.clearAfterConfirmedRemoval(of: departure.record)
        }
        if let current = try self.departure(),
           current.archiveID == departure.archiveID,
           departure.replacement != nil {
            try deleteData(account: "guided-departure")
        }
    }

    func dismissConfirmedDeparture() throws {
        guard let departure = try departure(), departure.removed else { return }
        try finishConfirmedDeparture(departure)
        try deleteData(account: "guided-departure")
    }

    private func sameInstallation(_ lhs: NativeEnrollmentRecord, _ rhs: NativeEnrollmentRecord) -> Bool {
        lhs.deviceID == rhs.deviceID && NativeAuthorityBinding.samePerson(lhs.personID, rhs.personID) && lhs.host == rhs.host &&
            lhs.enrollmentPort == rhs.enrollmentPort && lhs.trustedRootDER == rhs.trustedRootDER
    }

    private func apply(_ response: EnrollmentReply, to attempt: NativeJoinAttempt) throws -> NativeJoinAttempt {
        let current = try currentAttempt(matching: attempt)
        if current.isTerminal { return current }
        if current.phase == .approved && response.state != "approved" && response.state != "revoked" { return current }
        let generation = response.requestGeneration ?? attempt.requestGeneration ?? 0
        guard generation >= 0 else { throw NativeJoinError.invalidResponse }
        if let supplied = response.requestGeneration, supplied <= 0 { throw NativeJoinError.invalidResponse }
        let currentGeneration = current.requestGeneration ?? 0
        guard generation >= currentGeneration else { return current }
        if response.personID != nil || response.deviceID != nil {
            guard NativeAuthorityBinding.samePerson(response.personID, attempt.invitation.personID),
                  response.deviceID == attempt.deviceID else { throw NativeJoinError.wrongApproval }
        }
        if generation > currentGeneration,
           response.state == "pending" || response.state == "approved" || response.state == "expired",
           let oldCode = current.approvalCode,
           let oldDeadline = current.approvalExpiresAt {
            let normalizingLegacy = currentGeneration == 0 && response.approvalCode == oldCode && response.expiresAt == oldDeadline
            if !normalizingLegacy {
                guard let code = response.approvalCode, code != oldCode,
                      let deadline = response.expiresAt, deadline > oldDeadline else {
                    throw NativeJoinError.invalidResponse
                }
            }
        }
        if generation == currentGeneration {
            if let code = response.approvalCode, let saved = current.approvalCode, code != saved {
                throw NativeJoinError.invalidResponse
            }
            if let deadline = response.expiresAt, let saved = current.approvalExpiresAt, deadline != saved {
                throw NativeJoinError.invalidResponse
            }
            if let deadline = response.statusExpiresAt, let saved = current.statusExpiresAt, deadline != saved {
                throw NativeJoinError.invalidResponse
            }
        }
        var next = current
        if generation > 0 { next.requestGeneration = generation }
        if response.requestGeneration != nil, response.state == "pending" || response.state == "approved" {
            guard NativeAuthorityBinding.samePerson(response.personID, attempt.invitation.personID),
                  response.deviceID == attempt.deviceID else { throw NativeJoinError.wrongApproval }
        }
        if response.approvalCode != nil || response.expiresAt != nil || response.statusExpiresAt != nil {
            guard let code = response.approvalCode, code.utf8.count == 10,
                  code.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }),
                  let deadline = response.expiresAt, deadline > 0,
                  let statusDeadline = response.statusExpiresAt, statusDeadline > deadline else {
                throw NativeJoinError.invalidResponse
            }
            next.approvalCode = code
            next.approvalExpiresAt = deadline
            next.statusExpiresAt = statusDeadline
        }
        switch response.state {
        case "pending":
            if generation > currentGeneration {
                guard response.approvalCode != nil, response.expiresAt != nil,
                      response.statusExpiresAt != nil else { throw NativeJoinError.invalidResponse }
            }
            guard let code = next.approvalCode,
                  code.utf8.count == 10,
                  code.utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) }),
                  let deadline = next.approvalExpiresAt, deadline > 0,
                  let statusDeadline = next.statusExpiresAt,
                  statusDeadline > deadline else { throw NativeJoinError.invalidResponse }
            next.approvalCode = code
            next.approvalExpiresAt = deadline
            next.statusExpiresAt = statusDeadline
            next.phase = .pending
        case "expired": next.phase = .expired
        case "declined", "denied": next.phase = .declined
        case "revoked": next.phase = .revoked
        case "cancelled": next.phase = .cancelled
        case "approved":
            guard NativeAuthorityBinding.samePerson(response.personID, attempt.invitation.personID),
                  response.deviceID == attempt.deviceID else { throw NativeJoinError.wrongApproval }
            var record = NativeEnrollmentRecord(host: attempt.invitation.enrollmentURL.host!.lowercased(),
                                                enrollmentPort: attempt.invitation.enrollmentURL.port ?? 443,
                                                relayPort: attempt.invitation.relayURL.port ?? 443,
                                                trustedRootDER: attempt.invitation.trustedRootDER,
                                                identityLabel: attempt.identityLabel,
                                                deviceLabel: attempt.deviceLabel, deviceID: attempt.deviceID,
                                                approvalCode: next.approvalCode ?? "",
                                                statusSecret: attempt.statusSecret,
                                                expiresAt: next.approvalExpiresAt ?? attempt.invitation.expiresAt,
                                                statusExpiresAt: next.statusExpiresAt ?? attempt.invitation.expiresAt,
                                                personID: response.personID)
            record.serverDisplayName = attempt.invitation.serverName
            record.accountDisplayName = attempt.invitation.personName
            record.foregroundRelayConfirmed = false
            record.notificationExplanationSeen = false
            let departure = try self.departure()
            let replaceableUnconfirmedAccount = departure.flatMap { value in
                !value.removed ? value.record : nil
            }
            try enrollment.retainApprovedGuided(record, expectedPersonID: attempt.invitation.personID,
                                                 expectedDeviceID: attempt.deviceID,
                                                 replacingUnconfirmedAccount: replaceableUnconfirmedAccount)
            next.phase = .approved
        default: throw NativeJoinError.invalidResponse
        }
        next.lastCheckedAt = Date()
        try save(next)
        return next
    }

    private func assertCurrent(_ attempt: NativeJoinAttempt) throws {
        _ = try currentAttempt(matching: attempt)
    }

    private func currentAttempt(matching attempt: NativeJoinAttempt) throws -> NativeJoinAttempt {
        guard let current = try loadAttempt(), current.id == attempt.id,
              current.statusSecret == attempt.statusSecret,
              current.invitation == attempt.invitation, current.deviceID == attempt.deviceID,
              current.certificateDER == attempt.certificateDER,
              current.identityLabel == attempt.identityLabel else { throw NativeJoinError.superseded }
        return current
    }

    private func acceptStatus(_ status: Int, data: Data) throws {
        if status == 200 { return }
        let error = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
        switch (status, error) {
        case (410, _): throw NativeJoinError.expired
        case (409, "used"): throw NativeJoinError.used
        case (409, "key_pending"): throw NativeEnrollmentError.keyPending
        case (409, "key_in_use"): throw NativeEnrollmentError.keyInUse
        case (404, "not_found"): throw NativeJoinError.notFound
        case (503, _): throw NativeJoinError.unavailable
        default: throw NativeJoinError.refused
        }
    }

    private func itemQuery(account: String = "guided-request") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: namespace, kSecAttrAccount as String: account]
    }

    private func save(_ attempt: NativeJoinAttempt) throws {
        try saveData(JSONEncoder().encode(attempt), account: "guided-request")
        if let departure = try departure(), departure.removed, departure.replacement != nil {
            try retainConfirmedDeparture(departure)
            try deleteData(account: "guided-departure")
        }
    }

    private func loadData(account: String) throws -> Data? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NativeEnrollmentError.identityStorage }
        return data
    }

    private func deleteData(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeEnrollmentError.identityStorage }
    }

    private func saveData(_ data: Data, account: String) throws {
        let query = itemQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NativeEnrollmentError.identityStorage }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
            throw NativeEnrollmentError.identityStorage
        }
    }

    private struct ErrorReply: Decodable { let error: String }
    private struct CancellationConflict: Decodable {
        let error: String
        let current: EnrollmentReply
    }
    private struct RemovalReply: Decodable {
        let state: String
        let personID: String
        let deviceID: String
        let enrollmentRevision: Int64
        enum CodingKeys: String, CodingKey {
            case state
            case personID = "person_id"
            case deviceID = "device_id"
            case enrollmentRevision = "enrollment_revision"
        }
    }
    private struct EnrollmentReply: Decodable {
        let state: String
        let approvalCode: String?
        let expiresAt: Int64?
        let statusExpiresAt: Int64?
        let personID: String?
        let deviceID: String?
        let requestGeneration: Int64?
        enum CodingKeys: String, CodingKey {
            case state
            case approvalCode = "approval_code"
            case expiresAt = "expires_at"
            case statusExpiresAt = "status_expires_at"
            case personID = "person_id"
            case deviceID = "device_id"
            case requestGeneration = "request_generation"
        }
    }
}
