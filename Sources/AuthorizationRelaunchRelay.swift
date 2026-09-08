import Foundation

struct AuthorizationRelaunchRelayRequest {
  let processIdentifier: Int32
  let bundleIdentifier: String
  let markerURL: URL
  var timeout: TimeInterval = 300
  var pollInterval: TimeInterval = 0.2
  var reopenDelay: TimeInterval = 0.8
  var presentationRetryDelay: TimeInterval = 3.0
  var openExecutableURL = URL(fileURLWithPath: "/usr/bin/open")
  var applicationURL: URL?
}

enum AuthorizationRelaunchRelayError: LocalizedError {
  case invalidRequest

  var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "授权重启接力参数无效。"
    }
  }
}

enum AuthorizationRelaunchRelayOutcome: Equatable {
  case reopened
  case timedOut
  case cancelled
  case failed(Int32)
}

private final class AuthorizationRelaunchRelayCompletionBox: @unchecked Sendable {
  private let completion: (AuthorizationRelaunchRelayOutcome) -> Void

  init(_ completion: @escaping (AuthorizationRelaunchRelayOutcome) -> Void) {
    self.completion = completion
  }

  func callAsFunction(_ outcome: AuthorizationRelaunchRelayOutcome) {
    completion(outcome)
  }
}

enum AuthorizationRelaunchRelay {
  @discardableResult
  static func arm(
    _ request: AuthorizationRelaunchRelayRequest,
    completion: ((AuthorizationRelaunchRelayOutcome) -> Void)? = nil
  ) throws -> Process {
    guard request.processIdentifier > 0,
      !request.bundleIdentifier.isEmpty,
      request.timeout > 0,
      request.pollInterval > 0,
      request.reopenDelay >= 0,
      request.presentationRetryDelay >= 0
    else {
      throw AuthorizationRelaunchRelayError.invalidRequest
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: request.markerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data().write(to: request.markerURL, options: .atomic)

    let maximumPolls = max(1, Int(ceil(request.timeout / request.pollInterval)))
    let completionBox = completion.map(AuthorizationRelaunchRelayCompletionBox.init)
    let relay = Process()
    relay.executableURL = URL(fileURLWithPath: "/bin/sh")
    relay.arguments = [
      "-c",
      """
      pid="$1"
      marker="$2"
      bundle="$3"
      maximum_polls="$4"
      poll_interval="$5"
      reopen_delay="$6"
      presentation_retry_delay="$7"
      open_tool="$8"
      application_path="$9"
      count=0
      while [ "$count" -lt "$maximum_polls" ]; do
        if ! /bin/kill -0 "$pid" 2>/dev/null; then
          if [ -f "$marker" ]; then
            /bin/sleep "$reopen_delay"
            if [ -n "$application_path" ] && [ -d "$application_path" ]; then
              "$open_tool" -a "$application_path"
            else
              "$open_tool" -b "$bundle"
            fi
            first_open_status=$?
            /bin/sleep "$presentation_retry_delay"
            if [ -n "$application_path" ] && [ -d "$application_path" ]; then
              "$open_tool" -a "$application_path"
            else
              "$open_tool" -b "$bundle"
            fi
            presentation_status=$?
            /bin/rm -f "$marker"
            if [ "$first_open_status" -ne 0 ]; then
              exit "$first_open_status"
            fi
            exit "$presentation_status"
          fi
          exit 0
        fi
        count=$((count + 1))
        /bin/sleep "$poll_interval"
      done
      /bin/rm -f "$marker"
      exit 124
      """,
      "authorization-relaunch-relay",
      "\(request.processIdentifier)",
      request.markerURL.path,
      request.bundleIdentifier,
      "\(maximumPolls)",
      "\(request.pollInterval)",
      "\(request.reopenDelay)",
      "\(request.presentationRetryDelay)",
      request.openExecutableURL.path,
      request.applicationURL?.path ?? "",
    ]
    relay.terminationHandler = { process in
      let outcome: AuthorizationRelaunchRelayOutcome
      switch process.terminationReason {
      case .uncaughtSignal:
        outcome = .cancelled
      case .exit:
        switch process.terminationStatus {
        case 0:
          outcome = .reopened
        case 124:
          outcome = .timedOut
        default:
          outcome = .failed(process.terminationStatus)
        }
      @unknown default:
        outcome = .failed(process.terminationStatus)
      }
      completionBox?(outcome)
    }

    do {
      try relay.run()
      return relay
    } catch {
      try? fileManager.removeItem(at: request.markerURL)
      throw error
    }
  }
}
