import Foundation

/// Rate limiter for pointer samples that never loses the final position.
///
/// A plain "drop everything that arrives within `interval`" throttle forgets
/// where the pointer came to rest: a mouse at rest sends no further events,
/// so if the last samples of a movement were dropped, the hover state stays
/// at whatever the last *processed* sample saw (menu and preview stay open
/// although the pointer left the Dock long ago). This throttle reports a
/// dropped sample as a trailing evaluation that the caller must schedule.
struct TrailingThrottle {
    enum Decision: Equatable {
        /// Evaluate this sample now.
        case process
        /// Sample dropped; evaluate the pointer once after this delay.
        case scheduleTrailing(after: TimeInterval)
        /// Sample dropped; a trailing evaluation is already scheduled.
        case trailingPending
    }

    let interval: TimeInterval
    private var lastProcessed: TimeInterval = -.infinity
    private var isTrailingScheduled = false

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func submit(at now: TimeInterval) -> Decision {
        let elapsed = now - lastProcessed
        if elapsed >= interval {
            lastProcessed = now
            return .process
        }
        if isTrailingScheduled {
            return .trailingPending
        }
        isTrailingScheduled = true
        return .scheduleTrailing(after: max(0, interval - elapsed))
    }

    /// Call when the scheduled trailing evaluation runs.
    mutating func trailingFired(at now: TimeInterval) {
        isTrailingScheduled = false
        lastProcessed = now
    }
}
