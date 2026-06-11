import Foundation
import Testing
@testable import LocalPilotDesktop

struct SettingsStoreTests {
    @Test
    func settingsRoundTripPersistsManagedRuntimeConfiguration() throws {
        let fileURL = URL.temporaryDirectory.appending(path: "localpilot-settings-\(UUID().uuidString).json")
        let store = SettingsStore(fileURL: fileURL)
        var settings = AppSettings.defaultValue
        settings.runtimeExecutableURL = URL(fileURLWithPath: "/usr/local/bin/localpilot-model-runner")
        settings.plannerModelURL = URL(fileURLWithPath: "/Models/planner.gguf")
        settings.guardModelURL = URL(fileURLWithPath: "/Models/guard.gguf")
        settings.runtimePort = 49191
        settings.plannerModel = "planner.gguf"
        settings.guardModel = "guard.gguf"
        settings.unloadModelsAfterRun = true

        try store.save(settings)
        let loaded = try store.load()

        #expect(loaded.runtimeExecutableURL.path == "/usr/local/bin/localpilot-model-runner")
        #expect(loaded.plannerModelURL.path == "/Models/planner.gguf")
        #expect(loaded.guardModelURL.path == "/Models/guard.gguf")
        #expect(loaded.runtimePort == 49191)
        #expect(loaded.plannerModel == "planner.gguf")
        #expect(loaded.guardModel == "guard.gguf")
        #expect(loaded.unloadModelsAfterRun == true)
    }
}
