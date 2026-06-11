import Foundation
import Testing
@testable import LocalPilotDesktop

struct InternalModelProviderTests {
    @Test
    func defaultSettingsUseInternalInProcessModelProvider() {
        let settings = AppSettings.defaultValue

        #expect(settings.modelProviderMode == .internalInProcess)
        #expect(settings.plannerConfiguration().providerName == "internal-in-process")
        #expect(settings.guardConfiguration().providerName == "internal-in-process")
    }

    @Test
    func internalPlannerReturnsOneStructuredActionWithoutRuntime() async throws {
        let provider = InternalLocalModelProvider(role: .planner)
        let planner = JSONActionPlanner(provider: provider)

        let first = try await planner.proposeOneAction(
            originalTask: "look at the screen",
            context: .empty,
            recentMessages: []
        )
        let second = try await planner.proposeOneAction(
            originalTask: "look at the screen",
            context: .empty,
            recentMessages: []
        )

        #expect(first.type == .observe)
        #expect(first.riskLevel == .low)
        #expect(second.type == .finish)
    }

    @Test
    func internalGuardReturnsAllowDecisionWithoutRuntime() async throws {
        let provider = InternalLocalModelProvider(role: .guard)
        let guardModel = JSONGuardModel(provider: provider)
        let action = StructuredAction(
            type: .observe,
            targetKind: "screen",
            targetText: "current screen",
            expectedResult: "fresh screen state",
            riskLevel: .low,
            reason: "observe"
        )

        let decision = try await guardModel.review(
            action: action,
            context: .empty,
            policyDecision: PolicyDecision(classification: .allow, reason: "Low risk")
        )

        #expect(decision.decision == .allow)
        #expect(decision.reason.contains("internal guard"))
    }
}
