import Foundation
import Observation

/// Observable, main-actor store of persisted task sessions. Mutations write the
/// full session list to a JSON file off the main actor; the list is loaded
/// synchronously at init. Sessions are always kept newest-first.
@Observable
@MainActor
public final class TaskSessionStore {
    /// All sessions, newest first, including archived ones.
    public private(set) var sessions: [TaskSession]

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.sessions = Self.loadSessions(from: resolvedURL)
    }

    // MARK: Derived views

    /// Sessions that are not archived, newest first.
    public var active: [TaskSession] {
        sessions.filter { $0.archivedAt == nil }
    }

    /// Sessions that are pinned and not archived, newest first.
    public var pinned: [TaskSession] {
        sessions.filter { $0.isPinned && $0.archivedAt == nil }
    }

    // MARK: Mutations

    /// Inserts a new session or replaces an existing one with the same id,
    /// keeping the list sorted newest-first by `createdAt`.
    public func upsert(_ session: TaskSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sortNewestFirst()
        persist()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isPinned = pinned
        persist()
    }

    public func archive(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].archivedAt = Date()
        persist()
    }

    public func delete(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        persist()
    }

    // MARK: Persistence

    private func sortNewestFirst() {
        sessions.sort { $0.createdAt > $1.createdAt }
    }

    /// Persists the current session list to JSON off the main actor.
    private func persist() {
        let snapshot = sessions
        let url = fileURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Best-effort persistence; a write failure must not crash the UI.
            }
        }
    }

    private static func loadSessions(from url: URL) -> [TaskSession] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([TaskSession].self, from: data)
            loaded.sort { $0.createdAt > $1.createdAt }
            return loaded
        } catch {
            return []
        }
    }

    public static func defaultFileURL() -> URL {
        AppSettings.defaultSupportDirectory()
            .appending(path: "sessions.json")
    }
}
