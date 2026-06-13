import SwiftUI

struct ChatPanelView: View {
    @Bindable var controller: AgentController
    @Binding var taskText: String

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
            StatusPill(status: controller.runStatus)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask LocalPilot to do a task...", text: $taskText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(controller.runStatus == .running || controller.runStatus == .paused)

            Button {
                controller.start(task: taskText)
                taskText = ""
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.runStatus == .running || controller.runStatus == .paused)

            if controller.runStatus == .running {
                Button {
                    controller.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            }

            if controller.runStatus == .running || controller.runStatus == .paused {
                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
        }
        .padding(18)
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
