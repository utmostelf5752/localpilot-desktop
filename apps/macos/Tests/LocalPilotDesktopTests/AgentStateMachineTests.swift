import Foundation
import Testing
@testable import LocalPilotDesktop

@MainActor
struct AgentStateMachineTests {
    @Test
    func stopImmediatelyDisablesExecutionAndClearsOverlay() async {
        let logger = LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "localpilot-stop-test.jsonl"))
        let controller = AgentController(logger: logger, useModelLoop: false)

        controller.start(task: "search for a note")
        controller.stop()

        #expect(controller.runStatus == .stopped)
        #expect(controller.overlayState == .idle)
        #expect(controller.executorEnabled == false)
        #expect(controller.currentActionLabel == "Stopped")
    }

    @Test
    func pauseFreezesExecutionAndContinueResumesWithInstruction() async {
        let logger = LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "localpilot-pause-test.jsonl"))
        let controller = AgentController(logger: logger, useModelLoop: false)

        controller.start(task: "draft a message")
        controller.pause()
        #expect(controller.runStatus == .paused)
        #expect(controller.overlayState == .paused)
        #expect(controller.executorEnabled == false)

        controller.continueTask(instruction: "Use a shorter tone")
        #expect(controller.runStatus == .running)
        #expect(controller.overlayState == .running)
        #expect(controller.executorEnabled == true)
        #expect(controller.continueInstructions.last == "Use a shorter tone")
    }
}
