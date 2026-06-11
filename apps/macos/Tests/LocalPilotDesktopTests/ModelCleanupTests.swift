import Foundation
import Testing
@testable import LocalPilotDesktop

@MainActor
struct ModelCleanupTests {
    @Test
    func stopClosesLoadedModels() async {
        let closer = StubModelSessionCloser()
        let controller = AgentController(logger: LocalEventLogger(fileURL: URL.temporaryDirectory.appending(path: "localpilot-cleanup-test.jsonl")), modelSessionCloser: closer, useModelLoop: false)

        controller.start(task: "observe the screen")
        controller.stop()

        await Task.yield()
        #expect(closer.closeCount == 1)
    }
}

@MainActor
final class StubModelSessionCloser: ModelSessionClosing {
    var closeCount = 0

    func closeLoadedModels() {
        closeCount += 1
    }
}
