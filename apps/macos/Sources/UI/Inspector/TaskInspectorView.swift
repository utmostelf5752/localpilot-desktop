import SwiftUI

/// Compact, dense, editable side panel for the New Task screen.
///
/// Replaces the older 300pt read-only inspector. This is intentionally narrow
/// (220pt) and shows only the few things worth glancing at while a task runs,
/// plus the handful of controls worth flipping quickly.
///
/// Editing `controller.settings` here applies to the *next* run, and is persisted
/// (see `.onChange` below) so the Settings screen and a relaunch stay in sync.
struct TaskInspectorView: View {
    @Bindable var controller: AgentController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Status")
            StatusRow(label: "Run",
                      value: controller.runStatus.rawValue,
                      valueColor: runColor)
            StatusRow(label: "Action", value: controller.currentActionLabel)

            Divider()

            SectionHeader("Model")
            // Provider + planner model on one dense line; truncate rather than wrap
            // so the panel keeps its fixed width.
            Text("\(controller.settings.modelProviderMode.displayName) · \(controller.settings.plannerModel)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            SectionHeader("Controls")

            // Approval mode: the single most useful thing to change on the fly.
            HStack {
                Text("Approval")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Approval", selection: $controller.settings.approvalMode) {
                    ForEach(ApprovalMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            Toggle("Dry-run", isOn: $controller.settings.dryRunExecutionOnly)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Guard model", isOn: $controller.settings.useGuardModel)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.small)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
        // Persist quick-control edits so they survive relaunch and the Settings
        // screen reflects them. Applies to the next run, not the in-flight one.
        .onChange(of: controller.settings) { _, _ in
            controller.saveSettings()
        }
    }

    /// Color cue for the run status value: active states read positive, halted
    /// states read as a warning, everything else stays muted.
    private var runColor: Color {
        switch controller.runStatus {
        case .running:
            return .green
        case .paused, .stopping:
            return .blue
        case .blocked, .stopped:
            return .red
        case .idle, .done:
            return .secondary // Color.secondary, the muted gray
        }
    }
}

/// Small uppercase-ish section header used between blocks.
private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

/// A dense label/value row: a small caption label on the left, the value pinned
/// to the right and allowed to take a tint color (used for run status).
private struct StatusRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
