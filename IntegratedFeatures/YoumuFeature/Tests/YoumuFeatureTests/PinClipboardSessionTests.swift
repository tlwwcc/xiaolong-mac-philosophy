import XCTest

@testable import YoumuFeature

@MainActor
final class PinClipboardSessionTests: XCTestCase {
    func testNewClipboardKeepsAllEarlierOwners() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 10)!
        let second = pins.begin(clipboardChangeCount: 11)!
        let third = pins.begin(clipboardChangeCount: 12)!

        XCTAssertEqual(pins.count, 3)
        XCTAssertEqual(pins.take(clipboardChangeCount: 11)?.owner, second)
        XCTAssertEqual(pins.count, 2)
        XCTAssertEqual(Set(pins.takeAll().map(\.owner)), Set([first, third]))
    }

    func testSameClipboardTogglesOnlyItsOwnOwner() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 20)!
        let second = pins.begin(clipboardChangeCount: 21)!

        XCTAssertNil(pins.take(clipboardChangeCount: 22))
        XCTAssertEqual(pins.take(clipboardChangeCount: 21)?.owner, second)
        XCTAssertNil(pins.take(clipboardChangeCount: 21))
        XCTAssertEqual(pins.take(clipboardChangeCount: 20)?.owner, first)
    }

    func testLateDismissalCannotRemoveNewPinForSameClipboard() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 30)!
        XCTAssertEqual(pins.take(clipboardChangeCount: 30)?.owner, first)
        let second = pins.begin(clipboardChangeCount: 30)!

        pins.finish(first)
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.take(clipboardChangeCount: 30)?.owner, second)
    }

    func testClosingOlderWindowLeavesCurrentPinReachable() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 40)!
        let second = pins.begin(clipboardChangeCount: 41)!

        pins.finish(first)
        XCTAssertEqual(pins.take(clipboardChangeCount: 41)?.owner, second)
        XCTAssertEqual(pins.count, 0)
    }

    func testGlobalInvalidationDrainsEveryPinBeforeWindowTeardown() {
        var pins = PinClipboardSessionRegistry()
        let owners = (0..<12).map { pins.begin(clipboardChangeCount: $0)! }

        let drained = pins.takeAll()
        XCTAssertEqual(Set(drained.map(\.owner)), Set(owners))
        XCTAssertTrue(drained.allSatisfy { $0.phase == .presenting })
        XCTAssertEqual(pins.count, 0)
        XCTAssertTrue(pins.takeAll().isEmpty)
        owners.forEach { pins.finish($0) }
        XCTAssertEqual(pins.count, 0)
    }

    func testDuplicateBeginDoesNotOrphanExistingOwner() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 50)!

        XCTAssertNil(pins.begin(clipboardChangeCount: 50))
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.take(clipboardChangeCount: 50)?.owner, first)
    }
}
