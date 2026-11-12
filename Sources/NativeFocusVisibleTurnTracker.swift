import CoreGraphics
import Foundation
import AttentionDomain

/// Keeps row geometry outside SwiftUI observation and selects a visible turn
/// only when the caller says scrolling has settled.
@MainActor
final class NativeFocusVisibleTurnTracker {
    private var framesByEventID: [String: CGRect] = [:]
    private var visibleRect: CGRect?
    private var selectedEventID: String?

    func updateFrame(_ frame: CGRect, for eventID: String) {
        guard framesByEventID[eventID] != frame else { return }
        framesByEventID[eventID] = frame
    }

    func removeFrame(for eventID: String) {
        framesByEventID[eventID] = nil
    }

    func updateVisibleRect(_ rect: CGRect) {
        visibleRect = rect
    }

    func reset() {
        framesByEventID.removeAll(keepingCapacity: true)
        visibleRect = nil
        selectedEventID = nil
    }

    /// Returns the newest turn at the bottom, or the turn with the greatest
    /// visible height elsewhere. `orderedEventIDs` supplies a stable tie order.
    /// Call after scrolling settles; geometry updates alone never select a turn.
    func settle(orderedEventIDs: [String],
                newestEventID: String?,
                isAtNewestTurn: Bool) -> String? {
        guard let newestEventID else {
            selectedEventID = nil
            return nil
        }
        if isAtNewestTurn {
            selectedEventID = newestEventID
            return newestEventID
        }
        guard let visibleRect, !visibleRect.isNull else { return nil }

        var bestID: String?
        var bestHeight: CGFloat = 0
        for eventID in orderedEventIDs {
            guard let frame = framesByEventID[eventID] else { continue }
            let height = max(0, min(frame.maxY, visibleRect.maxY) - max(frame.minY, visibleRect.minY))
            guard height > 0 else { continue }
            if height > bestHeight || (height == bestHeight && eventID == selectedEventID) {
                bestID = eventID
                bestHeight = height
            }
        }

        guard let bestID else { return nil }
        selectedEventID = bestID
        return bestID
    }

    func chatVisibility(for turns: [ConversationTurn],
                        isAtNewestTurn: Bool) -> NativeFocusChatVisibility? {
        guard let newestTurn = turns.last else {
            reset()
            return .noTurns
        }
        let eventIDs = turns.map { $0.id.rawValue }
        guard let eventID = settle(orderedEventIDs: eventIDs,
                                  newestEventID: newestTurn.id.rawValue,
                                  isAtNewestTurn: isAtNewestTurn) else { return nil }
        return .eventID(eventID)
    }
}
