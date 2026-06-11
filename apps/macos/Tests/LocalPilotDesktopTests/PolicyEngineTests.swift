import Testing
@testable import LocalPilotDesktop

struct PolicyEngineTests {
    @Test
    func deletionCommandsAreBlockedByDefault() {
        let policy = DeterministicPolicyEngine()
        let action = StructuredAction(
            type: .runTerminalCommand,
            targetKind: "terminal",
            targetText: "shell",
            coordinates: nil,
            text: nil,
            command: "rm -rf build",
            expectedResult: "remove build artifacts",
            riskLevel: .high,
            reason: "cleanup"
        )

        let decision = policy.classify(action: action, context: .empty)

        #expect(decision.classification == .block)
        #expect(decision.reason.contains("Deletion"))
    }

    @Test
    func personalInformationTypingIsBlockedInV1() {
        let policy = DeterministicPolicyEngine()
        let action = StructuredAction(
            type: .typeTextSensitive,
            targetKind: "email_field",
            targetText: "Email",
            coordinates: nil,
            text: "person@example.com",
            command: nil,
            expectedResult: "email filled",
            riskLevel: .high,
            reason: "fill form"
        )

        let decision = policy.classify(action: action, context: .empty)

        #expect(decision.classification == .block)
    }

    @Test
    func unapprovedDomainsAskUserOrBlock() {
        let policy = DeterministicPolicyEngine()
        let action = StructuredAction(
            type: .openURL,
            targetKind: "browser",
            targetText: "https://unknown.example/path",
            coordinates: nil,
            text: nil,
            command: nil,
            expectedResult: "page opens",
            riskLevel: .medium,
            reason: "browse"
        )

        let decision = policy.classify(action: action, context: .empty)

        #expect(decision.classification == .askUser)
    }

    @Test
    func multiActionBatchesAreBlocked() {
        let policy = DeterministicPolicyEngine()
        let actions = [
            StructuredAction(type: .observe, targetKind: "screen", targetText: "screen", expectedResult: "state", riskLevel: .low, reason: "observe"),
            StructuredAction(type: .wait, targetKind: "timer", targetText: "one second", expectedResult: "delay", riskLevel: .low, reason: "wait")
        ]

        let decision = policy.classifyBatch(actions: actions, context: .empty)

        #expect(decision.classification == .block)
    }
}
