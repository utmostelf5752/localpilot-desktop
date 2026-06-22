import Foundation
import Testing
@testable import LocalPilotDesktop

actor StubTextProvider: LocalModelProvider {
    let configuration: ModelProviderConfiguration
    var completions: [String]
    private(set) var closeCount = 0

    init(completions: [String]) {
        self.completions = completions
        self.configuration = ModelProviderConfiguration(
            providerName: "stub",
            modelName: "stub-model",
            contextWindowSize: 4096,
            temperature: 0,
            timeoutSeconds: 1,
            supportsStreaming: false
        )
    }

    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        completions.removeFirst()
    }

    func healthCheck() async throws {}
    func cancel() async {}

    func closeModel() async throws {
        closeCount += 1
    }
}

actor DeltaCollector {
    private(set) var combinedReasoning = ""
    func append(_ delta: StreamDelta) { combinedReasoning += delta.reasoning }
}

actor ScriptedGuard: GuardModel {
    let decision: GuardDecision
    let delay: Duration
    private(set) var reviewCount = 0

    init(decision: GuardDecision, delay: Duration = .zero) {
        self.decision = decision
        self.delay = delay
    }

    func review(action: StructuredAction, context: AgentContext, policyDecision: PolicyDecision) async throws -> GuardDecision {
        reviewCount += 1
        if delay != .zero {
            try await Task.sleep(for: delay)
        }
        return decision
    }

    func cancel() async {}
}

/// Records the `format` it was last asked to complete with, so tests can assert
/// the planner forwards the expected structured-output mode.
actor FormatCapturingProvider: LocalModelProvider {
    let configuration: ModelProviderConfiguration
    let canned: String
    private(set) var lastFormat: ModelResponseFormat?

    init(canned: String) {
        self.canned = canned
        self.configuration = ModelProviderConfiguration(
            providerName: "capture",
            modelName: "capture-model",
            contextWindowSize: 4096,
            temperature: 0,
            timeoutSeconds: 1,
            supportsStreaming: false
        )
    }

    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        lastFormat = format
        return canned
    }

    func healthCheck() async throws {}
    func cancel() async {}
    func closeModel() async throws {}
}

struct PlannerGuardTests {
    @Test
    func plannerParsesStructuredActionFromManagedModelJsonResponse() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"wait","target_kind":"timer","target_text":"one second","coordinates":null,"text":null,"command":null,"expected_result":"delay","risk_level":"low","reason":"safe wait"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let action = try await planner.proposeOneAction(originalTask: "wait", context: .empty, recentMessages: [])

        #expect(action.type == .wait)
        #expect(action.targetKind == "timer")
        #expect(action.riskLevel == .low)
    }

    @Test
    func plannerParsesTargetElementIDFromJson() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"click","target_kind":"element","target_text":"Save","target_element_id":3,"expected_result":"clicked","risk_level":"low","reason":"click the save button"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let action = try await planner.proposeOneAction(originalTask: "save", context: .empty, recentMessages: [])

        #expect(action.type == .click)
        #expect(action.targetElementID == 3)
        #expect(action.coordinates == nil)
    }

    @Test
    func plannerDefaultsTargetElementIDToNilWhenAbsent() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"click","target_kind":"point","target_text":"Save","coordinates":[10,20],"expected_result":"clicked","risk_level":"low","reason":"click"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let action = try await planner.proposeOneAction(originalTask: "save", context: .empty, recentMessages: [])

        #expect(action.targetElementID == nil)
        #expect(action.coordinates == [10, 20])
    }

    @Test
    func plannerParsesMultiActionPlan() async throws {
        let provider = StubTextProvider(completions: [
            #"{"actions":[{"type":"observe","target_kind":"screen","target_text":"screen","expected_result":"state","risk_level":"low","reason":"look"},{"type":"finish","target_kind":"task","target_text":"task","expected_result":"done","risk_level":"low","reason":"complete"}]}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "do it", context: .empty, recentMessages: []).actions

        #expect(actions.count == 2)
        #expect(actions.first?.type == .observe)
        #expect(actions.last?.type == .finish)
    }

    @Test
    func streamingPlannerDecodesAndForwardsReasoningDelta() async throws {
        // The stub only implements `complete`, so it exercises the protocol's
        // default `completeStreaming` fallback: one delta carrying the split-off
        // reasoning, and a plan decoded identically to the non-streaming path.
        let provider = StubTextProvider(completions: [
            #"<think>weighing options</think>{"type":"finish","target_kind":"task","target_text":"task","expected_result":"done","risk_level":"low","reason":"complete"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let deltas = DeltaCollector()
        let plan = try await planner.proposeActions(prompt: "do it") { delta in
            Task { await deltas.append(delta) }
        }

        #expect(plan.actions.first?.type == .finish)
        #expect(plan.reasoning == "weighing options")
        // Give the detached delta task a beat to land before asserting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await deltas.combinedReasoning == "weighing options")
    }

    @Test
    func plannerFallsBackToSingleActionObjectForPlans() async throws {
        let provider = StubTextProvider(completions: [
            #"{"type":"wait","target_kind":"timer","target_text":"a beat","expected_result":"delay","risk_level":"low","reason":"wait"}"#
        ])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "wait", context: .empty, recentMessages: []).actions

        #expect(actions.count == 1)
        #expect(actions.first?.type == .wait)
    }

    @Test
    func plannerCapsPlanToMaxActions() async throws {
        let item = #"{"type":"observe","target_kind":"screen","target_text":"s","expected_result":"r","risk_level":"low","reason":"x"}"#
        let items = Array(repeating: item, count: 10).joined(separator: ",")
        let provider = StubTextProvider(completions: ["{\"actions\":[\(items)]}"])
        let planner = JSONActionPlanner(provider: provider)

        let actions = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [], maxActions: 3).actions

        #expect(actions.count == 3)
    }

    @Test
    func plannerPassesJsonSchemaFormatWhenStructuredOutputEnabled() async throws {
        let canned = #"{"actions":[{"type":"wait","target_kind":"timer","target_text":"a beat","expected_result":"delay","risk_level":"low","reason":"wait"}]}"#
        let provider = FormatCapturingProvider(canned: canned)
        let planner = JSONActionPlanner(provider: provider, structuredOutput: true)

        _ = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [])

        let format = await provider.lastFormat
        guard case .jsonSchema = format else {
            Issue.record("Expected .jsonSchema format, got \(String(describing: format))")
            return
        }
    }

    @Test
    func plannerPassesPlainJsonFormatWhenStructuredOutputDisabled() async throws {
        let canned = #"{"actions":[{"type":"wait","target_kind":"timer","target_text":"a beat","expected_result":"delay","risk_level":"low","reason":"wait"}]}"#
        let provider = FormatCapturingProvider(canned: canned)
        let planner = JSONActionPlanner(provider: provider, structuredOutput: false)

        _ = try await planner.proposeActions(originalTask: "t", context: .empty, recentMessages: [])

        #expect(await provider.lastFormat == .json)
    }

    @Test
    func guardParsesAllowDenyOnlyDecision() async throws {
        let provider = StubTextProvider(completions: [
            #"{"decision":"allow","reason":"safe observation"}"#
        ])
        let guardModel = JSONGuardModel(provider: provider)
        let action = StructuredAction(type: .observe, targetKind: "screen", targetText: "screen", expectedResult: "state", riskLevel: .low, reason: "observe")

        let decision = try await guardModel.review(action: action, context: .empty, policyDecision: .init(classification: .allow, reason: "allowed"))

        #expect(decision.decision == .allow)
        #expect(decision.reason == "safe observation")
    }

    @Test
    func tieredGuardAllowsLowRiskInstantlyWithoutBlockingOnModel() async {
        // Model would deny, but a low-risk + policy-allow action takes the fast
        // path and is allowed instantly; the model only runs as a concurrent audit.
        let model = ScriptedGuard(decision: GuardDecision(decision: .deny, reason: "slow deny"), delay: .seconds(5))
        let guardModel = TieredGuard(model: model, timeout: .seconds(5))
        let action = StructuredAction(type: .observe, targetKind: "screen", targetText: "screen", expectedResult: "state", riskLevel: .low, reason: "observe")

        let decision = await guardModel.decide(
            action: action,
            context: .empty,
            policyDecision: .init(classification: .allow, reason: "allowed")
        )

        #expect(decision.decision == .allow)
    }

    @Test
    func tieredGuardRespectsModelDenyOnRiskyAction() async {
        let model = ScriptedGuard(decision: GuardDecision(decision: .deny, reason: "unsafe click"))
        let guardModel = TieredGuard(model: model, timeout: .seconds(2))
        let action = StructuredAction(type: .click, targetKind: "point", targetText: "Delete", coordinates: [10, 10], expectedResult: "click", riskLevel: .high, reason: "risky")

        let decision = await guardModel.decide(
            action: action,
            context: .empty,
            policyDecision: .init(classification: .askUser, reason: "needs review")
        )

        #expect(decision.decision == .deny)
        #expect(decision.reason == "unsafe click")
    }

    @Test
    func tieredGuardFailsClosedWhenModelTimesOut() async {
        let model = ScriptedGuard(decision: GuardDecision(decision: .allow, reason: "too late"), delay: .seconds(5))
        let guardModel = TieredGuard(model: model, timeout: .milliseconds(50))
        let action = StructuredAction(type: .click, targetKind: "point", targetText: "Confirm", coordinates: [10, 10], expectedResult: "click", riskLevel: .high, reason: "risky")

        let decision = await guardModel.decide(
            action: action,
            context: .empty,
            policyDecision: .init(classification: .askUser, reason: "needs review")
        )

        #expect(decision.decision == .deny)
    }
}
