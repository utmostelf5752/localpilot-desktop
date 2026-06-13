import Foundation
import Testing
@testable import LocalPilotDesktop

actor MockHTTPClient: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    var responses: [HTTPResponse] = []

    func enqueue(_ response: HTTPResponse) {
        responses.append(response)
    }

    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if responses.isEmpty {
            return HTTPResponse(data: Data("{}".utf8), statusCode: 200)
        }
        return responses.removeFirst()
    }
}

actor StubManagedRuntime: ManagedModelRuntime {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let endpoint: URL

    init(endpoint: URL = URL(string: "http://127.0.0.1:49191")!) {
        self.endpoint = endpoint
    }

    func ensureRunning(configuration: ManagedModelRuntimeConfiguration) async throws -> URL {
        startCount += 1
        return endpoint
    }

    func stop() async {
        stopCount += 1
    }
}

/// HTTP client whose response can be released on demand, letting tests observe
/// in-flight cancellation without launching a real process or hitting the network.
actor BlockingHTTPClient: HTTPClient {
    private(set) var started = false
    private var continuation: CheckedContinuation<HTTPResponse, Error>?

    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.started = true
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.failWithCancellation() }
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release(_ response: HTTPResponse) {
        continuation?.resume(returning: response)
        continuation = nil
    }

    private func failWithCancellation() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private func makeConfig(timeoutSeconds: TimeInterval = 20) -> ModelProviderConfiguration {
    ModelProviderConfiguration(
        providerName: "managed-local",
        modelName: "planner.gguf",
        contextWindowSize: 8192,
        temperature: 0.1,
        timeoutSeconds: timeoutSeconds,
        supportsStreaming: false
    )
}

private func makeRuntimeConfig() -> ManagedModelRuntimeConfiguration {
    ManagedModelRuntimeConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/localpilot-model-runner"),
        modelURL: URL(fileURLWithPath: "/Models/planner.gguf"),
        host: "127.0.0.1",
        port: 49191,
        launchArguments: ["--model", "{model}", "--host", "{host}", "--port", "{port}"],
        environment: [:],
        healthPath: "/health",
        completionsPath: "/v1/localpilot/complete"
    )
}

struct ManagedLocalModelProviderTests {
    @Test
    func completeStartsManagedRuntimeAndRequestsJsonFromLocalEndpoint() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        await client.enqueue(HTTPResponse(data: Data(#"{"response":"{\"type\":\"wait\"}","done":true}"#.utf8), statusCode: 200))
        let config = ModelProviderConfiguration(
            providerName: "managed-local",
            modelName: "planner.gguf",
            contextWindowSize: 8192,
            temperature: 0.1,
            timeoutSeconds: 20,
            supportsStreaming: false
        )
        let runtimeConfig = ManagedModelRuntimeConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/localpilot-model-runner"),
            modelURL: URL(fileURLWithPath: "/Models/planner.gguf"),
            host: "127.0.0.1",
            port: 49191,
            launchArguments: ["--model", "{model}", "--host", "{host}", "--port", "{port}"],
            environment: [:],
            healthPath: "/health",
            completionsPath: "/v1/localpilot/complete"
        )
        let provider = ManagedLocalModelProvider(configuration: config, runtimeConfiguration: runtimeConfig, runtime: runtime, httpClient: client)

        _ = try await provider.complete(prompt: "Return JSON", system: "You are a planner.", format: .json)

        #expect(await runtime.startCount == 1)
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].url.path == "/v1/localpilot/complete")
        let body = try #require(requests[0].jsonBody)
        #expect(body["model"] as? String == "planner.gguf")
        #expect(body["format"] as? String == "json")
        #expect(body["prompt"] as? String == "Return JSON")
        #expect(body["system"] as? String == "You are a planner.")
    }

    @Test
    func closeModelStopsManagedRuntimeImmediately() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        let config = ModelProviderConfiguration(
            providerName: "managed-local",
            modelName: "planner.gguf",
            contextWindowSize: 8192,
            temperature: 0.1,
            timeoutSeconds: 20,
            supportsStreaming: false
        )
        let runtimeConfig = ManagedModelRuntimeConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/localpilot-model-runner"),
            modelURL: URL(fileURLWithPath: "/Models/planner.gguf"),
            host: "127.0.0.1",
            port: 49191,
            launchArguments: ["--model", "{model}", "--host", "{host}", "--port", "{port}"],
            environment: [:],
            healthPath: "/health",
            completionsPath: "/v1/localpilot/complete"
        )
        let provider = ManagedLocalModelProvider(configuration: config, runtimeConfiguration: runtimeConfig, runtime: runtime, httpClient: client)

        try await provider.closeModel()

        #expect(await runtime.stopCount == 1)
        #expect(await client.requests.isEmpty)
    }

    @Test
    func completeAppliesConfiguredTimeoutToCompletionRequest() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        await client.enqueue(HTTPResponse(data: Data(#"{"response":"ok"}"#.utf8), statusCode: 200))
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(timeoutSeconds: 42),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        _ = try await provider.complete(prompt: "hi", system: nil, format: nil)

        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].timeoutSeconds == 42)
    }

    @Test
    func healthCheckAppliesConfiguredTimeout() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        await client.enqueue(HTTPResponse(data: Data("{}".utf8), statusCode: 200))
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(timeoutSeconds: 17),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        try await provider.healthCheck()

        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].url.path == "/health")
        #expect(requests[0].timeoutSeconds == 17)
    }

    @Test
    func completeThrowsBadStatusWithBody() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        await client.enqueue(HTTPResponse(data: Data("upstream boom".utf8), statusCode: 503))
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        await #expect(throws: ModelProviderError.self) {
            _ = try await provider.complete(prompt: "hi", system: nil, format: nil)
        }
    }

    @Test
    func completeThrowsInvalidResponseWhenNoKnownField() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        await client.enqueue(HTTPResponse(data: Data(#"{"unexpected":"value"}"#.utf8), statusCode: 200))
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        await #expect(throws: ModelProviderError.self) {
            _ = try await provider.complete(prompt: "hi", system: nil, format: nil)
        }
    }

    @Test
    func completeDecodesContentField() async throws {
        let client = MockHTTPClient()
        let runtime = StubManagedRuntime()
        await client.enqueue(HTTPResponse(data: Data(#"{"content":"from-content"}"#.utf8), statusCode: 200))
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        let result = try await provider.complete(prompt: "hi", system: nil, format: nil)
        #expect(result == "from-content")
    }

    @Test
    func cancelStopsInFlightCompletion() async throws {
        let client = BlockingHTTPClient()
        let runtime = StubManagedRuntime()
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        let completion = Task<String, Error> {
            try await provider.complete(prompt: "hi", system: nil, format: nil)
        }
        await client.waitUntilStarted()

        await provider.cancel()

        await #expect(throws: Error.self) {
            _ = try await completion.value
        }
    }

    @Test
    func cancellingCallerTaskPropagatesToCompletion() async throws {
        let client = BlockingHTTPClient()
        let runtime = StubManagedRuntime()
        let provider = ManagedLocalModelProvider(
            configuration: makeConfig(),
            runtimeConfiguration: makeRuntimeConfig(),
            runtime: runtime,
            httpClient: client
        )

        let completion = Task<String, Error> {
            try await provider.complete(prompt: "hi", system: nil, format: nil)
        }
        await client.waitUntilStarted()

        // Cancelling the awaiting (structured) task must forward into the
        // spawned completion task so the in-flight request is abandoned.
        completion.cancel()

        await #expect(throws: Error.self) {
            _ = try await completion.value
        }
    }
}
