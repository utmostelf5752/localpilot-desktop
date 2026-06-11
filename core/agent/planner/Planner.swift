import Foundation

public protocol PlannerModel: Sendable {
    func proposeOneAction(for context: AgentContext) async throws -> StructuredAction
    func cancel() async
}

public struct StubPlannerModel: PlannerModel {
    public init() {}

    public func proposeOneAction(for context: AgentContext) async throws -> StructuredAction {
        StructuredAction(
            type: .wait,
            targetKind: "timer",
            targetText: "one scripted beat",
            expectedResult: "fake task advances",
            riskLevel: .low,
            reason: "Milestone 1 stub action"
        )
    }

    public func cancel() async {}
}

public struct JSONActionPlanner: Sendable {
    private let provider: any LocalModelProvider
    private let decoder = JSONDecoder()

    public init(provider: any LocalModelProvider) {
        self.provider = provider
    }

    public func proposeOneAction(originalTask: String, context: AgentContext, recentMessages: [ChatMessage]) async throws -> StructuredAction {
        let response = try await provider.complete(
            prompt: plannerPrompt(originalTask: originalTask, context: context, recentMessages: recentMessages),
            system: Self.systemPrompt,
            format: .json
        )
        let data = Data(response.utf8)
        return try decoder.decode(StructuredAction.self, from: data)
    }

    private func plannerPrompt(originalTask: String, context: AgentContext, recentMessages: [ChatMessage]) -> String {
        """
        Original task:
        \(originalTask)

        Current context:
        active_app=\(context.activeApp ?? "unknown")
        active_window=\(context.activeWindow ?? "unknown")
        current_domain=\(context.currentDomain ?? "none")
        visible_text=\(context.visibleText)

        Return exactly one JSON object matching the LocalPilot action schema.
        """
    }

    private static let systemPrompt = """
    You are the LocalPilot planner. You may propose exactly one structured action and no batches.
    Return JSON only. Do not include markdown. Prefer observe, wait, ask_user, or finish when uncertain.
    The model never controls the OS directly; it only proposes an action.
    """
}
