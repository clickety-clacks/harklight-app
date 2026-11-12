import Foundation

/// Enables one visible-turn measurement at first display and after each scroll
/// phase returns to idle. Row geometry is absent while a scroll is active.
struct NativeFocusScrollSampling: Equatable {
    private(set) var isIdle = true
    private(set) var needsSample = true

    var shouldMeasureTurnFrames: Bool { isIdle && needsSample }

    mutating func phaseChanged(isIdle nextIsIdle: Bool) {
        guard isIdle != nextIsIdle else { return }
        isIdle = nextIsIdle
        needsSample = nextIsIdle
    }

    mutating func didMeasureTurnFrames() {
        needsSample = false
    }
}
