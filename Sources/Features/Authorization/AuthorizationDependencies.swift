import AppKit
import ApplicationServices
import Foundation

enum AuthorizationTerminationIntent: Equatable {
  case ordinary
  case authorizationRelaunch(UUID)
  case systemAuthorizationRelaunch(UUID)

  var relayToken: UUID? {
    switch self {
    case .ordinary: return nil
    case .authorizationRelaunch(let token), .systemAuthorizationRelaunch(let token): return token
    }
  }
}

extension AuthorizationWorkspace {
  struct Context {
    let bundleIdentifier: String
    let expectedBundleIdentifier: String
    let applicationURL: URL
    let displayName: String
    let supportDirectory: URL
    let isInstalledInApplications: Bool
    let allowsStablePermissionRepair: Bool
    let isInvalid: Bool
    let processIdentifier: Int32

    static func live(_ identity: AppRuntimeIdentity) -> Context {
      let applicationURL = Bundle.main.bundleURL
      return Context(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? identity.bundleIdentifier,
        expectedBundleIdentifier: identity.bundleIdentifier,
        applicationURL: applicationURL,
        displayName: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
          ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
          ?? applicationURL.deletingPathExtension().lastPathComponent,
        supportDirectory: FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appendingPathComponent(identity.applicationSupportDirectoryName, isDirectory: true),
        isInstalledInApplications: applicationURL.standardizedFileURL.path
          == identity.installURL.standardizedFileURL.path,
        allowsStablePermissionRepair: identity.allowsStablePermissionRepair,
        isInvalid: identity.isInvalid,
        processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }
  }

  @MainActor
  struct ProcessHandle {
    let start: () -> Void
    let cancel: () -> Void
  }

  @MainActor
  struct RelayHandle {
    let isRunning: () -> Bool
    let cancel: () -> Void
    /// Detach delivery only: an accepted relay must keep running after the source App exits.
    let detach: () -> Void
  }

  @MainActor
  struct Dependencies {
    var context: Context?
    var now: () -> Date = Date.init
    var snapshot: () -> AuthorizationPermissionSnapshot = {
      AuthorizationPermissionSnapshot(accessibility: AXIsProcessTrusted(),
        inputMonitoring: CGPreflightListenEventAccess(),
        screenRecording: CGPreflightScreenCaptureAccess())
    }
    var requestOfficialPermission: (AuthorizationRepairService) -> Bool = { service in
      switch service {
      case .accessibility:
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
      case .screenRecording: return CGRequestScreenCaptureAccess()
      case .inputMonitoring: return CGRequestListenEventAccess()
      }
    }
    var schedule: AuthorizationFlowSession.Scheduler = AuthorizationFlowSession.scheduleOnMain
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var showGuide: (AuthorizationRepairService, Int, Int, @escaping @MainActor () -> Void) -> Void = {
      service, step, total, register in
      AuthorizationDragGuideController.shared.show(
        for: service, step: step, total: total, onRegister: register)
    }
    var hideGuide: () -> Void = { AuthorizationDragGuideController.shared.hide() }
    var hideDragPrompt: () -> Void = {
      AuthorizationDragGuideController.shared.hideDragPromptIfNeeded()
    }
    var startPromptMonitor: (String, AuthorizationRepairService, @escaping @MainActor () -> Void) -> Void = {
      name, service, callback in
      AuthorizationSystemRelaunchPromptMonitor.shared.start(
        applicationDisplayName: name, service: service
      ) { Task { @MainActor in callback() } }
    }
    var stopPromptMonitor: () -> Void = { AuthorizationSystemRelaunchPromptMonitor.shared.stop() }
    /// The factory constructs without starting, so ownership is installed before synchronous completion.
    var makeProcess: (
      URL, [String], TimeInterval, Int, @escaping @MainActor (BoundedProcessResult) -> Void
    ) -> ProcessHandle = { executable, arguments, timeout, limit, completion in
      let process = BoundedProcessExecution(executableURL: executable, arguments: arguments,
        timeout: timeout, outputByteLimit: limit, completion: completion)
      return ProcessHandle(start: { process.start() }, cancel: { process.cancel() })
    }
    var armRelay: (
      AuthorizationRelaunchRelayRequest, @escaping @MainActor (AuthorizationRelaunchRelayOutcome) -> Void
    ) throws -> RelayHandle = { request, completion in
      let process = try AuthorizationRelaunchRelay.arm(request) { outcome in
        Task { @MainActor in completion(outcome) }
      }
      return RelayHandle(
        isRunning: { process.isRunning },
        cancel: { if process.isRunning { process.terminate() } },
        detach: { process.terminationHandler = nil })
    }
    var markerExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    var removeMarker: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
  }
}
