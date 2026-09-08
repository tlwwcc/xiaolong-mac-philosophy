#if canImport(PlatformContracts)
  import ApplicationServices
  import CoreGraphics
  import Foundation
  import PlatformContracts

  /// All product features are free. System permissions remain separate.
  struct FreeFeatureAccessAdapter: EntitlementChecking {
    func decision(for request: FeatureEntitlementRequest) -> FeatureAccessDecision {
      .allowed
    }
  }

  struct HostFeaturePermissionAdapter: PermissionChecking {
    func decision(for request: FeaturePermissionRequest) -> FeatureAccessDecision {
      switch request.permissionID {
      case .screenRecording:
        return CGPreflightScreenCaptureAccess()
          ? .allowed
          : .denied("需要开启屏幕录制权限。")
      case .inputMonitoring:
        return CGPreflightListenEventAccess()
          ? .allowed
          : .denied("需要开启输入监控权限。")
      case .accessibility:
        return AXIsProcessTrusted()
          ? .allowed
          : .denied("需要开启辅助功能权限。")
      case .userSelectedFiles:
        // The feature still opens a user-controlled NSOpenPanel before reading a document.
        return .allowed
      case .microphone:
        return .denied("当前宿主尚未接入麦克风授权路由。")
      default:
        return .denied("未知系统权限，动作未执行。")
      }
    }
  }
#endif
