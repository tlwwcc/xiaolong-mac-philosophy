import Foundation

enum SystemVolumeRouteGuard {
  static func changeVolume<Device: Equatable>(
    by delta: Double,
    maximumAttempts: Int = 3,
    defaultDevice: () -> Device?,
    currentVolume: (Device) -> Double?,
    setVolume: (Device, Double) -> Bool,
    unmute: (Device) -> Bool,
    onRouteChanged: (Device, Device) -> Void = { _, _ in }
  ) -> Double? {
    guard maximumAttempts > 0, delta.isFinite else { return nil }

    for _ in 0..<maximumAttempts {
      guard let device = defaultDevice(), let current = currentVolume(device),
        current.isFinite, (0...100).contains(current)
      else { return nil }
      guard let confirmedDevice = defaultDevice() else { return nil }
      guard confirmedDevice == device else {
        onRouteChanged(device, confirmedDevice)
        continue
      }

      let next = min(max(current + delta, 0), 100)
      let written = setVolume(device, next)
      guard let writtenDevice = defaultDevice() else { return nil }
      guard writtenDevice == device else {
        onRouteChanged(device, writtenDevice)
        continue
      }
      guard written else { return nil }

      guard let applied = currentVolume(device), applied.isFinite,
        (0...100).contains(applied), let appliedDevice = defaultDevice()
      else { return nil }
      guard appliedDevice == device else {
        onRouteChanged(device, appliedDevice)
        continue
      }
      // Do not unmute an old level when a driver ignored the scalar write.
      guard abs(next - current) < 0.001 || abs(applied - current) >= 0.001 else {
        return nil
      }

      // A scalar write does not clear Core Audio's separate mute control.
      // Write the intended level first so unmuting cannot expose an old loud level.
      guard next == 0 || unmute(device) else { return nil }
      guard let audibleDevice = defaultDevice() else { return nil }
      guard audibleDevice == device else {
        onRouteChanged(device, audibleDevice)
        continue
      }

      guard let actual = currentVolume(device), actual.isFinite,
        (0...100).contains(actual), let finalDevice = defaultDevice()
      else { return nil }
      guard finalDevice == device else {
        onRouteChanged(device, finalDevice)
        continue
      }

      // Drivers can acknowledge a write without applying it, and hardware may
      // round scalar values. Feedback must use the observed level, not `next`.
      guard abs(next - current) < 0.001 || abs(actual - current) >= 0.001 else {
        return nil
      }
      return actual
    }
    return nil
  }
}
