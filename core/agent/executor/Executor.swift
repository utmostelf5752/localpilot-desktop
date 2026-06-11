import Foundation

public protocol ActionExecutor: Sendable {
    func execute(_ action: StructuredAction) async -> String
    func stopImmediately() async
    func setPaused(_ paused: Bool) async
}

public actor LocalPilotActionExecutor: ActionExecutor {
    private let screenObserver: any ScreenObserving
    private let dryRun: Bool
    private var enabled = true
    private var paused = false

    public init(screenObserver: any ScreenObserving = LiveScreenObserver(), dryRun: Bool = true) {
        self.screenObserver = screenObserver
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
        default:
            if dryRun {
                return "Dry-run only: \(action.type.rawValue) was validated but no OS control was performed."
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
