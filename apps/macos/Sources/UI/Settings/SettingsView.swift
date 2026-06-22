import AppKit
import SwiftUI

/// Redesigned Settings screen. Holds a working `draft` copy of `AppSettings`;
/// nothing is applied to the controller until the user hits "Save Settings".
struct SettingsView: View {
    @Bindable var controller: AgentController

    // Working copy. Seeded once from controller.settings in onAppear so that
    // edits are local until an explicit Save. `loaded` guards the one-time seed.
    @State private var draft: AppSettings = .defaultValue

    // Model discovery state.
    @State private var models: [String] = []
    @State private var discoveryState: DiscoveryState = .ok
    @State private var detectedContext: Int?

    // Distinguishes an unreachable server from a reachable one that simply has
    // no models, so the UI stops reporting a running Ollama/LM Studio as "not
    // detected" when the real problem is an empty model list.
    private enum DiscoveryState { case ok, unreachable, empty }

    // Permission rows are informational/read-only.
    private let permissionRows: [PermissionSummary] = [
        PermissionSummary(permission: .screenRecording, requiredFor: "Screen observation through ScreenCaptureKit.", milestone: "Milestone 4"),
        PermissionSummary(permission: .accessibility, requiredFor: "AXUIElement semantic UI observation and controlled interaction.", milestone: "Milestone 4"),
        PermissionSummary(permission: .inputMonitoring, requiredFor: "Keyboard/mouse event execution through Quartz where required.", milestone: "Milestone 8+"),
        PermissionSummary(permission: .automation, requiredFor: "Narrow app-specific automation scopes.", milestone: "Milestone 8+")
    ]

    var body: some View {
        Form {
            modelSection
            behaviorSection
            performanceSection
            permissionsSection
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save Settings") {
                    controller.settings = draft
                    controller.saveSettings()
                }
                .disabled(draft == controller.settings)
            }
        }
        .onAppear {
            // Re-seed from the controller every appearance so quick edits made in
            // the inspector panel are reflected here. Settings and the inspector
            // are never on screen at once (separate sidebar tabs), so this can't
            // clobber edits being made elsewhere.
            draft = controller.settings
            refreshDiscovery()
            refreshDetectedContext()
        }
        .onChange(of: draft.modelProviderMode) { _, _ in
            refreshDiscovery()
            refreshDetectedContext(snapToNative: true)
        }
        .onChange(of: draft.ollamaBaseURL) { _, _ in refreshDiscovery() }
        .onChange(of: draft.lmStudioBaseURL) { _, _ in refreshDiscovery() }
        .onChange(of: draft.plannerModel) { _, _ in refreshDetectedContext(snapToNative: true) }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        Section("Model") {
            Picker("Provider", selection: $draft.modelProviderMode) {
                ForEach(ModelProviderMode.selectableCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch draft.modelProviderMode {
            case .apiProvider:
                TextField("API base URL", text: urlBinding(\.apiBaseURL))
                    .textFieldStyle(.roundedBorder)
                SecureField("API key", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)
            case .ollama:
                TextField("Ollama base URL", text: urlBinding(\.ollamaBaseURL))
                    .textFieldStyle(.roundedBorder)
                discoveryArea(
                    notRunning: "Ollama not detected — make sure the Ollama app is running, then Recheck.",
                    noModels: "Ollama is running but has no models. Pull one first, e.g. `ollama pull llama3.2`, then Recheck."
                )
            case .lmStudio:
                TextField("LM Studio base URL", text: urlBinding(\.lmStudioBaseURL))
                    .textFieldStyle(.roundedBorder)
                discoveryArea(
                    notRunning: "LM Studio not detected — open LM Studio and start its local server (Developer tab → Start Server), then Recheck.",
                    noModels: "LM Studio server is running but no model is loaded. Load a model in LM Studio, then Recheck."
                )
            default:
                EmptyView()
            }

            Toggle("Use guard model", isOn: $draft.useGuardModel)

            HStack {
                Button("Test Connection") {
                    controller.testModelRuntimeConnection(using: draft)
                }
                Spacer()
                Text(controller.providerStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func discoveryArea(notRunning: String, noModels: String) -> some View {
        // Planner model picker.
        Picker("Planner model", selection: $draft.plannerModel) {
            ForEach(modelOptions(including: draft.plannerModel), id: \.self) { name in
                Text(name).tag(name)
            }
        }

        // Guard model picker, disabled and greyed when guard model is off.
        Picker("Guard model", selection: $draft.guardModel) {
            ForEach(modelOptions(including: draft.guardModel), id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .disabled(!draft.useGuardModel)
        .foregroundStyle(draft.useGuardModel ? .primary : .secondary)

        HStack {
            Button("Recheck") { refreshDiscovery() }
            switch discoveryState {
            case .unreachable:
                Text(notRunning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .empty:
                Text(noModels)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ok:
                EmptyView()
            }
        }
    }

    /// Available model names plus the currently-selected value if it's not in the
    /// discovered list, so the Picker always has a tag matching the binding.
    private func modelOptions(including current: String) -> [String] {
        var options = models
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !options.contains(trimmed) {
            options.insert(trimmed, at: 0)
        }
        return options
    }

    // MARK: - Behavior

    @ViewBuilder
    private var behaviorSection: some View {
        Section("Behavior") {
            Picker("Approval mode", selection: $draft.approvalMode) {
                ForEach(ApprovalMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(approvalModeCaption(draft.approvalMode))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Dry-run execution only", isOn: $draft.dryRunExecutionOnly)
        }
    }

    private func approvalModeCaption(_ mode: ApprovalMode) -> String {
        switch mode {
        case .accept: "Accept each: pause before every action."
        case .risky: "Risky only: pause only on risky actions."
        case .yolo: "YOLO: never pause; only hard blocks stop it."
        }
    }

    // MARK: - Performance

    @ViewBuilder
    private var performanceSection: some View {
        Section("Performance") {
            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: contextWindowBinding,
                    // max(1024, …): a detected native window below 1024 would make
                    // the lower bound exceed the upper bound and crash the Slider.
                    in: 1024...Double(max(1024, contextUpperBound)),
                    step: 1024
                )
                Text(contextWindowLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $draft.temperature, in: 0...1)
                Text(String(format: "Temperature: %.2f", draft.temperature))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Stepper(
                "Timeout: \(Int(draft.timeoutSeconds))s",
                value: $draft.timeoutSeconds,
                in: 5...600,
                step: 5
            )

            Toggle("Unload models after each run", isOn: $draft.unloadModelsAfterRun)
            Toggle("Structured decoding", isOn: $draft.useStructuredDecoding)
        }
    }

    private var contextUpperBound: Int {
        detectedContext ?? AppSettings.maximumContextWindowSize
    }

    private var contextWindowBinding: Binding<Double> {
        Binding(
            get: { Double(draft.contextWindowSize) },
            set: { draft.contextWindowSize = Int($0) }
        )
    }

    private var contextWindowLabel: String {
        let tokens = draft.contextWindowSize.formatted()
        if let native = detectedContext, native > 0 {
            let percent = Int((Double(draft.contextWindowSize) / Double(native) * 100).rounded())
            return "\(tokens) tokens (\(percent)% of \(native.formatted()) native)"
        }
        return "\(tokens) tokens"
    }

    // MARK: - Permissions & Scope

    @ViewBuilder
    private var permissionsSection: some View {
        Section("Permissions & Scope") {
            Text("Limit what the agent may touch. Empty means no restriction.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Allowed domains, comma separated", text: listBinding(\.allowedDomains))
                .textFieldStyle(.roundedBorder)
            TextField("Allowed apps, comma separated", text: listBinding(\.allowedApps))
                .textFieldStyle(.roundedBorder)
            TextField("Allowed folders, comma separated", text: listBinding(\.allowedFolders))
                .textFieldStyle(.roundedBorder)

            ForEach(permissionRows, id: \.permission.rawValue) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.permission.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Text(row.requiredFor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let url = row.permission.systemSettingsURL {
                        Button("Open Settings") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Discovery

    private func refreshDiscovery() {
        guard draft.modelProviderMode.supportsModelDiscovery else {
            models = []
            discoveryState = .ok
            return
        }
        let mode = draft.modelProviderMode
        let ollama = draft.ollamaBaseURL
        let lmStudio = draft.lmStudioBaseURL
        Task {
            do {
                let found = try await ModelDiscovery().listModels(
                    mode: mode,
                    ollamaBaseURL: ollama,
                    lmStudioBaseURL: lmStudio
                )
                models = found
                discoveryState = found.isEmpty ? .empty : .ok
                // Replace a stale/placeholder selection (e.g. the "planner.gguf"
                // default) with a real discovered model, so the picker shows an
                // actual model instead of a name the server doesn't have.
                if let first = found.first {
                    if !found.contains(draft.plannerModel) { draft.plannerModel = first }
                    if !found.contains(draft.guardModel) { draft.guardModel = first }
                }
            } catch {
                models = []
                discoveryState = .unreachable
            }
        }
    }

    /// Detects the selected model's native context window and updates the budget.
    /// - `snapToNative: true` (model/provider changed): set the budget to the new
    ///   model's full window so the "tokens" value tracks the chosen model.
    /// - `snapToNative: false` (settings just opened): only clamp down, so a
    ///   smaller budget the user saved earlier is preserved.
    private func refreshDetectedContext(snapToNative: Bool = false) {
        guard draft.modelProviderMode.supportsModelDiscovery else {
            detectedContext = nil
            return
        }
        let mode = draft.modelProviderMode
        let model = draft.plannerModel
        let ollama = draft.ollamaBaseURL
        let lmStudio = draft.lmStudioBaseURL
        Task {
            let native = await ModelDiscovery().detectContextWindow(
                mode: mode,
                modelName: model,
                ollamaBaseURL: ollama,
                lmStudioBaseURL: lmStudio
            )
            detectedContext = native
            if let native {
                draft.contextWindowSize = snapToNative
                    ? native
                    : min(draft.contextWindowSize, native)
            }
        }
    }

    // MARK: - Binding helpers

    /// Two-way bridge between a `URL` field and a text field's `String`.
    private func urlBinding(_ keyPath: WritableKeyPath<AppSettings, URL>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath].absoluteString },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), !trimmed.isEmpty {
                    draft[keyPath: keyPath] = url
                }
            }
        )
    }

    /// Two-way bridge between a `[String]` field and a comma-separated text field.
    private func listBinding(_ keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath].joined(separator: ", ") },
            set: { newValue in
                draft[keyPath: keyPath] = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
