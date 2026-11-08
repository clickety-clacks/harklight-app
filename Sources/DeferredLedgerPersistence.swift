import Foundation

/// UserDefaults supports concurrent access; the wrapper lets the writer actor
/// use the same defaults instance without transferring its main-actor isolation.
private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private actor DefaultsLedgerWriter {
    private let defaults: SendableUserDefaults
    private let key: String
    private var latestGeneration: UInt64 = 0

    init(defaults: SendableUserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func write<Value: Codable & Sendable>(_ value: Value, generation: UInt64) {
        guard generation > latestGeneration,
              let data = try? JSONEncoder().encode(value) else { return }
        defaults.value.set(data, forKey: key)
        latestGeneration = generation
    }
}

@MainActor
private enum DefaultsLedgerWriterRegistry {
    private struct Key: Hashable {
        let defaults: ObjectIdentifier
        let name: String
    }

    private static var writers: [Key: DefaultsLedgerWriter] = [:]
    private static var generations: [Key: UInt64] = [:]

    static func writer(defaults: UserDefaults, key: String) -> DefaultsLedgerWriter {
        let registryKey = Key(defaults: ObjectIdentifier(defaults), name: key)
        if let writer = writers[registryKey] { return writer }
        let writer = DefaultsLedgerWriter(defaults: SendableUserDefaults(defaults), key: key)
        writers[registryKey] = writer
        return writer
    }

    static func nextGeneration(defaults: UserDefaults, key: String) -> UInt64 {
        let registryKey = Key(defaults: ObjectIdentifier(defaults), name: key)
        let generation = generations[registryKey, default: 0] &+ 1
        generations[registryKey] = generation
        return generation
    }
}

/// Coalesces ledger mutations on the main actor, then encodes and writes the
/// newest snapshot on a non-main actor. Generations keep a superseded store
/// from replacing a newer store's snapshot after navigation or recreation.
@MainActor
final class DeferredLedgerPersistence<Value: Codable & Sendable> {
    private struct PendingWrite {
        let value: Value
        let generation: UInt64
    }

    private let defaults: UserDefaults
    private let key: String
    private let writer: DefaultsLedgerWriter
    private var pendingWrite: PendingWrite?
    private var worker: Task<Void, Never>?

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        self.writer = DefaultsLedgerWriterRegistry.writer(defaults: defaults, key: key)
    }

    func schedule(_ value: Value) {
        pendingWrite = PendingWrite(value: value,
            generation: DefaultsLedgerWriterRegistry.nextGeneration(defaults: defaults, key: key))
        guard worker == nil else { return }

        worker = Task { @MainActor [self] in
            await Task.yield()
            while let pending = self.pendingWrite {
                self.pendingWrite = nil
                await self.writer.write(pending.value, generation: pending.generation)
            }
            self.worker = nil
        }
    }
}
