import Foundation
import Testing
@testable import LocalPilotDesktop

actor SpyComputerController: ComputerControlling {
    private(set) var clicks: [CGPoint] = []
    private(set) var doubleClicks: [CGPoint] = []
    private(set) var typedText: [String] = []
    private(set) var scrolls: [Int32] = []
    private(set) var keys: [String] = []
    private(set) var copyCount = 0
    private(set) var pastedText: [String] = []
    private(set) var openedURLs: [String] = []
    private(set) var terminalCommands: [String] = []
    private(set) var switchedApps: [String] = []

    func click(at point: CGPoint) async {
        clicks.append(point)
    }

    func doubleClick(at point: CGPoint) async {
        doubleClicks.append(point)
    }

    func typeText(_ text: String) async {
        typedText.append(text)
    }

    func scroll(deltaY: Int32) async {
        scrolls.append(deltaY)
    }

    func pressKey(named key: String) async {
        keys.append(key)
    }

    func copySelection() async {
        copyCount += 1
    }

    func pasteText(_ text: String) async {
        pastedText.append(text)
    }

    func openURL(_ urlString: String) async -> Bool {
        openedURLs.append(urlString)
        return true
    }

    func runTerminalCommand(_ command: String) async -> String {
        terminalCommands.append(command)
        return "spy output"
    }

    func switchApp(named appName: String) async -> Bool {
        switchedApps.append(appName)
        return true
    }
}

@MainActor
struct ActionExecutorTests {
    @Test
    func dryRunClickDoesNotTouchComputerController() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: true)
        let action = StructuredAction(
            type: .click,
            targetKind: "point",
            targetText: "Search",
            coordinates: [40, 80],
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result.contains("Dry-run only"))
        #expect(await controller.clicks.isEmpty)
    }

    @Test
    func permissionedClickUsesCoordinates() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)
        let action = StructuredAction(
            type: .click,
            targetKind: "point",
            targetText: "Search",
            coordinates: [40, 80],
            expectedResult: "clicked",
            riskLevel: .low,
            reason: "test"
        )

        let result = await executor.execute(action)

        #expect(result == "Clicked Search at 40,80.")
        #expect(await controller.clicks == [CGPoint(x: 40, y: 80)])
    }

    @Test
    func permissionedTypingScrollAndKeyUseComputerController() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        _ = await executor.execute(StructuredAction(
            type: .typeTextSafe,
            targetKind: "focused_field",
            targetText: "focused field",
            text: "hello",
            expectedResult: "typed",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .scroll,
            targetKind: "window",
            targetText: "main window",
            coordinates: [0, -3],
            expectedResult: "scrolled",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .pressKey,
            targetKind: "keyboard",
            targetText: "Return",
            text: "return",
            expectedResult: "pressed",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(await controller.typedText == ["hello"])
        #expect(await controller.scrolls == [-3])
        #expect(await controller.keys == ["return"])
    }

    @Test
    func permissionedExtendedDesktopActionsUseComputerController() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        _ = await executor.execute(StructuredAction(
            type: .doubleClick,
            targetKind: "point",
            targetText: "File",
            coordinates: [100, 200],
            expectedResult: "opened",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .copy,
            targetKind: "selection",
            targetText: "selected text",
            expectedResult: "copied",
            riskLevel: .medium,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .paste,
            targetKind: "focused_field",
            targetText: "focused field",
            text: "safe paste",
            expectedResult: "pasted",
            riskLevel: .medium,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .openURL,
            targetKind: "browser",
            targetText: "https://example.com",
            expectedResult: "opened",
            riskLevel: .medium,
            reason: "test"
        ))
        let terminalResult = await executor.execute(StructuredAction(
            type: .runTerminalCommand,
            targetKind: "terminal",
            targetText: "shell",
            command: "pwd",
            expectedResult: "printed cwd",
            riskLevel: .low,
            reason: "test"
        ))
        _ = await executor.execute(StructuredAction(
            type: .switchApp,
            targetKind: "app",
            targetText: "Finder",
            expectedResult: "Finder activated",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(await controller.doubleClicks == [CGPoint(x: 100, y: 200)])
        #expect(await controller.copyCount == 1)
        #expect(await controller.pastedText == ["safe paste"])
        #expect(await controller.openedURLs == ["https://example.com"])
        #expect(await controller.terminalCommands == ["pwd"])
        #expect(terminalResult == "Terminal command completed: spy output")
        #expect(await controller.switchedApps == ["Finder"])
    }

    @Test
    func permissionedExtendedActionsValidateRequiredFields() async {
        let controller = SpyComputerController()
        let executor = LocalPilotActionExecutor(computerController: controller, dryRun: false)

        let doubleClickResult = await executor.execute(StructuredAction(
            type: .doubleClick,
            targetKind: "point",
            targetText: "File",
            expectedResult: "opened",
            riskLevel: .low,
            reason: "test"
        ))
        let pasteResult = await executor.execute(StructuredAction(
            type: .paste,
            targetKind: "focused_field",
            targetText: "focused field",
            expectedResult: "pasted",
            riskLevel: .medium,
            reason: "test"
        ))
        let terminalResult = await executor.execute(StructuredAction(
            type: .runTerminalCommand,
            targetKind: "terminal",
            targetText: "shell",
            expectedResult: "ran",
            riskLevel: .low,
            reason: "test"
        ))

        #expect(doubleClickResult.contains("coordinates are missing"))
        #expect(pasteResult.contains("text is missing"))
        #expect(terminalResult.contains("command is missing"))
        #expect(await controller.doubleClicks.isEmpty)
        #expect(await controller.pastedText.isEmpty)
        #expect(await controller.terminalCommands.isEmpty)
    }
}
