import Foundation

public enum ModelResponseFormat: Sendable, Equatable {
    case json
}

public struct ModelProviderConfiguration: Codable, Equatable, Sendable {
    public var providerName: String
    public var modelName: String
    public var contextWindowSize: Int
    public var temperature: Double
    public var timeoutSeconds: TimeInterval
    public var supportsStreaming: Bool

    public init(
        providerName: String,
        modelName: String,
        contextWindowSize: Int,
        temperature: Double,
        timeoutSeconds: TimeInterval,
        supportsStreaming: Bool
    ) {
        self.providerName = providerName
        self.modelName = modelName
        self.contextWindowSize = contextWindowSize
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.supportsStreaming = supportsStreaming
    }
}

public protocol LocalModelProvider: Sendable {
    var configuration: ModelProviderConfiguration { get }
    func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String
    func healthCheck() async throws
    func cancel() async
    func closeModel() async throws
}

public extension LocalModelProvider {
    func complete(prompt: String) async throws -> String {
        try await complete(prompt: prompt, system: nil, format: nil)
    }
}

public enum InternalModelRole: Sendable {
    case planner
    case `guard`
}

public actor InternalLocalModelProvider: LocalModelProvider {
    public let configuration: ModelProviderConfiguration
    private let role: InternalModelRole
    private var plannerStep = 0

    public init(role: InternalModelRole, configuration: ModelProviderConfiguration? = nil) {
        self.role = role
        self.configuration = configuration ?? ModelProviderConfiguration(
            providerName: "internal-in-process",
            modelName: role.defaultModelName,
            contextWindowSize: 131_072,
            temperature: 0,
            timeoutSeconds: 1,
            supportsStreaming: false
        )
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        switch role {
        case .planner:
            return try nextPlannerAction(for: prompt)
        case .guard:
            return #"{"decision":"allow","reason":"Allowed by internal guard model for the current low-risk step."}"#
        }
    }

    public func healthCheck() async throws {}
    public func cancel() async {}
    public func closeModel() async throws {}

    private func nextPlannerAction(for prompt: String) throws -> String {
        plannerStep += 1
        let action: StructuredAction
        if plannerStep == 1 {
            action = StructuredAction(
                type: .observe,
                targetKind: "screen",
                targetText: "current screen",
                expectedResult: "fresh screen state captured for planner context",
                riskLevel: .low,
                reason: "Internal planner starts with a visible observation step."
            )
        } else if plannerStep == 2, let taskAction = Self.actionForTask(Self.originalTask(from: prompt)) {
            action = taskAction
        } else {
            action = StructuredAction(
                type: .finish,
                targetKind: "task",
                targetText: "current task",
                expectedResult: "task completed after the first internal loop",
                riskLevel: .low,
                reason: "Internal planner completed the smoke-run task."
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(action), encoding: .utf8) ?? "{}"
    }

    private static func originalTask(from prompt: String) -> String {
        guard let start = prompt.range(of: "Original task:")?.upperBound,
              let end = prompt.range(of: "Current context:")?.lowerBound else {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prompt[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func actionForTask(_ task: String) -> StructuredAction? {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if let url = firstURL(in: trimmed), lowered.contains("open") || lowered.contains("go to") {
            return StructuredAction(
                type: .openURL,
                targetKind: "browser",
                targetText: url,
                expectedResult: "URL opens in the default browser",
                riskLevel: .medium,
                reason: "Internal planner recognized a simple open URL task."
            )
        }

        if lowered.hasPrefix("switch to ") {
            let appName = String(trimmed.dropFirst("switch to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty else { return nil }
            return StructuredAction(
                type: .switchApp,
                targetKind: "app",
                targetText: appName,
                expectedResult: "Requested app becomes active",
                riskLevel: .low,
                reason: "Internal planner recognized a simple app switch task."
            )
        }

        if lowered.hasPrefix("press ") {
            let keyName = String(trimmed.dropFirst("press ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyName.isEmpty else { return nil }
            return StructuredAction(
                type: .pressKey,
                targetKind: "keyboard",
                targetText: keyName,
                text: keyName.lowercased(),
                expectedResult: "Requested key is pressed",
                riskLevel: .low,
                reason: "Internal planner recognized a simple keypress task."
            )
        }

        if lowered.hasPrefix("type "), let text = quotedText(in: trimmed) ?? textAfterPrefix(trimmed, prefix: "type ") {
            return StructuredAction(
                type: .typeTextSafe,
                targetKind: "focused_field",
                targetText: "focused field",
                text: text,
                expectedResult: "Text is typed into the focused field",
                riskLevel: .low,
                reason: "Internal planner recognized a simple safe typing task."
            )
        }

        if lowered.contains("scroll down") || lowered == "scroll" {
            return StructuredAction(
                type: .scroll,
                targetKind: "window",
                targetText: "current window",
                coordinates: [0, -5],
                expectedResult: "Current view scrolls down",
                riskLevel: .low,
                reason: "Internal planner recognized a simple scroll task."
            )
        }

        if lowered.contains("scroll up") {
            return StructuredAction(
                type: .scroll,
                targetKind: "window",
                targetText: "current window",
                coordinates: [0, 5],
                expectedResult: "Current view scrolls up",
                riskLevel: .low,
                reason: "Internal planner recognized a simple scroll task."
            )
        }

        if lowered.hasPrefix("run "), let command = quotedText(in: trimmed) ?? backtickedText(in: trimmed) ?? textAfterPrefix(trimmed, prefix: "run ") {
            return StructuredAction(
                type: .runTerminalCommand,
                targetKind: "terminal",
                targetText: "shell",
                command: command,
                expectedResult: "Terminal command completes",
                riskLevel: .low,
                reason: "Internal planner recognized a simple terminal command task."
            )
        }

        if lowered.hasPrefix("double click "), let point = firstPoint(in: lowered) {
            return StructuredAction(
                type: .doubleClick,
                targetKind: "point",
                targetText: "screen point",
                coordinates: point,
                expectedResult: "Target point is double-clicked",
                riskLevel: .low,
                reason: "Internal planner recognized a simple double-click task."
            )
        }

        if lowered.hasPrefix("click "), let point = firstPoint(in: lowered) {
            return StructuredAction(
                type: .click,
                targetKind: "point",
                targetText: "screen point",
                coordinates: point,
                expectedResult: "Target point is clicked",
                riskLevel: .low,
                reason: "Internal planner recognized a simple click task."
            )
        }

        return nil
    }

    private static func firstURL(in text: String) -> String? {
        firstMatch(in: text, pattern: #"https?://[^\s]+"#)
    }

    private static func quotedText(in text: String) -> String? {
        firstMatch(in: text, pattern: #""([^"]+)""#, group: 1)
    }

    private static func backtickedText(in text: String) -> String? {
        firstMatch(in: text, pattern: #"`([^`]+)`"#, group: 1)
    }

    private static func firstPoint(in text: String) -> [Double]? {
        guard let match = firstMatch(in: text, pattern: #"(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)"#),
              let comma = match.firstIndex(of: ","),
              let x = Double(match[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(match[match.index(after: comma)...].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return [x, y]
    }

    private static func textAfterPrefix(_ text: String, prefix: String) -> String? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func firstMatch(in text: String, pattern: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let resultRange = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[resultRange])
    }
}

private extension InternalModelRole {
    var defaultModelName: String {
        switch self {
        case .planner: "internal-planner"
        case .guard: "internal-guard"
        }
    }
}

public struct HTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    /// Per-request timeout. When non-nil and positive it is applied to the
    /// underlying `URLRequest.timeoutInterval` so callers can honor the
    /// provider's configured `timeoutSeconds`.
    public let timeoutSeconds: TimeInterval?

    public init(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }

    public var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPClient: Sendable {
    func data(for request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }
        if let timeoutSeconds = request.timeoutSeconds, timeoutSeconds > 0 {
            urlRequest.timeoutInterval = timeoutSeconds
        }

        let (data, response) = try await session.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(data: data, statusCode: statusCode)
    }
}

public enum ModelProviderError: LocalizedError, Sendable {
    case badStatus(Int, String)
    case invalidResponse
    case runtimeExecutableMissing(String)
    case runtimeLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .badStatus(status, body):
            "Model provider returned HTTP \(status): \(body)"
        case .invalidResponse:
            "Model provider returned an invalid response."
        case let .runtimeExecutableMissing(path):
            "Model runtime executable was not found at \(path)."
        case let .runtimeLaunchFailed(message):
            "Model runtime failed to launch: \(message)"
        }
    }
}

public struct ManagedModelRuntimeConfiguration: Codable, Equatable, Sendable {
    public var executableURL: URL
    public var modelURL: URL
    public var host: String
    public var port: Int
    public var launchArguments: [String]
    public var environment: [String: String]
    public var healthPath: String
    public var completionsPath: String

    public init(
        executableURL: URL,
        modelURL: URL,
        host: String,
        port: Int,
        launchArguments: [String],
        environment: [String: String],
        healthPath: String,
        completionsPath: String
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.host = host
        self.port = port
        self.launchArguments = launchArguments
        self.environment = environment
        self.healthPath = healthPath
        self.completionsPath = completionsPath
    }

    public var endpoint: URL {
        URL(string: "http://\(host):\(port)")!
    }
}

public protocol ManagedModelRuntime: Sendable {
    func ensureRunning(configuration: ManagedModelRuntimeConfiguration) async throws -> URL
    func stop() async
}

public actor ProcessManagedModelRuntime: ManagedModelRuntime {
    private let httpClient: HTTPClient
    /// Seconds to wait for the runtime to report healthy before giving up.
    private let healthCheckTimeout: TimeInterval
    private var process: Process?
    private var endpoint: URL?
    /// Pipes are retained so we can detach their readability handlers on stop.
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    public init(httpClient: HTTPClient = URLSessionHTTPClient(), healthCheckTimeout: TimeInterval = 8) {
        self.httpClient = httpClient
        self.healthCheckTimeout = healthCheckTimeout
    }

    public func ensureRunning(configuration: ManagedModelRuntimeConfiguration) async throws -> URL {
        if let process, process.isRunning, let endpoint {
            return endpoint
        }

        // A previously launched process may have exited; clean it up before relaunching.
        if process != nil {
            teardownProcess(kill: false)
        }

        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw ModelProviderError.runtimeExecutableMissing(configuration.executableURL.path)
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.launchArguments.map { argument in
            argument
                .replacingOccurrences(of: "{model}", with: configuration.modelURL.path)
                .replacingOccurrences(of: "{host}", with: configuration.host)
                .replacingOccurrences(of: "{port}", with: String(configuration.port))
        }
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }

        // Drain stdout/stderr continuously. Without this the OS pipe buffer
        // (typically 64KB) fills up and the model subprocess blocks forever on
        // its next write, deadlocking startup.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ModelProviderError.runtimeLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.endpoint = configuration.endpoint
        do {
            try await waitUntilHealthy(configuration: configuration, process: process)
        } catch {
            // Tear down the half-started process so we don't leak it / leave a zombie.
            teardownProcess(kill: true)
            throw error
        }
        return configuration.endpoint
    }

    public func stop() {
        teardownProcess(kill: true)
    }

    /// Terminates and reaps the managed process, detaching pipe handlers.
    /// When `kill` is true the process is escalated from SIGTERM to SIGKILL if
    /// it does not exit promptly.
    private func teardownProcess(kill: Bool) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        guard let process else {
            endpoint = nil
            return
        }
        if process.isRunning {
            process.terminate() // SIGTERM: request graceful shutdown.
            if kill {
                // Escalate to SIGKILL if it is still alive after a short grace period.
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill_(process.processIdentifier)
                }
            }
        }
        // Reap so the OS does not retain a zombie entry.
        if process.isRunning {
            process.waitUntilExit()
        }
        self.process = nil
        endpoint = nil
    }

    private nonisolated func kill_(_ pid: pid_t) {
        // SIGKILL (9) cannot be caught; guarantees the runtime is gone.
        Foundation.kill(pid, SIGKILL)
    }

    private func waitUntilHealthy(configuration: ManagedModelRuntimeConfiguration, process: Process) async throws {
        let deadline = Date().addingTimeInterval(healthCheckTimeout)
        let healthURL = configuration.endpoint.appending(path: normalizedPath(configuration.healthPath))

        while Date() < deadline {
            // If the subprocess exited (e.g. bad model file) stop polling immediately.
            if !process.isRunning {
                throw ModelProviderError.runtimeLaunchFailed(
                    "Runtime exited during startup (status \(process.terminationStatus))."
                )
            }
            do {
                // Bound each probe so a connected-but-hung server cannot block
                // past the overall health-check deadline (the loop only re-checks
                // `deadline` between probes, so an unbounded request would stall).
                let response = try await httpClient.data(for: HTTPRequest(
                    url: healthURL,
                    method: "GET",
                    timeoutSeconds: max(1, healthCheckTimeout / 4)
                ))
                if (200..<300).contains(response.statusCode) {
                    return
                }
            } catch {
                // Connection refused while the server is still binding is expected; retry.
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        throw ModelProviderError.runtimeLaunchFailed("Timed out waiting for \(healthURL.absoluteString)")
    }
}

public actor ManagedLocalModelProvider: LocalModelProvider {
    public let configuration: ModelProviderConfiguration
    private let runtimeConfiguration: ManagedModelRuntimeConfiguration
    private let runtime: any ManagedModelRuntime
    private let httpClient: HTTPClient
    private var activeTask: Task<String, Error>?

    public init(
        configuration: ModelProviderConfiguration,
        runtimeConfiguration: ManagedModelRuntimeConfiguration,
        runtime: any ManagedModelRuntime = ProcessManagedModelRuntime(),
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.configuration = configuration
        self.runtimeConfiguration = runtimeConfiguration
        self.runtime = runtime
        self.httpClient = httpClient
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        // Cancel any previously in-flight completion before starting a new one so
        // overlapping calls don't leak tasks or clobber `activeTask` bookkeeping.
        activeTask?.cancel()

        let task = Task<String, Error> {
            try Task.checkCancellation()
            let endpoint = try await self.runtime.ensureRunning(configuration: self.runtimeConfiguration)
            try Task.checkCancellation()
            var payload: [String: Any] = [
                "model": self.configuration.modelName,
                "prompt": prompt,
                "stream": false,
                "options": [
                    "temperature": self.configuration.temperature
                ]
            ]
            if let system {
                payload["system"] = system
            }
            if format == .json {
                payload["format"] = "json"
            }

            let response = try await self.postCompletion(endpoint: endpoint, payload: payload)
            try Task.checkCancellation()
            return try self.decodeCompletionResponse(response)
        }
        activeTask = task
        defer {
            // Only clear if it is still the task we installed; a concurrent
            // completion may already have replaced it.
            if activeTask == task {
                activeTask = nil
            }
        }
        // Propagate cancellation of the *calling* task (e.g. the orchestrator's
        // action loop being cancelled) into the spawned unstructured task.
        // Awaiting `task.value` alone does not forward structured cancellation,
        // so without this an aborted run would leak an in-flight HTTP request.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func healthCheck() async throws {
        let endpoint = try await runtime.ensureRunning(configuration: runtimeConfiguration)
        let url = endpoint.appending(path: normalizedPath(runtimeConfiguration.healthPath))
        let response = try await httpClient.data(for: HTTPRequest(
            url: url,
            method: "GET",
            timeoutSeconds: configuration.timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(data: response.data, encoding: .utf8) ?? "")
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    public func closeModel() async throws {
        await runtime.stop()
    }

    private func postCompletion(endpoint: URL, payload: [String: Any]) async throws -> Data {
        let url = endpoint.appending(path: normalizedPath(runtimeConfiguration.completionsPath))
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await httpClient.data(for: HTTPRequest(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeoutSeconds: configuration.timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(data: response.data, encoding: .utf8) ?? "")
        }
        return response.data
    }

    private func decodeCompletionResponse(_ data: Data) throws -> String {
        struct CompletionResponse: Decodable {
            let response: String?
            let text: String?
            let content: String?
        }

        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let response = decoded.response ?? decoded.text ?? decoded.content else {
            throw ModelProviderError.invalidResponse
        }
        return response
    }
}

public protocol ModelSessionClosing: AnyObject {
    @MainActor func closeLoadedModels()
}

@MainActor
public final class ModelSessionManager: ModelSessionClosing {
    private var providers: [any LocalModelProvider] = []

    public init() {}

    public func register(_ provider: any LocalModelProvider) {
        providers.append(provider)
    }

    public func closeLoadedModels() {
        let providersToClose = providers
        providers.removeAll()
        Task {
            for provider in providersToClose {
                await provider.cancel()
                try? await provider.closeModel()
            }
        }
    }
}

private func normalizedPath(_ path: String) -> String {
    path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}
