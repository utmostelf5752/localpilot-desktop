import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public protocol ActionExecutor: Sendable {
    func execute(_ action: StructuredAction) async -> String
    func stopImmediately() async
    func setPaused(_ paused: Bool) async
    /// Set whether execution is dry-run (validate only) or performs real OS
    /// control. A required member (not a defaulted one) so the witness is always
    /// the conformer's own implementation.
    func setDryRun(_ dryRun: Bool) async
}

public protocol ComputerControlling: Sendable {
    func move(to point: CGPoint) async
    func click(at point: CGPoint) async
    func doubleClick(at point: CGPoint) async
    func typeText(_ text: String) async
    func scroll(deltaY: Int32) async
    func pressKey(named key: String) async
    func copySelection() async
    func pasteText(_ text: String) async
    func openURL(_ urlString: String) async -> Bool
    func runTerminalCommand(_ command: String) async -> String
    func switchApp(named appName: String) async -> Bool
}

public actor QuartzComputerController: ComputerControlling {
    public init() {}

    public func move(to point: CGPoint) {
        postMouse(.mouseMoved, at: point)
    }

    public func click(at point: CGPoint) {
        postMouse(.mouseMoved, at: point)
        postMouse(.leftMouseDown, at: point)
        postMouse(.leftMouseUp, at: point)
    }

    public func doubleClick(at point: CGPoint) {
        postMouse(.mouseMoved, at: point)
        postMouse(.leftMouseDown, at: point, clickState: 1)
        postMouse(.leftMouseUp, at: point, clickState: 1)
        postMouse(.leftMouseDown, at: point, clickState: 2)
        postMouse(.leftMouseUp, at: point, clickState: 2)
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
        postKey(keyCode)
    }

    public func copySelection() {
        postCommandKey(8)
    }

    public func pasteText(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        postCommandKey(9)
    }

    public func openURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return false
        }
        #if canImport(AppKit)
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #else
        return false
        #endif
    }

    public func runTerminalCommand(_ command: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "failed to start: \(error.localizedDescription)"
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let bounded = String(combined.prefix(1_000))
        if process.terminationStatus == 0 {
            return bounded.isEmpty ? "exit 0" : bounded
        }
        return "exit \(process.terminationStatus): \(bounded)"
    }

    public func switchApp(named appName: String) async -> Bool {
        #if canImport(AppKit)
        let normalized = appName.lowercased()
        if let runningApp = await MainActor.run(body: {
            NSWorkspace.shared.runningApplications.first { app in
                app.localizedName?.lowercased() == normalized ||
                    app.bundleIdentifier?.lowercased() == normalized
            }
        }) {
            return await MainActor.run {
                runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }

        let escaped = appName.replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runTerminalCommand("/usr/bin/open -a \"\(escaped)\"")
        return !result.hasPrefix("exit ")
        #else
        return false
        #endif
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, clickState: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: clickState)
        event?.post(tap: .cghidEventTap)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postCommandKey(_ keyCode: CGKeyCode) {
        postKey(keyCode, flags: .maskCommand)
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
    private var dryRun: Bool
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

    public func setDryRun(_ dryRun: Bool) {
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
        case .batch:
            // A batch is expanded and gated action-by-action by the orchestrator;
            // it must never be executed as an opaque unit here.
            return "Batch is expanded by the orchestrator and not executed directly."
        case .moveCursor:
            guard !dryRun else { return dryRunResult(for: action) }
            let point: CGPoint
            if let elementID = action.targetElementID {
                switch await resolveElement(id: elementID) {
                case .resolved(let resolved): point = resolved
                case .notFound(let message): return message
                }
            } else {
                guard let coordinatePoint = action.point else { return "Move blocked: coordinates are missing." }
                point = coordinatePoint
            }
            await computerController.move(to: point)
            return "Moved cursor to \(Int(point.x)),\(Int(point.y))."
        case .click:
            guard !dryRun else { return dryRunResult(for: action) }
            let point: CGPoint
            if let elementID = action.targetElementID {
                switch await resolveElement(id: elementID) {
                case .resolved(let resolved): point = resolved
                case .notFound(let message): return message
                }
            } else {
                guard let coordinatePoint = action.point else { return "Click blocked: coordinates are missing." }
                point = coordinatePoint
            }
            await computerController.click(at: point)
            return "Clicked \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
        case .doubleClick:
            guard !dryRun else { return dryRunResult(for: action) }
            let point: CGPoint
            if let elementID = action.targetElementID {
                switch await resolveElement(id: elementID) {
                case .resolved(let resolved): point = resolved
                case .notFound(let message): return message
                }
            } else {
                guard let coordinatePoint = action.point else { return "Double-click blocked: coordinates are missing." }
                point = coordinatePoint
            }
            await computerController.doubleClick(at: point)
            return "Double-clicked \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
        case .typeTextSafe:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let text = action.text, !text.isEmpty else { return "Typing blocked: text is missing." }
            // If an element id is given, focus the field by clicking its center
            // before typing; otherwise type into whatever is currently focused.
            if let elementID = action.targetElementID {
                switch await resolveElement(id: elementID) {
                case .resolved(let point):
                    await computerController.click(at: point)
                    await computerController.typeText(text)
                    return "Typed safe text into \(action.targetText) at \(Int(point.x)),\(Int(point.y))."
                case .notFound(let message):
                    return message
                }
            }
            await computerController.typeText(text)
            return "Typed safe text into \(action.targetText)."
        case .scroll:
            guard !dryRun else { return dryRunResult(for: action) }
            let delta = action.scrollDeltaY
            await computerController.scroll(deltaY: delta)
            return "Scrolled \(action.targetText) by \(delta)."
        case .pressKey:
            guard !dryRun else { return dryRunResult(for: action) }
            let key = (action.text ?? action.targetText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty else { return "Key press blocked: key name is missing." }
            await computerController.pressKey(named: key)
            return "Pressed \(key)."
        case .copy:
            guard !dryRun else { return dryRunResult(for: action) }
            await computerController.copySelection()
            return "Copied \(action.targetText)."
        case .paste:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let text = action.text, !text.isEmpty else { return "Paste blocked: text is missing." }
            await computerController.pasteText(text)
            return "Pasted approved text into \(action.targetText)."
        case .openURL:
            guard !dryRun else { return dryRunResult(for: action) }
            let urlString = action.text ?? action.targetText
            guard await computerController.openURL(urlString) else { return "Open URL blocked or failed: \(urlString)." }
            return "Opened URL \(urlString)."
        case .runTerminalCommand:
            guard !dryRun else { return dryRunResult(for: action) }
            guard let command = action.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Terminal command blocked: command is missing."
            }
            let output = await computerController.runTerminalCommand(command)
            return "Terminal command completed: \(output)"
        case .switchApp:
            guard !dryRun else { return dryRunResult(for: action) }
            let appName = action.text ?? action.targetText
            guard !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Switch app blocked: app name is missing."
            }
            guard await computerController.switchApp(named: appName) else { return "Switch app failed: \(appName)." }
            return "Switched to \(appName)."
        case .typeTextSensitive:
            return "Sensitive typing is blocked by policy and executor."
        }
    }

    public func stopImmediately() {
        enabled = false
        paused = false
    }

    public func setPaused(_ paused: Bool) {
        // Pause is a soft interrupt: it sets the paused flag but leaves the
        // executor "enabled", so execute() reports "Executor paused." rather than
        // the hard-stop "Executor disabled.". Unpausing also re-enables, which is
        // what lets a fresh run recover after a prior hard Stop disabled it.
        self.paused = paused
        if !paused {
            enabled = true
        }
    }

    private func dryRunResult(for action: StructuredAction) -> String {
        "Dry-run only: \(action.type.rawValue) was validated but no OS control was performed."
    }

    private enum ElementResolution {
        case resolved(CGPoint)
        case notFound(String)
    }

    /// Resolve an accessibility element id to a click point by re-observing the
    /// screen. Ids are traversal-order indices that are only stable within a
    /// single observation, so we capture a fresh one here rather than trusting a
    /// stale list. Returns a clear blocked string when the id is absent so the
    /// loop's failure heuristic re-plans instead of clicking the wrong spot.
    private func resolveElement(id: Int) async -> ElementResolution {
        let observation = await screenObserver.capture()
        guard let element = observation.elements.first(where: { $0.id == id }) else {
            return .notFound("Click blocked: element \(id) not found.")
        }
        return .resolved(CGPoint(x: element.centerX, y: element.centerY))
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

    // The stub never performs OS control, so dry-run state is a no-op here.
    public func setDryRun(_ dryRun: Bool) {}
}

private extension StructuredAction {
    var point: CGPoint? {
        guard let coordinates, coordinates.count >= 2 else { return nil }
        let x = coordinates[0]
        let y = coordinates[1]
        // Reject non-finite or negative coordinates: a NaN/Infinity would crash
        // when later converted to Int, and off-screen negatives indicate a
        // malformed action rather than a real target.
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
        return CGPoint(x: x, y: y)
    }

    var scrollDeltaY: Int32 {
        guard let coordinates, coordinates.count >= 2, coordinates[1].isFinite else { return -5 }
        // Clamp to Int32 range so a malformed huge value cannot trap on
        // conversion; Int32(_:) crashes on out-of-range Doubles.
        let raw = coordinates[1].rounded()
        if raw >= Double(Int32.max) { return Int32.max }
        if raw <= Double(Int32.min) { return Int32.min }
        return Int32(raw)
    }
}
