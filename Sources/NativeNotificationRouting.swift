import AttentionDomain
import Foundation
import Observation

struct NativeNotificationBinding: Codable, Equatable {
    let bindingID: ExactText
    let operationID: UUID
    let revision: UInt64
}

struct NativeNotificationProfile: Codable, Equatable {
    let identity: ProfileIdentity
    let trustedRootDER: Data
    let generation: UUID

    init?(_ record: NativeEnrollmentRecord) {
        guard let person = record.personID, let generation = record.notificationProfileGeneration else { return nil }
        identity = ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
            personID: ExactText(person), deviceID: ExactText(record.deviceID))
        trustedRootDER = record.trustedRootDER
        self.generation = generation
    }
}

extension NativeEnrollmentRecord {
    func matchesNotificationIdentity(_ identity: ProfileIdentity) -> Bool {
        isApproved && ExactText(profileAuthority) == identity.trustedRelayAuthority &&
            personID.map { ExactText($0) } == identity.personID && ExactText(deviceID) == identity.deviceID
    }

    func sameNotificationProfile(as other: Self) -> Bool {
        isApproved && other.isApproved && ExactText(profileAuthority) == ExactText(other.profileAuthority) &&
            NativeAuthorityBinding.samePerson(personID, other.personID) && ExactText(deviceID) == ExactText(other.deviceID) &&
            trustedRootDER == other.trustedRootDER && identityLabel == other.identityLabel &&
            notificationProfileGeneration == other.notificationProfileGeneration
    }
}

struct NativeNotificationLocator: Codable, Equatable {
    let bindingID: ExactText
    let deviceID: ExactText
    let request: RequestKey
    let acceptanceSequence: UInt64

    init?(_ payload: JSONValue) {
        guard let attention = payload.uniqueValue(named: "attention"),
              attention.uniqueValue(named: "v")?.integerValue == 1,
              attention.uniqueValue(named: "type")?.stringValue?.rawValue == "sync",
              let locator = attention.uniqueValue(named: "locator"),
              locator.uniqueValue(named: "v")?.integerValue == 1,
              let binding = locator.uniqueValue(named: "binding_id")?.stringValue,
              UUID(uuidString: binding.rawValue) != nil,
              let person = locator.uniqueValue(named: "person_id")?.stringValue, !person.rawValue.isEmpty,
              let device = locator.uniqueValue(named: "device_id")?.stringValue, !device.rawValue.isEmpty,
              let sender = locator.uniqueValue(named: "sender_id")?.stringValue, !sender.rawValue.isEmpty,
              let message = locator.uniqueValue(named: "message_id")?.stringValue, !message.rawValue.isEmpty,
              case let .number(number)? = locator.uniqueValue(named: "acceptance_seq"),
              let sequence = UInt64(number.lexeme), sequence > 0 else { return nil }
        bindingID = binding
        deviceID = device
        request = RequestKey(accountScope: person, senderID: sender, messageID: message)
        acceptanceSequence = sequence
    }

    func profile(in records: [NativeEnrollmentRecord]) -> NativeNotificationProfile? {
        let matches = records.filter { record in
            (record.notificationBindings ?? []).contains { $0.bindingID == bindingID }
        }
        guard matches.count == 1, let record = matches.first,
              NativeAuthorityBinding.samePerson(record.personID, request.accountScope.rawValue),
              ExactText(record.deviceID) == deviceID else { return nil }
        return NativeNotificationProfile(record)
    }
}

struct NativeNotificationIntent: Codable, Equatable {
    let serial: UInt64
    var locator: NativeNotificationLocator?
    var profile: NativeNotificationProfile?
}

struct NativeInboxNavigation: Equatable {
    let serial: UInt64
    let request: RequestKey?
}

/// The persisted data is navigation only. It never enters the answer/outbox store.
@MainActor
@Observable
final class NativeNotificationRouter {
    static let shared = NativeNotificationRouter()
    private(set) var intent: NativeNotificationIntent?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "harklight.notification.navigation"
    @ObservationIgnored private var liveGeneration: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        intent = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NativeNotificationIntent.self, from: $0) }
    }

    func receive(_ payload: JSONValue, opened: Bool) {
        guard opened else { return }
        let serial = UInt64(defaults.string(forKey: key + ".serial") ?? "0") ?? 0
        intent = NativeNotificationIntent(serial: serial &+ 1, locator: NativeNotificationLocator(payload))
        liveGeneration = nil
        defaults.set(String(serial &+ 1), forKey: key + ".serial")
        persist()
    }

    /// Resolve only within already selected authenticated profiles. The caller
    /// never includes removed accounts or read-only archives in this list.
    func resolve(records: [NativeEnrollmentRecord], context: ProfileContext,
                 requests: [PresentedRequest], synchronized: Bool) -> RequestKey? {
        guard var pending = intent, let locator = pending.locator else { return nil }
        guard let profile = locator.profile(in: records), profile.identity == context.identity,
              pending.profile == nil || pending.profile == profile,
              liveGeneration == nil || liveGeneration == context.generation else {
            fallback()
            return nil
        }
        pending.profile = profile
        intent = pending
        liveGeneration = context.generation
        persist()
        guard synchronized, let request = requests.first(where: { $0.key == locator.request }),
              request.acceptanceOrder == locator.acceptanceSequence else { return nil }
        return request.key
    }

    func fallback() {
        guard var pending = intent else { return }
        pending.locator = nil
        pending.profile = nil
        intent = pending
        liveGeneration = nil
        persist()
    }

    func consumed() {
        intent = nil
        liveGeneration = nil
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        if let intent, let data = try? JSONEncoder().encode(intent) { defaults.set(data, forKey: key) }
    }
}
