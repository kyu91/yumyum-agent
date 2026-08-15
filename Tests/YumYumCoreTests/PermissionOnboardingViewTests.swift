import SwiftUI
import Testing
import YumYumCore
@testable import YumYumApp

extension AppGlobalStateTests {
@Suite
@MainActor
struct PermissionOnboardingViewTests {
    @Test
    func allGrantedMeansNoAutomaticPresentation() {
        let view = PermissionOnboardingView(
            theme: .light,
            isScreenRecordingGranted: { true },
            isAccessibilityGranted: { true },
            isInputMonitoringGranted: { true }
        )
        #expect(view.allRequiredPermissionsGranted)
    }

    @Test
    func anySingleMissingPermissionRequestsPresentation() {
        let missingScreenRecording = PermissionOnboardingView(
            theme: .light,
            isScreenRecordingGranted: { false },
            isAccessibilityGranted: { true },
            isInputMonitoringGranted: { true }
        )
        #expect(!missingScreenRecording.allRequiredPermissionsGranted)

        let missingAccessibility = PermissionOnboardingView(
            theme: .light,
            isScreenRecordingGranted: { true },
            isAccessibilityGranted: { false },
            isInputMonitoringGranted: { true }
        )
        #expect(!missingAccessibility.allRequiredPermissionsGranted)

        let missingInputMonitoring = PermissionOnboardingView(
            theme: .light,
            isScreenRecordingGranted: { true },
            isAccessibilityGranted: { true },
            isInputMonitoringGranted: { false }
        )
        #expect(!missingInputMonitoring.allRequiredPermissionsGranted)
    }

    @Test
    func recomputesFromCurrentValuesOnEachCall() {
        var inputMonitoringGranted = false
        let view = PermissionOnboardingView(
            theme: .light,
            isScreenRecordingGranted: { true },
            isAccessibilityGranted: { true },
            isInputMonitoringGranted: { inputMonitoringGranted }
        )
        #expect(!view.allRequiredPermissionsGranted)
        inputMonitoringGranted = true
        #expect(view.allRequiredPermissionsGranted)
    }
}
}
