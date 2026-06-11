import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var runtimeExecutableURL: URL
    public var plannerModelURL: URL
    public var guardModelURL: URL
    public var runtimeHost: String
    public var runtimePort: Int
    public var runtimeLaunchArguments: [String]
    public var runtimeEnvironment: [String: String]
    public var runtimeHealthPath: String
    public var runtimeCompletionsPath: String
    public var plannerModel: String
    public var guardModel: String
    public var contextWindowSize: Int
    public var temperature: Double
    public var timeoutSeconds: TimeInterval
    public var unloadModelsAfterRun: Bool
    public var useGuardModel: Bool
    public var dryRunExecutionOnly: Bool
    public var allowedDomains: [String]
    public var allowedApps: [String]
    public var allowedFolders: [String]

    public static let defaultValue = AppSettings(
        runtimeExecutableURL: Self.defaultRuntimeExecutableURL(),
        plannerModelURL: Self.defaultModelDirectory().appending(path: "planner.gguf"),
        guardModelURL: Self.defaultModelDirectory().appending(path: "guard.gguf"),
        runtimeHost: "127.0.0.1",
        runtimePort: 49191,
        runtimeLaunchArguments: ["--model", "{model}", "--host", "{host}", "--port", "{port}"],
        runtimeEnvironment: [:],
        runtimeHealthPath: "/health",
        runtimeCompletionsPath: "/v1/localpilot/complete",
        plannerModel: "planner.gguf",
        guardModel: "guard.gguf",
        contextWindowSize: 8192,
        temperature: 0.1,
        timeoutSeconds: 60,
        unloadModelsAfterRun: true,
        useGuardModel: true,
        dryRunExecutionOnly: true,
        allowedDomains: [],
        allowedApps: [],
        allowedFolders: []
    )

    public func plannerConfiguration() -> ModelProviderConfiguration {
        ModelProviderConfiguration(
            providerName: "managed-local",
            modelName: plannerModel,
            contextWindowSize: contextWindowSize,
            temperature: temperature,
            timeoutSeconds: timeoutSeconds,
            supportsStreaming: false
        )
    }

    public func guardConfiguration() -> ModelProviderConfiguration {
        ModelProviderConfiguration(
            providerName: "managed-local",
            modelName: guardModel,
            contextWindowSize: contextWindowSize,
            temperature: 0,
            timeoutSeconds: timeoutSeconds,
            supportsStreaming: false
        )
    }

    public func plannerRuntimeConfiguration() -> ManagedModelRuntimeConfiguration {
        runtimeConfiguration(modelURL: plannerModelURL)
    }

    public func guardRuntimeConfiguration() -> ManagedModelRuntimeConfiguration {
        runtimeConfiguration(modelURL: guardModelURL)
    }

    private func runtimeConfiguration(modelURL: URL) -> ManagedModelRuntimeConfiguration {
        ManagedModelRuntimeConfiguration(
            executableURL: runtimeExecutableURL,
            modelURL: modelURL,
            host: runtimeHost,
            port: runtimePort,
            launchArguments: runtimeLaunchArguments,
            environment: runtimeEnvironment,
            healthPath: runtimeHealthPath,
            completionsPath: runtimeCompletionsPath
        )
    }

    public static func defaultRuntimeExecutableURL() -> URL {
        defaultSupportDirectory().appending(path: "bin/localpilot-model-runner")
    }

    public static func defaultModelDirectory() -> URL {
        defaultSupportDirectory().appending(path: "Models", directoryHint: .isDirectory)
    }

    static func defaultSupportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appending(path: "LocalPilot Desktop", directoryHint: .isDirectory)
    }
}

public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultSettingsURL()
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .defaultValue
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultSettingsURL() -> URL {
        AppSettings.defaultSupportDirectory()
            .appending(path: "settings.json")
    }
}
