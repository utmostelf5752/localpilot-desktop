import Foundation

public enum MacPermission: String, CaseIterable, Sendable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case automation = "Automation"
    case inputMonitoring = "Input Monitoring"
}

public struct PermissionSummary: Sendable {
    public let permission: MacPermission
    public let requiredFor: String
    public let milestone: String
}
