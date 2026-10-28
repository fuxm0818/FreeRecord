# 贡献指南

先说结论：**这个项目没有第三方依赖，不需要 Xcode 工程文件，`swift build` 就能跑起来。** 唯一的硬性前置是 Xcode 16+（`Package.swift` 用了 `swift-tools-version: 6.0`）。

## 环境

```bash
xcode-select -p                  # 应指向 Xcode，而不是 CommandLineTools 单独安装
swift --version                  # 需要 Swift 6.x
```

如果只有 Command Line Tools，`swift build` 会因缺少 macOS SDK 里的 ScreenCaptureKit / CoreAudio 头文件而失败——装上完整 Xcode 即可，本项目不做兼容。

## 本地开发循环

```bash
swift build                        # 最快的编译/类型检查（只编当前架构）
bash scripts/build.sh              # 完整通用二进制 → dist/FreeRecord.app
open dist/FreeRecord.app           # 运行（推荐：LSUIElement 菜单栏 App 必须以 .app 形式运行才规范）
```

几个会反复用到的点：

- 直接跑 `swift run FreeRecordApp` 也能启动，但会被系统当成裸可执行文件，权限、图标、`Info.plist` 文案都不对，**排查权限问题时不要这样跑**。
- FreeRecord 常驻菜单栏，关窗口不算退出。改完代码要**真正退出旧进程**再看新行为（右键菜单栏图标 → 退出，或 `pkill -x FreeRecord`）。
- 每次重新构建都可能触发录屏授权问题，**先跑一次 `bash scripts/create-signing-cert.sh`**（只在你本机钥匙串建一张自签名证书，一次性动作），之后 `build.sh` 会自动用它签名，授权可跨构建保留。原理见 [docs/PERMISSIONS.md](docs/PERMISSIONS.md)。
- 看日志：`log stream --predicate 'process == "FreeRecord"' --level info`。

## 代码约定

- Swift 5 语言模式（`swiftSettings: [.swiftLanguageMode(.v5)]`，三个 target 都设了），别在 PR 里顺手升到 Swift 6 严格并发。
- UI 相关类型标 `@MainActor`；内核里的共享状态用 `NSLock` 保护，不要在锁里调用 async 上下文（编译器会警告，警告要清零）。
- 界面文案、错误提示、代码注释统一中文；标识符、日志 tag 用英文。
- 不引入第三方库。这个项目的卖点之一就是"零依赖、单包 6900 行能读懂"。
- 格式化没有强制工具，跟随所在文件的既有风格；不要提交与功能无关的全文件格式化。

## 动手前必读的两个坑

1. **新增任何悬浮窗/面板，必须同时做两件事**，否则会把自家 UI 录进视频里：
   - 窗口标题带上 `ScreenCapture.swift` 里 `hiddenWindowTitle` 约定的零宽字符标记；
   - 设置 `sharingType = .none`。
   内核过滤自身窗口的两条规则缺一不可（`windowLayer >= 1000` 的另一条只覆盖系统级浮层）。
2. **坐标系有三套**：AppKit 的全局坐标（原点左下）、`CGWindowList` 的坐标（原点左上）、`SCStreamConfiguration.sourceRect` 用的像素坐标。区域录制相关改动要同时验证 Retina（2x）和外接显示器（非整数缩放）两种情况。

完整的数据流和模块职责在 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 分支与 PR

```
main      ← 只接受来自 develop 的合并，代表可发布状态
develop   ← 日常开发主干
feat/*    ← 从 develop 切出，改完提 PR 回 develop
fix/*     ← 同上
```

PR 检查清单：

- [ ] `swift build` 无错误、无警告
- [ ] `bash scripts/build.sh` 能通过，`lipo -info` 显示 `x86_64 arm64`
- [ ] 手动跑过受影响的功能（见下面的回归清单）
- [ ] 用户可见的变化同步更新了 README / CHANGELOG
- [ ] 没有把 `dist/`、`.build*`、本地私有文件提交进来（`git status --ignored` 检查）

## 测试现状（诚实版）

**目前没有自动化测试**，CI 只做编译与打包。录屏这类功能强依赖系统权限和真实屏幕，单元测试收益有限，所以采用手工回归清单：

| 场景 | 怎么验 |
|---|---|
| 整屏 / 窗口 / 区域录制 | 各录 10 秒，检查画面范围与清晰度 |
| 四种音频 | 录一段有系统声音 + 说话的内容，用播放器确认两条音轨 |
| 暂停 / 继续 | 暂停 30 秒后继续，成片时长不应包含暂停时间 |
| 停止保存 | 停止后确认文件可播放；异常中断也应保留可播放片段 |
| 多显示器 | 主屏与副屏各选一次区域，检查坐标是否跑偏 |
| 自己的 UI 不被录进 | 录制时悬浮条/选区层不应出现在成片里 |
| macOS 12 路径 | 需要 BlackHole 的系统声音分支（Retina 老机型实测） |

改内核（`Sources/FreeRecordCore`）时，请至少跑一遍前两行 + 暂停 + 成片可播放。

## 发布

日常发布（无需 Apple 账号，产物需右键打开一次）：

1. 在 `Resources/App-Info.plist` 里同步升 `CFBundleShortVersionString`（如 `0.3.0`）和 `CFBundleVersion`（整数 +1）
2. 在 `CHANGELOG.md` 顶部加一节
3. PR 合并进 `develop`，本地验证无误后合并 `develop → main`
4. 打 tag 并推送，CI 会自动构建 dmg/zip 并创建 GitHub Release：

   ```bash
   git tag -a v0.3.0 -m "FreeRecord 0.3.0"
   git push origin v0.3.0
   ```

想要"双击即开、不被 Gatekeeper 拦"的正式分发，需要 **Apple Developer Program（99 美元/年）** 的 Developer ID 证书，并在仓库 → Settings → Secrets and variables → Actions 里配置：

| Secret | 内容 |
|---|---|
| `DEVELOPER_ID_P12` | Developer ID Application 证书导出的 .p12，base64 后粘贴 |
| `DEVELOPER_ID_P12_PASS` | 该 .p12 的口令 |
| `DEVELOPER_ID_NAME` | 证书全名，如 `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_API_KEY_ID` / `NOTARY_API_ISSUER_ID` / `NOTARY_API_KEY` | App Store Connect API 密钥三件套，`NOTARY_API_KEY` 放 .p8 文件的文本内容 |

`.github/workflows/build.yml` 里两个标记「可选」的步骤会**自动检测这些 secrets 是否存在**：没配就跳过（走 ad-hoc 签名），配了就走 Developer ID 签名 + 公证 + staple。首次配置后建议手动触发一次 `workflow_dispatch` 验证整条链路。

生成 base64 证书：

```bash
base64 -i devID.p12 | pbcopy
```

## Issue

- Bug 报告请用 `.github/ISSUE_TEMPLATE` 里的表单，务必带上 macOS 版本、机型架构、是否重装过 App。
- 「录制黑屏」「授权失效」两类问题，先读 [docs/PERMISSIONS.md](docs/PERMISSIONS.md) 再开 issue——绝大多数是签名身份变化导致的。
