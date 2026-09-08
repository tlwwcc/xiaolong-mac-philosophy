# 小龙哥 Mac 哲学

**左手掌控 Mac。全部功能免费，源码开放。**

把常用操作放到顺手的位置：Caps 快捷键、应用启动、窗口切换、快捷短语、剪贴板历史、鼠标与滚轮、菜单栏状态，以及游目截图与 OCR、披卷 PDF 阅读、听澜音频播放。

[下载官方版与使用教程](https://aixlg.com/mac/) · [认识小龙哥](https://aixlg.com/)

软件功能无需购买、邀请续时、账号或登录激活。感谢最初购买或接受赠送、支持小龙哥的朋友；既有的长期 AI 答疑承诺继续保留，可通过[联系与支持入口](https://aixlg.com/support.html)联系小龙哥。

如果它替你省了事，欢迎告诉朋友、分享自己的用法，或给项目点一颗 Star。一个真实的使用场景，比复杂的邀请规则更有价值。

## 源码范围

此仓库包含主 App、两个状态辅助进程、平台模块，以及游目、披卷、听澜的完整客户端实现。听澜源码位于主 App 的 `Sources/AIPlayer*.swift`。

| 目录 | 内容 |
| --- | --- |
| `Sources/` | 主 App、系统交互、窗口、设置、听澜 |
| `HelperSources/`、`SleepStatusHelperSources/` | 菜单栏状态辅助进程 |
| `Platform/` | 功能契约、注册与测试 |
| `IntegratedFeatures/YoumuFeature/` | 游目截图、OCR、长截图、翻译与测试 |
| `IntegratedFeatures/PijuanPDFFeature/` | 披卷 PDF 阅读 |
| `Resources/` | App 元数据、图标与内置脚本 |

源码来自独立的洁净快照，不含历史仓库、用户数据、早期支持者名单、支付后台、签名私钥或生产部署配置。软件不依赖这些资料来编译。

## 开发

在支持 Swift 6.2 或更新工具链的 macOS 上：

```sh
./scripts/check.sh
```

该命令编译完整主 App、辅助进程及功能模块，并运行独立测试，不安装或启动 App。具体环境与编译产物见 [BUILDING.md](BUILDING.md)。普通用户直接下载官方签名、公证的安装包。

发现问题或有改进想法，欢迎提交 Issue 或 Pull Request。报告问题时请描述复现步骤、预期与实际结果、macOS 和软件版本；不要附上私人剪贴板、证书或密钥。

## 许可证

第一方主代码与本文档采用 [MIT](LICENSE)，允许学习、修改、再分发与商业使用，并保留版权和许可证。披卷保留原有 Apache-2.0；游目中的 Snapzy 适配代码及 Sparkle 保留各自许可证。详见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 [品牌说明](TRADEMARKS.md)。
