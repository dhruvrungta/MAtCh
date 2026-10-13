import Foundation
import os

/// A clock that only moves when a test advances it.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration = .zero

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant()
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Swift.Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let dueIDs = state.sleepers.filter { $0.value.deadline <= state.now }.map(\.key)
            return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0) }
                .sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// How long each current sleeper still has to wait.
    var pendingSleeps: [Swift.Duration] {
        state.withLock { state in
            state.sleepers.values.map { state.now.duration(to: $0.deadline) }.sorted()
        }
    }

    /// Waits (in real time) until something is sleeping for exactly `duration`.
    func waitForSleep(of duration: Swift.Duration, timeout: Swift.Duration = .seconds(5)) async -> Bool {
        await eventually(timeout: timeout) { self.pendingSleeps.contains(duration) }
    }
}

/// A test clock together with a wall clock that follows it, plus a skew for
/// simulating the Mac having slept.
final class TestTime: Sendable {
    let clock = TestClock()
    private let skew = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    var date: Date {
        let offset = clock.now.offset
        let seconds = Double(offset.components.seconds) + Double(offset.components.attoseconds) * 1e-18
        return Self.start.addingTimeInterval(seconds + skew.withLock { $0 })
    }

    /// Jumps the wall clock without moving the timer, as sleep does.
    func sleepMac(for seconds: TimeInterval) {
        skew.withLock { $0 += seconds }
    }
}

/// Polls `condition` in real time until it holds.
func eventually(
    timeout: Swift.Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
