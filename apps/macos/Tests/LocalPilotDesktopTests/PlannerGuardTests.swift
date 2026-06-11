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
}
