import Foundation
import Testing
@testable import LocalPilotDesktop

struct JSONExtractionTests {
    @Test
    func stripsJSONCodeFences() {
        let raw = "```json\n{\"a\":1}\n```"
        #expect(JSONExtraction.extract(raw) == "{\"a\":1}")
    }

    @Test
    func slicesJSONOutOfSurroundingProse() {
        let raw = "Sure! Here is the action: {\"type\":\"wait\"} — hope that helps."
        #expect(JSONExtraction.extract(raw) == "{\"type\":\"wait\"}")
    }

    @Test
    func passesThroughCleanJSON() {
        #expect(JSONExtraction.extract("{\"x\":true}") == "{\"x\":true}")
    }
}

struct NewPolicyTests {
    private let engine = DeterministicPolicyEngine()

    @Test
    func moveCursorIsAllowed() {
        let action = StructuredAction(type: .moveCursor, targetKind: "point", targetText: "x", coordinates: [10, 10], expectedResult: "moved", riskLevel: .low, reason: "")
        #expect(engine.classify(action: action, context: .empty).classification == .allow)
    }

    @Test
    func clickTokenMatchAllowsInnocuousWords() {
        // "Posts" contains "post" as a substring but is not the risky token.
        let action = StructuredAction(type: .click, targetKind: "link", targetText: "Posts", expectedResult: "", riskLevel: .low, reason: "")
        #expect(engine.classify(action: action, context: .empty).classification == .allow)
    }

    @Test
    func clickRiskyTokenStillAsks() {
        let action = StructuredAction(type: .click, targetKind: "button", targetText: "Send message", expectedResult: "", riskLevel: .low, reason: "")
        #expect(engine.classify(action: action, context: .empty).classification == .askUser)
    }

    @Test
    func batchTakesWorstSubActionClassification() {
        let safe = StructuredAction(type: .moveCursor, targetKind: "point", targetText: "x", coordinates: [1, 1], expectedResult: "", riskLevel: .low, reason: "")
        let risky = StructuredAction(type: .click, targetKind: "button", targetText: "Delete", expectedResult: "", riskLevel: .low, reason: "")
        let batch = StructuredAction(type: .batch, targetKind: "batch", targetText: "do two things", actions: [safe, risky], expectedResult: "", riskLevel: .low, reason: "")
        #expect(engine.classify(action: batch, context: .empty).classification == .askUser)
    }

    @Test
    func switchAppNotInAllowlistAsksUser() {
        var context = AgentContext.empty
        context.allowedApps = ["Safari"]
        let action = StructuredAction(type: .switchApp, targetKind: "app", targetText: "Mail", expectedResult: "", riskLevel: .low, reason: "")
        #expect(engine.classify(action: action, context: context).classification == .askUser)
    }

    @Test
    func safeFindCommandIsRecoverableNotBlocked() {
        let action = StructuredAction(type: .runTerminalCommand, targetKind: "terminal", targetText: "shell", command: "find . -name foo", expectedResult: "", riskLevel: .low, reason: "")
        #expect(engine.classify(action: action, context: .empty).classification == .askUser)
    }

    @Test
    func destructiveFindIsStillBlocked() {
        let action = StructuredAction(type: .runTerminalCommand, targetKind: "terminal", targetText: "shell", command: "find . -name foo -delete", expectedResult: "", riskLevel: .low, reason: "")
        #expect(engine.classify(action: action, context: .empty).classification == .block)
    }
}

@MainActor
struct NewExecutorTests {
    @Test
    func moveCursorActionMovesPointer() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)
        let action = StructuredAction(type: .moveCursor, targetKind: "point", targetText: "x", coordinates: [30, 40], expectedResult: "", riskLevel: .low, reason: "")

        let result = await executor.execute(action)

        #expect(result == "Moved cursor to 30,40.")
        #expect(await controller.moves == [CGPoint(x: 30, y: 40)])
    }

    @Test
    func setDryRunFalseEnablesRealExecution() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: true)
        await executor.setDryRun(false)
        let action = StructuredAction(type: .click, targetKind: "point", targetText: "x", coordinates: [5, 6], expectedResult: "", riskLevel: .low, reason: "")

        _ = await executor.execute(action)

        #expect(await controller.clicks == [CGPoint(x: 5, y: 6)])
    }

    @Test
    func batchActionIsNotExecutedDirectly() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)
        let action = StructuredAction(type: .batch, targetKind: "batch", targetText: "x", actions: [], expectedResult: "", riskLevel: .low, reason: "")

        let result = await executor.execute(action)

        #expect(result.contains("expanded by the orchestrator"))
    }
}

struct ModelCatalogServiceTests {
    @Test
    func ollamaTagsAreParsed() async throws {
        let client = MockHTTPClient()
        await client.enqueue(HTTPResponse(data: Data(#"{"models":[{"name":"llama3.2"},{"name":"qwen2.5-coder"}]}"#.utf8), statusCode: 200))
        let catalog = ModelCatalogService(httpClient: client)

        let models = try await catalog.listModels(baseURL: URL(string: "http://localhost:11434")!, apiShape: .ollamaGenerate)

        #expect(models.map(\.id) == ["llama3.2", "qwen2.5-coder"])
    }

    @Test
    func lmStudioModelsIncludeContextLength() async throws {
        let client = MockHTTPClient()
        await client.enqueue(HTTPResponse(data: Data(#"{"data":[{"id":"qwen2.5-7b","max_context_length":8192}]}"#.utf8), statusCode: 200))
        let catalog = ModelCatalogService(httpClient: client)

        let models = try await catalog.listModels(baseURL: URL(string: "http://localhost:1234")!, apiShape: .openAIChat)

        #expect(models.first?.id == "qwen2.5-7b")
        #expect(models.first?.contextLength == 8192)
    }
}
