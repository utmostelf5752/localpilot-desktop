import SwiftUI

struct ChatPanelView: View {
    @Bindable var controller: AgentController
    @Binding var taskText: String

    private let liveActivityID = "live-activity"

    private var isActive: Bool {
        controller.runStatus == .running || controller.runStatus == .paused
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(controller.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                        if controller.isStreaming && controller.runStatus == .running {
                            LiveActivityCard(
                                label: controller.currentActionLabel,
                                reasoning: controller.liveReasoning,
                                tokens: controller.liveTokenCount
                            )
                            .id(liveActivityID)
                        }
                    }
                    .padding(24)
                }
                .onChange(of: controller.messages.count) { _, _ in
                    if let last = controller.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: controller.liveTokenCount) { _, _ in
                    proxy.scrollTo(liveActivityID, anchor: .bottom)
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LocalPilot Desktop")
                    .font(.title2.weight(.semibold))
                Text("Internal local model loop with guarded dry-run execution")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.newTask()
                taskText = ""
            } label: {
                Label("New task", systemImage: "square.and.pencil")
            }
            .disabled(controller.runStatus == .running || controller.runStatus == .paused)
            StatusPill(status: controller.runStatus)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var composer: some View {
        if isActive {
            activeControls
        } else {
            inputControls
        }
    }

    private var inputControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask LocalPilot to do a task...", text: $taskText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            Button {
                controller.start(task: taskText)
                taskText = ""
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
    }

    // While a task runs the composer becomes a live status line plus Pause/Resume
    // and Stop controls, mirroring agent mode.
    private var activeControls: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(controller.currentActionLabel)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)

            if controller.runStatus == .running {
                Button {
                    controller.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            } else {
                Button {
                    controller.continueTask(instruction: "")
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            Button(role: .destructive) {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(18)
    }
}

private struct LiveActivityCard: View {
    let label: String
    let reasoning: String
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if tokens > 0 {
                    Text("\(tokens) tokens")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !reasoning.isEmpty {
                ScrollView {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.3))
        )
    }
}

private struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: roleIcon)
                        .font(.caption2)
                    Text(roleLabel)
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                Text(message.text)
                    .textSelection(.enabled)
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(reasoning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if message.role != .user {
                Spacer(minLength: 80)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .agent: "LocalPilot"
        case .system: "System"
        }
    }

    private var roleIcon: String {
        switch message.role {
        case .user: "person.fill"
        case .agent: "sparkle"
        case .system: "info.circle"
        }
    }

    private var background: some ShapeStyle {
        switch message.role {
        case .user: Color.accentColor.opacity(0.16)
        case .agent: Color(nsColor: .controlBackgroundColor)
        case .system: Color.yellow.opacity(0.16)
        }
    }
}

private struct StatusPill: View {
    let status: AgentRunStatus

    var body: some View {
        Label(status.rawValue.capitalized, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var icon: String {
        switch status {
        case .idle: "circle"
        case .running: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .stopping: "hourglass"
        case .stopped: "stop.circle.fill"
        case .done: "checkmark.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch status {
        case .idle: .secondary
        case .running: .green
        case .paused: .orange
        case .stopping, .stopped: .red
        case .done: .blue
        case .blocked: .red
        }
    }
}
