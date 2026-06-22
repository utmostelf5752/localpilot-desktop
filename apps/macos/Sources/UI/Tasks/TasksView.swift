import SwiftUI
import AppKit

/// "Past tasks" screen: a master-detail browser over persisted task sessions.
///
/// The left column is a searchable list of active (non-archived) sessions,
/// pinned first then newest. Selecting a session reveals its full record on the
/// right: either the per-turn conversation (text + the screenshot captured at
/// that moment) or a chronological activity log of what the model did. The data
/// is rendered straight from `controller.taskSessionStore`, which the running
/// agent updates live, so no separate live wiring is needed here.
struct TasksView: View {
    @Bindable var controller: AgentController

    @State private var selectedID: TaskSession.ID?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle("Tasks")
        } detail: {
            detail
        }
    }

    // MARK: - Master list

    private var sessionList: some View {
        Group {
            if controller.taskSessionStore.active.isEmpty {
                ContentUnavailableView(
                    "No past tasks yet.",
                    systemImage: "clock",
                    description: Text("Run a task and it will show up here.")
                )
            } else if filteredSessions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredSessions, selection: $selectedID) { session in
                    TaskRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin") {
                                controller.taskSessionStore.setPinned(session.id, !session.isPinned)
                            }
                            Button("Archive", systemImage: "archivebox") {
                                controller.taskSessionStore.archive(session.id)
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                if selectedID == session.id { selectedID = nil }
                                controller.taskSessionStore.delete(session.id)
                            }
                        }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search tasks")
        .frame(minWidth: 260)
    }

    /// Active sessions filtered by the search field. The store already returns
    /// `active` newest-first, so we only need to float pinned rows to the top
    /// while preserving that order within each group.
    private var filteredSessions: [TaskSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = controller.taskSessionStore.active.filter { session in
            guard !query.isEmpty else { return true }
            return session.displayTitle.localizedCaseInsensitiveContains(query)
                || session.originalTask.localizedCaseInsensitiveContains(query)
        }
        let pinned = base.filter(\.isPinned)
        let rest = base.filter { !$0.isPinned }
        return pinned + rest
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID,
           let session = controller.taskSessionStore.sessions.first(where: { $0.id == id }) {
            TaskDetailView(session: session)
                .id(session.id)
        } else {
            ContentUnavailableView(
                "Select a task to view its history.",
                systemImage: "sidebar.left"
            )
        }
    }
}

// MARK: - Row

private struct TaskRow: View {
    let session: TaskSession

    var body: some View {
        HStack(spacing: 8) {
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(rowTitle(for: session))
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusChip(status: session.status)
                    Text(shortDate(session.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail body

private struct TaskDetailView: View {
    let session: TaskSession

    private enum Mode: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case activity = "Activity"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch mode {
            case .conversation: conversation
            case .activity: activity
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(rowTitle(for: session))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rowTitle(for: session))
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 8) {
                StatusChip(status: session.status)
                Text(fullDate(session.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        if session.messages.isEmpty {
            ContentUnavailableView(
                "No messages recorded.",
                systemImage: "bubble.left.and.bubble.right"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messages) { message in
                        MessageView(message: message)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activity: some View {
        if session.events.isEmpty {
            ContentUnavailableView(
                "No activity recorded.",
                systemImage: "list.bullet.rectangle"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.events.enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                        Divider()
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Message

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)
                Text(shortTime(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let path = message.screenshotPath,
               FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .cornerRadius(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .agent: "Agent"
        case .system: "System"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user: .blue
        case .agent: .primary
        case .system: .secondary
        }
    }
}

// MARK: - Event row

private struct EventRow: View {
    let event: LocalEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(shortTime(event.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(humanizeEvent(event.event))
                    .font(.callout.weight(.medium))
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Status chip

private struct StatusChip: View {
    let status: AgentRunStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .idle: "Idle"
        case .running: "Running"
        case .paused: "Paused"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }

    private var color: Color {
        switch status {
        case .running: .blue
        case .done: .green
        case .blocked, .stopped: .red
        default: .secondary
        }
    }
}

// MARK: - Local helpers

/// Prefer the stored title; fall back to a trimmed prefix of the raw task.
private func rowTitle(for session: TaskSession) -> String {
    let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { return title }
    let task = session.originalTask.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.isEmpty { return "Untitled task" }
    return String(task.prefix(60))
}

/// Maps the raw event name (e.g. "executor_result") to a short readable label.
/// Unknown names fall back to a title-cased version of the underscored string.
private func humanizeEvent(_ name: String) -> String {
    switch name {
    case "planning": "Planning"
    case "policy_decision": "Policy"
    case "guard_decision": "Guard"
    case "executor_result": "Executor"
    case "screen_observed": "Observed screen"
    case "task_done": "Task done"
    case "task_blocked": "Task blocked"
    default:
        name
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private func shortTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .standard)
}

private func shortDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func fullDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}
