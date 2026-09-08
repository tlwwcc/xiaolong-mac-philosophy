import Foundation

struct CarbonHotkeyPressGate {
  private(set) var heldIDs = Set<UInt32>()

  mutating func begin(id: UInt32) -> Bool {
    heldIDs.insert(id).inserted
  }

  mutating func end(id: UInt32) -> Bool {
    heldIDs.remove(id) != nil
  }

  mutating func reset() {
    heldIDs.removeAll()
  }
}
