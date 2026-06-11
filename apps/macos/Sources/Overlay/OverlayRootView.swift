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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.currentActionLabel)
                        .font(.headline)
                    Text(controller.runStatus.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if controller.runStatus == .paused {
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
                }

                if controller.runStatus == .paused {
                    Button(action: continueAction) {
                        Label("Continue", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()

                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 8)
    }

    private var icon: String {
        switch controller.runStatus {
        case .running: "sparkle.magnifyingglass"
        case .paused: "pause.circle.fill"
        case .stopped, .stopping: "stop.circle.fill"
        case .done: "checkmark.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .idle: "circle"
        }
    }
}
