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

public struct HTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
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
    private var process: Process?
    private var endpoint: URL?

    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func ensureRunning(configuration: ManagedModelRuntimeConfiguration) async throws -> URL {
        if let process, process.isRunning, let endpoint {
            return endpoint
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
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ModelProviderError.runtimeLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.endpoint = configuration.endpoint
        try await waitUntilHealthy(configuration: configuration)
        return configuration.endpoint
    }

    public func stop() {
        guard let process else {
            endpoint = nil
            return
        }
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    process.interrupt()
                }
            }
        }
        self.process = nil
        endpoint = nil
    }

    private func waitUntilHealthy(configuration: ManagedModelRuntimeConfiguration) async throws {
        let deadline = Date().addingTimeInterval(8)
        let healthURL = configuration.endpoint.appending(path: normalizedPath(configuration.healthPath))

        while Date() < deadline {
            do {
                let response = try await httpClient.data(for: HTTPRequest(url: healthURL, method: "GET"))
                if (200..<300).contains(response.statusCode) {
                    return
                }
            } catch {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
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
        let task = Task<String, Error> {
            let endpoint = try await runtime.ensureRunning(configuration: runtimeConfiguration)
            var payload: [String: Any] = [
                "model": configuration.modelName,
                "prompt": prompt,
                "stream": false,
                "options": [
                    "temperature": configuration.temperature
                ]
            ]
            if let system {
                payload["system"] = system
            }
            if format == .json {
                payload["format"] = "json"
            }

            let response = try await postCompletion(endpoint: endpoint, payload: payload)
            return try decodeCompletionResponse(response)
        }
        activeTask = task
        defer { activeTask = nil }
        return try await task.value
    }

    public func healthCheck() async throws {
        let endpoint = try await runtime.ensureRunning(configuration: runtimeConfiguration)
        let url = endpoint.appending(path: normalizedPath(runtimeConfiguration.healthPath))
        let response = try await httpClient.data(for: HTTPRequest(url: url, method: "GET"))
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
            body: body
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
        }

        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let response = decoded.response ?? decoded.text else {
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
