import AppKit
import SwiftUI

struct ScrollPanelView: View {
  @EnvironmentObject private var model: AppModel

  private var settings: ScrollEngineSettings {
    model.scrollSettings
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 14) {
        IconBadge(systemImage: "scroll.fill", tint: accent, size: 44, iconSize: 19)

        HStack(spacing: 8) {
          Text("滚动手感")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(ink)
          StatusPill(
            text: model.scrollEngineRunning ? "运行中" : "未启用",
            color: model.scrollEngineRunning ? teal : amber)
        }

        Spacer()

        Toggle(
          "",
          isOn: Binding(
            get: { settings.enabled },
            set: { model.setScrollEngineEnabled($0) }
          )
        )
        .toggleStyle(.switch)
      }

      VStack(alignment: .leading, spacing: 12) {
        MosCheckRow(
          label: "平滑滚动",
          title: "启用 Mos-like 丝滑滚动",
          isOn: settings.smooth,
          set: { value in
            model.updateScrollSettings { settings in settings.smooth = value }
          })
        MosCheckRow(
          label: "反转滚动",
          title: "反转滚轮方向",
          isOn: settings.reverseVertical && settings.reverseHorizontal,
          set: { value in
            model.updateScrollSettings { settings in
              settings.reverseVertical = value
              settings.reverseHorizontal = value
            }
          })
        MosCheckRow(
          label: "设备",
          title: "触控板始终保持系统原样",
          isOn: true,
          set: { _ in
            model.updateScrollSettings { settings in
              settings.affectTrackpad = false
            }
          }
        )
        .disabled(true)
        .opacity(0.72)
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        MosKeyRow(
          label: "加速键",
          keyText: "⌥",
          help: "长页面滚动加速")
        MosKeyRow(
          label: "转换键",
          keyText: "⇧",
          help: "垂直滚动转水平")
        MosKeyRow(
          label: "禁用键",
          keyText: "⌘",
          help: "临时绕过接管")
      }

      Divider()

      VStack(alignment: .leading, spacing: 14) {
        MosSliderRow(
          title: "最短步长",
          value: settings.step,
          range: 8.0...60.0,
          help: "单次滚动最短距离"
        ) { nextValue in
          model.updateScrollSettings { settings in settings.step = nextValue }
        }
        MosSliderRow(
          title: "速度增益",
          value: settings.speed,
          range: 0.5...5.0,
          help: "持续滚动速度"
        ) { nextValue in
          model.updateScrollSettings { settings in settings.speed = nextValue }
        }
        MosSliderRow(
          title: "持续时间",
          value: settings.duration,
          range: 1.0...6.0,
          help: "滚动缓动时间"
        ) { nextValue in
          model.updateScrollSettings { settings in settings.duration = nextValue }
        }
      }

      HStack(spacing: 10) {
        ScrollMetric(title: "参数", value: "稳定方向")
        ScrollMetric(title: "范围", value: settings.affectTrackpad ? "鼠标和触控板" : "仅鼠标滚轮")
        Spacer()
        Button {
          model.applyMosScrollPreset()
        } label: {
          Label("恢复稳定手感", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(GlassLabelButtonStyle(tint: teal, prominent: false))
      }
    }
    .padding(16)
    .premiumPanel(radius: 17)
    .onAppear {
      model.refreshLegacyScrollProfile()
      model.reloadScrollEngine()
    }
  }

}
