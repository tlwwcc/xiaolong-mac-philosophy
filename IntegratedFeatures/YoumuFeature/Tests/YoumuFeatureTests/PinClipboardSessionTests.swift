import Testing

@testable import YoumuFeature

@MainActor
@Suite(.serialized)
final class PinClipboardSessionTests {
    @Test
    func testNewClipboardKeepsAllEarlierOwners() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 10)!
        let second = pins.begin(clipboardChangeCount: 11)!
        let third = pins.begin(clipboardChangeCount: 12)!

        #expect((pins.count) == (3))
        #expect((pins.take(clipboardChangeCount: 11)?.owner) == (second))
        #expect((pins.count) == (2))
        #expect((Set(pins.takeAll().map(\.owner))) == (Set([first, third])))
    }

    @Test
    func testSameClipboardTogglesOnlyItsOwnOwner() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 20)!
        let second = pins.begin(clipboardChangeCount: 21)!

        #expect((pins.take(clipboardChangeCount: 22)) == nil)
        #expect((pins.take(clipboardChangeCount: 21)?.owner) == (second))
        #expect((pins.take(clipboardChangeCount: 21)) == nil)
        #expect((pins.take(clipboardChangeCount: 20)?.owner) == (first))
    }

    @Test
    func testLateDismissalCannotRemoveNewPinForSameClipboard() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 30)!
        #expect((pins.take(clipboardChangeCount: 30)?.owner) == (first))
        let second = pins.begin(clipboardChangeCount: 30)!

        pins.finish(first)
        #expect((pins.count) == (1))
        #expect((pins.take(clipboardChangeCount: 30)?.owner) == (second))
    }

    @Test
    func testClosingOlderWindowLeavesCurrentPinReachable() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 40)!
        let second = pins.begin(clipboardChangeCount: 41)!

        pins.finish(first)
        #expect((pins.take(clipboardChangeCount: 41)?.owner) == (second))
        #expect((pins.count) == (0))
    }

    @Test
    func testGlobalInvalidationDrainsEveryPinBeforeWindowTeardown() {
        var pins = PinClipboardSessionRegistry()
        let owners = (0..<12).map { pins.begin(clipboardChangeCount: $0)! }

        let drained = pins.takeAll()
        #expect((Set(drained.map(\.owner))) == (Set(owners)))
        #expect(drained.allSatisfy { $0.phase == .presenting })
        #expect((pins.count) == (0))
        #expect(pins.takeAll().isEmpty)
        owners.forEach { pins.finish($0) }
        #expect((pins.count) == (0))
    }

    @Test
    func testDuplicateBeginDoesNotOrphanExistingOwner() {
        var pins = PinClipboardSessionRegistry()
        let first = pins.begin(clipboardChangeCount: 50)!

        #expect((pins.begin(clipboardChangeCount: 50)) == nil)
        #expect((pins.count) == (1))
        #expect((pins.take(clipboardChangeCount: 50)?.owner) == (first))
    }
}
