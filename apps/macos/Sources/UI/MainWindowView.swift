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
            case .newTask:
                HStack(spacing: 0) {
                    ChatPanelView(controller: controller, taskText: $taskText)
                    Divider()
                    TaskInspectorView(controller: controller)
                }
            case .pastTasks:
                TasksView(controller: controller)
            case .settings:
                SettingsView(controller: controller)
            }
        }
        .onAppear {
            OverlayWindowManager.shared.configure(controller: controller)
            // Reconcile overlay visibility on first appearance too, in case the
            // controller is already in a non-idle state when the window opens
            // (e.g. after a restored session). `onChange` alone would miss this.
            OverlayWindowManager.shared.setVisible(shouldShowOverlay, controller: controller)
        }
        .onChange(of: controller.overlayState) { _, _ in
            OverlayWindowManager.shared.setVisible(shouldShowOverlay, controller: controller)
        }
        // The approval sheet is hosted by the *main* window. The overlay window
        // sits at `.screenSaver` level and covers the entire screen, so while it
        // is visible it would obscure (and block clicks to) that sheet. When an
        // approval is pending we therefore hide the overlay so the user can
        // actually reach the Allow/Deny controls. The floating controls already
        // direct the user to the main window for approvals, so nothing in the
        // overlay is lost by hiding it during this window.
        .onChange(of: controller.pendingApproval) { _, _ in
            OverlayWindowManager.shared.setVisible(shouldShowOverlay, controller: controller)
        }
        // A single sheet driven by a derived enum. Presenting two separate
        // `.sheet` modifiers on the same view is unreliable in SwiftUI (the
        // second may silently fail to present, or the first may dismiss the
        // second). An approval request always takes precedence over the plain
        // pause sheet, because `requestApproval` sets both `runStatus == .paused`
        // and a non-nil `pendingApproval` at the same time.
        .sheet(item: Binding(
            get: { activeSheet },
            set: { _ in }
        )) { sheet in
            switch sheet {
            case .approval(let approval):
                ApprovalReviewSheet(
                    approval: approval,
                    allowAction: controller.approvePendingAction,
                    denyAction: controller.denyPendingAction
                )
            case .pause:
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
        }
    }

    /// The overlay should be visible whenever the agent is in a non-idle overlay
    /// state, EXCEPT while an approval is pending: in that case the main-window
    /// approval sheet must be reachable, and the full-screen overlay would cover
    /// it. Hiding the overlay here is what lets the Allow/Deny buttons be clicked.
    private var shouldShowOverlay: Bool {
        guard controller.pendingApproval == nil else { return false }
        return controller.overlayState != .idle
    }

    /// Derives which modal (if any) should be presented from the controller's
    /// observable state. Approval wins over the pause sheet so the two can never
    /// fight to present simultaneously.
    private var activeSheet: ActiveSheet? {
        if let approval = controller.pendingApproval {
            return .approval(approval)
        }
        if controller.runStatus == .paused {
            return .pause
        }
        return nil
    }
}

private enum ActiveSheet: Identifiable {
    case pause
    case approval(PendingApproval)

    var id: String {
        switch self {
        case .pause: "pause"
        case .approval(let approval): "approval-\(approval.id.uuidString)"
        }
    }
}

private enum SidebarSection: String, CaseIterable, Identifiable {
    case newTask = "New task"
    case pastTasks = "Past tasks"
    case settings = "Settings"

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
        }
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
