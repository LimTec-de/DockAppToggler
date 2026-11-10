import Foundation
import Testing
@testable import DockAppToggler

/// The Dock hover state is driven by throttled mouse-move samples. Whatever
/// the throttle drops, the position the pointer comes to rest at must still
/// be evaluated, otherwise chooser and preview stay open after the pointer
/// has left (a resting mouse sends no further events).
struct TrailingThrottleTests {
    @Test func firstSampleAndSamplesAfterTheIntervalAreProcessed() {
        var throttle = TrailingThrottle(interval: 0.05)
        #expect(throttle.submit(at: 10.000) == .process)
        #expect(throttle.submit(at: 10.050) == .process)
        #expect(throttle.submit(at: 10.200) == .process)
    }

    @Test func droppedSampleSchedulesExactlyOneTrailingEvaluation() {
        var throttle = TrailingThrottle(interval: 0.05)
        #expect(throttle.submit(at: 10.000) == .process)

        guard case .scheduleTrailing(let delay) = throttle.submit(at: 10.008) else {
            Issue.record("a dropped sample must schedule a trailing evaluation")
            return
        }
        #expect(abs(delay - 0.042) < 1e-9)
        #expect(throttle.submit(at: 10.016) == .trailingPending)
        #expect(throttle.submit(at: 10.040) == .trailingPending)
    }

    /// A quick flick away from a Dock icon: samples every 8 ms for 96 ms,
    /// then the mouse rests. The old drop-only throttles (50 ms in the event
    /// tap, 80 ms behind it) evaluated none of these samples.
    @Test func everyBurstEndsWithAnEvaluationAtOrAfterItsLastSample() {
        for burstLength in 1...40 {
            var throttle = TrailingThrottle(interval: 0.05)
            var lastEvaluation = 0.0
            var trailingDue: Double?
            #expect(throttle.submit(at: 0) == .process)

            var lastSample = 0.0
            for step in 1...burstLength {
                let now = Double(step) * 0.008
                if let due = trailingDue, due <= now {
                    throttle.trailingFired(at: due)
                    lastEvaluation = due
                    trailingDue = nil
                }
                switch throttle.submit(at: now) {
                case .process: lastEvaluation = now
                case .scheduleTrailing(let delay): trailingDue = now + delay
                case .trailingPending: break
                }
                lastSample = now
            }
            if let due = trailingDue {
                throttle.trailingFired(at: due)
                lastEvaluation = due
            }
            #expect(lastEvaluation >= lastSample, "burst of \(burstLength) samples")
            #expect(lastEvaluation - lastSample <= 0.05 + 1e-9, "burst of \(burstLength) samples")
        }
    }

    @Test func trailingEvaluationCountsAsProcessedSample() {
        var throttle = TrailingThrottle(interval: 0.05)
        #expect(throttle.submit(at: 1.000) == .process)
        guard case .scheduleTrailing = throttle.submit(at: 1.010) else {
            Issue.record("expected the sample to be deferred")
            return
        }
        throttle.trailingFired(at: 1.050)
        // Right after the trailing evaluation the rate limit applies again …
        guard case .scheduleTrailing = throttle.submit(at: 1.060) else {
            Issue.record("expected the sample to be deferred")
            return
        }
        throttle.trailingFired(at: 1.100)
        // … and a later sample is processed directly.
        #expect(throttle.submit(at: 1.200) == .process)
    }
}
