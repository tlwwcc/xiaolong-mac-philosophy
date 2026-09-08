import Foundation
import XCTest

@testable import YoumuFeature

@MainActor
final class CaptureCommandSessionTests: XCTestCase {
    func testSecondInvocationOfSameModeTakesOnlyThatOwner() {
        for phase in [
            CaptureCommandPhase.selecting,
            .processing,
            .presenting,
        ] {
            var registry = CaptureCommandSessionRegistry()
            let owner = registry.begin(mode: .silentOCR, phase: phase)!

            let cancelled = registry.take(mode: .silentOCR)
            XCTAssertEqual(cancelled?.owner, owner)
            XCTAssertEqual(cancelled?.phase, phase)
            XCTAssertNil(registry.session(for: .silentOCR))
        }
    }

    func testDifferentModeNeverInvalidatesExistingOwner() {
        var registry = CaptureCommandSessionRegistry()
        let ocr = registry.begin(mode: .silentOCR)!
        let reader = registry.begin(mode: .selectionReader)!
        XCTAssertTrue(registry.transition(ocr, to: .processing))
        XCTAssertTrue(registry.transition(reader, to: .presenting))

        XCTAssertEqual(registry.take(mode: .selectionReader)?.owner, reader)
        XCTAssertTrue(registry.isCurrent(ocr, phase: .processing))
        XCTAssertEqual(registry.count, 1)
    }

    func testQuickSnapshotCompletionResetsToggleImmediately() {
        var registry = CaptureCommandSessionRegistry()
        let first = registry.begin(mode: .quickSnapshot)!

        XCTAssertTrue(registry.finish(first))
        XCTAssertNil(registry.session(for: .quickSnapshot))

        let second = registry.begin(mode: .quickSnapshot)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testLateGenerationCannotTransitionOrFinishNewInvocation() {
        var registry = CaptureCommandSessionRegistry()
        let stale = registry.begin(mode: .screenshotTranslate)!
        XCTAssertTrue(registry.finish(stale))
        let current = registry.begin(mode: .screenshotTranslate)!

        XCTAssertFalse(registry.transition(stale, to: .presenting))
        XCTAssertFalse(registry.finish(stale))
        XCTAssertTrue(registry.isCurrent(current, phase: .selecting))
    }

    func testLateOwnerDismissalCannotClearReplacementOnSharedSurface() {
        var registry = CaptureCommandSessionRegistry()
        let oldEditorOwner = registry.begin(mode: .screenshotEdit)!
        XCTAssertTrue(registry.transition(oldEditorOwner, to: .presenting))
        XCTAssertTrue(registry.finish(oldEditorOwner))

        let replacementOwner = registry.begin(mode: .screenshotEdit)!
        XCTAssertTrue(registry.transition(replacementOwner, to: .presenting))

        // Simulates the old editor's delayed AppKit release callback arriving after replacement.
        XCTAssertFalse(registry.finish(oldEditorOwner))
        XCTAssertTrue(registry.isCurrent(replacementOwner, phase: .presenting))
    }

    func testAllEightModesHaveIndependentConstantTimeSlots() {
        var registry = CaptureCommandSessionRegistry()
        for mode in TranslateMode.allCases {
            XCTAssertNotNil(registry.begin(mode: mode))
        }

        XCTAssertEqual(registry.count, 8)
        for mode in TranslateMode.allCases {
            XCTAssertEqual(registry.session(for: mode)?.owner.mode, mode)
        }
    }

    func testLifecycleInvalidationPoliciesPreserveUnaffectedModes() {
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.modes(affectedBy: .proEntitlementLost),
            [.longScreenshot, .selectionReader, .imageTranslate, .screenshotTranslate]
        )
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.modes(
                affectedBy: .screenRecordingPermissionLost
            ),
            Set(TranslateMode.allCases).subtracting([.pinClipboard])
        )
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.modes(affectedBy: .inputMonitoringPermissionLost),
            [.longScreenshot]
        )
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.modes(affectedBy: .globalInputOwnershipYielded),
            Set(TranslateMode.allCases)
        )
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.phases(
                affectedBy: .screenRecordingPermissionLost
            ),
            [.selecting, .processing]
        )
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.phases(affectedBy: .inputMonitoringPermissionLost),
            [.selecting, .processing]
        )
        XCTAssertEqual(
            CaptureCommandInvalidationPolicy.phases(affectedBy: .proEntitlementLost),
            [.selecting, .processing, .presenting]
        )
    }

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

        XCTAssertEqual(removed.map(\.owner), [proReader])
        XCTAssertTrue(registry.isCurrent(freeEditor, phase: .presenting))
        XCTAssertTrue(registry.isCurrent(pin, phase: .presenting))
    }

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

        XCTAssertEqual(removed.map(\.owner), [translating])
        XCTAssertTrue(registry.isCurrent(completedEditor, phase: .presenting))
        XCTAssertTrue(registry.isCurrent(pinEditor, phase: .presenting))
    }

    func testTransferredPinOwnerRemainsActiveForSecondShortcutPress() {
        var registry = CaptureCommandSessionRegistry()
        let owner = registry.begin(mode: .pinClipboard, phase: .presenting)!

        // Moving from the pin surface to its editor does not finish or replace the command owner.
        XCTAssertTrue(registry.isCurrent(owner, phase: .presenting))
        XCTAssertEqual(registry.take(mode: .pinClipboard)?.owner, owner)
    }

    func testTakeAllClearsEveryGenerationBeforeTeardown() {
        var registry = CaptureCommandSessionRegistry()
        for mode in TranslateMode.allCases {
            XCTAssertNotNil(registry.begin(mode: mode, phase: .processing))
        }

        XCTAssertEqual(registry.takeAll().count, 8)
        XCTAssertEqual(registry.count, 0)
        for mode in TranslateMode.allCases {
            XCTAssertNil(registry.session(for: mode))
        }
    }
}
