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
    private let structuredOutput: Bool
    private let decoder = JSONDecoder()

    public init(provider: any LocalModelProvider, structuredOutput: Bool = true) {
        self.provider = provider
        self.structuredOutput = structuredOutput
    }

    public func proposeOneAction(originalTask: String, context: AgentContext, recentMessages: [ChatMessage]) async throws -> StructuredAction {
        let format: ModelResponseFormat = structuredOutput
            ? .jsonSchema(name: "localpilot_action", schema: StructuredOutputSchema.action)
            : .json
        return try await decodeWithRetry(
            prompt: plannerPrompt(originalTask: originalTask, context: context, recentMessages: recentMessages),
            system: Self.systemPrompt,
            format: format,
            images: context.screenshotJPEGBase64.map { [$0] }
        ) { text in
            try decoder.decode(StructuredAction.self, from: Data(JSONExtraction.extract(text).utf8))
        }
    }

    /// Propose an ordered plan of up to `maxActions` actions. The model may
    /// return either a single action object or `{"actions":[...]}`. Either way
    /// the orchestrator gates and executes each action one at a time.
    public func proposeActions(
        originalTask: String,
        context: AgentContext,
        recentMessages: [ChatMessage],
        maxActions: Int = 6
    ) async throws -> [StructuredAction] {
        let format: ModelResponseFormat = structuredOutput
            ? .jsonSchema(name: "localpilot_plan", schema: StructuredOutputSchema.plan)
            : .json
        let actions = try await decodeWithRetry(
            prompt: plannerPrompt(originalTask: originalTask, context: context, recentMessages: recentMessages),
            system: Self.planSystemPrompt,
            format: format,
            images: context.screenshotJPEGBase64.map { [$0] }
        ) { text in
            try Self.parsePlan(text, decoder: decoder)
        }

        let bounded = Array(actions.prefix(max(1, maxActions)))
        guard !bounded.isEmpty else {
            throw PlannerError.emptyPlan
        }
        return bounded
    }

    /// Complete and decode. Local models often wrap JSON in code fences or add
    /// prose, so decoding runs through `JSONExtraction`. On the first decode
    /// failure we retry exactly once with a schema-correction prompt (Milestone
    /// 5); if the retry still fails, the decode error propagates so the caller
    /// fails safely.
    private func decodeWithRetry<T>(
        prompt: String,
        system: String,
        format: ModelResponseFormat,
        images: [String]?,
        decode: (String) throws -> T
    ) async throws -> T {
        let first = try await provider.complete(prompt: prompt, system: system, format: format, images: images)
        if let value = try? decode(first) {
            return value
        }
        let retry = try await provider.complete(
            prompt: prompt + "\n\n" + Self.correctionSuffix,
            system: system,
            format: format,
            images: images
        )
        return try decode(retry)
    }

    private static func parsePlan(_ text: String, decoder: JSONDecoder) throws -> [StructuredAction] {
        let data = Data(JSONExtraction.extract(text).utf8)
        if let plan = try? decoder.decode(ActionPlan.self, from: data) {
            return plan.actions
        }
        // Fall back to a single action object for models that ignore the plan
        // envelope; this keeps small models working.
        return [try decoder.decode(StructuredAction.self, from: data)]
    }

    private func plannerPrompt(originalTask: String, context: AgentContext, recentMessages: [ChatMessage]) -> String {
        var sections: [String] = ["Original task:\n\(originalTask)"]

        let conversation = recentMessages.suffix(6).map { "\($0.role.rawValue): \($0.text)" }
        if !conversation.isEmpty {
            sections.append("Recent conversation:\n" + conversation.joined(separator: "\n"))
        }

        var scope: [String] = []
        if !context.allowedDomains.isEmpty { scope.append("allowed_domains=" + context.allowedDomains.sorted().joined(separator: ", ")) }
        if !context.allowedApps.isEmpty { scope.append("allowed_apps=" + context.allowedApps.sorted().joined(separator: ", ")) }
        if !context.allowedFolders.isEmpty { scope.append("allowed_folders=" + context.allowedFolders.sorted().joined(separator: ", ")) }
        if !scope.isEmpty { sections.append("Permission scope (never exceed):\n" + scope.joined(separator: "\n")) }

        if !context.deniedActionSummaries.isEmpty {
            sections.append("Already denied this run (do not repeat):\n" + context.deniedActionSummaries.joined(separator: "\n"))
        }

        sections.append("""
        Current context:
        active_app=\(context.activeApp ?? "unknown")
        active_window=\(context.activeWindow ?? "unknown")
        current_domain=\(context.currentDomain ?? "none")
        visible_text=\(context.visibleText)
        """)

        sections.append("""
        When visible_text lists numbered elements ("elements: [n] role \"label\""),
        target one by setting "target_element_id" to that number for click,
        double_click, type_text_safe, and move_cursor actions instead of guessing
        raw "coordinates". Only use coordinates when no listed element matches.
        To do several tightly-coupled steps at once (for example, click a text
        field then type into it), return a single {"type":"batch", ...,
        "actions":[ ... ]} action; every sub-action is still validated individually.
        Return JSON only that matches the LocalPilot action schema.
        """)

        if context.screenshotJPEGBase64 != nil {
            sections.append("A screenshot of the current screen is attached; use it to locate elements.")
        }

        return sections.joined(separator: "\n\n")
    }

    private static let correctionSuffix = """
    Your previous reply could not be parsed as valid JSON for the required schema.
    Return ONLY a single JSON object matching the schema — no markdown, no code
    fences, no commentary.
    """

    private static let systemPrompt = """
    You are the LocalPilot planner. You may propose exactly one structured action and no batches.
    Return JSON only. Do not include markdown. Prefer observe, wait, ask_user, or finish when uncertain.
    The model never controls the OS directly; it only proposes an action.
    """

    private static let planSystemPrompt = """
    You are the LocalPilot planner. Return JSON only, no markdown.
    Propose the next step or a short ordered plan of up to 6 steps as
    {"actions":[ ... ]}, where each item is a structured action. A single action
    object is also accepted. For tightly-coupled steps that should run without
    re-observing in between (e.g. click a field then type), use one batch action:
    {"type":"batch", "actions":[ ... ]}. Action types include observe, move_cursor,
    click, double_click, type_text_safe, press_key, scroll, copy, paste, open_url,
    run_terminal_command, switch_app, batch, wait, finish, ask_user.
    Only chain steps you are confident about; the app re-checks the screen and
    re-validates every action, and will stop early if a step does not match the
    new screen state. Prefer observe, wait, ask_user, or finish when uncertain.
    The model never controls the OS directly; it only proposes actions, and every
    action passes policy and guard review.
    """
}

/// Recovers a JSON object/array from a model reply that may be wrapped in
/// markdown code fences or surrounded by prose — common with small local models.
public enum JSONExtraction {
    public static func extract(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading ```json / ``` fence and its closing ``` if present.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let closingFence = text.range(of: "```", options: .backwards) {
                text = String(text[..<closingFence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If prose surrounds the JSON, slice from the first opening bracket to the
        // last matching closing bracket.
        if let firstBrace = text.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            let closing: Character = text[firstBrace] == "{" ? "}" : "]"
            if let lastBrace = text.lastIndex(of: closing), lastBrace > firstBrace {
                return String(text[firstBrace...lastBrace])
            }
        }
        return text
    }
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
