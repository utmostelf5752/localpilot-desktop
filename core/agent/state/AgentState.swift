import Foundation

public enum AgentRunStatus: String, Codable, Sendable {
    case idle
    case running
    case paused
    case stopping
    case stopped
    case done
    case blocked
}

public enum OverlayState: String, Codable, Sendable {
    case idle
    case running
    case paused
    case approvalRequired = "approval_required"
    case stopping
    case stopped
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case agent
        case system
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let timestamp: Date

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public struct LocalPilotState: Codable, Equatable, Sendable {
    public var taskID: UUID?
    public var originalTask: String
    public var currentSubtask: String
    public var status: AgentRunStatus
    public var allowedDomains: [String]
    public var allowedApps: [String]
    public var allowedFolders: [String]
    public var completedSteps: [String]
    public var knownFacts: [String: String]
    public var openRisks: [String]
    public var deniedActions: [StructuredAction]
    public var userApprovals: [String]
    public var lastObservationSummary: String
    public var lastActionResult: String

    public static let empty = LocalPilotState(
        taskID: nil,
        originalTask: "",
        currentSubtask: "",
        status: .idle,
        allowedDomains: [],
        allowedApps: [],
        allowedFolders: [],
        completedSteps: [],
        knownFacts: [:],
        openRisks: [],
        deniedActions: [],
        userApprovals: [],
        lastObservationSummary: "",
        lastActionResult: ""
    )
}
