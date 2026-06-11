import SwiftUI

struct MainWindowView: View {
    @Bindable var controller: AgentController
    @State private var selectedSection: SidebarSection = .newTask
    @State private var taskText = ""
    @State private var continueInstruction = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedSection)
        } detail: {
            switch selectedSection {
            case .newTask, .pastTasks:
                HStack(spacing: 0) {
                    ChatPanelView(controller: controller, taskText: $taskText)
                    Divider()
                    InspectorPanelView(controller: controller)
                }
            case .settings:
                SettingsPanelView(controller: controller)
            case .permissions:
                PermissionsPanelView()
            case .logs:
                LogsPanelView(controller: controller)
            }
        }
        .onAppear {
            OverlayWindowManager.shared.configure(controller: controller)
        }
        .onChange(of: controller.overlayState) { _, state in
            OverlayWindowManager.shared.setVisible(state != .idle, controller: controller)
        }
        .sheet(isPresented: Binding(
            get: { controller.runStatus == .paused && controller.pendingApproval == nil },
            set: { _ in }
        )) {
            PauseSheetView(
                instruction: $continueInstruction,
                continueAction: {
                    controller.continueTask(instruction: continueInstruction)
                    continueInstruction = ""
                },
                stopAction: {
                    controller.stop()
                    continueInstruction = ""
                }
            )
        }
        .sheet(item: Binding(
            get: { controller.pendingApproval },
            set: { _ in }
        )) { approval in
            ApprovalReviewSheet(
                approval: approval,
                allowAction: controller.approvePendingAction,
                denyAction: controller.denyPendingAction
            )
        }
    }
}

private enum SidebarSection: String, CaseIterable, Identifiable {
    case newTask = "New task"
    case pastTasks = "Past tasks"
    case settings = "Settings"
    case permissions = "Permissions"
    case logs = "Logs"

    var id: String { rawValue }
}

private struct SidebarView: View {
    @Binding var selection: SidebarSection

    var body: some View {
        List(SidebarSection.allCases, selection: $selection) { section in
            Label(section.rawValue, systemImage: icon(for: section))
                .tag(section)
        }
        .navigationTitle("LocalPilot")
        .listStyle(.sidebar)
    }

    private func icon(for section: SidebarSection) -> String {
        switch section {
        case .newTask: "plus.message"
        case .pastTasks: "clock"
        case .settings: "gearshape"
        case .permissions: "lock.shield"
        case .logs: "doc.text.magnifyingglass"
        }
    }
}

private struct InspectorPanelView: View {
    let controller: AgentController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("State")
                .font(.headline)

            StatusRow(label: "Run", value: controller.runStatus.rawValue)
            StatusRow(label: "Overlay", value: controller.overlayState.rawValue)
            StatusRow(label: "Executor", value: controller.executorEnabled ? "enabled" : "disabled")
            StatusRow(label: "Action", value: controller.currentActionLabel)
            StatusRow(label: "Runtime", value: controller.providerStatus)

            Divider()

            Text("Scope")
                .font(.headline)
            StatusRow(label: "Domains", value: controller.state.allowedDomains.isEmpty ? "none" : controller.state.allowedDomains.joined(separator: ", "))
            StatusRow(label: "Apps", value: controller.state.allowedApps.isEmpty ? "none" : controller.state.allowedApps.joined(separator: ", "))
            StatusRow(label: "Folders", value: controller.state.allowedFolders.isEmpty ? "none" : controller.state.allowedFolders.joined(separator: ", "))

            Divider()

            Text("Recent logs")
                .font(.headline)
            ForEach(controller.recentLogSnippets, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(controller.logFileURL.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(width: 300)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SettingsPanelView: View {
    @Bindable var controller: AgentController

    var body: some View {
        Form {
            Section("Managed Local Runtime") {
                TextField("Runtime executable", text: urlBinding(\.runtimeExecutableURL))
                TextField("Planner model file", text: urlBinding(\.plannerModelURL))
                TextField("Guard model file", text: urlBinding(\.guardModelURL))
                TextField("Planner model", text: $controller.settings.plannerModel)
                TextField("Guard model", text: $controller.settings.guardModel)
                TextField("Host", text: $controller.settings.runtimeHost)
                Stepper("Port: \(controller.settings.runtimePort)", value: $controller.settings.runtimePort, in: 1024...65535, step: 1)
                TextField("Launch arguments", text: stringListBinding(\.runtimeLaunchArguments))
                TextField("Health path", text: $controller.settings.runtimeHealthPath)
                TextField("Completion path", text: $controller.settings.runtimeCompletionsPath)
                Toggle("Unload models after each run", isOn: $controller.settings.unloadModelsAfterRun)
                Toggle("Use guard model", isOn: $controller.settings.useGuardModel)
                Toggle("Dry-run execution only", isOn: $controller.settings.dryRunExecutionOnly)
                HStack {
                    Button("Test Connection") {
                        controller.testModelRuntimeConnection()
                    }
                    Button("Save Settings") {
                        controller.saveSettings()
                    }
                    Spacer()
                    Text(controller.settingsStatus)
                        .foregroundStyle(.secondary)
                }
                Text(controller.providerStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model Options") {
                Stepper("Context window: \(controller.settings.contextWindowSize)", value: $controller.settings.contextWindowSize, in: 1024...262144, step: 1024)
                HStack {
                    Text("Temperature")
                    Slider(value: $controller.settings.temperature, in: 0...1)
                    Text(controller.settings.temperature, format: .number.precision(.fractionLength(2)))
                        .frame(width: 44, alignment: .trailing)
                }
                Stepper("Timeout: \(Int(controller.settings.timeoutSeconds))s", value: $controller.settings.timeoutSeconds, in: 5...600, step: 5)
            }

            Section("Task Scope") {
                TextField("Allowed domains, comma separated", text: listBinding(\.allowedDomains))
                TextField("Allowed apps, comma separated", text: listBinding(\.allowedApps))
                TextField("Allowed folders, comma separated", text: listBinding(\.allowedFolders))
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
    }

    private func urlBinding(_ keyPath: WritableKeyPath<AppSettings, URL>) -> Binding<String> {
        Binding(
            get: { controller.settings[keyPath: keyPath].path },
            set: { value in
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    controller.settings[keyPath: keyPath] = URL(fileURLWithPath: value)
                }
            }
        )
    }

    private func stringListBinding(_ keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(
            get: { controller.settings[keyPath: keyPath].joined(separator: " ") },
            set: { value in
                controller.settings[keyPath: keyPath] = value
                    .split(separator: " ")
                    .map(String.init)
            }
        )
    }

    private func listBinding(_ keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(
            get: { controller.settings[keyPath: keyPath].joined(separator: ", ") },
            set: { value in
                controller.settings[keyPath: keyPath] = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

private struct PermissionsPanelView: View {
    private let rows: [PermissionSummary] = [
        PermissionSummary(permission: .screenRecording, requiredFor: "Future screen observation through ScreenCaptureKit.", milestone: "Milestone 4"),
        PermissionSummary(permission: .accessibility, requiredFor: "Future AXUIElement semantic UI observation and controlled interaction.", milestone: "Milestone 4"),
        PermissionSummary(permission: .inputMonitoring, requiredFor: "Future keyboard/mouse event execution through Quartz where required.", milestone: "Milestone 8+"),
        PermissionSummary(permission: .automation, requiredFor: "Future narrow app-specific automation scopes.", milestone: "Milestone 8+")
    ]

    var body: some View {
        List(rows, id: \.permission.rawValue) { row in
            VStack(alignment: .leading, spacing: 6) {
                Text(row.permission.rawValue)
                    .font(.headline)
                Text(row.requiredFor)
                    .foregroundStyle(.secondary)
                Text(row.milestone)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Permissions")
    }
}

private struct LogsPanelView: View {
    let controller: AgentController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local Logs")
                .font(.title2.weight(.semibold))
            Text(controller.logFileURL.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Divider()
            ForEach(controller.recentLogSnippets, id: \.self) { item in
                Text(item)
                    .font(.body)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Logs")
    }
}

private struct ApprovalReviewSheet: View {
    let approval: PendingApproval
    let allowAction: () -> Void
    let denyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approval Required")
                .font(.title2.weight(.semibold))
            Text(approval.reason)
                .foregroundStyle(.secondary)
            Divider()
            StatusRow(label: "Action", value: approval.action.type.rawValue)
            StatusRow(label: "Target", value: approval.action.targetText)
            StatusRow(label: "Risk", value: approval.action.riskLevel.rawValue)
            if let text = approval.action.text {
                StatusRow(label: "Text", value: text)
            }
            if let command = approval.action.command {
                StatusRow(label: "Command", value: command)
            }
            StatusRow(label: "Expected", value: approval.action.expectedResult)
            HStack {
                Button("Deny", role: .destructive, action: denyAction)
                Spacer()
                Button("Allow Once", action: allowAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}

private struct PauseSheetView: View {
    @Binding var instruction: String
    let continueAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paused")
                .font(.title2.weight(.semibold))
            Text("Add an optional instruction before LocalPilot resumes the fake task.")
                .foregroundStyle(.secondary)
            TextField("Optional instruction", text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
            HStack {
                Button("Stop", role: .destructive, action: stopAction)
                Spacer()
                Button("Continue", action: continueAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
