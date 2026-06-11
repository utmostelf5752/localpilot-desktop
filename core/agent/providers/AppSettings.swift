import Foundation

public enum ModelProviderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case internalInProcess = "internal_in_process"
    case managedRuntime = "managed_runtime"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .internalInProcess: "Internal in-process"
        case .managedRuntime: "Managed runtime"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var modelProviderMode: ModelProviderMode
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
        modelProviderMode: .internalInProcess,
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
            providerName: modelProviderMode.providerName,
            modelName: plannerModel,
            contextWindowSize: contextWindowSize,
            temperature: temperature,
            timeoutSeconds: timeoutSeconds,
            supportsStreaming: false
        )
    }

    public func guardConfiguration() -> ModelProviderConfiguration {
        ModelProviderConfiguration(
            providerName: modelProviderMode.providerName,
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

    private enum CodingKeys: String, CodingKey {
        case modelProviderMode
        case runtimeExecutableURL
        case plannerModelURL
        case guardModelURL
        case runtimeHost
        case runtimePort
        case runtimeLaunchArguments
        case runtimeEnvironment
        case runtimeHealthPath
        case runtimeCompletionsPath
        case plannerModel
        case guardModel
        case contextWindowSize
        case temperature
        case timeoutSeconds
        case unloadModelsAfterRun
        case useGuardModel
        case dryRunExecutionOnly
        case allowedDomains
        case allowedApps
        case allowedFolders
    }

    public init(
        modelProviderMode: ModelProviderMode,
        runtimeExecutableURL: URL,
        plannerModelURL: URL,
        guardModelURL: URL,
        runtimeHost: String,
        runtimePort: Int,
        runtimeLaunchArguments: [String],
        runtimeEnvironment: [String: String],
        runtimeHealthPath: String,
        runtimeCompletionsPath: String,
        plannerModel: String,
        guardModel: String,
        contextWindowSize: Int,
        temperature: Double,
        timeoutSeconds: TimeInterval,
        unloadModelsAfterRun: Bool,
        useGuardModel: Bool,
        dryRunExecutionOnly: Bool,
        allowedDomains: [String],
        allowedApps: [String],
        allowedFolders: [String]
    ) {
        self.modelProviderMode = modelProviderMode
        self.runtimeExecutableURL = runtimeExecutableURL
        self.plannerModelURL = plannerModelURL
        self.guardModelURL = guardModelURL
        self.runtimeHost = runtimeHost
        self.runtimePort = runtimePort
        self.runtimeLaunchArguments = runtimeLaunchArguments
        self.runtimeEnvironment = runtimeEnvironment
        self.runtimeHealthPath = runtimeHealthPath
        self.runtimeCompletionsPath = runtimeCompletionsPath
        self.plannerModel = plannerModel
        self.guardModel = guardModel
        self.contextWindowSize = contextWindowSize
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.unloadModelsAfterRun = unloadModelsAfterRun
        self.useGuardModel = useGuardModel
        self.dryRunExecutionOnly = dryRunExecutionOnly
        self.allowedDomains = allowedDomains
        self.allowedApps = allowedApps
        self.allowedFolders = allowedFolders
    }

    public init(from decoder: Decoder) throws {
        let defaults = Self.defaultValue
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelProviderMode = try container.decodeIfPresent(ModelProviderMode.self, forKey: .modelProviderMode) ?? defaults.modelProviderMode
        runtimeExecutableURL = try container.decodeIfPresent(URL.self, forKey: .runtimeExecutableURL) ?? defaults.runtimeExecutableURL
        plannerModelURL = try container.decodeIfPresent(URL.self, forKey: .plannerModelURL) ?? defaults.plannerModelURL
        guardModelURL = try container.decodeIfPresent(URL.self, forKey: .guardModelURL) ?? defaults.guardModelURL
        runtimeHost = try container.decodeIfPresent(String.self, forKey: .runtimeHost) ?? defaults.runtimeHost
        runtimePort = try container.decodeIfPresent(Int.self, forKey: .runtimePort) ?? defaults.runtimePort
        runtimeLaunchArguments = try container.decodeIfPresent([String].self, forKey: .runtimeLaunchArguments) ?? defaults.runtimeLaunchArguments
        runtimeEnvironment = try container.decodeIfPresent([String: String].self, forKey: .runtimeEnvironment) ?? defaults.runtimeEnvironment
        runtimeHealthPath = try container.decodeIfPresent(String.self, forKey: .runtimeHealthPath) ?? defaults.runtimeHealthPath
        runtimeCompletionsPath = try container.decodeIfPresent(String.self, forKey: .runtimeCompletionsPath) ?? defaults.runtimeCompletionsPath
        plannerModel = try container.decodeIfPresent(String.self, forKey: .plannerModel) ?? defaults.plannerModel
        guardModel = try container.decodeIfPresent(String.self, forKey: .guardModel) ?? defaults.guardModel
        contextWindowSize = try container.decodeIfPresent(Int.self, forKey: .contextWindowSize) ?? defaults.contextWindowSize
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        unloadModelsAfterRun = try container.decodeIfPresent(Bool.self, forKey: .unloadModelsAfterRun) ?? defaults.unloadModelsAfterRun
        useGuardModel = try container.decodeIfPresent(Bool.self, forKey: .useGuardModel) ?? defaults.useGuardModel
        dryRunExecutionOnly = try container.decodeIfPresent(Bool.self, forKey: .dryRunExecutionOnly) ?? defaults.dryRunExecutionOnly
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? defaults.allowedDomains
        allowedApps = try container.decodeIfPresent([String].self, forKey: .allowedApps) ?? defaults.allowedApps
        allowedFolders = try container.decodeIfPresent([String].self, forKey: .allowedFolders) ?? defaults.allowedFolders
    }
}

private extension ModelProviderMode {
    var providerName: String {
        switch self {
        case .internalInProcess: "internal-in-process"
        case .managedRuntime: "managed-local"
        }
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
