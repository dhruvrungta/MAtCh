import Foundation

/// Watches a signed-in connection and reports when something needs doing about it.
struct HealthChecker: Sendable {
    enum Verdict: Equatable, Sendable {
        /// Enough consecutive probes failed that the session has probably expired.
        case sessionLost
        /// Far more wall-clock time passed than the timer accounts for: the Mac slept.
        case wokeFromSleep
    }

    var interval: Duration = .seconds(60)
    var probeTimeout: Duration = .seconds(5)
    var maxConsecutiveFailures = 3

    /// Probes every `interval` until there is a verdict. Returns `nil` when cancelled.
    ///
    /// One failed probe on congested Wi-Fi is normal, so only a run of failures counts.
    func run(
        clock: any Clock<Duration>,
        now: @Sendable () -> Date,
        probe: @Sendable () async -> ProbeResult
    ) async -> Verdict? {
        var failures = 0
        var lastTick = now()
        while true {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return nil
            }

            let tick = now()
            let gap = tick.timeIntervalSince(lastTick)
            lastTick = tick
            if gap > 2 * interval.seconds {
                return .wokeFromSleep
            }

            let result = await probe()
            if Task.isCancelled { return nil }
            if result == .online {
                failures = 0
            } else {
                failures += 1
                Log.engine.debug("health check failed (\(failures)/\(maxConsecutiveFailures))")
                if failures >= maxConsecutiveFailures {
                    return .sessionLost
                }
            }
        }
    }
}
