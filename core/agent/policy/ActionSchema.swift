import Foundation

public enum ActionType: String, Codable, Sendable, CaseIterable {
    case observe
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
    public let text: String?
    public let command: String?
    public let expectedResult: String
    public let riskLevel: RiskLevel
    public let reason: String

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case targetKind = "target_kind"
        case targetText = "target_text"
        case coordinates
        case text
        case command
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
        text: String? = nil,
        command: String? = nil,
        expectedResult: String,
        riskLevel: RiskLevel,
        reason: String
    ) {
        self.id = id
        self.type = type
        self.targetKind = targetKind
        self.targetText = targetText
        self.coordinates = coordinates
        self.text = text
        self.command = command
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
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.expectedResult = try container.decode(String.self, forKey: .expectedResult)
        self.riskLevel = try container.decode(RiskLevel.self, forKey: .riskLevel)
        self.reason = try container.decode(String.self, forKey: .reason)
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
