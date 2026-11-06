import AppKit
import SwiftUI

struct AccessibilityAuthorizationSheetView: View {
  @EnvironmentObject private var model: AppModel
  @State private var isClearPermissionConfirmationPresented = false
  @State private var isPermissionRecoveryExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        IconBadge(systemImage: "lock.shield.fill", tint: indigo, size: 40, iconSize: 17)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(
              model.allRequiredPermissionsComplete
                ? (model.authorizationRelaunchCompleted ? "权限已生效" : "权限已开启")
                : "权限设置向导"
            )
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ink)
            StatusPill(
              text: model.allRequiredPermissionsComplete ? "已开启" : "待授权",
              color: model.allRequiredPermissionsComplete ? teal : amber)
          }
          Text(
            model.allRequiredPermissionsComplete
              ? "三项必要权限均已生效。"
              : "从这里开始，按提示完成快捷键、截图所需的三项权限。"
          )
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(muted)
          .lineLimit(2)
        }

        Spacer()

        Button {
          model.dismissAuthorizationCenter()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(muted)
            .frame(width: 30, height: 30)
            .background(AppVisualStyle.surface.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(line.opacity(0.54), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("收起窗口；当前授权步骤会继续")
      }

      Label(
        model.allRequiredPermissionsComplete
          ? "所需权限均已生效。"
          : "系统设置前会出现授权卡；完成一项后会自动进入下一项。",
        systemImage: model.allRequiredPermissionsComplete
          ? "checkmark.circle.fill" : "hand.draw.fill"
      )
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(model.allRequiredPermissionsComplete ? teal : indigo)
      .fixedSize(horizontal: false, vertical: true)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(softSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(line.opacity(0.68), lineWidth: 1))

      VStack(spacing: 8) {
        AuthorizationPermissionStepRow(
          step: 1,
          title: "辅助功能",
          isGranted: model.advancedListeningAuthorized,
          isCurrent: !model.advancedListeningAuthorized)
        AuthorizationPermissionStepRow(
          step: 2,
          title: "屏幕录制",
          isGranted: model.screenRecordingAuthorized,
          isCurrent: model.advancedListeningAuthorized && !model.screenRecordingAuthorized)
        AuthorizationPermissionStepRow(
          step: 3,
          title: "输入监控",
          isGranted: model.inputMonitoringAuthorized,
          isCurrent: model.advancedListeningAuthorized && model.screenRecordingAuthorized
            && !model.inputMonitoringAuthorized)
      }

      Button {
        model.performAuthorizationPrimaryAction()
      } label: {
        Label(
          model.authorizationPrimaryButtonTitle,
          systemImage: model.authorizationManualRelaunchRequired
            ? "power.circle.fill"
            : (model.authorizationAutomaticRelaunchInProgress
              ? "arrow.clockwise.circle.fill"
              : (model.allRequiredPermissionsComplete
                ? (model.authorizationRelaunchCompleted
                  ? "checkmark.circle.fill" : "arrow.clockwise.circle.fill")
                : "lock.open.fill"))
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(
        GlassLabelButtonStyle(
          tint: model.allRequiredPermissionsComplete ? teal : indigo,
          prominent: true)
      )
      .disabled(model.authorizationPrimaryButtonDisabled)

      Text(model.authorizationPrimarySafetyText)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(muted)
        .fixedSize(horizontal: false, vertical: true)

      DisclosureGroup("权限已经打开，但功能仍不生效？", isExpanded: $isPermissionRecoveryExpanded) {
        HStack(spacing: 8) {
          Text("仅在系统权限记录失效时使用：")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)

          Button {
            isClearPermissionConfirmationPresented = true
          } label: {
            Label(
              model.isRepairingAuthorization ? "正在修复权限…" : "修复失效权限…",
              systemImage: "arrow.counterclockwise.circle")
          }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(model.isRepairingAuthorization ? muted : amber)
          .disabled(model.isRepairingAuthorization)
          .accessibilityLabel("修复本软件失效的系统权限")
          .help("清理本 App 的旧权限记录，随后自动重启并重新引导授权")
        }
        .padding(.top, 6)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !model.authorizationRepairResultText.isEmpty {
        Text(model.authorizationRepairResultText)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(10)
          .background(
            AppVisualStyle.surface.opacity(0.62),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
    .padding(20)
    .frame(width: 560)
    .background(AppBackdrop())
    .allowsApplicationTerminationWhenModal()
    .explicitPermissionClearConfirmation(
      isPresented: $isClearPermissionConfirmationPresented,
      model: model)
  }
}

struct AuthorizationPermissionStepRow: View {
  let step: Int
  let title: String
  let isGranted: Bool
  let isCurrent: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isGranted ? "checkmark.circle.fill" : "\(step).circle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(isGranted ? teal : (isCurrent ? indigo : muted.opacity(0.72)))
        .frame(width: 22)

      Text(title)
        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
        .foregroundStyle(isCurrent || isGranted ? ink : muted)

      Spacer()

      Text(isGranted ? "已完成" : (isCurrent ? "正在设置" : "稍后设置"))
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isGranted ? teal : (isCurrent ? indigo : muted))
    }
    .padding(.horizontal, 11)
    .frame(height: 38)
    .background(
      (isCurrent ? indigo.opacity(0.09) : softSurface),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isCurrent ? indigo.opacity(0.34) : line.opacity(0.58), lineWidth: 1)
    )
  }
}

struct ExplicitPermissionClearConfirmationModifier: ViewModifier {
  @Binding var isPresented: Bool
  let model: AppModel

  func body(content: Content) -> some View {
    content.alert(
      "修复本 App 的权限？",
      isPresented: $isPresented
    ) {
      Button("取消", role: .cancel) {}
      Button("清除旧记录并修复", role: .destructive) {
        model.clearAuthorizationPermissionsAndRestart(userConfirmed: true)
      }
    } message: {
      Text("会清理“小龙哥 Mac 哲学”的辅助功能、屏幕录制和输入监控旧记录，不影响其他 App。软件随后会自动重启，并重新引导你打开系统开关。")
    }
  }
}

extension View {
  func explicitPermissionClearConfirmation(
    isPresented: Binding<Bool>,
    model: AppModel
  ) -> some View {
    modifier(
      ExplicitPermissionClearConfirmationModifier(
        isPresented: isPresented,
        model: model))
  }
}
