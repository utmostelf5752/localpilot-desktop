import Testing
@testable import LocalPilotDesktop

struct PermissionSummaryTests {
    @Test func everyPermissionDeepLinksToItsPrivacyPane() {
        let expected: [MacPermission: String] = [
            .accessibility: "Privacy_Accessibility",
            .screenRecording: "Privacy_ScreenCapture",
            .automation: "Privacy_Automation",
            .inputMonitoring: "Privacy_ListenEvent"
        ]
        for permission in MacPermission.allCases {
            let url = permission.systemSettingsURL
            #expect(url != nil)
            #expect(url?.scheme == "x-apple.systempreferences")
            #expect(url?.absoluteString.hasSuffix(expected[permission]!) == true)
        }
    }
}
