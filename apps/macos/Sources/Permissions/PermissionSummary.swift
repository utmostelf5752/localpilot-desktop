import Foundation

public enum MacPermission: String, CaseIterable, Sendable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case automation = "Automation"
    case inputMonitoring = "Input Monitoring"

    /// Deep link to this permission's pane in System Settings → Privacy & Security.
    /// The `Privacy_*` anchors are the stable pane identifiers macOS exposes
    /// through the `x-apple.systempreferences:` URL scheme.
    public var systemSettingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .automation: anchor = "Privacy_Automation"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

public struct PermissionSummary: Sendable {
    public let permission: MacPermission
    public let requiredFor: String
    public let milestone: String
}
