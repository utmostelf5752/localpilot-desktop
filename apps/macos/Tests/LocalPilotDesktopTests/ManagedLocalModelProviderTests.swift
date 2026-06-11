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
}
