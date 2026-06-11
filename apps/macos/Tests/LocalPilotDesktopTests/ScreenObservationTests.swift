import Testing
@testable import LocalPilotDesktop

@MainActor
final class StubScreenObserver: ScreenObserving {
    private(set) var captureCount = 0
    var observation: ScreenObservation

    init(observation: ScreenObservation) {
        self.observation = observation
    }

    func capture() async -> ScreenObservation {
        captureCount += 1
        return observation
    }
}

@MainActor
struct ScreenObservationTests {
    @Test
    func observeActionCapturesCurrentScreenMetadata() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Finder",
            activeWindow: "Downloads",
            screenshotWidth: 1200,
            screenshotHeight: 800,
            screenshotPNGBase64: "abc123"
        ))
        let executor = LocalPilotActionExecutor(screenObserver: observer, dryRun: true)
        let action = StructuredAction(
            type: .observe,
            targetKind: "screen",
            targetText: "current screen",
            expectedResult: "fresh observation",
            riskLevel: .low,
            reason: "update context"
        )

        let result = await executor.execute(action)

        #expect(observer.captureCount == 1)
        #expect(result.contains("Finder"))
        #expect(result.contains("Downloads"))
        #expect(result.contains("1200x800"))
        #expect(result.contains("screenshot captured"))
    }

    @Test
    func contextBuilderIncludesLatestScreenObservationForPlanner() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Safari",
            activeWindow: "LocalPilot issue tracker",
            screenshotWidth: 1440,
            screenshotHeight: 900,
            screenshotPNGBase64: "def456"
        ))
        let builder = AgentContextBuilder(screenObserver: observer)

        let context = await builder.makeContext(
            settings: .defaultValue,
            messages: [
                ChatMessage(role: .user, text: "Open the issue tracker")
            ]
        )

        #expect(observer.captureCount == 1)
        #expect(context.activeApp == "Safari")
        #expect(context.activeWindow == "LocalPilot issue tracker")
        #expect(context.visibleText.contains("Open the issue tracker"))
        #expect(context.visibleText.contains("screenshot captured"))
    }
}
