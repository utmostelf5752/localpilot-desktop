import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct ScreenObservation: Codable, Equatable, Sendable {
    public let activeApp: String?
    public let activeWindow: String?
    public let screenshotWidth: Int?
    public let screenshotHeight: Int?
    public let screenshotPNGBase64: String?
    public let accessibilitySummary: String?

    public init(
        activeApp: String?,
        activeWindow: String?,
        screenshotWidth: Int?,
        screenshotHeight: Int?,
        screenshotPNGBase64: String?,
        accessibilitySummary: String?
    ) {
        self.activeApp = activeApp
        self.activeWindow = activeWindow
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.screenshotPNGBase64 = screenshotPNGBase64
        self.accessibilitySummary = accessibilitySummary
    }

    public var summary: String {
        var parts: [String] = []
        parts.append("active_app=\(activeApp ?? "unknown")")
        parts.append("active_window=\(activeWindow ?? "unknown")")

        if let screenshotWidth, let screenshotHeight {
            let screenshotState = screenshotPNGBase64 == nil ? "screenshot unavailable" : "screenshot captured"
            parts.append("screen=\(screenshotWidth)x\(screenshotHeight) \(screenshotState)")
        } else {
            parts.append("screen=unknown screenshot unavailable")
        }

        if let accessibilitySummary, !accessibilitySummary.isEmpty {
            parts.append(accessibilitySummary)
        }

        return parts.joined(separator: "; ")
    }
}

public protocol ScreenObserving: Sendable {
    @MainActor func capture() async -> ScreenObservation
}

public struct LiveScreenObserver: ScreenObserving {
    public init() {}

    @MainActor
    public func capture() async -> ScreenObservation {
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let activeWindow = Self.frontmostWindowTitle(for: activeApp)
        let screenshot = Self.captureMainDisplayPNG()

        return ScreenObservation(
            activeApp: activeApp,
            activeWindow: activeWindow,
            screenshotWidth: screenshot.width,
            screenshotHeight: screenshot.height,
            screenshotPNGBase64: screenshot.pngBase64,
            accessibilitySummary: Self.accessibilitySummary()
        )
    }

    private static func frontmostWindowTitle(for activeApp: String?) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windows.first { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            guard let activeApp else { return true }
            return owner == activeApp
        }?[kCGWindowName as String] as? String
    }

    private static func captureMainDisplayPNG() -> (width: Int?, height: Int?, pngBase64: String?) {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            return (nil, nil, nil)
        }

        let width = image.width
        let height = image.height
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = bitmap.representation(using: .png, properties: [:])
        return (width, height, data?.base64EncodedString())
    }

    private static func accessibilitySummary() -> String? {
        guard AXIsProcessTrusted() else {
            return "AX: accessibility permission not granted"
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "AX: frontmost app unavailable"
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        let root = windowResult == .success ? focusedWindow as! AXUIElement : appElement

        var items: [String] = []
        collectAccessibilityItems(from: root, into: &items, depth: 0)
        if items.isEmpty {
            return "AX: no readable elements"
        }
        return "AX: " + items.prefix(16).joined(separator: ", ")
    }

    private static func collectAccessibilityItems(from element: AXUIElement, into items: inout [String], depth: Int) {
        guard depth <= 3, items.count < 16 else { return }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let title = stringAttribute(kAXTitleAttribute, from: element)
        let value = stringAttribute(kAXValueAttribute, from: element)
        let label = [role, title, value]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !label.isEmpty {
            items.append(label)
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children {
            collectAccessibilityItems(from: child, into: &items, depth: depth + 1)
        }
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

public struct AgentContextBuilder: Sendable {
    private let screenObserver: any ScreenObserving

    public init(screenObserver: any ScreenObserving = LiveScreenObserver()) {
        self.screenObserver = screenObserver
    }

    @MainActor
    public func makeContext(settings: AppSettings, messages: [ChatMessage]) async -> AgentContext {
        let observation = await screenObserver.capture()
        let visibleText = (messages.map(\.text) + [observation.summary]).joined(separator: "\n")

        return AgentContext(
            activeApp: observation.activeApp,
            activeWindow: observation.activeWindow,
            currentDomain: nil,
            allowedDomains: Set(settings.allowedDomains.map { $0.lowercased() }),
            allowedApps: Set(settings.allowedApps),
            allowedFolders: Set(settings.allowedFolders),
            visibleText: visibleText,
            activeFieldKind: nil
        )
    }
}
