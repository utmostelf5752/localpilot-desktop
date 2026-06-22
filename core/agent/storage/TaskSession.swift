import Foundation

/// A persisted record of a single agent task run, including its full chat
/// transcript. Sessions are listed in the "Past tasks" view and can be pinned
/// for quick access or archived to hide them from the active list.
public struct TaskSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Short human-readable title (typically the first ~40 chars of the task).
    public var displayTitle: String
    /// The full original task text the user submitted.
    public var originalTask: String
    public var createdAt: Date
    public var completedAt: Date?
    public var status: AgentRunStatus
    public var messages: [ChatMessage]
    /// Turn-by-turn event log (planning, policy/guard decisions, executor
    /// results) so history can show exactly what the model did, per task.
    public var events: [LocalEvent]
    public var isPinned: Bool
    /// When set, the session is archived (hidden from the active list).
    public var archivedAt: Date?

    public init(
        id: UUID,
        displayTitle: String,
        originalTask: String,
        createdAt: Date,
        completedAt: Date?,
        status: AgentRunStatus,
        messages: [ChatMessage],
        events: [LocalEvent] = [],
        isPinned: Bool,
        archivedAt: Date?
    ) {
        self.id = id
        self.displayTitle = displayTitle
        self.originalTask = originalTask
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.messages = messages
        self.events = events
        self.isPinned = isPinned
        self.archivedAt = archivedAt
    }
}
