import Foundation
import Observation

/// Measures the Wi-Fi interface's traffic: the current speed for the menu, and the
/// total for each signed-in session, which it hands to the session history.
@MainActor
@Observable
final class UsageMonitor {
    static let sampleInterval: Duration = .seconds(2)
    /// How often the session in progress is written to disk.
    static let checkpointInterval: TimeInterval = 60
    /// Shorter sessions than this are not worth a line in the history.
    static let minimumSessionLength: TimeInterval = 60

    /// Bytes per second.
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0
    /// Bytes since the current session began.
    private(set) var sessionDownloaded: UInt64 = 0
    private(set) var sessionUploaded: UInt64 = 0
    private(set) var sessionStart: Date?

    /// Set by the menu while it is on screen.
    var menuIsOpen = false {
        didSet { updateSampling() }
    }

    @ObservationIgnored private let counters: any ByteCounting
    @ObservationIgnored private let interface: () -> String
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var meter = UsageMeter()
    @ObservationIgnored private var lastCheckpoint: Date?
    @ObservationIgnored private var sampling: Task<Void, Never>?

    init(
        counters: any ByteCounting,
        interface: @escaping () -> String,
        sessions: SessionStore,
        now: @escaping () -> Date = { Date() }
    ) {
        self.counters = counters
        self.interface = interface
        self.sessions = sessions
        self.now = now
    }

    var isSampling: Bool { sampling != nil }

    /// Follows the engine: a session lasts for as long as it stays connected.
    func connectionChanged(to state: EngineState) {
        if case .connected(let since) = state {
            if sessionStart != since {
                endSession()
                beginSession(since: since)
            }
        } else {
            endSession()
        }
        updateSampling()
    }

    /// Takes one reading. Called on a timer, and directly by tests.
    func sample() {
        guard let counts = counters.counts(for: interface()) else { return }
        let time = now()
        meter.record(counts, at: time)
        downloadRate = meter.downloadRate
        uploadRate = meter.uploadRate
        guard let sessionStart else { return }

        sessionDownloaded = meter.downloaded
        sessionUploaded = meter.uploaded
        if time.timeIntervalSince(lastCheckpoint ?? sessionStart) >= Self.checkpointInterval {
            lastCheckpoint = time
            sessions.checkpoint(
                start: sessionStart, end: time,
                downloadBytes: Int64(clamping: sessionDownloaded), uploadBytes: Int64(clamping: sessionUploaded)
            )
        }
    }

    /// Closes the session in progress, for when the app is about to quit.
    func flush() {
        endSession()
    }

    private func beginSession(since: Date) {
        meter.reset()
        sessionStart = since
        sessionDownloaded = 0
        sessionUploaded = 0
        lastCheckpoint = nil
        sample()
    }

    private func endSession() {
        guard let start = sessionStart else { return }
        sample()
        let end = now()
        sessionStart = nil
        if end.timeIntervalSince(start) >= Self.minimumSessionLength {
            sessions.recordMeasured(
                start: start, end: end,
                downloadBytes: Int64(clamping: sessionDownloaded), uploadBytes: Int64(clamping: sessionUploaded)
            )
        } else {
            sessions.discardOpen()
        }
    }

    /// Samples only while someone can see the result or a session is being measured.
    private func updateSampling() {
        let wanted = menuIsOpen || sessionStart != nil
        if wanted, sampling == nil {
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.sampleInterval)
                    if Task.isCancelled { return }
                    self?.sample()
                }
            }
        } else if !wanted, sampling != nil {
            sampling?.cancel()
            sampling = nil
            meter.clearRates()
            downloadRate = 0
            uploadRate = 0
        }
    }
}
