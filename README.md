# FreeRecord（自由录屏）

免费、开源、无水印、无时长限制的 macOS 录屏工具。常驻菜单栏，支持整屏 / 窗口 / 区域录制，麦克风与系统声音可单独或同时录制。

[English](#english) · [下载 Release](https://github.com/fuxm0818/FreeRecord/releases) · [权限说明](docs/PERMISSIONS.md) · [架构说明](docs/ARCHITECTURE.md)

![license](https://img.shields.io/badge/license-MIT-blue)
![platform](https://img.shields.io/badge/macOS-12.3%2B-000000?logo=apple)
![build](https://img.shields.io/github/actions/workflow/status/fuxm0818/FreeRecord/build.yml?branch=main&label=build)

---

## 为什么做这个

macOS 上顺手录一段屏，常常卡在三件事：商业软件带水印或限时、开源方案要装一堆依赖、系统自带的 `screencapture -v` 不能选区域也不能录系统声音。FreeRecord 想做的事很直接——**一个几百 KB 的原生 App，装完就能录，录完就是能直接发的文件**。

交互流程参考了主流录屏软件的通用选取与浮条模式，并在几处做了改进：录制中浮条可暂停/截图、区域框选后可继续拖动微调、菜单栏直接显示彩色计时。

## 功能

- **三种画面来源**：整屏、单个窗口、任意区域（悬停自动吸附窗口，拖拽框选，框选完成后仍可 8 向手柄调整）
- **四种声音**：静音 / 麦克风 / 系统声音 / 麦克风 + 系统声音（双音轨，后期可分轨剪辑）
- **常驻菜单栏** + 悬浮控制条：录制计时、暂停 / 继续、截屏、停止并保存
- **倒计时**（3-2-1，可关）、**鼠标点击高亮**（可开，不需要「辅助功能」权限）
- **快捷键**：<kbd>⌥⌘R</kbd> 开始 / 停止录制，<kbd>⌥⌘P</kbd> 暂停 / 继续
- **输出**：H.264 MP4（分片写入，中途异常也不丢已录内容），可无损转封装为 MOV
- **分辨率与帧率**：原始 / 1080P / 720P，15 / 30 / 60 fps
- 摄像头录制、纯录音模式、录制完成预览、开机自启
- **零遥测**：不联网、不上传，文件只落在你选的目录（默认 `~/Movies/自由录屏`）

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS 12.3 及以上（Apple 芯片与 Intel 通用二进制，2015 款 Intel MacBook Pro 实测目标机型） |
| 屏幕录制权限 | 必需，[授权步骤](docs/PERMISSIONS.md#屏幕录制授权步骤) |
| 麦克风 / 摄像头权限 | 使用对应功能时必需 |
| 系统声音 | macOS 13+ 直接采集；**macOS 12 需额外安装免费开源的 [BlackHole](https://existential.audio/blackhole/) 虚拟声卡**，App 内有引导入口 |

录制 DRM 保护的播放器窗口时，系统接口本身会返回黑屏——这是 macOS 的限制，不是本项目的 bug。

## 安装

1. 到 [Releases](https://github.com/fuxm0818/FreeRecord/releases) 下载 `FreeRecord-x.y.z.dmg`
2. 打开后把 `FreeRecord.app` 拖进 `Applications`
3. 当前版本用自签名 / ad-hoc 签名，首次打开会被 Gatekeeper 拦一次：
   **右键图标 →「打开」→「打开」**（或系统设置 → 隐私与安全性 → 仍要打开）
4. 按提示授予「屏幕录制」权限，完全退出 App 再打开

> 想要双击直接打开、不弹拦截，需要 Apple Developer ID 签名 + 公证（付费账号）。CI 已预留这一步，见 [CONTRIBUTING.md](CONTRIBUTING.md#发布)。

## 从源码构建

前置：Xcode 16 及以上（需要 Swift 6 工具链来解析 `swift-tools-version: 6.0`）、命令行开发者工具。无第三方依赖，无需 `pod`/`npm install`。

```bash
git clone https://github.com/fuxm0818/FreeRecord.git
cd FreeRecord

# 只想要当前架构的可执行文件（最快）
swift build

# 打成能直接双击运行的通用二进制 .app（arm64 + x86_64）
bash scripts/build.sh          # 产物：dist/FreeRecord.app

# 再打一个可拖拽安装的 dmg
bash scripts/make-dmg.sh       # 产物：dist/FreeRecord-<版本>.dmg

# 建议：创建一张本机自签名证书，这样每次重新构建不会丢失屏幕录制授权
bash scripts/create-signing-cert.sh
```

构建产物性能压测工具（会生成耗时/内存/CPU 报告）：

```bash
bash scripts/build-poc.sh      # 产物：dist/FreeRecordPOC.app
```

## 目录结构

```
Package.swift                 SwiftPM 清单，三个 target，无第三方依赖
Sources/FreeRecordCore/       录制内核：ScreenCaptureKit 采集、AVAssetWriter 写入、音频设备
Sources/FreeRecordApp/        正式 App：菜单栏、选区层、悬浮条、设置、保存与预览
Sources/FreeRecordPOC/        性能压测与内核验证工具（保留用于 Intel 机型实测）
Resources/                    Info.plist、entitlements
scripts/                      build.sh / make-dmg.sh / create-signing-cert.sh / build-poc.sh
docs/                         权限说明、架构说明
.github/workflows/            自动打包与发布
```

想先了解实现细节再动手，读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)；准备提 PR 前读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 常见问题

**已经授权过了，为什么还提示我去授权？**
macOS 的录屏授权按**代码签名身份**记录。ad-hoc 签名每次重新构建都会变，旧授权随之失效（系统设置里的开关看着仍是开的，那是残留显示）。用 `bash scripts/create-signing-cert.sh` 建立稳定身份，或用 App 内「重置授权记录」后重新授权一次。详见 [docs/PERMISSIONS.md](docs/PERMISSIONS.md#为什么每次重新打包授权就莫名其妙失效了)。

**打开 dmg 提示"无法验证开发者"？**
正常，见上面安装第 3 步。右键 →「打开」只需做一次。

**系统声音录不到 / 选项是灰的？**
macOS 12 需要安装 BlackHole；装完在「声音设置」里确认可见，再重启 App。macOS 13+ 无需任何额外安装。

**录制的画面是全黑的？**
DRM 保护内容（部分播放器、私密窗口）会返回黑屏；另一种可能是刚重新构建导致授权失效。

**停止后保存失败？**
分片 MP4 的索引写在文件头，即使收尾失败，已录内容通常仍可播放。App 会自动检测并保留可播放的文件，不会让你白录。

**怎么卸载？**
把 `FreeRecord.app` 移出 `Applications`，再执行 `tccutil reset ScreenCapture com.fuxiangming.freerec` 清掉授权记录。录制产物都在你自己的目录里。

## 参与

- 日常开发在 `develop` 分支，验证通过后合并 `main`；`main` 上打 `v*` tag 会由 CI 自动发布 Release。
- Bug 与功能请求欢迎开 Issue，改动请提 PR，先读 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 新手友好标签：内核和 UI 的边界很清楚，`docs/ARCHITECTURE.md` 里列了 7 个最容易踩的实现坑。

## 许可与声明

- 代码以 [MIT](LICENSE) 授权。
- 本项目不收集任何数据，不联网上传任何内容。
- 使用本工具录制他人屏幕、会议或受版权保护的内容前，请自行确认已获得授权并符合当地法律。
- BlackHole 是 [Existential Audio](https://existential.audio/blackhole/) 的第三方开源软件，本项目仅调用它，不随包分发。

---

<a name="english"></a>

## English

FreeRecord is a free, open-source, watermark-free screen recorder for macOS 12.3+ (universal binary: Apple Silicon + Intel). It captures the full screen, a single window, or a draggable region, with four audio choices — none, microphone, system audio, or both on separate tracks. It lives in the menu bar with a floating control bar, offers a countdown, click highlight, hotkeys (<kbd>⌥⌘R</kbd> / <kbd>⌥⌘P</kbd>), and writes fragmented H.264 MP4 so a crash never loses recorded content.

No third-party dependencies: Swift + ScreenCaptureKit + AVFoundation only. Build with `bash scripts/build.sh`, package with `bash scripts/make-dmg.sh`. Current releases are ad-hoc/self-signed, so first launch needs right-click → Open; system audio on macOS 12 requires the free BlackHole virtual sound card. Zero telemetry. MIT licensed.
