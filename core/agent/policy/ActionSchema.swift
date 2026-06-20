import Foundation

public enum ActionType: String, Codable, Sendable, CaseIterable {
    case observe
    case moveCursor = "move_cursor"
    case click
    case doubleClick = "double_click"
    case typeTextSafe = "type_text_safe"
    case typeTextSensitive = "type_text_sensitive"
    case pressKey = "press_key"
    case scroll
    case copy
    case paste
    case openURL = "open_url"
    case runTerminalCommand = "run_terminal_command"
    case switchApp = "switch_app"
    /// A short ordered macro of tightly-coupled sub-actions (e.g. click a field
    /// then type) executed without re-observing between them. Each sub-action is
    /// still independently classified by policy and reviewed by the guard before
    /// it runs — `batch` is an ergonomic grouping, never an ungated bypass.
    case batch
    case wait
    case finish
    case askUser = "ask_user"
}

public enum RiskLevel: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct StructuredAction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let type: ActionType
    public let targetKind: String
    public let targetText: String
    public let coordinates: [Double]?
    /// Optional accessibility-element id, referencing the numbered elements in
    /// the latest observation. When set on a click/double_click/type_text_safe
    /// action, the executor resolves it to a concrete click point instead of
    /// using raw `coordinates`. This is an additive field: it never changes the
    /// action's type or its policy/guard risk classification.
    public let targetElementID: Int?
    public let text: String?
    public let command: String?
    /// Sub-actions for a `batch` action. Each is independently policy-classified
    /// and guard-reviewed before execution. Nil for every non-batch action.
    public let actions: [StructuredAction]?
    public let expectedResult: String
    public let riskLevel: RiskLevel
    public let reason: String

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case targetKind = "target_kind"
        case targetText = "target_text"
        case coordinates
        case targetElementID = "target_element_id"
        case text
        case command
        case actions
        case expectedResult = "expected_result"
        case riskLevel = "risk_level"
        case reason
    }

    public init(
        id: UUID = UUID(),
        type: ActionType,
        targetKind: String,
        targetText: String,
        coordinates: [Double]? = nil,
        targetElementID: Int? = nil,
        text: String? = nil,
        command: String? = nil,
        actions: [StructuredAction]? = nil,
        expectedResult: String,
        riskLevel: RiskLevel,
        reason: String
    ) {
        self.id = id
        self.type = type
        self.targetKind = targetKind
        self.targetText = targetText
        self.coordinates = coordinates
        self.targetElementID = targetElementID
        self.text = text
        self.command = command
        self.actions = actions
        self.expectedResult = expectedResult
        self.riskLevel = riskLevel
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.type = try container.decode(ActionType.self, forKey: .type)
        self.targetKind = try container.decode(String.self, forKey: .targetKind)
        self.targetText = try container.decode(String.self, forKey: .targetText)
        self.coordinates = try container.decodeIfPresent([Double].self, forKey: .coordinates)
        self.targetElementID = try container.decodeIfPresent(Int.self, forKey: .targetElementID)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        // Sub-actions are decoded one level deep; a batch's children are never
        // themselves batches (the structured-output schema forbids it), so this
        // recursion is bounded.
        self.actions = try container.decodeIfPresent([StructuredAction].self, forKey: .actions)
        self.expectedResult = try container.decode(String.self, forKey: .expectedResult)
        self.riskLevel = try container.decode(RiskLevel.self, forKey: .riskLevel)
        self.reason = try container.decode(String.self, forKey: .reason)
    }
}

/// An ordered plan of one or more actions proposed in a single planner turn.
///
/// The planner may look ahead and propose several steps at once, but this is
/// only a *proposal*: the orchestrator still gates and executes each action one
/// at a time (policy + guard + Stop/Pause checks + re-observation between
/// steps). No action in a plan executes without passing the full pipeline.
public struct ActionPlan: Codable, Equatable, Sendable {
    public let actions: [StructuredAction]

    public init(actions: [StructuredAction]) {
        self.actions = actions
    }
}

public struct AgentContext: Codable, Equatable, Sendable {
    public var activeApp: String?
    public var activeWindow: String?
    public var currentDomain: String?
    public var allowedDomains: Set<String>
    public var allowedApps: Set<String>
    public var allowedFolders: Set<String>
    public var visibleText: String
    public var activeFieldKind: String?
    /// Latest downscaled JPEG screenshot as base64, attached to the planner
    /// request only when vision is enabled. Never accumulates across steps.
    public var screenshotJPEGBase64: String?
    /// Short summaries of actions the policy/guard already denied this run, so the
    /// planner can avoid re-proposing them. A never-summarized context layer.
    public var deniedActionSummaries: [String]

    public init(
        activeApp: String?,
        activeWindow: String?,
        currentDomain: String?,
        allowedDomains: Set<String>,
        allowedApps: Set<String>,
        allowedFolders: Set<String>,
        visibleText: String,
        activeFieldKind: String?,
        screenshotJPEGBase64: String? = nil,
        deniedActionSummaries: [String] = []
    ) {
        self.activeApp = activeApp
        self.activeWindow = activeWindow
        self.currentDomain = currentDomain
        self.allowedDomains = allowedDomains
        self.allowedApps = allowedApps
        self.allowedFolders = allowedFolders
        self.visibleText = visibleText
        self.activeFieldKind = activeFieldKind
        self.screenshotJPEGBase64 = screenshotJPEGBase64
        self.deniedActionSummaries = deniedActionSummaries
    }

    public static let empty = AgentContext(
        activeApp: nil,
        activeWindow: nil,
        currentDomain: nil,
        allowedDomains: [],
        allowedApps: [],
        allowedFolders: [],
        visibleText: "",
        activeFieldKind: nil
    )
}

public enum PolicyClassification: String, Codable, Sendable {
    case allow
    case askUser = "ask_user"
    case block
}

public struct PolicyDecision: Codable, Equatable, Sendable {
    public let classification: PolicyClassification
    public let reason: String
}
