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
        let overlayWindow = KeyableOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayWindow.level = .screenSaver
        overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        // Released elsewhere; we keep a strong reference in `window`. Setting this
        // to false avoids AppKit over-releasing the window when it is ordered out.
        overlayWindow.isReleasedWhenClosed = false
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
            // The overlay hosts an editable text field and buttons, so it must be
            // able to become key to receive keyboard focus and clicks.
            window.makeKey()
        } else {
            window.orderOut(nil)
        }
    }
}

/// A borderless window that can still become key/main so the SwiftUI controls
/// it hosts (text field, Pause/Continue/Stop buttons) can receive focus and
/// keyboard events. A vanilla borderless `NSWindow` returns `false` for both,
/// which would make the overlay's instruction field impossible to type into.
private final class KeyableOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
