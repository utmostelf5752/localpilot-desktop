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

struct LocalEventLoggerTests {
    private func makeEvent(_ detail: String) -> LocalEvent {
        LocalEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            taskID: nil,
            event: "test",
            status: .running,
            detail: detail,
            currentAction: "none"
        )
    }

    @Test
    func logAppendsOneJSONLinePerEvent() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "localpilot-logger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let logger = LocalEventLogger(fileURL: fileURL)

        await logger.log(makeEvent("first"))
        await logger.log(makeEvent("second"))

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(contents.contains("first"))
        #expect(contents.contains("second"))
    }

    @Test
    func logRecreatesFileWhenRemovedBetweenWrites() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "localpilot-logger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let logger = LocalEventLogger(fileURL: fileURL)

        await logger.log(makeEvent("first"))
        try FileManager.default.removeItem(at: fileURL)
        await logger.log(makeEvent("second"))

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.contains("second"))
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
    }

    @Test
    func concurrentLogsAreAllPersisted() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "localpilot-logger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let logger = LocalEventLogger(fileURL: fileURL)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    await logger.log(self.makeEvent("event-\(index)"))
                }
            }
        }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 20)
    }
}
