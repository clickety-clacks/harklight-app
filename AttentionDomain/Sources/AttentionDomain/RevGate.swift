import Foundation

/// The one write rule for the local model (design section 3.2): a snapshot
/// item or a change is applied only if its `rev` is newer than the held one.
/// A removal is a tombstone at its `rev`, kept for the change log's retention
/// window, so an older snapshot cannot bring the item back.
public struct RevGate: Codable, Equatable, Sendable {
    public static let tombstoneRetention: TimeInterval = 30 * 24 * 3600

    public internal(set) var held: [String: UInt64] = [:]
    public internal(set) var removedAt: [String: Date] = [:]

    public init() {}

    /// True when `rev` is newer than what is held for `resource`; it is then
    /// recorded as held (and any tombstone is cleared).
    public mutating func admit(_ resource: String, rev: UInt64) -> Bool {
        if let current = held[resource], current >= rev { return false }
        held[resource] = rev
        removedAt[resource] = nil
        return true
    }

    /// Records a removal at `rev`. Returns false when a newer write is held.
    public mutating func admitRemoval(_ resource: String, rev: UInt64, at now: Date) -> Bool {
        if let current = held[resource], current >= rev { return false }
        held[resource] = rev
        removedAt[resource] = now
        return true
    }

    public func isRemoved(_ resource: String) -> Bool { removedAt[resource] != nil }

    public func holds(_ resource: String, atLeast rev: UInt64) -> Bool {
        (held[resource] ?? 0) >= rev
    }

    /// Forgets tombstones older than the retention window; past it, the
    /// server answers `410` and the client rebaselines anyway.
    public mutating func pruneTombstones(now: Date) {
        for (resource, at) in removedAt where now.timeIntervalSince(at) > Self.tombstoneRetention {
            removedAt[resource] = nil
            held[resource] = nil
        }
    }
}
