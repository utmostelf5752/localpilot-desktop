import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class AgentController {
    public private(set) var runStatus: AgentRunStatus = .idle
    public private(set) var overlayState: OverlayState = .idle
    public private(set) var executorEnabled = false
    public private(set) var currentActionLabel = "Idle"
    public private(set) var fakeCursorPosition = CGPoint(x: 240, y: 180)
    public private(set) var messages: [ChatMessage] = [
        ChatMessage(role: .system, text: "LocalPilot Desktop is ready. Enter a task to start a guarded fake run.")
    ]
    public private(set) var recentLogSnippets: [String] = []
    public private(set) var continueInstructions: [String] = []
    public private(set) var state = LocalPilotState.empty
    public var settings: AppSettings
    public private(set) var settingsStatus = "Settings loaded"
    public private(set) var providerStatus = "Not connected"
    public private(set) var pendingApproval: PendingApproval?
    /// Live event log for the in-progress task, shown by the Activity view.
    public private(set) var currentTaskEvents: [LocalEvent] = []

    /// Persisted past-task transcripts, surfaced in the Tasks list.
    @ObservationIgnored public let taskSessionStore: TaskSessionStore

    @ObservationIgnored private let logger: LocalEventLogger
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let policyEngine = DeterministicPolicyEngine()
    @ObservationIgnored private let executor: any ActionExecutor
    @ObservationIgnored private let contextBuilder: AgentContextBuilder
    @ObservationIgnored private weak var modelSessionCloser: ModelSessionClosing?
    @ObservationIgnored private let useModelLoop: Bool
    @ObservationIgnored private var actionLoop: Task<Void, Never>?
    @ObservationIgnored private var activeTaskID: UUID?
    @ObservationIgnored private var approvalDecision: ApprovalDecision?
    @ObservationIgnored private var history = AgentHistory()
    @ObservationIgnored private var sessionCreatedAt = Date()
    @ObservationIgnored private var turnScreenshotIndex = 0
    /// Index into `messages` where the current task's transcript begins, so each
    /// persisted session captures only its own turns (the live chat is one
    /// continuous stream).
    @ObservationIgnored private var sessionMessageStartIndex = 0

    public init(
        logger: LocalEventLogger = LocalEventLogger(),
        settingsStore: SettingsStore = SettingsStore(),
        taskSessionStore: TaskSessionStore = TaskSessionStore(),
        screenObserver: any ScreenObserving = LiveScreenObserver(),
        executor: (any ActionExecutor)? = nil,
        modelSessionCloser: ModelSessionClosing? = nil,
        useModelLoop: Bool = true
    ) {
        self.logger = logger
        self.settingsStore = settingsStore
        self.taskSessionStore = taskSessionStore
        self.contextBuilder = AgentContextBuilder(screenObserver: screenObserver)
        self.executor = executor ?? LocalPilotActionExecutor(screenObserver: screenObserver)
        self.modelSessionCloser = modelSessionCloser
        self.useModelLoop = useModelLoop
        self.settings = (try? settingsStore.load()) ?? .defaultValue
    }

    public var logFileURL: URL {
        logger.logFileURL
    }

    public func start(task rawTask: String) {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }

        stopLoopOnly()

        let taskID = UUID()
        activeTaskID = taskID
        history = AgentHistory()
        currentTaskEvents = []
        turnScreenshotIndex = 0
        sessionCreatedAt = Date()
        state = LocalPilotState.empty
        state.taskID = taskID
        state.originalTask = task
        state.status = .running
        state.allowedDomains = settings.allowedDomains
        state.allowedApps = settings.allowedApps
        state.allowedFolders = settings.allowedFolders

        sessionMessageStartIndex = messages.count
        messages.append(ChatMessage(role: .user, text: task))
        messages.append(ChatMessage(role: .agent, text: "Starting Agent Mode with managed local planner/guard integration. Observe actions now capture current screen metadata; non-observe execution remains dry-run unless a later permissioned executor is enabled."))
        runStatus = .running
        overlayState = .running
        executorEnabled = true
        currentActionLabel = "Observing screen"
        fakeCursorPosition = CGPoint(x: 260, y: 220)
        appendLog("Started task")

        log(event: "task_started", detail: task)
        if useModelLoop {
            actionLoop = Task { [weak self] in
                await self?.runAgentLoop(task: task)
            }
        }
    }

    public func pause() {
        guard runStatus == .running else { return }
        runStatus = .paused
        overlayState = .paused
        executorEnabled = false
        Task { await executor.setPaused(true) }
        currentActionLabel = "Paused"
        state.status = .paused
        appendLog("Paused")
        log(event: "task_paused", detail: "Paused by user")
    }

    public func continueTask(instruction rawInstruction: String) {
        guard runStatus == .paused else { return }
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            continueInstructions.append(instruction)
            messages.append(ChatMessage(role: .user, text: "Continue instruction: \(instruction)"))
        }

        runStatus = .running
        overlayState = .running
        executorEnabled = true
        Task { await executor.setPaused(false) }
        currentActionLabel = "Resuming"
        state.status = .running
        appendLog("Continued")
        log(event: "task_continued", detail: instruction.isEmpty ? "No extra instruction" : instruction)
    }

    public func stop() {
        guard runStatus != .idle else { return }
        runStatus = .stopped
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Stopped"
        state.status = .stopped
        stopLoopOnly()
        Task { await executor.stopImmediately() }
        closeModelsIfNeeded()
        appendLog("Stopped")
        messages.append(ChatMessage(role: .agent, text: "Stopped. The executor is disabled and no queued actions remain."))
        log(event: "task_stopped", detail: "Hard stop by user")
    }

    private func stopLoopOnly() {
        actionLoop?.cancel()
        actionLoop = nil
        pendingApproval = nil
        approvalDecision = nil
    }

    public func approvePendingAction() {
        approvalDecision = .allow
        pendingApproval = nil
        runStatus = .running
        overlayState = .running
        executorEnabled = true
        appendLog("Approval allowed once")
        log(event: "approval_allowed", detail: "User allowed action once")
    }

    public func denyPendingAction() {
        approvalDecision = .deny
        let action = pendingApproval?.action
        pendingApproval = nil
        runStatus = .blocked
        overlayState = .idle
        executorEnabled = false
        if let action {
            state.deniedActions.append(action)
        }
        appendLog("Approval denied")
        messages.append(ChatMessage(role: .agent, text: "Action denied. The task was blocked."))
        log(event: "approval_denied", detail: "User denied action")
        closeModelsIfNeeded()
    }

    public func saveSettings() {
        do {
            try settingsStore.save(settings)
            settingsStatus = "Settings saved"
            log(event: "settings_saved", detail: settings.plannerModel)
        } catch {
            settingsStatus = "Settings save failed: \(error.localizedDescription)"
        }
    }

    /// Verifies the provider end to end: reach the server, load the selected
    /// model into memory with a tiny completion, then unload it again so the
    /// check leaves no model resident.
    public func testModelRuntimeConnection(using settingsOverride: AppSettings? = nil) {
        let settings = settingsOverride ?? settings
        providerStatus = "Loading model into memory..."
        Task {
            let provider = makePlannerProvider(settings: settings, runtime: ProcessManagedModelRuntime())
            do {
                try await provider.healthCheck()
                _ = try await provider.complete(prompt: "ping", system: nil, format: nil)
                try? await provider.closeModel()
                await MainActor.run {
                    providerStatus = "Model loaded and unloaded OK"
                    appendLog(providerStatus)
                }
            } catch {
                try? await provider.closeModel()
                await MainActor.run {
                    providerStatus = "Connection failed: \(error.localizedDescription)"
                    appendLog(providerStatus)
                }
            }
        }
    }

    private func runAgentLoop(task: String) async {
        let runtime = ProcessManagedModelRuntime()
        let plannerProvider = makePlannerProvider(settings: settings, runtime: runtime)
        let guardProvider = makeGuardProvider(settings: settings, runtime: runtime)
        if let manager = modelSessionCloser as? ModelSessionManager {
            manager.register(plannerProvider)
            manager.register(guardProvider)
        }

        let planner = JSONActionPlanner(provider: plannerProvider, structuredOutput: settings.useStructuredDecoding)
        let compactor = ContextCompactor(config: ContextCompactionConfig(
            contextWindowTokens: max(1, settings.contextWindowSize),
            compactionThreshold: ContextCompactionConfig.defaultValue.compactionThreshold,
            rawTailRatio: ContextCompactionConfig.defaultValue.rawTailRatio
        ))
        let tieredGuard = TieredGuard(
            model: JSONGuardModel(provider: guardProvider),
            auditLog: { [weak self] decision in
                Task { @MainActor in
                    self?.log(event: "guard_audit", detail: "\(decision.decision.rawValue): \(decision.reason)")
                }
            }
        )
        var context = await contextBuilder.makeContext(settings: settings, task: task, history: history)
        state.lastObservationSummary = context.visibleText.components(separatedBy: "\n").last ?? ""

        do {
            currentActionLabel = "Checking \(settings.modelProviderMode.displayName)"
            providerStatus = currentActionLabel + "..."
            try await plannerProvider.healthCheck()
            providerStatus = "\(settings.modelProviderMode.displayName) connected"

            let maxActions = 20
            let maxPlan = 6
            var executedActions = 0

            planningRounds: while executedActions < maxActions {
                guard !Task.isCancelled, runStatus == .running else { return }
                await waitIfPaused()
                guard runStatus == .running else { return }

                currentActionLabel = "Observing screen"
                context = await contextBuilder.makeContext(settings: settings, task: task, history: history)
                state.lastObservationSummary = context.visibleText.components(separatedBy: "\n").last ?? ""
                if compactor.shouldCompact(estimatedTokens: compactor.estimateTokens(context.visibleText)) {
                    log(event: "context_compacted", detail: "Context kept lean: rolling summary plus recent step tail.")
                }
                log(event: "screen_observed", detail: state.lastObservationSummary)

                currentActionLabel = "Planning"
                log(event: "planning", detail: "Requesting next action plan")

                let plan = try await planner.proposeActions(
                    originalTask: task,
                    context: context,
                    recentMessages: messages,
                    maxActions: maxPlan
                )
                if plan.count > 1 {
                    log(event: "plan_proposed", detail: "Planner proposed \(plan.count) actions; each is gated and executed one at a time.")
                }

                // Execute the planned actions one at a time. Each is independently
                // re-validated and remains interruptible; we re-observe between
                // steps and abandon the rest of the plan to re-plan if a step
                // fails or the screen no longer matches.
                for (index, action) in plan.enumerated() {
                    guard executedActions < maxActions else { break planningRounds }
                    guard !Task.isCancelled, runStatus == .running else { return }
                    await waitIfPaused()
                    guard runStatus == .running else { return }

                    if index > 0 {
                        currentActionLabel = "Observing screen"
                        context = await contextBuilder.makeContext(settings: settings, task: task, history: history)
                        state.lastObservationSummary = context.visibleText.components(separatedBy: "\n").last ?? ""
                        log(event: "screen_observed", detail: state.lastObservationSummary)
                    }

                    let turnScreenshot = saveTurnScreenshot(context.latestScreenshotPNGBase64)
                    messages.append(ChatMessage(role: .agent, text: "Proposed `\(action.type.rawValue)`: \(action.expectedResult)", screenshotPath: turnScreenshot))
                    currentActionLabel = "Policy check: \(action.type.rawValue)"

                    let policy = policyEngine.classify(action: action, context: context)
                    log(event: "policy_decision", detail: "\(policy.classification.rawValue): \(policy.reason)")

                    // Approval gating respects the user's approval mode:
                    // - yolo:   never pause; deterministic blocks still block.
                    // - risky:  pause only on policy/guard-flagged actions (askUser).
                    // - accept: pause on every action, including plain allows.
                    switch policy.classification {
                    case .block:
                        blockTask(reason: policy.reason, action: action)
                        return
                    case .askUser:
                        if settings.approvalMode != .yolo {
                            let allowed = await requestApproval(action: action, reason: policy.reason)
                            guard allowed else { return }
                        }
                    case .allow:
                        if settings.approvalMode == .accept {
                            let allowed = await requestApproval(action: action, reason: "Approval mode: confirm every action.")
                            guard allowed else { return }
                        }
                    }

                    if settings.useGuardModel {
                        currentActionLabel = "Guard review"
                        let guardDecision = await tieredGuard.decide(action: action, context: context, policyDecision: policy)
                        log(event: "guard_decision", detail: "\(guardDecision.decision.rawValue): \(guardDecision.reason)")
                        guard guardDecision.decision == .allow else {
                            blockTask(reason: guardDecision.reason, action: action)
                            return
                        }
                    }

                    guard !Task.isCancelled, runStatus == .running else { return }

                    executedActions += 1
                    fakeCursorPosition = CGPoint(x: 260 + CGFloat(executedActions * 18), y: 220 + CGFloat(executedActions * 10))
                    currentActionLabel = "Executing \(action.type.rawValue)"
                    let result = await executor.execute(action)
                    state.completedSteps.append(action.type.rawValue)
                    state.lastActionResult = result
                    history.record("\(action.type.rawValue): \(result)", compactor: compactor, maxRecent: 4)
                    appendLog(result)
                    log(event: "executor_result", detail: result)

                    if action.type == .finish {
                        completeTask(message: "Task finished by planner.")
                        return
                    }

                    if Self.indicatesFailure(result) {
                        log(event: "plan_aborted", detail: "Step result indicates failure; re-planning from fresh observation.")
                        continue planningRounds
                    }
                }
            }

            blockTask(reason: "Planner reached the \(maxActions) action safety limit.", action: nil)
        } catch is CancellationError {
            return
        } catch {
            blockTask(reason: "Model loop failed: \(error.localizedDescription)", action: nil)
        }
    }

    private func requestApproval(action: StructuredAction, reason: String) async -> Bool {
        pendingApproval = PendingApproval(action: action, reason: reason)
        approvalDecision = nil
        runStatus = .paused
        overlayState = .approvalRequired
        executorEnabled = false
        currentActionLabel = "Approval required"
        log(event: "approval_required", detail: reason)

        while approvalDecision == nil && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let allowed = approvalDecision == .allow
        approvalDecision = nil
        return allowed
    }

    private func completeTask(message: String) {
        guard runStatus == .running else { return }
        runStatus = .done
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Done"
        state.status = .done
        messages.append(ChatMessage(role: .agent, text: message))
        appendLog("Done")
        log(event: "task_done", detail: message)
        closeModelsIfNeeded()
    }

    private func blockTask(reason: String, action: StructuredAction?) {
        if let action {
            state.deniedActions.append(action)
        }
        runStatus = .blocked
        overlayState = .idle
        executorEnabled = false
        currentActionLabel = "Blocked"
        state.status = .blocked
        messages.append(ChatMessage(role: .agent, text: "Blocked: \(reason)"))
        appendLog("Blocked")
        log(event: "task_blocked", detail: reason)
        closeModelsIfNeeded()
    }

    /// Heuristic: did an executed step fail or get blocked? If so we abandon the
    /// rest of a pre-planned batch and re-plan from fresh observation rather than
    /// blindly running stale follow-up steps.
    private static func indicatesFailure(_ result: String) -> Bool {
        let lowered = result.lowercased()
        return lowered.contains("blocked") || lowered.contains("failed") || lowered.contains("disabled")
    }

    private func waitIfPaused() async {
        while runStatus == .paused && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
        }
    }

    private func appendLog(_ text: String) {
        recentLogSnippets.insert(text, at: 0)
        if recentLogSnippets.count > 8 {
            recentLogSnippets.removeLast()
        }
    }

    private func log(event: String, detail: String) {
        let logEvent = LocalEvent(
            timestamp: Date(),
            taskID: activeTaskID,
            event: event,
            status: runStatus,
            detail: detail,
            currentAction: currentActionLabel
        )
        if activeTaskID != nil {
            currentTaskEvents.append(logEvent)
            syncSession()
        }
        Task {
            await logger.log(logEvent)
        }
    }

    /// Mirror the in-progress run into the persisted session store so the Tasks
    /// list and history reflect it live and survive relaunch. Pin/archive flags
    /// set by the user are preserved across syncs.
    private func syncSession() {
        guard let taskID = activeTaskID else { return }
        let transcript = sessionMessageStartIndex <= messages.count
            ? Array(messages[sessionMessageStartIndex...])
            : messages
        let title = state.originalTask.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
        let isTerminal = runStatus == .done || runStatus == .blocked || runStatus == .stopped
        let existing = taskSessionStore.sessions.first { $0.id == taskID }
        let session = TaskSession(
            id: taskID,
            displayTitle: title.isEmpty ? "Task" : title,
            originalTask: state.originalTask,
            createdAt: sessionCreatedAt,
            completedAt: isTerminal ? Date() : existing?.completedAt,
            status: runStatus,
            messages: transcript,
            events: currentTaskEvents,
            isPinned: existing?.isPinned ?? false,
            archivedAt: existing?.archivedAt
        )
        taskSessionStore.upsert(session)
    }

    /// Persist a per-turn screenshot to disk and return its path, so task history
    /// can show the screen exactly as it was when the action was proposed.
    private func saveTurnScreenshot(_ base64: String?) -> String? {
        guard let base64,
              let data = Data(base64Encoded: base64),
              let taskID = activeTaskID else { return nil }
        let dir = AppSettings.defaultSupportDirectory()
            .appending(path: "screenshots", directoryHint: .isDirectory)
            .appending(path: taskID.uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            turnScreenshotIndex += 1
            let url = dir.appending(path: "turn-\(turnScreenshotIndex).png")
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    private func closeModelsIfNeeded() {
        guard settings.unloadModelsAfterRun else { return }
        modelSessionCloser?.closeLoadedModels()
    }

    private func makePlannerProvider(settings: AppSettings, runtime: any ManagedModelRuntime) -> any LocalModelProvider {
        switch settings.modelProviderMode {
        case .internalInProcess:
            InternalLocalModelProvider(role: .planner, configuration: settings.plannerConfiguration())
        case .managedRuntime:
            ManagedLocalModelProvider(
                configuration: settings.plannerConfiguration(),
                runtimeConfiguration: settings.plannerRuntimeConfiguration(),
                runtime: runtime
            )
        case .apiProvider:
            APIModelProvider(
                configuration: settings.plannerConfiguration(),
                baseURL: settings.apiBaseURL,
                apiKey: settings.apiKey
            )
        case .ollama:
            makeOllamaProvider(configuration: settings.plannerConfiguration(), baseURL: settings.ollamaBaseURL)
        case .lmStudio:
            makeLMStudioProvider(configuration: settings.plannerConfiguration(), baseURL: settings.lmStudioBaseURL)
        }
    }

    private func makeGuardProvider(settings: AppSettings, runtime: any ManagedModelRuntime) -> any LocalModelProvider {
        switch settings.modelProviderMode {
        case .internalInProcess:
            InternalLocalModelProvider(role: .guard, configuration: settings.guardConfiguration())
        case .managedRuntime:
            ManagedLocalModelProvider(
                configuration: settings.guardConfiguration(),
                runtimeConfiguration: settings.guardRuntimeConfiguration(),
                runtime: runtime
            )
        case .apiProvider:
            APIModelProvider(
                configuration: settings.guardConfiguration(),
                baseURL: settings.apiBaseURL,
                apiKey: settings.apiKey
            )
        case .ollama:
            makeOllamaProvider(configuration: settings.guardConfiguration(), baseURL: settings.ollamaBaseURL)
        case .lmStudio:
            makeLMStudioProvider(configuration: settings.guardConfiguration(), baseURL: settings.lmStudioBaseURL)
        }
    }
}

public struct PendingApproval: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let action: StructuredAction
    public let reason: String
}

private enum ApprovalDecision {
    case allow
    case deny
}
