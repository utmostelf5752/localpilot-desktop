import CoreGraphics
import Foundation

public protocol ActionExecutor: Sendable {
    func execute(_ action: StructuredAction) async -> String
    func stopImmediately() async
    func setPaused(_ paused: Bool) async
}

public protocol ComputerControlling: Sendable {
    func click(at point: CGPoint) async
    func typeText(_ text: String) async
    func scroll(deltaY: Int32) async
    func pressKey(named key: String) async
}

public actor QuartzComputerController: ComputerControlling {
    public init() {}

    public func click(at point: CGPoint) {
        postMouse(.mouseMoved, at: point)
        postMouse(.leftMouseDown, at: point)
        postMouse(.leftMouseUp, at: point)
    }

    public func typeText(_ text: String) {
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }
            utf16.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    public func scroll(deltaY: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    public func pressKey(named key: String) {
        guard let keyCode = Self.keyCode(for: key.lowercased()) else { return }
        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        switch key {
        case "return", "enter": 36
        case "tab": 48
        case "space": 49
        case "delete", "backspace": 51
        case "escape", "esc": 53
        case "left": 123
        case "right": 124
        case "down": 125
        case "up": 126
        default: nil
        }
    }
}

public actor LocalPilotActionExecutor: ActionExecutor {
    private let screenObserver: any ScreenObserving
    private let computerController: any ComputerControlling
    private let dryRun: Bool
    private var enabled = true
    private var paused = false

    public init(
        screenObserver: any ScreenObserving = LiveScreenObserver(),
        computerController: any ComputerControlling = QuartzComputerController(),
        dryRun: Bool = true
    ) {
        self.screenObserver = screenObserver
        self.computerController = computerController
        self.dryRun = dryRun
    }

    public func execute(_ action: StructuredAction) async -> String {
        guard enabled else { return "Executor disabled." }
        guard !paused else { return "Executor paused." }

        switch action.type {
        case .observe:
            let observation = await screenObserver.capture()
            return "Observed current screen: \(observation.summary)"
        case .wait:
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "Wait completed."
        case .finish:
            return "Task marked finished."
        case .askUser:
            return "Asked user for input."
        case .click:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let point = action.point else { return "Click blocked: coordinates are missing." }
            await computerController.click(at: point)
            return "Clicked \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
        case .typeTextSafe:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let text = action.text, !text.isEmpty else { return "Typing blocked: text is missing." }
            await computerController.typeText(text)
            return "Typed safe text into \(action.targetText)."
        case .scroll:
            guard !dryRun else { return dryRunResult(for: action) }
            let delta = action.scrollDeltaY
            await computerController.scroll(deltaY: delta)
            return "Scrolled \(action.targetText) by \(delta)."
        case .pressKey:
            guard !dryRun else { return dryRunResult(for: action) }
            let key = (action.text ?? action.targetText).lowercased()
            await computerController.pressKey(named: key)
            return "Pressed \(key)."
        case .doubleClick, .typeTextSensitive, .copy, .paste, .openURL, .runTerminalCommand, .switchApp:
            if dryRun {
                return dryRunResult(for: action)
            }
            return "Executor has no implementation for \(action.type.rawValue) yet."
        }
    }

    public func stopImmediately() {
        enabled = false
        paused = false
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        enabled = !paused
    }

    private func dryRunResult(for action: StructuredAction) -> String {
        "Dry-run only: \(action.type.rawValue) was validated but no OS control was performed."
    }
}

public actor StubActionExecutor: ActionExecutor {
    private var enabled = true
    private var paused = false

    public init() {}

    public func execute(_ action: StructuredAction) async -> String {
        guard enabled else { return "Executor disabled." }
        guard !paused else { return "Executor paused." }

        switch action.type {
        case .observe:
            return "Observed current app shell state. Real screen capture is not enabled yet."
        case .wait:
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "Wait completed."
        case .finish:
            return "Task marked finished."
        case .askUser:
            return "Asked user for input."
        default:
            return "Dry-run only: \(action.type.rawValue) was validated but no OS control was performed."
        }
    }

    public func stopImmediately() {
        enabled = false
        paused = false
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            enabled = false
        } else {
            enabled = true
        }
    }
}

private extension StructuredAction {
    var point: CGPoint? {
        guard let coordinates, coordinates.count >= 2 else { return nil }
        return CGPoint(x: coordinates[0], y: coordinates[1])
    }

    var scrollDeltaY: Int32 {
        guard let coordinates, coordinates.count >= 2 else { return -5 }
        return Int32(coordinates[1])
    }
}
