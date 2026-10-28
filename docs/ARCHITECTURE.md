# 架构说明

单 SwiftPM 包、三个目标，无 Xcode 工程文件、无第三方依赖：

| 目标 | 规模 | 职责 |
| --- | --- | --- |
| `FreeRecordCore` | 8 个文件 / 约 1.1k 行 | 采集与写入内核：ScreenCaptureKit 抓屏、麦克风/系统声音、AVAssetWriter 封装、计数器、指标采样。不含界面代码 |
| `FreeRecordApp` | 17 个文件 / 约 5k 行 | AppKit + SwiftUI 界面与流程编排：菜单栏、选区层、预录制工具条、录制条、预览、设置 |
| `FreeRecordPOC` | 4 个文件 / 约 0.8k 行 | 性能压测 demo，用来量化 CPU/内存/掉帧，可选构建 |

## 数据流

```
SCStream (ScreenCaptureKit 画面)            ──视频帧──┐
SCStream (系统声音, macOS 13+)              ─音频轨1──┤─▶ RecordingWriter ─▶ AVAssetWriter ─▶ 分片 MP4
AVAudioEngine / AVCaptureSession (麦克风)   ─音频轨0──┘
```

- 一条视频轨 + 最多两条独立 AAC 音轨（麦克风轨 0、系统声音轨 1），互不混音，后期可单独处理。
- `RecordingCoordinator`（`Sources/FreeRecordApp/RecordingCoordinator.swift`）是唯一的状态机：`idle → recording ⇄ paused → finishing → idle`，负责创建 writer、启动采集、停止并收尾。界面上所有按钮最终都只调它。

## 界面构成（纯代码，无 storyboard/xib）

菜单栏 `NSStatusItem`（`LSUIElement`，无常驻 Dock 图标）→ 首页窗口（历史列表 + 三个录制入口）→ 全屏选区层 → 预录制工具条 → 录制中浮动条 → 预览面板 / 设置面板 / 保存面板 / 音频录制窗 / 摄像头录制窗。

交互范式：**先选范围，再在浮动工具条里调参数，点确认才开始**；选区层悬停即高亮窗口、单击录该窗口、拖拽框选区域、双击桌面录全屏、ESC 取消。

## 新手最需要知道的 7 个实现点

1. **自己的 UI 不会进画面。** `SCContentFilter` 会排除本 App 中标题等于 `ScreenCapture.hiddenWindowTitle` 或 `windowLayer >= 1000` 的窗口（见 `FreeRecordCore/ScreenCapture.swift`），浮动窗口本身还设了 `sharingType = .none`。新增浮动面板时**必须**带上这个标题，否则会被录进视频。
2. **分片 MP4。** `movieFragmentInterval = 5s`（`RecordingWriter`），崩溃或被强杀时已录内容仍可播放。代价是收尾失败时文件已经"写出去一大截"，所以 `RecordingCoordinator` 在 finish 抛错后会检查文件是否仍可播放，能播就照常进预览。
3. **暂停是真压缩，不是打标记。** `RecordingWriter.makeRetimed` 用 `shift = 上一样本结束时间 − 当前样本相对 PTS` 把暂停时段从时间轴里挤掉，视频和每条音轨各自维护 shift。改这里要同时考虑三条轨。
4. **停录有竞态。** `SCStream.stopCapture` 返回后仍可能补发队列里的帧，若此时已 `markAsFinished`，整个 `AVAssetWriter` 会进入 failed 并报「这项工作无法完成」。所以 `finish()` 先置 `finishing` 标志丢弃迟到样本，再在同一把锁下 markAsFinished。
5. **macOS 12 录系统声音要靠虚拟声卡。** SCK 的系统音频捕获是 macOS 13+ 能力；12 上走 BlackHole + 「多输出设备」聚合（`SystemAudioSupport` 可一键创建聚合设备），从 BlackHole 采集写入系统声音轨。
6. **三套坐标系。** AppKit 屏幕坐标（左下原点）↔ CoreGraphics/显示器坐标（左上原点）↔ 像素（× `backingScaleFactor`）。区域录制在 `AppMain.prepareRegionTarget` / `beginConfirmedRecording` 里来回换算，写反就会出现"录到的区域上下颠倒/偏移"。
7. **权限按签名身份记账。** 见 [PERMISSIONS.md](PERMISSIONS.md)：ad-hoc 签名每次构建都换 cdhash，屏幕录制授权会失效；本地开发请建一张自签证书（`scripts/create-signing-cert.sh`）。

## 关键约定

- 语言模式 Swift 5（`Package.swift` 里显式设置），并发标注用 `@MainActor`，跨线程状态用 `NSLock` 保护。
- 面向用户的文案与代码注释一律中文。
- 不引入第三方依赖；系统框架优先。
