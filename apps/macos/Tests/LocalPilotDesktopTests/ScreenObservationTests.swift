import Foundation
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
            screenshotPNGBase64: "abc123",
            accessibilitySummary: nil
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
            screenshotPNGBase64: "def456",
            accessibilitySummary: "AX: button Start, text field Ask LocalPilot"
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
        #expect(context.visibleText.contains("button Start"))
        #expect(context.visibleText.contains("text field Ask LocalPilot"))
    }

    @Test
    func axElementSnapshotRoundTripsCodable() throws {
        let original = AXElementSnapshot(
            id: 3,
            role: "Button",
            label: "Save",
            centerX: 120.5,
            centerY: 64,
            width: 80,
            height: 32
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AXElementSnapshot.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func summaryIncludesListedElements() {
        let observation = ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Untitled",
            screenshotWidth: 100,
            screenshotHeight: 100,
            screenshotPNGBase64: "abc",
            accessibilitySummary: nil,
            elements: [
                AXElementSnapshot(id: 0, role: "Button", label: "Save", centerX: 10, centerY: 20, width: 4, height: 4),
                AXElementSnapshot(id: 1, role: "TextField", label: "Search", centerX: 30, centerY: 40, width: 4, height: 4)
            ]
        )

        let summary = observation.summary

        #expect(summary.contains("elements: "))
        #expect(summary.contains("[0] button \"Save\""))
        #expect(summary.contains("[1] textfield \"Search\""))
    }

    @Test
    func summaryReachesPlannerContextViaTaskBuilder() async {
        let observer = StubScreenObserver(observation: ScreenObservation(
            activeApp: "Notes",
            activeWindow: "Untitled",
            screenshotWidth: 100,
            screenshotHeight: 100,
            screenshotPNGBase64: "abc",
            accessibilitySummary: nil,
            elements: [
                AXElementSnapshot(id: 0, role: "Button", label: "Save", centerX: 10, centerY: 20, width: 4, height: 4)
            ]
        ))
        let builder = AgentContextBuilder(screenObserver: observer)

        let context = await builder.makeContext(
            settings: .defaultValue,
            task: "Save the note",
            history: AgentHistory()
        )

        #expect(context.visibleText.contains("[0] button \"Save\""))
    }
}
