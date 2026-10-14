import Foundation
import os
import Testing
@testable import Match

@Suite struct InterfaceCountersTests {
    // These run inside the sandboxed app, so they also show the kernel lets it read the counters.
    @Test func readsTheLoopbackInterface() throws {
        let counters = InterfaceCounters()
        let first = try #require(counters.counts(for: "lo0"))
        let second = try #require(counters.counts(for: "lo0"))
        #expect(second.received >= first.received)
        #expect(second.sent >= first.sent)
    }

    @Test func readsEveryInterfaceTheSystemLists() {
        var names = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            if current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                names.insert(String(cString: current.pointee.ifa_name))
            }
            entry = current.pointee.ifa_next
        }
        #expect(names.contains("lo0"))
        let counters = InterfaceCounters()
        for name in names {
            #expect(counters.counts(for: name) != nil, "no counters for \(name)")
        }
    }

    @Test func anUnknownInterfaceHasNoCounts() {
        #expect(InterfaceCounters().counts(for: "nosuch99") == nil)
        #expect(InterfaceCounters().counts(for: "") == nil)
    }
}

@Suite struct UsageMeterTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func counts(_ received: UInt64, _ sent: UInt64) -> InterfaceByteCounts {
        InterfaceByteCounts(received: received, sent: sent)
    }

    @Test func theFirstReadingIsOnlyABaseline() {
        var meter = UsageMeter()
        meter.record(counts(5_000_000_000, 1_000), at: start)
        #expect(meter.downloaded == 0)
        #expect(meter.uploaded == 0)
        #expect(meter.downloadRate == 0)
    }

    @Test func speedIsTheChangeOverTheInterval() {
        var meter = UsageMeter()
        meter.record(counts(1_000, 500), at: start)
        meter.record(counts(5_000, 1_500), at: start.addingTimeInterval(2))
        #expect(meter.downloadRate == 2_000)
        #expect(meter.uploadRate == 500)
        #expect(meter.downloaded == 4_000)
        #expect(meter.uploaded == 1_000)

        meter.record(counts(5_000, 1_500), at: start.addingTimeInterval(4))
        #expect(meter.downloadRate == 0)
        #expect(meter.downloaded == 4_000)
    }

    @Test func countsBeyondFourGigabytesDoNotWrap() {
        var meter = UsageMeter()
        let fourGigabytes: UInt64 = 4_294_967_296
        meter.record(counts(fourGigabytes - 1_000, 0), at: start)
        meter.record(counts(fourGigabytes + 9_000, 0), at: start.addingTimeInterval(2))
        #expect(meter.downloaded == 10_000)
        meter.record(counts(fourGigabytes * 3, 0), at: start.addingTimeInterval(4))
        #expect(meter.downloaded == fourGigabytes * 2 + 1_000)
    }

    @Test func aCounterResetStartsANewBaseline() {
        var meter = UsageMeter()
        meter.record(counts(1_000_000, 500_000), at: start)
        meter.record(counts(1_500_000, 600_000), at: start.addingTimeInterval(2))
        #expect(meter.downloaded == 500_000)

        // The interface went down and came back: its counters start again from zero.
        meter.record(counts(2_000, 1_000), at: start.addingTimeInterval(4))
        #expect(meter.downloaded == 500_000)
        #expect(meter.uploaded == 100_000)
        #expect(meter.downloadRate == 0)

        meter.record(counts(12_000, 3_000), at: start.addingTimeInterval(6))
        #expect(meter.downloaded == 510_000)
        #expect(meter.uploaded == 102_000)
        #expect(meter.downloadRate == 5_000)
    }

    @Test func twoReadingsAtTheSameInstantDoNotDivideByZero() {
        var meter = UsageMeter()
        meter.record(counts(0, 0), at: start)
        meter.record(counts(100, 100), at: start)
        #expect(meter.downloaded == 100)
        #expect(meter.downloadRate.isFinite)
    }

    @Test func resetClearsTheTotal() {
        var meter = UsageMeter()
        meter.record(counts(0, 0), at: start)
        meter.record(counts(100, 100), at: start.addingTimeInterval(1))
        meter.reset()
        #expect(meter == UsageMeter())
    }
}

@Suite @MainActor struct SessionStoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("match-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private func portalSession(endingAt end: Date, duration: TimeInterval = 600) -> PortalSession {
        PortalSession(
            loginTime: end.addingTimeInterval(-duration), logoutTime: end, duration: duration,
            uploadBytes: 1_234, downloadBytes: 5_678
        )
    }

    @Test func recordsSurviveARelaunch() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = SessionStore(fileURL: file)
        store.recordMeasured(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), downloadBytes: 10, uploadBytes: 20)
        store.record(portalSession(endingAt: now))

        let reopened = SessionStore(fileURL: file)
        #expect(reopened.records == store.records)
        #expect(reopened.records.map(\.source) == [.portal, .measured])
        #expect(reopened.latest?.downloadBytes == 5_678)
    }

    @Test func theHistoryFileHoldsNothingSecret() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: file)
        store.record(portalSession(endingAt: now))
        let text = try String(contentsOf: file, encoding: .utf8)
        // Only times and byte counts.
        let keys = Set(text.matches(of: #/"([A-Za-z]+)"\s*:/#).map { String($0.output.1) })
        #expect(keys == ["records", "id", "start", "end", "downloadBytes", "uploadBytes", "source"])
    }

    @Test func thePortalsFiguresReplaceMatchsOwnForTheSameSession() {
        let store = SessionStore(fileURL: nil)
        store.recordMeasured(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-2), downloadBytes: 999, uploadBytes: 999)
        store.record(portalSession(endingAt: now))
        #expect(store.records.count == 1)
        #expect(store.records.first?.source == .portal)

        // In the other order, the measured copy is not added.
        let other = SessionStore(fileURL: nil)
        other.record(portalSession(endingAt: now))
        other.recordMeasured(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3), downloadBytes: 999, uploadBytes: 999)
        #expect(other.records.map(\.source) == [.portal])
    }

    @Test func separateSessionsAreBothKept() {
        let store = SessionStore(fileURL: nil)
        store.recordMeasured(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), downloadBytes: 1, uploadBytes: 1)
        store.record(portalSession(endingAt: now))
        #expect(store.records.count == 2)
    }

    @Test func aSessionCutShortByARestartIsKept() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = SessionStore(fileURL: file)
        store.checkpoint(start: now, end: now.addingTimeInterval(60), downloadBytes: 100, uploadBytes: 10)
        store.checkpoint(start: now, end: now.addingTimeInterval(120), downloadBytes: 250, uploadBytes: 25)
        #expect(store.records.isEmpty)
        #expect(store.open?.downloadBytes == 250)
        // The app is killed here, with no chance to close the session.

        let reopened = SessionStore(fileURL: file)
        #expect(reopened.open == nil)
        #expect(reopened.records.count == 1)
        #expect(reopened.records.first?.end == now.addingTimeInterval(120))
        #expect(reopened.records.first?.downloadBytes == 250)

        // And it is not added a second time on the launch after that.
        #expect(SessionStore(fileURL: file).records.count == 1)
    }

    @Test func closingASessionClearsItsCheckpoint() {
        let store = SessionStore(fileURL: nil)
        store.checkpoint(start: now, end: now.addingTimeInterval(60), downloadBytes: 100, uploadBytes: 10)
        store.recordMeasured(start: now, end: now.addingTimeInterval(90), downloadBytes: 150, uploadBytes: 15)
        #expect(store.open == nil)
        #expect(store.records.count == 1)

        store.checkpoint(start: now, end: now.addingTimeInterval(60), downloadBytes: 100, uploadBytes: 10)
        store.discardOpen()
        #expect(store.open == nil)
        #expect(store.records.count == 1)
    }

    @Test func theHistoryIsCappedAndNewestFirst() {
        let store = SessionStore(fileURL: nil)
        for index in 0..<(SessionStore.maxRecords + 20) {
            let end = now.addingTimeInterval(TimeInterval(index) * 3600)
            store.recordMeasured(start: end.addingTimeInterval(-600), end: end, downloadBytes: Int64(index), uploadBytes: 0)
        }
        #expect(store.records.count == SessionStore.maxRecords)
        #expect(store.records.first?.downloadBytes == Int64(SessionStore.maxRecords + 19))
        #expect(store.records.last?.downloadBytes == 20)
    }

    @Test func aDamagedFileStartsAnEmptyHistory() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        let store = SessionStore(fileURL: file)
        #expect(store.records.isEmpty)
        store.record(portalSession(endingAt: now))
        #expect(SessionStore(fileURL: file).records.count == 1)
    }

    @Test func clearRemovesEverything() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: file)
        store.record(portalSession(endingAt: now))
        store.checkpoint(start: now, end: now.addingTimeInterval(60), downloadBytes: 1, uploadBytes: 1)
        store.clear()
        #expect(store.records.isEmpty)
        #expect(SessionStore(fileURL: file).records.isEmpty)
    }
}

@Suite @MainActor struct UsageMonitorTests {
    private final class Time: Sendable {
        private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { current.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
    }

    private let time = Time()
    private let counters = FakeCounters()
    private let sessions = SessionStore(fileURL: nil)

    private func makeMonitor() -> UsageMonitor {
        let time = time
        return UsageMonitor(counters: counters, interface: { "en0" }, sessions: sessions, now: { time.now })
    }

    @Test func measuresASessionFromConnectedToDisconnected() {
        let monitor = makeMonitor()
        counters.set(received: 1_000_000, sent: 100_000)
        let since = time.now
        monitor.connectionChanged(to: .connected(since: since))
        #expect(monitor.sessionStart == since)
        #expect(monitor.isSampling)
        #expect(monitor.sessionDownloaded == 0)

        time.advance(2)
        counters.set(received: 1_500_000, sent: 120_000)
        monitor.sample()
        #expect(monitor.downloadRate == 250_000)
        #expect(monitor.uploadRate == 10_000)
        #expect(monitor.sessionDownloaded == 500_000)
        #expect(monitor.sessionUploaded == 20_000)

        time.advance(298)
        counters.set(received: 9_000_000, sent: 400_000)
        monitor.connectionChanged(to: .checking)

        #expect(monitor.sessionStart == nil)
        #expect(!monitor.isSampling)
        #expect(monitor.downloadRate == 0)
        #expect(sessions.records.count == 1)
        let record = sessions.records[0]
        #expect(record.source == .measured)
        #expect(record.start == since)
        #expect(record.duration == 300)
        #expect(record.downloadBytes == 8_000_000)
        #expect(record.uploadBytes == 300_000)
    }

    @Test func aRecheckThatStaysConnectedDoesNotSplitTheSession() {
        let monitor = makeMonitor()
        counters.set(received: 0, sent: 0)
        let since = time.now
        monitor.connectionChanged(to: .connected(since: since))
        time.advance(120)
        counters.set(received: 1_000, sent: 1_000)
        // The engine re-announces the same connection, as after a wake.
        monitor.connectionChanged(to: .connected(since: since))
        #expect(sessions.records.isEmpty)
        #expect(monitor.sessionStart == since)

        // A new sign-in is a new session.
        time.advance(60)
        monitor.connectionChanged(to: .connected(since: time.now))
        #expect(sessions.records.count == 1)
        #expect(monitor.sessionDownloaded == 0)
    }

    @Test func veryShortSessionsAreNotRecorded() {
        let monitor = makeMonitor()
        counters.set(received: 0, sent: 0)
        monitor.connectionChanged(to: .connected(since: time.now))
        time.advance(20)
        counters.set(received: 500, sent: 500)
        monitor.connectionChanged(to: .noWiFi)
        #expect(sessions.records.isEmpty)
        #expect(sessions.open == nil)
    }

    @Test func aLongSessionIsCheckpointedOnceAMinute() {
        let monitor = makeMonitor()
        counters.set(received: 0, sent: 0)
        let since = time.now
        monitor.connectionChanged(to: .connected(since: since))

        for step in 1...29 {
            time.advance(2)
            counters.set(received: UInt64(step) * 1_000, sent: 0)
            monitor.sample()
        }
        #expect(sessions.open == nil)

        time.advance(2)
        counters.set(received: 30_000, sent: 0)
        monitor.sample()
        #expect(sessions.open?.start == since)
        #expect(sessions.open?.end == since.addingTimeInterval(60))
        #expect(sessions.open?.downloadBytes == 30_000)
        #expect(sessions.records.isEmpty)
    }

    @Test func quittingClosesTheSession() {
        let monitor = makeMonitor()
        counters.set(received: 0, sent: 0)
        monitor.connectionChanged(to: .connected(since: time.now))
        time.advance(600)
        counters.set(received: 42_000, sent: 7_000)
        monitor.flush()
        #expect(sessions.records.count == 1)
        #expect(sessions.records.first?.downloadBytes == 42_000)
        #expect(sessions.open == nil)
    }

    @Test func aLoggedOutSessionEndsUpWithThePortalsFigures() {
        let monitor = makeMonitor()
        counters.set(received: 0, sent: 0)
        let since = time.now
        monitor.connectionChanged(to: .connected(since: since))
        time.advance(600)
        counters.set(received: 99_000, sent: 9_000)

        // Logging out: the engine leaves "connected", then reports the portal's figures.
        monitor.connectionChanged(to: .checking)
        #expect(sessions.records.map(\.source) == [.measured])
        time.advance(1)
        sessions.record(PortalSession(
            loginTime: since, logoutTime: time.now, duration: 600, uploadBytes: 1_234, downloadBytes: 5_678
        ))
        #expect(sessions.records.map(\.source) == [.portal])
        #expect(sessions.records.first?.downloadBytes == 5_678)
    }

    @Test func theMenuAloneKeepsTheSpeedUpToDate() {
        let monitor = makeMonitor()
        #expect(!monitor.isSampling)
        monitor.menuIsOpen = true
        #expect(monitor.isSampling)

        counters.set(received: 0, sent: 0)
        monitor.sample()
        time.advance(2)
        counters.set(received: 4_000, sent: 2_000)
        monitor.sample()
        #expect(monitor.downloadRate == 2_000)
        // No session is being measured, so nothing is totalled or recorded.
        #expect(monitor.sessionDownloaded == 0)

        monitor.menuIsOpen = false
        #expect(!monitor.isSampling)
        #expect(monitor.downloadRate == 0)
        #expect(sessions.records.isEmpty)
    }

    @Test func aMissingInterfaceIsHarmless() {
        let monitor = makeMonitor()
        counters.setUnavailable()
        monitor.connectionChanged(to: .connected(since: time.now))
        monitor.sample()
        #expect(monitor.downloadRate == 0)
        time.advance(120)
        monitor.connectionChanged(to: .noWiFi)
        #expect(sessions.records.first?.downloadBytes == 0)
    }
}

@Suite struct UsageCopyTests {
    @Test func speedsNeverGoNegativeOrBlank() {
        #expect(StatusCopy.speed(0).hasSuffix("/s"))
        #expect(StatusCopy.speed(-5) == StatusCopy.speed(0))
        #expect(StatusCopy.speed(1_500_000) != StatusCopy.speed(0))
        // Numbers, not words: "0 kB/s" rather than "Zero kB/s".
        #expect(StatusCopy.speed(0).first?.isNumber == true)
        #expect(StatusCopy.bytes(0).first?.isNumber == true)
    }

    @Test func aRecordSummaryMatchesThePortalSessionSummary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = PortalSession(
            loginTime: now.addingTimeInterval(-3723), logoutTime: now, duration: 3723,
            uploadBytes: 1_234, downloadBytes: 5_678
        )
        #expect(StatusCopy.summary(of: SessionRecord(session)) == StatusCopy.summary(of: session))
    }
}
