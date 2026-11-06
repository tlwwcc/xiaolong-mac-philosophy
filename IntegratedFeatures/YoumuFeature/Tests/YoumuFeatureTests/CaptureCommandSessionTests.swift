import Foundation
import Testing

@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class CaptureCommandSessionTests {
    @Test
    func testSecondInvocationOfSameModeTakesOnlyThatOwner() {
        for phase in [
            CaptureCommandPhase.selecting,
            .processing,
            .presenting,
        ] {
            var registry = CaptureCommandSessionRegistry()
            let owner = registry.begin(mode: .silentOCR, phase: phase)!

            let cancelled = registry.take(mode: .silentOCR)
            #expect((cancelled?.owner) == (owner))
            #expect((cancelled?.phase) == (phase))
            #expect((registry.session(for: .silentOCR)) == nil)
        }
    }

    @Test
    func testDifferentModeNeverInvalidatesExistingOwner() {
        var registry = CaptureCommandSessionRegistry()
        let ocr = registry.begin(mode: .silentOCR)!
        let reader = registry.begin(mode: .selectionReader)!
        let didTransitionOCR = registry.transition(ocr, to: .processing)
        #expect(didTransitionOCR)
        let didTransitionReader = registry.transition(reader, to: .presenting)
        #expect(didTransitionReader)

        #expect((registry.take(mode: .selectionReader)?.owner) == (reader))
        #expect(registry.isCurrent(ocr, phase: .processing))
        #expect((registry.count) == (1))
    }

    @Test
    func testQuickSnapshotCompletionResetsToggleImmediately() {
        var registry = CaptureCommandSessionRegistry()
        let first = registry.begin(mode: .quickSnapshot)!

        let finishedFirst = registry.finish(first)
        #expect(finishedFirst)
        #expect((registry.session(for: .quickSnapshot)) == nil)

        let second = registry.begin(mode: .quickSnapshot)
        #expect((second) != nil)
        #expect((first) != (second))
    }

    @Test
    func testLateGenerationCannotTransitionOrFinishNewInvocation() {
        var registry = CaptureCommandSessionRegistry()
        let stale = registry.begin(mode: .screenshotTranslate)!
        let finishedStale = registry.finish(stale)
        #expect(finishedStale)
        let current = registry.begin(mode: .screenshotTranslate)!

        let staleTransitioned = registry.transition(stale, to: .presenting)
        #expect(!staleTransitioned)
        let staleFinished = registry.finish(stale)
        #expect(!staleFinished)
        #expect(registry.isCurrent(current, phase: .selecting))
    }

    @Test
    func testLateOwnerDismissalCannotClearReplacementOnSharedSurface() {
        var registry = CaptureCommandSessionRegistry()
        let oldEditorOwner = registry.begin(mode: .screenshotEdit)!
        let oldTransitioned = registry.transition(oldEditorOwner, to: .presenting)
        #expect(oldTransitioned)
        let oldFinished = registry.finish(oldEditorOwner)
        #expect(oldFinished)

        let replacementOwner = registry.begin(mode: .screenshotEdit)!
        let replacementTransitioned = registry.transition(replacementOwner, to: .presenting)
        #expect(replacementTransitioned)

        // Simulates the old editor's delayed AppKit release callback arriving after replacement.
        let delayedOldFinished = registry.finish(oldEditorOwner)
        #expect(!delayedOldFinished)
        #expect(registry.isCurrent(replacementOwner, phase: .presenting))
    }

    @Test
    func testAllEightModesHaveIndependentConstantTimeSlots() {
        var registry = CaptureCommandSessionRegistry()
        for mode in TranslateMode.allCases {
            #expect((registry.begin(mode: mode)) != nil)
        }

        #expect((registry.count) == (8))
        for mode in TranslateMode.allCases {
            #expect((registry.session(for: mode)?.owner.mode) == (mode))
        }
    }

    @Test
    func testLifecycleInvalidationPoliciesPreserveUnaffectedModes() {
        #expect((CaptureCommandInvalidationPolicy.modes(affectedBy: .proEntitlementLost)) == ([.longScreenshot, .selectionReader, .imageTranslate, .screenshotTranslate]))
        #expect((CaptureCommandInvalidationPolicy.modes(
                affectedBy: .screenRecordingPermissionLost
            )) == (Set(TranslateMode.allCases).subtracting([.pinClipboard])))
        #expect((CaptureCommandInvalidationPolicy.modes(affectedBy: .inputMonitoringPermissionLost)) == ([.longScreenshot]))
        #expect((CaptureCommandInvalidationPolicy.modes(affectedBy: .globalInputOwnershipYielded)) == (Set(TranslateMode.allCases)))
        #expect((CaptureCommandInvalidationPolicy.phases(
                affectedBy: .screenRecordingPermissionLost
            )) == ([.selecting, .processing]))
        #expect((CaptureCommandInvalidationPolicy.phases(affectedBy: .inputMonitoringPermissionLost)) == ([.selecting, .processing]))
        #expect((CaptureCommandInvalidationPolicy.phases(affectedBy: .proEntitlementLost)) == ([.selecting, .processing, .presenting]))
    }

    @Test
    func testTargetedInvalidationAtomicallyTakesOnlyAffectedOwners() {
        var registry = CaptureCommandSessionRegistry()
        let freeEditor = registry.begin(mode: .screenshotEdit, phase: .presenting)!
        let pin = registry.begin(mode: .pinClipboard, phase: .presenting)!
        let proReader = registry.begin(mode: .selectionReader, phase: .processing)!

        let removed = registry.take(
            modes: CaptureCommandInvalidationPolicy.modes(affectedBy: .proEntitlementLost),
            phases: CaptureCommandInvalidationPolicy.phases(
                affectedBy: .proEntitlementLost
            )
        )

        #expect((removed.map(\.owner)) == ([proReader]))
        #expect(registry.isCurrent(freeEditor, phase: .presenting))
        #expect(registry.isCurrent(pin, phase: .presenting))
    }

    @Test
    func testPermissionLossPreservesCompletedPresentationsButCancelsLateWork() {
        var registry = CaptureCommandSessionRegistry()
        let completedEditor = registry.begin(mode: .screenshotEdit, phase: .presenting)!
        let translating = registry.begin(mode: .screenshotTranslate, phase: .processing)!
        let pinEditor = registry.begin(mode: .pinClipboard, phase: .presenting)!
        let reason = YoumuCommandSessionInvalidationReason.screenRecordingPermissionLost

        let removed = registry.take(
            modes: CaptureCommandInvalidationPolicy.modes(affectedBy: reason),
            phases: CaptureCommandInvalidationPolicy.phases(affectedBy: reason)
        )

        #expect((removed.map(\.owner)) == ([translating]))
        #expect(registry.isCurrent(completedEditor, phase: .presenting))
        #expect(registry.isCurrent(pinEditor, phase: .presenting))
    }

    @Test
    func testTransferredPinOwnerRemainsActiveForSecondShortcutPress() {
        var registry = CaptureCommandSessionRegistry()
        let owner = registry.begin(mode: .pinClipboard, phase: .presenting)!

        // Moving from the pin surface to its editor does not finish or replace the command owner.
        #expect(registry.isCurrent(owner, phase: .presenting))
        #expect((registry.take(mode: .pinClipboard)?.owner) == (owner))
    }

    @Test
    func testTakeAllClearsEveryGenerationBeforeTeardown() {
        var registry = CaptureCommandSessionRegistry()
        for mode in TranslateMode.allCases {
            #expect((registry.begin(mode: mode, phase: .processing)) != nil)
        }

        #expect((registry.takeAll().count) == (8))
        #expect((registry.count) == (0))
        for mode in TranslateMode.allCases {
            #expect((registry.session(for: mode)) == nil)
        }
    }
}
