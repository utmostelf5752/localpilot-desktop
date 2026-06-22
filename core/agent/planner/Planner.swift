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

/// A planned set of actions plus the model's reasoning, if it emitted any.
public struct PlannedActions: Sendable {
    public let actions: [StructuredAction]
    public let reasoning: String?

    public init(actions: [StructuredAction], reasoning: String?) {
        self.actions = actions
        self.reasoning = reasoning
    }
}

public struct JSONActionPlanner: Sendable {
    private let provider: any LocalModelProvider
    private let structuredOutput: Bool
    private let decoder = JSONDecoder()

    public init(provider: any LocalModelProvider, structuredOutput: Bool = true) {
        self.provider = provider
        self.structuredOutput = structuredOutput
    }

    public func proposeOneAction(originalTask: String, context: AgentContext, recentMessages: [ChatMessage]) async throws -> StructuredAction {
        let response = try await provider.complete(
            prompt: plannerPrompt(originalTask: originalTask, context: context, recentMessages: recentMessages),
            system: Self.systemPrompt,
            format: structuredOutput ? .jsonSchema(name: "localpilot_action", schema: StructuredOutputSchema.action) : .json
        )
        let payload = lpExtractJSONPayload(lpSplitReasoning(response).content)
        return try decoder.decode(StructuredAction.self, from: Data(payload.utf8))
    }

    /// Propose an ordered plan of up to `maxActions` actions. The model may
    /// return either a single action object or `{"actions":[...]}`. Either way
    /// the orchestrator gates and executes each action one at a time. Reasoning
    /// models' chain-of-thought is split off and returned alongside the actions.
    public func proposeActions(
        originalTask: String,
        context: AgentContext,
        recentMessages: [ChatMessage],
        maxActions: Int = 6
    ) async throws -> PlannedActions {
        let response = try await provider.complete(
            prompt: plannerPrompt(originalTask: originalTask, context: context, recentMessages: recentMessages),
            system: Self.planSystemPrompt,
            format: structuredOutput ? .jsonSchema(name: "localpilot_plan", schema: StructuredOutputSchema.plan) : .json
        )
        return try decodePlan(response, maxActions: maxActions)
    }

    /// Sends a caller-built prompt verbatim — the agent loop passes the entire
    /// running transcript (text only, no image) here every turn. Shipping the
    /// full history as a stable, append-only prefix lets the inference server
    /// reuse its KV cache instead of re-prefilling everything each turn.
    public func proposeActions(prompt: String, maxActions: Int = 6) async throws -> PlannedActions {
        let response = try await provider.complete(
            prompt: prompt,
            system: Self.planSystemPrompt,
            format: structuredOutput ? .jsonSchema(name: "localpilot_plan", schema: StructuredOutputSchema.plan) : .json
        )
        return try decodePlan(response, maxActions: maxActions)
    }

    /// Streaming variant of `proposeActions(prompt:)`: forwards live token deltas
    /// to `onDelta` while the model generates, then decodes the full response the
    /// same way. Falls back to a single delta on providers that can't stream.
    public func proposeActions(
        prompt: String,
        maxActions: Int = 6,
        onDelta: @escaping @Sendable (StreamDelta) -> Void
    ) async throws -> PlannedActions {
        let response = try await provider.completeStreaming(
            prompt: prompt,
            system: Self.planSystemPrompt,
            format: structuredOutput ? .jsonSchema(name: "localpilot_plan", schema: StructuredOutputSchema.plan) : .json,
            onDelta: onDelta
        )
        return try decodePlan(response, maxActions: maxActions)
    }

    private func decodePlan(_ response: String, maxActions: Int) throws -> PlannedActions {
        let split = lpSplitReasoning(response)
        let data = Data(lpExtractJSONPayload(split.content).utf8)

        let actions: [StructuredAction]
        if let plan = try? decoder.decode(ActionPlan.self, from: data) {
            actions = plan.actions
        } else {
            // Fall back to a single action object for models that ignore the
            // plan envelope; this also keeps small models working.
            actions = [try decoder.decode(StructuredAction.self, from: data)]
        }

        let bounded = Array(actions.prefix(max(1, maxActions)))
        guard !bounded.isEmpty else {
            throw PlannerError.emptyPlan
        }
        return PlannedActions(actions: bounded, reasoning: split.reasoning)
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

        When the visible_text lists numbered "elements: [n] role \"label\"",
        prefer targeting one of them by setting "target_element_id" to that
        number for click, double_click, and type_text_safe actions, instead of
        guessing raw "coordinates". Only fall back to coordinates when no listed
        element matches.

        Return exactly one JSON object matching the LocalPilot action schema.
        """
    }

    private static let systemPrompt = """
    You are the LocalPilot planner. You may propose exactly one structured action and no batches.
    Return JSON only. Do not include markdown. Prefer observe, wait, ask_user, or finish when uncertain.
    The model never controls the OS directly; it only proposes an action.
    """

    private static let planSystemPrompt = """
    You are the LocalPilot planner. Return JSON only, no markdown.
    Propose the next step or a short ordered plan of up to 6 steps as
    {"actions":[ ... ]}, where each item is a structured action. A single action
    object is also accepted. Only chain steps you are confident about; the app
    re-checks the screen and re-validates every action, and will stop early if a
    step does not match the new screen state. Prefer observe, wait, ask_user, or
    finish when uncertain. The model never controls the OS directly; it only
    proposes actions, and every action passes policy and guard review.
    """
}

public enum PlannerError: LocalizedError, Sendable {
    case emptyPlan

    public var errorDescription: String? {
        switch self {
        case .emptyPlan:
            "Planner returned an empty action plan."
        }
    }
}
