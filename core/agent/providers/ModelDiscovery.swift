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

    public func completeStreaming(
        prompt: String,
        system: String?,
        format: ModelResponseFormat?,
        onDelta: @escaping @Sendable (StreamDelta) -> Void
    ) async throws -> String {
        activeTask?.cancel()

        let task = Task<String, Error> {
            try Task.checkCancellation()
            var payload = try self.chatPayload(prompt: prompt, system: system, format: format)
            payload["stream"] = true
            let body = try JSONSerialization.data(withJSONObject: payload)
            let bytes = try await lpOpenStreamingPOST(
                url: try self.endpointURL(path: self.endpointConfiguration.chatCompletionsPath),
                headers: self.headers(),
                body: body,
                timeoutSeconds: self.configuration.timeoutSeconds
            )
            // OpenAI-style SSE: `data: {chunk}` lines, terminated by `data: [DONE]`.
            var content = ""
            var reasoning = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payloadText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payloadText == "[DONE]" { break }
                guard let data = payloadText.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                      let delta = chunk.choices?.first?.delta else { continue }
                let c = delta.content ?? ""
                let r = delta.reasoningContent ?? delta.reasoning ?? ""
                if !c.isEmpty { content += c }
                if !r.isEmpty { reasoning += r }
                if !c.isEmpty || !r.isEmpty {
                    onDelta(StreamDelta(content: c, reasoning: r))
                }
            }
            return lpEmbedReasoning(content: content, reasoning: reasoning.isEmpty ? nil : reasoning)
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

    public func warmupAndRelease() async throws {
        // Load the model with a 1-token generation (so the test doesn't burn a
        // full response) and a short TTL so LM Studio auto-evicts the
        // JIT-loaded model right after. The OpenAI-compatible endpoint exposes
        // no explicit unload, so TTL is the supported eviction path.
        // ponytail: TTL only evicts models JIT-loaded via the API; a model
        // loaded by hand in LM Studio's UI won't auto-unload, and that's fine
        // for a connection test.
        var payload = try chatPayload(prompt: "ping", system: nil, format: nil)
        payload["max_tokens"] = 1
        payload["ttl"] = 1
        _ = try await postChatCompletion(payload: payload)
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
                    let reasoningContent: String?
                    let reasoning: String?

                    enum CodingKeys: String, CodingKey {
                        case content
                        case reasoningContent = "reasoning_content"
                        case reasoning
                    }
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
        if let choice = decoded.choices?.first, let content = choice.message?.content ?? choice.text {
            return lpEmbedReasoning(content: content, reasoning: choice.message?.reasoningContent ?? choice.message?.reasoning)
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

    /// One SSE chunk from a streamed OpenAI-compatible chat completion.
    private struct OpenAIStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoningContent: String?
                let reasoning: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case reasoning
                }
            }
            let delta: Delta?
        }
        let choices: [Choice]?
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

    public func completeStreaming(
        prompt: String,
        system: String?,
        format: ModelResponseFormat?,
        onDelta: @escaping @Sendable (StreamDelta) -> Void
    ) async throws -> String {
        activeTask?.cancel()

        let task = Task<String, Error> {
            try Task.checkCancellation()
            var payload = try self.chatPayload(prompt: prompt, system: system, format: format)
            payload["stream"] = true
            let body = try JSONSerialization.data(withJSONObject: payload)
            let bytes = try await lpOpenStreamingPOST(
                url: try self.endpointURL(path: self.endpointConfiguration.chatPath),
                headers: ["Content-Type": "application/json"],
                body: body,
                timeoutSeconds: self.configuration.timeoutSeconds
            )
            // Ollama streams NDJSON: one JSON object per line, `done:true` at the end.
            var content = ""
            var thinking = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(OllamaStreamChunk.self, from: data) else { continue }
                let c = chunk.message?.content ?? ""
                let t = chunk.message?.thinking ?? ""
                if !c.isEmpty { content += c }
                if !t.isEmpty { thinking += t }
                if !c.isEmpty || !t.isEmpty {
                    onDelta(StreamDelta(content: c, reasoning: t))
                }
                if chunk.done == true { break }
            }
            return lpEmbedReasoning(content: content, reasoning: thinking.isEmpty ? nil : thinking)
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

    public func warmupAndRelease() async throws {
        // Generate a single token to load the model, then evict it immediately
        // (keep_alive: 0) in the same request, so the test loads and unloads
        // without burning a full generation.
        var payload = try chatPayload(prompt: "ping", system: nil, format: nil)
        payload["options"] = ["temperature": configuration.temperature, "num_predict": 1]
        payload["keep_alive"] = 0
        _ = try await postChat(payload: payload)
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
                let thinking: String?
            }

            let message: Message?
            let response: String?
            let text: String?
            let content: String?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ModelProviderError.invalidResponse
        }
        if let content = decoded.message?.content {
            return lpEmbedReasoning(content: content, reasoning: decoded.message?.thinking)
        }
        if let content = decoded.response ?? decoded.text ?? decoded.content {
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

    /// One NDJSON frame from Ollama's streamed `/api/chat`.
    private struct OllamaStreamChunk: Decodable {
        struct Message: Decodable {
            let content: String?
            let thinking: String?
        }
        let message: Message?
        let done: Bool?
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
