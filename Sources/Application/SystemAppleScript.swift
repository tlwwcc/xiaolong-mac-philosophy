import Foundation

@MainActor
enum SystemAppleScript {
  @discardableResult
  static func run(
    _ source: String,
    timeout: TimeInterval,
    completion: @escaping (Bool) -> Void
  ) -> BoundedProcessExecution {
    BoundedProcessExecution(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-e", source],
      timeout: timeout,
      outputByteLimit: 32_768
    ) { result in
      completion(result.succeeded)
    }.start()
  }

}
