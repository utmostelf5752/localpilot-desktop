import Foundation

public struct GuardDecision: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case allow
        case deny
    }

    public let decision: Decision
    public let reason: String
}

public protocol GuardModel: Sendable {
    func review(action: StructuredAction, context: AgentContext, policyDecision: PolicyDecision) async throws -> GuardDecision
    func cancel() async
}

public struct StubGuardModel: GuardModel {
    public init() {}

    public func review(action: StructuredAction, context: AgentContext, policyDecision: PolicyDecision) async throws -> GuardDecision {
        GuardDecision(decision: policyDecision.classification == .block ? .deny : .allow, reason: "Stub guard mirrors deterministic blocks.")
    }

    public func cancel() async {}
}

public struct JSONGuardModel: GuardModel {
    private let provider: any LocalModelProvider
    private let decoder = JSONDecoder()

    public init(provider: any LocalModelProvider) {
        self.provider = provider
    }

    public func review(action: StructuredAction, context: AgentContext, policyDecision: PolicyDecision) async throws -> GuardDecision {
        let response = try await provider.complete(
            prompt: guardPrompt(action: action, context: context, policyDecision: policyDecision),
            system: Self.systemPrompt,
            format: .json
        )
        return try decoder.decode(GuardDecision.self, from: Data(response.utf8))
    }

    public func cancel() async {
        await provider.cancel()
    }

    private func guardPrompt(action: StructuredAction, context: AgentContext, policyDecision: PolicyDecision) -> String {
        let actionData = (try? JSONEncoder().encode(action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        Deterministic policy result: \(policyDecision.classification.rawValue) - \(policyDecision.reason)
        Active app: \(context.activeApp ?? "unknown")
        Active window: \(context.activeWindow ?? "unknown")
        Current domain: \(context.currentDomain ?? "none")
        Visible text: \(context.visibleText)
        Proposed action: \(actionData)
        Return {"decision":"allow"|"deny","reason":"short reason"} only.
        """
    }

    private static let systemPrompt = """
    You are the LocalPilot guard. Return JSON only. You can only allow or deny.
    Deny if context is insufficient. Never override deterministic blocks or human approval requirements.
    """
}
