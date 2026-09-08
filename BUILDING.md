# 从源码构建

## 环境

- macOS 与 Apple Silicon；App 最低系统版本为 macOS 13。
- Swift 6.2 或更新版本，以及包含 Translation、ScreenCaptureKit 等框架的 macOS SDK（macOS 15 或更新 SDK）。单独编译可使用合适版本的 Command Line Tools；运行 XCTest 需要完整 Xcode。
- 首次解析需要联网从 GitHub 获取锁定的 Sparkle 2.9.6。`Package.resolved` 固定版本与提交，构建不得自行更新依赖。

```sh
swift --version
xcrun --show-sdk-path
./scripts/check.sh
```

`check.sh` 编译主 App `aixlg-hotkeys`、网速与状态辅助进程 `aixlg-network-speed-status`、保持清醒辅助进程 `aixlg-sleep-status`，并执行游目和平台模块测试。源码中已包含披卷与听澜的真实实现。输出在 `.build/` 与 `Platform/.build/`，无需付费许可、私人路径、会员服务或签名凭据。

若当前 `xcode-select` 指向 Command Line Tools，`check.sh` 会在标准路径存在完整 Xcode 时，仅为本次子进程设置 `DEVELOPER_DIR`；不更改全局选择。Xcode 安装在其他位置时，可显式运行 `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./scripts/check.sh`。

只编译完整产品：

```sh
./scripts/build-source.sh
```

## 编译与安装的区别

SwiftPM 产物是编译验证产物，不是签名和公证的可安装 App。入口会拒绝缺少正确 Bundle 元数据的裸可执行文件，因此不要使用 `swift run`。本构建脚本不创建第二种 App 身份、不安装、不启动，也不修改现有软件的数据与权限。

官方 App 保持唯一 Bundle ID `cn.tlww.aixlg.hotkeys`，并由同一官方 Developer ID 身份完成签名、公证和安装。官方分发所需的证书、私钥、描述文件与 Apple 账号属于发行者，不随源码公开。正式更新的信任锚与公钥是公开验证材料，不是购买凭据。

若要贡献改动，可先完成源码编译与测试，再提交 Pull Request。涉及全局快捷键、窗口层级、系统权限或真实键鼠体验的改动，仍需在官方候选的实际设备上验收；编译通过不代表这些体验已验证。

## 可选外部服务

- 听澜常见音频使用 Apple AVFoundation；视频或其他扩展格式可调用用户自行安装的 `/opt/homebrew/bin/mpv`。仓库不包含 mpv 二进制，构建与常见音频播放不需要它。
- 游目截图、OCR 与 PDF 阅读使用本机 Apple 框架。第三方在线翻译需用户自行配置服务与凭据，服务商可能另行收费；App 免费不代表第三方 API 免费。
- 在线语音是可选服务能力，可能随服务提供方协议变化而失效；客户端保留本机语音回退。
- 官方自动更新、反馈与帮助入口可使用官方服务；客户端没有会员登录、许可恢复或购买系统，本机功能无需账号。

## 独立测试

```sh
swift test --only-use-versions-from-resolved-file
swift test --package-path Platform
```

测试使用测试进程；不安装或启动主 App。

游目有两项真实浏览器截图夹具测试，分别需要 `YOUMU_REAL_FIXTURE_DIR` 与 `YOUMU_REAL_FIXED_OVERLAY_FIXTURE_DIR` 指向当次受控截帧；未提供时 XCTest 明确跳过。它们不使用仓库外的私人默认路径，普通源码测试通过也不等于真实浏览器长截图验收。
