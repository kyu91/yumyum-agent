import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import YumYumCore

@MainActor
struct PermissionOnboardingView: View {
    let theme: AppTheme
    var isScreenRecordingGranted: () -> Bool = CGPreflightScreenCaptureAccess
    var requestScreenRecording: () -> Bool = CGRequestScreenCaptureAccess
    var isAccessibilityGranted: () -> Bool = AXIsProcessTrusted
    var requestAccessibility: () -> Bool = promptForAccessibilityAccess
    var isInputMonitoringGranted: () -> Bool = CGPreflightListenEventAccess
    var requestInputMonitoring: () -> Bool = CGRequestListenEventAccess

    @Environment(\.dismiss) private var dismiss
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppText.localized("시작하기 전에 권한을 확인하세요"))
                .font(.title2.bold())
            Text(AppText.localized("YumYum Agent가 아래 기능을 쓰려면 macOS 권한이 필요합니다. 지금 허용하지 않아도 앱은 정상적으로 실행됩니다."))
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionRow(
                symbol: "rectangle.on.rectangle",
                title: AppText.localized("화면 기록"),
                detail: AppText.localized("화면 영역을 캡처해서 에이전트에게 보내려면 필요합니다."),
                isGranted: screenRecordingGranted,
                request: { _ = requestScreenRecording(); refresh() },
                settingsPane: "Privacy_ScreenCapture"
            )
            permissionRow(
                symbol: "keyboard",
                title: AppText.localized("손쉬운 사용"),
                detail: AppText.localized("전역 단축키를 앱 밖에서 등록하려면 필요합니다."),
                isGranted: accessibilityGranted,
                request: { _ = requestAccessibility(); refresh() },
                settingsPane: "Privacy_Accessibility"
            )
            permissionRow(
                symbol: "keyboard.badge.ellipsis",
                title: AppText.localized("입력 모니터링"),
                detail: AppText.localized("전역 단축키 입력을 받으려면 손쉬운 사용과 별개로 이 권한이 필요합니다."),
                isGranted: inputMonitoringGranted,
                request: { _ = requestInputMonitoring(); refresh() },
                settingsPane: "Privacy_ListenEvent"
            )

            Text(AppText.localized("권한은 시스템 설정 > 개인정보 보호 및 보안에서 언제든지 바꿀 수 있습니다. 화면 기록과 입력 모니터링은 앱을 다시 실행한 뒤 적용됩니다."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(AppText.localized("나중에 하기")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .preferredColorScheme(theme.colorScheme)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    @ViewBuilder
    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        isGranted: Bool,
        request: @escaping () -> Void,
        settingsPane: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Label(AppText.localized("허용됨"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(AppText.localized("허용하기"), action: request)
                    Button(AppText.localized("시스템 설정 열기")) { openSystemSettings(settingsPane) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private func refresh() {
        screenRecordingGranted = isScreenRecordingGranted()
        accessibilityGranted = isAccessibilityGranted()
        inputMonitoringGranted = isInputMonitoringGranted()
    }
}

private func promptForAccessibilityAccess() -> Bool {
    AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    )
}

private func openSystemSettings(_ pane: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
    NSWorkspace.shared.open(url)
}
