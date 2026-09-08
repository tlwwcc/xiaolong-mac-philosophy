# 第三方与既有许可证

根目录 MIT 许可证不替代下列组件各自的授权。

| 组件 | 使用方式 | 许可证与来源 |
| --- | --- | --- |
| Sparkle 2.9.6 | SwiftPM 直接依赖；自动更新框架 | [上游完整许可](https://github.com/sparkle-project/Sparkle/blob/2.9.6/LICENSE)；本仓库完整副本 [ThirdParty/Sparkle/LICENSE](ThirdParty/Sparkle/LICENSE)，含其外部 BSD、MIT、Zlib 声明 |
| Snapzy 滚动截图拼接器 | 游目 `ScrollStitcher.swift` 的有署名适配；提交 `0405020e23598fa23aa5d530af3570aac2d3b292` | BSD-3-Clause；[原始许可](https://github.com/duongductrong/Snapzy/blob/0405020e23598fa23aa5d530af3570aac2d3b292/LICENSE)，完整声明保留于 [游目声明](IntegratedFeatures/YoumuFeature/THIRD_PARTY_NOTICES.md) |
| 披卷 PDF 功能 | 既有第一方 Apache-2.0 模块 | [LICENSE](IntegratedFeatures/PijuanPDFFeature/LICENSE)、[NOTICE](IntegratedFeatures/PijuanPDFFeature/NOTICE) 与 [品牌说明](IntegratedFeatures/PijuanPDFFeature/TRADEMARKS.md) 原样保留；宿主化改动见模块 [SOURCE_ORIGIN.md](IntegratedFeatures/PijuanPDFFeature/SOURCE_ORIGIN.md) |
| Apple 系统框架、系统 sqlite3 | 链接 macOS 自带框架/库 | 属于系统 SDK 与运行环境，不在本仓库重新许可或分发 SDK |
| mpv | 用户另行安装后可选调用的进程 | 本仓库不含其源码或二进制；如另行分发 mpv，须遵守该构建适用的 [mpv 许可](https://github.com/mpv-player/mpv/blob/master/Copyright) |

Sparkle 固定提交为 `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`，不跟随浮动版本。

游目其余代码来自小龙哥维护的既有第一方实现，并作为主项目完整客户端源码公开。听澜采用本机 AVFoundation 与可选 mpv IPC；没有把 mpv 源码复制进主 App。

分发构建后的 App 时，应随包保留根目录 LICENSE、本文，以及所有适用的组件 LICENSE/NOTICE。在线翻译与语音服务属于外部服务调用，不因本项目开源而获得其服务或商标授权。
