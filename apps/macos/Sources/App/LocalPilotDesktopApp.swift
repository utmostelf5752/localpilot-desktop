import SwiftUI

@main
struct LocalPilotDesktopApp: App {
    @State private var modelSessionManager = ModelSessionManager()
    @State private var controller: AgentController

    init() {
        let manager = ModelSessionManager()
        _modelSessionManager = State(initialValue: manager)
        _controller = State(initialValue: AgentController(modelSessionCloser: manager))
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(controller: controller)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    controller.stop()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
