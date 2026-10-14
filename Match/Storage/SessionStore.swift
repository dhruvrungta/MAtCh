import Foundation
import Observation

/// Receives the sessions the portal reports when signing out.
protocol SessionRecording: Sendable {
    func record(_ session: PortalSession) async
}

/// One stretch of being signed in.
struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Figures the portal reported at sign-out.
        case portal
        /// Figures Match measured itself, from the Wi-Fi interface's counters.
        case measured
    }

    var id = UUID()
    var start: Date
    var end: Date
    var downloadBytes: Int64
    var uploadBytes: Int64
    var source: Source

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

extension SessionRecord {
    init(_ session: PortalSession) {
        self.init(
            start: session.loginTime,
            end: session.logoutTime,
            downloadBytes: session.downloadBytes,
            uploadBytes: session.uploadBytes,
            source: .portal
        )
    }
}

/// The history of sessions, kept in a small JSON file.
@MainActor
@Observable
final class SessionStore: SessionRecording {
    static let maxRecords = 500
    /// A measured session ending this close to a portal-reported one is the same
    /// session, and the portal's figures replace it.
    static let sameSessionWindow: TimeInterval = 30

    /// Newest first.
    private(set) var records: [SessionRecord] = []
    /// The session in progress, as of its last checkpoint. It is written to disk so
    /// that a session cut short by a restart is not lost.
    private(set) var open: SessionRecord?

    @ObservationIgnored private let fileURL: URL?

    private struct Contents: Codable {
        var records: [SessionRecord]
        var open: SessionRecord?
    }

    /// `fileURL` nil keeps everything in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    var latest: SessionRecord? { records.first }

    /// The file in the app's Application Support folder.
    static func defaultFileURL(name: String = "sessions.json") -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return support.appendingPathComponent("Match", isDirectory: true).appendingPathComponent(name)
    }

    // MARK: Recording

    /// A session the portal reported at sign-out.
    func record(_ session: PortalSession) {
        let reported = SessionRecord(session)
        records.removeAll { record in
            record.source == .measured && abs(record.end.timeIntervalSince(reported.end)) <= Self.sameSessionWindow
        }
        open = nil
        insert(reported)
    }

    /// A session Match measured itself.
    func recordMeasured(start: Date, end: Date, downloadBytes: Int64, uploadBytes: Int64) {
        open = nil
        // The portal's own figures for the same session may already be here.
        let alreadyReported = records.contains { record in
            record.source == .portal && abs(record.end.timeIntervalSince(end)) <= Self.sameSessionWindow
        }
        guard !alreadyReported else {
            save()
            return
        }
        insert(SessionRecord(
            start: start, end: end, downloadBytes: downloadBytes, uploadBytes: uploadBytes, source: .measured
        ))
    }

    /// Notes how far the session in progress has got.
    func checkpoint(start: Date, end: Date, downloadBytes: Int64, uploadBytes: Int64) {
        open = SessionRecord(
            id: open?.start == start ? (open?.id ?? UUID()) : UUID(),
            start: start, end: end, downloadBytes: downloadBytes, uploadBytes: uploadBytes, source: .measured
        )
        save()
    }

    /// Drops the session in progress without recording it.
    func discardOpen() {
        guard open != nil else { return }
        open = nil
        save()
    }

    func clear() {
        records = []
        open = nil
        save()
    }

    private func insert(_ record: SessionRecord) {
        records.append(record)
        records.sort { $0.end > $1.end }
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        save()
    }

    // MARK: File

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let contents = try decoder.decode(Contents.self, from: data)
            records = contents.records.sorted { $0.end > $1.end }
            // A session still open in the file was cut short, by a restart or a
            // crash. Keep it, ending at its last checkpoint.
            if let interrupted = contents.open {
                insert(interrupted)
            }
        } catch {
            Log.storage.error("could not read the session history: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Contents(records: records, open: open))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.storage.error("could not save the session history: \(error.localizedDescription)")
        }
    }
}
