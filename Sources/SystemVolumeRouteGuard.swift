import Foundation

enum SystemVolumeRouteGuard {
  static func changeVolume<Device: Equatable>(
    by delta: Double,
    maximumAttempts: Int = 3,
    defaultDevice: () -> Device?,
    currentVolume: (Device) -> Double?,
    setVolume: (Device, Double) -> Bool,
    onRouteChanged: (Device, Device) -> Void = { _, _ in }
  ) -> Double? {
    guard maximumAttempts > 0 else { return nil }

    for _ in 0..<maximumAttempts {
      guard let device = defaultDevice(), let current = currentVolume(device) else { return nil }
      guard let confirmedDevice = defaultDevice() else { return nil }
      guard confirmedDevice == device else {
        onRouteChanged(device, confirmedDevice)
        continue
      }

      let next = min(max(current + delta, 0), 100)
      if setVolume(device, next) {
        return next
      }

      guard let latestDevice = defaultDevice(), latestDevice != device else { return nil }
      onRouteChanged(device, latestDevice)
    }
    return nil
  }
}
