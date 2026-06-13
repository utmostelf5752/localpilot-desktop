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

/// Fast, two-tier guard that keeps risky actions safe without slowing the main
/// planner on the common low-risk path.
///
/// - Low-risk actions that deterministic policy already allows are allowed
///   instantly. The model guard still runs concurrently as a background audit
///   (surfaced via `auditLog`) but never blocks the loop.
/// - Risky actions (non-low risk, or policy `ask_user`/`block`) await the model
///   guard, but with a hard timeout. On timeout or model failure the guard fails
///   CLOSED — it denies — so a slow or unavailable guard can never wave through
///   a risky action.
public struct TieredGuard: Sendable {
    private let model: any GuardModel
    private let timeout: Duration
    private let auditLog: (@Sendable (GuardDecision) -> Void)?

    public init(
        model: any GuardModel,
        timeout: Duration = .seconds(4),
        auditLog: (@Sendable (GuardDecision) -> Void)? = nil
    ) {
        self.model = model
        self.timeout = timeout
        self.auditLog = auditLog
    }

    private func isFastPath(_ policyDecision: PolicyDecision, action: StructuredAction) -> Bool {
        policyDecision.classification == .allow && action.riskLevel == .low
    }

    public func decide(
        action: StructuredAction,
        context: AgentContext,
        policyDecision: PolicyDecision
    ) async -> GuardDecision {
        if isFastPath(policyDecision, action: action) {
            // Allow immediately; audit the model guard concurrently so it never
            // adds latency to the common low-risk path.
            if let auditLog {
                let model = self.model
                Task {
                    if let decision = try? await model.review(
                        action: action,
                        context: context,
                        policyDecision: policyDecision
                    ) {
                        auditLog(decision)
                    }
                }
            }
            return GuardDecision(
                decision: .allow,
                reason: "Fast-path: low-risk action allowed by deterministic policy; model guard auditing concurrently."
            )
        }

        return await reviewWithTimeout(action: action, context: context, policyDecision: policyDecision)
    }

    private func reviewWithTimeout(
        action: StructuredAction,
        context: AgentContext,
        policyDecision: PolicyDecision
    ) async -> GuardDecision {
        let model = self.model
        let timeout = self.timeout
        return await withTaskGroup(of: GuardDecision?.self) { group in
            group.addTask {
                try? await model.review(action: action, context: context, policyDecision: policyDecision)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return GuardDecision(decision: .deny, reason: "Guard timed out; failing closed on a risky action.")
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? GuardDecision(decision: .deny, reason: "Guard unavailable; failing closed on a risky action.")
        }
    }
}
