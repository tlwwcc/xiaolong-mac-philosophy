import Foundation

enum SleepStatusToggleAction: Equatable {
  case startInfinite
  case stop
}

func sleepStatusToggleAction(isAwake: Bool) -> SleepStatusToggleAction {
  isAwake ? .stop : .startInfinite
}
