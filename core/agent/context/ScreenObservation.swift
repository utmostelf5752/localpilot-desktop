import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A single actionable accessibility element captured during one observation.
///
/// `id` is a traversal-order index that is stable *within one observation*
/// only: it lets the planner reference an element by number ("click element 3")
/// and lets the executor resolve that id back to a concrete click point by
/// re-observing the screen. Coordinates are in global display space, matching
/// the coordinate space the executor's click controller expects.
public struct AXElementSnapshot: Codable, Equatable, Sendable {
    public let id: Int          // traversal-order index, stable within one observation
    public let role: String     // e.g. AXButton, AXTextField (AX prefix may be stripped)
    public let label: String    // best of title/value/description, trimmed
    public let centerX: Double
    public let centerY: Double
    public let width: Double
    public let height: Double

    public init(
        id: Int,
        role: String,
        label: String,
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }
}

public struct ScreenObservation: Codable, Equatable, Sendable {
    public let activeApp: String?
    public let activeWindow: String?
    public let screenshotWidth: Int?
    public let screenshotHeight: Int?
    public let screenshotPNGBase64: String?
    public let accessibilitySummary: String?
    public let elements: [AXElementSnapshot]

    public init(
        activeApp: String?,
        activeWindow: String?,
        screenshotWidth: Int?,
        screenshotHeight: Int?,
        screenshotPNGBase64: String?,
        accessibilitySummary: String?,
        elements: [AXElementSnapshot] = []
    ) {
        self.activeApp = activeApp
        self.activeWindow = activeWindow
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.screenshotPNGBase64 = screenshotPNGBase64
        self.accessibilitySummary = accessibilitySummary
        self.elements = elements
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

        if !elements.isEmpty {
            parts.append(Self.elementsSummary(elements))
        }

        return parts.joined(separator: "; ")
    }

    /// Compact, capped rendering of the actionable elements, e.g.
    /// `elements: [0] button "Save", [1] textfield "Search"`.
    /// Caps the count (~20) and truncates each label (~40 chars) so the
    /// element list cannot dominate the planner context.
    private static func elementsSummary(_ elements: [AXElementSnapshot]) -> String {
        let maxElements = 20
        let maxLabel = 40
        let rendered = elements.prefix(maxElements).map { element -> String in
            let role = element.role.lowercased()
            var label = element.label
            if label.count > maxLabel {
                label = String(label.prefix(maxLabel)) + "…"
            }
            return "[\(element.id)] \(role) \"\(label)\""
        }
        return "elements: " + rendered.joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey {
        case activeApp
        case activeWindow
        case screenshotWidth
        case screenshotHeight
        case screenshotPNGBase64
        case accessibilitySummary
        case elements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeApp = try container.decodeIfPresent(String.self, forKey: .activeApp)
        self.activeWindow = try container.decodeIfPresent(String.self, forKey: .activeWindow)
        self.screenshotWidth = try container.decodeIfPresent(Int.self, forKey: .screenshotWidth)
        self.screenshotHeight = try container.decodeIfPresent(Int.self, forKey: .screenshotHeight)
        self.screenshotPNGBase64 = try container.decodeIfPresent(String.self, forKey: .screenshotPNGBase64)
        self.accessibilitySummary = try container.decodeIfPresent(String.self, forKey: .accessibilitySummary)
        // Decode the element list when present; absent JSON (older payloads,
        // 6-field literals) decodes to an empty list rather than failing.
        self.elements = try container.decodeIfPresent([AXElementSnapshot].self, forKey: .elements) ?? []
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
        let screenshot = Self.captureMainDisplayImage()

        return ScreenObservation(
            activeApp: activeApp,
            activeWindow: activeWindow,
            screenshotWidth: screenshot.width,
            screenshotHeight: screenshot.height,
            screenshotPNGBase64: screenshot.base64,
            accessibilitySummary: Self.accessibilitySummary(),
            elements: Self.collectActionableElements()
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

    private static func captureMainDisplayImage() -> (width: Int?, height: Int?, base64: String?) {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            return (nil, nil, nil)
        }

        let width = image.width
        let height = image.height
        let bitmap = NSBitmapImageRep(cgImage: image)
        // JPEG, not PNG: screenshots sent to a vision model are far smaller this
        // way (~5-10x). 0.7 keeps UI text legible while cutting the payload.
        let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: screenshotJPEGQuality])
        return (width, height, data?.base64EncodedString())
    }

    // ponytail: raise toward 1.0 if the vision model misreads small on-screen text.
    private static let screenshotJPEGQuality = 0.7

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

    /// Roles we treat as directly actionable for element targeting. These are
    /// the controls a planner would want to click or type into.
    private static let actionableRoles: Set<String> = [
        kAXButtonRole as String,
        "AXLink",   // no kAXLinkRole constant exists in the SDK; AX link role value is "AXLink"
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXMenuItemRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String
    ]

    /// Walk the focused window's AX subtree and collect actionable elements
    /// (with geometry) for element-targeted clicks. Returns an empty list if AX
    /// permission is absent or no frontmost app is available, so callers never
    /// crash on missing accessibility access.
    private static func collectActionableElements() -> [AXElementSnapshot] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        let root = windowResult == .success ? focusedWindow as! AXUIElement : appElement

        var snapshots: [AXElementSnapshot] = []
        var nextID = 0
        collectElements(from: root, into: &snapshots, nextID: &nextID, depth: 0)
        return snapshots
    }

    private static let maxElements = 30
    private static let maxElementDepth = 6

    private static func collectElements(
        from element: AXUIElement,
        into snapshots: inout [AXElementSnapshot],
        nextID: inout Int,
        depth: Int
    ) {
        guard depth <= maxElementDepth, snapshots.count < maxElements else { return }

        let rawRole = stringAttribute(kAXRoleAttribute, from: element)
        if let rawRole, actionableRoles.contains(rawRole), let frame = elementFrame(of: element) {
            let label = bestLabel(of: element)
            let role = rawRole.hasPrefix("AX") ? String(rawRole.dropFirst(2)) : rawRole
            snapshots.append(
                AXElementSnapshot(
                    id: nextID,
                    role: role,
                    label: label,
                    centerX: Double(frame.midX),
                    centerY: Double(frame.midY),
                    width: Double(frame.width),
                    height: Double(frame.height)
                )
            )
            nextID += 1
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children {
            if snapshots.count >= maxElements { return }
            collectElements(from: child, into: &snapshots, nextID: &nextID, depth: depth + 1)
        }
    }

    private static func bestLabel(of element: AXUIElement) -> String {
        let candidates = [
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXValueAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element)
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Read an element's global frame from `kAXPositionAttribute`/`kAXSizeAttribute`.
    /// These come back as `AXValue` boxes carrying a `CGPoint`/`CGSize`, unpacked
    /// with `AXValueGetValue` into local CG structs.
    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef else {
            return nil
        }

        // CFTypeRef bridges to AXValue here; cast back so AXValueGetValue can
        // unpack the boxed CGPoint/CGSize.
        let axPosition = positionValue as! AXValue
        let axSize = sizeValue as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(axPosition, .cgPoint, &point),
              AXValueGetValue(axSize, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }
}

public struct AgentContextBuilder: Sendable {
    private let screenObserver: any ScreenObserving

    /// Upper bound on how many trailing chat messages the legacy builder keeps,
    /// so the prompt can never grow unbounded with conversation length.
    private static let maxMessageTail = 6

    public init(screenObserver: any ScreenObserving = LiveScreenObserver()) {
        self.screenObserver = screenObserver
    }

    /// Legacy builder kept for the message-oriented call sites and tests.
    /// Only the trailing `maxMessageTail` messages plus the single latest
    /// observation are surfaced; no screenshot/base64 data ever enters the text.
    @MainActor
    public func makeContext(settings: AppSettings, messages: [ChatMessage]) async -> AgentContext {
        let observation = await screenObserver.capture()
        let tail = messages.suffix(Self.maxMessageTail).map(\.text)
        let visibleText = (tail + [observation.summary]).joined(separator: "\n")

        return context(from: observation, settings: settings, visibleText: visibleText)
    }

    /// Lean builder used by the agent loop. Builds a short, fresh context from
    /// the task line, the rolling history summary, the raw recent-step tail, and
    /// ONLY the latest observation. Images are latest-only and never accumulate.
    @MainActor
    public func makeContext(settings: AppSettings, task: String, history: AgentHistory) async -> AgentContext {
        let observation = await screenObserver.capture()

        var parts: [String] = ["Task: \(task)"]
        if !history.compactedSummary.isEmpty {
            parts.append(history.compactedSummary)
        }
        if !history.recentSteps.isEmpty {
            parts.append("Recent steps:\n" + history.recentSteps.joined(separator: "\n"))
        }
        parts.append("Latest observation: \(observation.summary)")
        let visibleText = parts.joined(separator: "\n")

        return context(from: observation, settings: settings, visibleText: visibleText)
    }

    private func context(from observation: ScreenObservation, settings: AppSettings, visibleText: String) -> AgentContext {
        AgentContext(
            activeApp: observation.activeApp,
            activeWindow: observation.activeWindow,
            currentDomain: nil,
            allowedDomains: Set(settings.allowedDomains.map { $0.lowercased() }),
            allowedApps: Set(settings.allowedApps),
            allowedFolders: Set(settings.allowedFolders),
            visibleText: visibleText,
            activeFieldKind: nil,
            observationSummary: observation.summary,
            latestScreenshotPNGBase64: observation.screenshotPNGBase64
        )
    }
}
