import Foundation

public struct DeterministicPolicyEngine: Sendable {
    private let dangerousCommandFragments = [
        "rm ", "rm\t", "rm -", "sudo", "chmod -R", "chown -R", "curl | sh",
        "wget | sh", "dd ", "mkfs", "diskutil erase", "shutdown", "reboot",
        "killall", "~/.ssh", "keychain", ".env"
    ]

    private let riskyClickTerms = [
        "submit", "send", "delete", "remove", "confirm", "purchase",
        "checkout", "install", "run", "allow", "grant access"
    ]

    public init() {}

    public func classifyBatch(actions: [StructuredAction], context: AgentContext) -> PolicyDecision {
        guard actions.count == 1 else {
            return .init(classification: .block, reason: "Multi-action batches are blocked in v1.")
        }
        guard let action = actions.first else {
            return .init(classification: .block, reason: "No action was provided.")
        }
        return classify(action: action, context: context)
    }

    public func classify(action: StructuredAction, context: AgentContext) -> PolicyDecision {
        switch action.type {
        case .observe, .scroll, .wait, .finish, .askUser:
            return .init(classification: .allow, reason: "Low-risk action is allowed.")
        case .typeTextSensitive:
            return .init(classification: .block, reason: "Personal information and sensitive typing are blocked in v1.")
        case .runTerminalCommand:
            return classifyTerminalCommand(action.command)
        case .openURL:
            return classifyURL(action.targetText, context: context)
        case .click, .doubleClick:
            return classifyClick(action)
        case .paste:
            return .init(classification: .askUser, reason: "Pasting requires user approval unless generated safe text is proven.")
        case .copy:
            return .init(classification: .askUser, reason: "Clipboard access requires user approval by default.")
        case .typeTextSafe, .pressKey, .switchApp:
            return action.riskLevel == .low
                ? .init(classification: .allow, reason: "Low-risk structured action is allowed.")
                : .init(classification: .askUser, reason: "Medium or high risk action requires approval.")
        }
    }

    private func classifyTerminalCommand(_ command: String?) -> PolicyDecision {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(classification: .block, reason: "Terminal command is missing.")
        }

        let lowered = command.lowercased()
        if dangerousCommandFragments.contains(where: { lowered.contains($0) }) {
            return .init(classification: .block, reason: "Deletion or dangerous terminal command is blocked.")
        }

        let allowedPrefixes = ["pwd", "ls", "cd ", "cat ", "git status", "git diff", "git log", "npm test", "npm run build"]
        if allowedPrefixes.contains(where: { lowered == $0 || lowered.hasPrefix($0) }) {
            return .init(classification: .allow, reason: "Workspace-safe terminal command is allowed by policy.")
        }

        return .init(classification: .askUser, reason: "Unknown or medium-risk terminal command requires approval.")
    }

    private func classifyURL(_ rawURL: String, context: AgentContext) -> PolicyDecision {
        guard let host = URL(string: rawURL)?.host()?.lowercased() else {
            return .init(classification: .block, reason: "Invalid URL is blocked.")
        }

        if context.allowedDomains.contains(host) || context.allowedDomains.contains(where: { host.hasSuffix("." + $0) }) {
            return .init(classification: .allow, reason: "Domain is in the task allowlist.")
        }

        return .init(classification: .askUser, reason: "Unapproved website requires user approval.")
    }

    private func classifyClick(_ action: StructuredAction) -> PolicyDecision {
        let target = action.targetText.lowercased()
        if riskyClickTerms.contains(where: { target.contains($0) }) {
            return .init(classification: .askUser, reason: "Risky click target requires approval.")
        }

        return action.riskLevel == .low
            ? .init(classification: .allow, reason: "Low-risk click is allowed.")
            : .init(classification: .askUser, reason: "Click risk level requires approval.")
    }
}
