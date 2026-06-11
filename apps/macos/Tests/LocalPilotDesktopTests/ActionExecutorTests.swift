import Foundation
import Testing
@testable import LocalPilotDesktop

actor SpyComputerController: ComputerControlling {
    private(set) var clicks: [CGPoint] = []
    private(set) var typedText: [String] = []
    private(set) var scrolls: [Int32] = []
    private(set) var keys: [String] = []

    func click(at point: CGPoint) async {
        clicks.append(point)
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
}
