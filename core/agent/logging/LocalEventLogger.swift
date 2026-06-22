import Foundation

public struct LocalEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let taskID: UUID?
    public let event: String
    public let status: AgentRunStatus
    public let detail: String
    public let currentAction: String
}

public actor LocalEventLogger {
    private let fileURL: URL
    private let encoder: JSONEncoder

    public init(fileURL: URL? = nil) {
        let defaultURL = Self.defaultLogURL()
        self.fileURL = fileURL ?? defaultURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public nonisolated var logFileURL: URL {
        fileURL
    }

    public func log(_ event: LocalEvent) {
        guard let data = try? encoder.encode(event) else { return }
        let line = data + Data([0x0A])

        // Serialized by the actor, so there is no inter-task append race. We
        // still guard against the file having been removed between calls and
        // fall back to an atomic create-write if the append handle can't open.
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Appending failed (e.g. file truncated/removed underneath us);
                // recreate the file so the event isn't silently dropped.
                try? line.write(to: fileURL, options: .atomic)
            }
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    public static func defaultLogURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appending(path: "LocalPilot Desktop", directoryHint: .isDirectory)
            .appending(path: "logs.jsonl")
    }
}
