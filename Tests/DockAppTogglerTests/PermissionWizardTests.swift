import Testing
@testable import DockAppToggler

@MainActor
struct PermissionWizardTests {
    @MainActor private final class Permissions {
        var accessibility = false
        var input = false
        var screen = false

        var steps: [PermissionStep] {
            [
                PermissionStep(title: "Bedienungshilfen", settingsURLString: "",
                               isGranted: { self.accessibility }, needsRestartToTakeEffect: false),
                PermissionStep(title: "Eingabeüberwachung", settingsURLString: "",
                               isGranted: { self.input }, needsRestartToTakeEffect: true),
                PermissionStep(title: "Bildschirmaufnahme", settingsURLString: "",
                               isGranted: { self.screen }, needsRestartToTakeEffect: true)
            ]
        }
    }

    @Test func allGrantedNeedsNeitherWizardNorRestart() {
        let permissions = Permissions()
        permissions.accessibility = true
        permissions.input = true
        permissions.screen = true
        var progress = PermissionWizardProgress(steps: permissions.steps)
        #expect(progress.refresh() == .complete)
    }

    @Test func missingPermissionsAreCheckedInOrderWithOneRestartAtTheEnd() {
        let permissions = Permissions()
        var progress = PermissionWizardProgress(steps: permissions.steps)
        #expect(progress.refresh() == .permission(0))
        permissions.accessibility = true
        #expect(progress.refresh() == .permission(1))
        permissions.input = true
        #expect(progress.refresh() == .permission(2))
        permissions.screen = true
        #expect(progress.refresh() == .restart)

        var afterRestart = PermissionWizardProgress(steps: permissions.steps)
        #expect(afterRestart.refresh() == .complete)
    }

    @Test func existingPermissionsAreSkippedAndAccessibilityNeedsNoRestart() {
        let permissions = Permissions()
        permissions.input = true
        permissions.screen = true
        var progress = PermissionWizardProgress(steps: permissions.steps)
        #expect(progress.refresh() == .permission(0))
        permissions.accessibility = true
        #expect(progress.refresh() == .complete)
    }

    @Test func cachedPermissionChecksCanBeDeferredUntilTheFinalRestart() {
        let permissions = Permissions()
        permissions.accessibility = true
        var progress = PermissionWizardProgress(steps: permissions.steps)
        #expect(progress.refresh() == .permission(1))
        progress.confirmGrant(at: 1)
        #expect(progress.refresh() == .permission(2))
        progress.confirmGrant(at: 2)
        #expect(progress.refresh() == .restart)

        // Confirmations are not grants: a fresh process must query macOS again.
        var afterRestart = PermissionWizardProgress(steps: permissions.steps)
        #expect(afterRestart.refresh() == .permission(1))
        permissions.input = true
        #expect(afterRestart.refresh() == .permission(2))
    }

    @Test func accessibilityCannotBeSkippedByConfirmation() {
        let permissions = Permissions()
        var progress = PermissionWizardProgress(steps: permissions.steps)
        progress.confirmGrant(at: 0)
        #expect(progress.refresh() == .permission(0))
    }

    @Test func grantArrivingBeforeContinueClickDoesNotSkipNextPermission() {
        let permissions = Permissions()
        permissions.accessibility = true
        var progress = PermissionWizardProgress(steps: permissions.steps)
        #expect(progress.refresh() == .permission(1))
        permissions.input = true
        progress.confirmGrant(at: 1)
        #expect(progress.refresh() == .permission(2))
    }

    @Test func featureRequestsPreserveStartupStepsAndDeferredGrants() {
        let permissions = Permissions()
        permissions.accessibility = true
        var progress = PermissionWizardProgress(steps: permissions.steps)
        progress.confirmGrant(at: 1)
        progress.include(steps: [permissions.steps[0], permissions.steps[1]])
        #expect(progress.steps.count == 3)
        #expect(progress.refresh() == .permission(2))
        permissions.screen = true
        #expect(progress.refresh() == .restart)
    }

    @Test func newlyAddedMissingStepPreventsPrematureRestart() {
        let permissions = Permissions()
        permissions.accessibility = true
        var progress = PermissionWizardProgress(steps: Array(permissions.steps.prefix(2)))
        progress.confirmGrant(at: 1)
        progress.include(steps: permissions.steps)
        #expect(progress.refresh() == .permission(2))
    }

    @Test func revokedPermissionIsRecheckedBeforeSetupCompletes() {
        let permissions = Permissions()
        permissions.accessibility = true
        var progress = PermissionWizardProgress(steps: permissions.steps)
        #expect(progress.refresh() == .permission(1))
        permissions.accessibility = false
        permissions.input = true
        #expect(progress.refresh() == .permission(0))
        permissions.accessibility = true
        #expect(progress.refresh() == .permission(2))
    }
}
