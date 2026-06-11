import AppKit
import SwiftUI

@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    private var window: NSWindow?

    private init() {}

    func configure(controller: AgentController) {
        guard window == nil else { return }
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let overlayWindow = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayWindow.level = .screenSaver
        overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlayWindow.contentView = NSHostingView(rootView: OverlayRootView(controller: controller))
        overlayWindow.orderOut(nil)
        window = overlayWindow
    }

    func setVisible(_ visible: Bool, controller: AgentController) {
        configure(controller: controller)
        guard let window else { return }

        if visible {
            if let screenFrame = NSScreen.main?.frame {
                window.setFrame(screenFrame, display: true)
            }
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }
}
