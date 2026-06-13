import SwiftUI

struct OverlayRootView: View {
    @Bindable var controller: AgentController
    @State private var continueInstruction = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            haze
            FakeCursorView()
                .position(controller.fakeCursorPosition)
                .animation(.easeInOut(duration: 0.25), value: controller.fakeCursorPosition)

            FloatingControlsView(
                controller: controller,
                instruction: $continueInstruction,
                continueAction: {
                    controller.continueTask(instruction: continueInstruction)
                    continueInstruction = ""
                }
            )
            .frame(width: 420)
            .padding(28)
        }
        .ignoresSafeArea()
    }

    private var haze: some View {
        Rectangle()
            .fill(Color.black.opacity(controller.overlayState == .paused ? 0.28 : 0.18))
            .overlay {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct FakeCursorView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 3)
            Circle()
                .stroke(Color.cyan, lineWidth: 2)
                .frame(width: 48, height: 48)
                .offset(x: -10, y: -8)
                .opacity(0.72)
        }
        .accessibilityLabel("Fake AI cursor")
    }
}

private struct FloatingControlsView: View {
    @Bindable var controller: AgentController
    @Binding var instruction: String
    let continueAction: () -> Void

    /// True while the agent is blocked on an approval decision. During this
    /// window `runStatus` is `.paused`, but resuming via `continueTask` would
    /// NOT resolve the pending approval (the loop is parked in `requestApproval`
    /// waiting on the user's allow/deny in the main window). So we must not offer
    /// a plain "Continue" here; we point the user at the approval prompt instead.
    private var isAwaitingApproval: Bool {
        controller.pendingApproval != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Mode")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.currentActionLabel)
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(statusText): \(controller.currentActionLabel)")

            if isAwaitingApproval {
                Text("Review the approval request in the main window to allow or deny this action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.runStatus == .paused {
                TextField("Optional instruction", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            HStack {
                if controller.runStatus == .running {
                    Button {
                        controller.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause the agent after the current step")
                }

                if controller.runStatus == .paused && !isAwaitingApproval {
                    Button(action: continueAction) {
                        Label("Continue", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Resume the task, optionally with the instruction above")
                }

                Spacer()

                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Hard-stop the agent and disable the executor")
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Mode controls")
    }

    private var statusText: String {
        if isAwaitingApproval {
            return "Approval required"
        }
        return controller.runStatus.rawValue.capitalized
    }

    private var icon: String {
        if isAwaitingApproval {
            return "hand.raised.fill"
        }
        switch controller.runStatus {
        case .running: return "sparkle.magnifyingglass"
        case .paused: return "pause.circle.fill"
        case .stopped, .stopping: return "stop.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        case .idle: return "circle"
        }
    }
}
