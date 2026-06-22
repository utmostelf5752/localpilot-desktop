import Foundation

// MARK: - Model discovery

/// HTTP model discovery for the Ollama and LM Studio local providers.
///
/// Ollama: `GET {ollamaBaseURL}/api/tags` → `{ models: [{ name }] }`.
/// LM Studio: `GET {lmStudioBaseURL}/v1/models` → `{ data: [{ id }] }`.
///
/// `HTTPRequest`/`HTTPResponse`/`HTTPClient`/`URLSessionHTTPClient` and
/// `ModelProviderError` already live in `ModelProvider.swift`; this file reuses
/// them rather than redefining them to avoid duplicate symbols.
public struct ModelDiscovery: Sendable {
    private let client: HTTPClient
    private let timeoutSeconds: TimeInterval

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
        self.timeoutSeconds = 10
    }

    /// Lists available model identifiers for the given provider mode. Modes that
    /// do not support HTTP discovery (internal / managed runtime) return `[]`.
    public func listModels(
        mode: ModelProviderMode,
        ollamaBaseURL: URL,
        lmStudioBaseURL: URL
    ) async throws -> [String] {
        switch mode {
        case .ollama:
            return try await listOllamaModels(baseURL: ollamaBaseURL)
        case .lmStudio:
            return try await listLMStudioModels(baseURL: lmStudioBaseURL)
        default:
            return []
        }
    }

    /// Best-effort native context length for a selected model, used to scale the
    /// context-window slider. Returns nil when the provider does not expose it or
    /// the server is unreachable.
    public func detectContextWindow(
        mode: ModelProviderMode,
        modelName: String,
        ollamaBaseURL: URL,
        lmStudioBaseURL: URL
    ) async -> Int? {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch mode {
        case .ollama:
            return try? await ollamaContextWindow(baseURL: ollamaBaseURL, model: trimmed)
        case .lmStudio:
            return try? await lmStudioContextWindow(baseURL: lmStudioBaseURL, model: trimmed)
        default:
            return nil
        }
    }

    private func ollamaContextWindow(baseURL: URL, model: String) async throws -> Int? {
        let url = try lpProviderEndpointURL(baseURL: baseURL, path: "/api/show")
        let body = try JSONSerialization.data(withJSONObject: ["name": model])
        let response = try await client.data(for: HTTPRequest(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeoutSeconds: timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else { return nil }
        // model_info holds arch-prefixed keys, e.g. "llama.context_length".
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let info = root["model_info"] as? [String: Any] else {
            return nil
        }
        for (key, value) in info where key.hasSuffix(".context_length") {
            if let n = (value as? NSNumber)?.intValue, n > 0 { return n }
        }
        return nil
    }

    private func lmStudioContextWindow(baseURL: URL, model: String) async throws -> Int? {
        // LM Studio's REST API (/api/v0/models) reports per-model context length.
        let url = try lpProviderEndpointURL(baseURL: baseURL, path: "/api/v0/models")
        let response = try await client.data(for: HTTPRequest(
            url: url,
            method: "GET",
            timeoutSeconds: timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            return nil
        }
        let match = models.first { ($0["id"] as? String) == model } ?? models.first
        for key in ["max_context_length", "loaded_context_length", "context_length"] {
            if let n = (match?[key] as? NSNumber)?.intValue, n > 0 { return n }
        }
        return nil
    }

    private func listOllamaModels(baseURL: URL) async throws -> [String] {
        let url = try lpProviderEndpointURL(baseURL: baseURL, path: "/api/tags")
        let response = try await client.data(for: HTTPRequest(
            url: url,
            method: "GET",
            timeoutSeconds: timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(data: response.data, encoding: .utf8) ?? "")
        }

        struct TagsResponse: Decodable {
            struct Model: Decodable {
                let name: String?
                let model: String?
            }

            let models: [Model]
        }

        guard let decoded = try? JSONDecoder().decode(TagsResponse.self, from: response.data) else {
            throw ModelProviderError.invalidResponse
        }
        return lpUniqueSorted(decoded.models.compactMap { $0.model ?? $0.name })
    }

    private func listLMStudioModels(baseURL: URL) async throws -> [String] {
        let url = try lpProviderEndpointURL(baseURL: baseURL, path: "/v1/models")
        let response = try await client.data(for: HTTPRequest(
            url: url,
            method: "GET",
            headers: ["Content-Type": "application/json"],
            timeoutSeconds: timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(data: response.data, encoding: .utf8) ?? "")
        }

        struct ModelsResponse: Decodable {
            struct Model: Decodable {
                let id: String?
                let name: String?
            }

            let data: [Model]?
            let models: [Model]?
        }

        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: response.data) else {
            throw ModelProviderError.invalidResponse
        }
        return lpUniqueSorted((decoded.data ?? decoded.models ?? []).compactMap { $0.id ?? $0.name })
    }
}

// MARK: - Endpoint configurations

/// Endpoint shape for an OpenAI-compatible chat-completions server (LM Studio,
/// llama.cpp server, etc.).
public struct OpenAICompatibleConfiguration: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var modelsPath: String
    public var chatCompletionsPath: String

    public init(
        baseURL: URL,
        apiKey: String = "",
        modelsPath: String = "/v1/models",
        chatCompletionsPath: String = "/v1/chat/completions"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelsPath = modelsPath
        self.chatCompletionsPath = chatCompletionsPath
    }
}

/// Endpoint shape for the native Ollama HTTP API.
public struct OllamaNativeConfiguration: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var tagsPath: String
    public var chatPath: String

    public init(
        baseURL: URL,
        tagsPath: String = "/api/tags",
        chatPath: String = "/api/chat"
    ) {
        self.baseURL = baseURL
        self.tagsPath = tagsPath
        self.chatPath = chatPath
    }
}

// MARK: - OpenAI-compatible chat provider (LM Studio)

/// `LocalModelProvider` over an OpenAI-compatible `/v1/chat/completions` server.
public actor OpenAICompatibleModelProvider: LocalModelProvider {
    public let configuration: ModelProviderConfiguration
    private let endpointConfiguration: OpenAICompatibleConfiguration
    private let httpClient: HTTPClient
    private var activeTask: Task<String, Error>?

    public init(
        configuration: ModelProviderConfiguration,
        endpointConfiguration: OpenAICompatibleConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.configuration = configuration
        self.endpointConfiguration = endpointConfiguration
        self.httpClient = httpClient
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        activeTask?.cancel()

        let task = Task<String, Error> {
            try Task.checkCancellation()
            let payload = try self.chatPayload(prompt: prompt, system: system, format: format)
            let response = try await self.postChatCompletion(payload: payload)
            try Task.checkCancellation()
            return try self.decodeChatCompletionResponse(response)
        }
        activeTask = task
        defer {
            if activeTask == task {
                activeTask = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func healthCheck() async throws {
        let url = try endpointURL(path: endpointConfiguration.modelsPath)
        let response = try await httpClient.data(for: HTTPRequest(
            url: url,
            method: "GET",
            headers: headers(),
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

    public func closeModel() async throws {}

    private func chatPayload(prompt: String, system: String?, format: ModelResponseFormat?) throws -> [String: Any] {
        var messages: [[String: String]] = []
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var payload: [String: Any] = [
            "model": configuration.modelName,
            "messages": messages,
            "temperature": configuration.temperature,
            "stream": false
        ]

        switch format {
        case .json:
            payload["response_format"] = ["type": "json_object"]
        case let .jsonSchema(name, schema):
            if let schemaObject = Self.schemaObject(from: schema) {
                payload["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": name,
                        "strict": true,
                        "schema": schemaObject
                    ]
                ]
            } else {
                payload["response_format"] = ["type": "json_object"]
            }
        case .none:
            break
        }

        return payload
    }

    private func postChatCompletion(payload: [String: Any]) async throws -> Data {
        let url = try endpointURL(path: endpointConfiguration.chatCompletionsPath)
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await httpClient.data(for: HTTPRequest(
            url: url,
            method: "POST",
            headers: headers(),
            body: body,
            timeoutSeconds: configuration.timeoutSeconds
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw ModelProviderError.badStatus(response.statusCode, String(data: response.data, encoding: .utf8) ?? "")
        }
        return response.data
    }

    private func decodeChatCompletionResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }

                let message: Message?
                let text: String?
            }

            let choices: [Choice]?
            let response: String?
            let text: String?
            let content: String?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ModelProviderError.invalidResponse
        }
        if let content = decoded.choices?.compactMap({ $0.message?.content ?? $0.text }).first {
            return content
        }
        if let response = decoded.response ?? decoded.text ?? decoded.content {
            return response
        }
        throw ModelProviderError.invalidResponse
    }

    private func endpointURL(path: String) throws -> URL {
        try lpProviderEndpointURL(baseURL: endpointConfiguration.baseURL, path: path)
    }

    private func headers() -> [String: String] {
        lpOpenAIHeaders(apiKey: endpointConfiguration.apiKey)
    }

    private static func schemaObject(from schema: String) -> [String: Any]? {
        guard let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

// MARK: - Ollama native chat provider

/// `LocalModelProvider` over the native Ollama `/api/chat` endpoint.
public actor OllamaNativeModelProvider: LocalModelProvider {
    public let configuration: ModelProviderConfiguration
    private let endpointConfiguration: OllamaNativeConfiguration
    private let httpClient: HTTPClient
    private var activeTask: Task<String, Error>?

    public init(
        configuration: ModelProviderConfiguration,
        endpointConfiguration: OllamaNativeConfiguration,
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.configuration = configuration
        self.endpointConfiguration = endpointConfiguration
        self.httpClient = httpClient
    }

    public func complete(prompt: String, system: String?, format: ModelResponseFormat?) async throws -> String {
        activeTask?.cancel()

        let task = Task<String, Error> {
            try Task.checkCancellation()
            let payload = try self.chatPayload(prompt: prompt, system: system, format: format)
            let response = try await self.postChat(payload: payload)
            try Task.checkCancellation()
            return try self.decodeChatResponse(response)
        }
        activeTask = task
        defer {
            if activeTask == task {
                activeTask = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func healthCheck() async throws {
        let response = try await httpClient.data(for: HTTPRequest(
            url: try endpointURL(path: endpointConfiguration.tagsPath),
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
        // Ask Ollama to evict the model from memory immediately (keep_alive: 0).
        guard let url = try? endpointURL(path: "/api/generate"),
              let body = try? JSONSerialization.data(withJSONObject: [
                "model": configuration.modelName,
                "keep_alive": 0
              ]) else { return }
        _ = try? await httpClient.data(for: HTTPRequest(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeoutSeconds: configuration.timeoutSeconds
        ))
    }

    private func chatPayload(prompt: String, system: String?, format: ModelResponseFormat?) throws -> [String: Any] {
        var messages: [[String: String]] = []
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var payload: [String: Any] = [
            "model": configuration.modelName,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": configuration.temperature
            ]
        ]

        switch format {
        case .json:
            payload["format"] = "json"
        case let .jsonSchema(_, schema):
            if let schemaObject = Self.schemaObject(from: schema) {
                payload["format"] = schemaObject
            } else {
                payload["format"] = "json"
            }
        case .none:
            break
        }

        return payload
    }

    private func postChat(payload: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await httpClient.data(for: HTTPRequest(
            url: try endpointURL(path: endpointConfiguration.chatPath),
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

    private func decodeChatResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
            let response: String?
            let text: String?
            let content: String?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ModelProviderError.invalidResponse
        }
        if let content = decoded.message?.content ?? decoded.response ?? decoded.text ?? decoded.content {
            return content
        }
        throw ModelProviderError.invalidResponse
    }

    private func endpointURL(path: String) throws -> URL {
        try lpProviderEndpointURL(baseURL: endpointConfiguration.baseURL, path: path)
    }

    private static func schemaObject(from schema: String) -> [String: Any]? {
        guard let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

// MARK: - Provider factories

/// Builds an Ollama native (`/api/chat`) provider for the given base URL.
public func makeOllamaProvider(
    configuration: ModelProviderConfiguration,
    baseURL: URL
) -> any LocalModelProvider {
    OllamaNativeModelProvider(
        configuration: configuration,
        endpointConfiguration: OllamaNativeConfiguration(baseURL: baseURL)
    )
}

/// Builds an LM Studio (OpenAI-compatible `/v1/chat/completions`) provider for
/// the given base URL.
public func makeLMStudioProvider(
    configuration: ModelProviderConfiguration,
    baseURL: URL
) -> any LocalModelProvider {
    OpenAICompatibleModelProvider(
        configuration: configuration,
        endpointConfiguration: OpenAICompatibleConfiguration(baseURL: baseURL)
    )
}

// MARK: - Private helpers

/// Joins a provider base URL with a path, de-duplicating an overlapping
/// trailing/leading path component so `http://host/v1` + `/v1/models` does not
/// become `http://host/v1/v1/models`.
private func lpProviderEndpointURL(baseURL: URL, path: String) throws -> URL {
    let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let baseLastComponent = baseURL.pathComponents.last?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let pathFirstComponent = path.split(separator: "/").first.map(String.init)
    if let baseLastComponent, let pathFirstComponent, baseLastComponent == pathFirstComponent {
        path = path.split(separator: "/").dropFirst().joined(separator: "/")
    }

    guard !base.isEmpty, !path.isEmpty, let url = URL(string: "\(base)/\(path)") else {
        throw ModelProviderError.invalidResponse
    }
    return url
}

private func lpOpenAIHeaders(apiKey: String) -> [String: String] {
    var values = ["Content-Type": "application/json"]
    let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apiKey.isEmpty {
        values["Authorization"] = "Bearer \(apiKey)"
    }
    return values
}

private func lpUniqueSorted(_ names: [String]) -> [String] {
    let cleaned = names
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return Array(Set(cleaned)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}
