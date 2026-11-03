# 架构说明

单 SwiftPM 包、三个目标，无 Xcode 工程文件、不链接第三方库（唯一的第三方组件是作为独立进程调用的 LAME，见「MP3 导出」）：

| 目标 | 规模 | 职责 |
| --- | --- | --- |
| `FreeRecordCore` | 12 个文件 / 约 2.5k 行 | 采集与写入内核：ScreenCaptureKit 抓屏、麦克风/系统声音、AVAssetWriter 封装、MP3 导出、计数器、指标采样。不含界面代码 |
| `FreeRecordApp` | 21 个文件 / 约 7.2k 行 | AppKit + SwiftUI 界面与流程编排：菜单栏、选区层、预录制工具条、录制条、预览、设置 |
| `FreeRecordPOC` | 4 个文件 / 约 0.8k 行 | 性能压测 demo，用来量化 CPU/内存/掉帧，可选构建 |

## 数据流

```
SCStream (ScreenCaptureKit 画面)            ──视频帧──┐
SCStream (系统声音, macOS 13+)              ─音频轨1──┤─▶ RecordingWriter ─▶ AVAssetWriter ─▶ 分片 MP4
AVAudioEngine / AVCaptureSession (麦克风)   ─音频轨0──┘
```

- 一条视频轨 + 最多两条独立 AAC 音轨（麦克风轨 0、系统声音轨 1），互不混音，后期可单独处理。
- **纯录音模式的成品是 MP3**：`RecordingWriter` 仍先写成 256 kbps 的 AAC/.m4a 中间档，停止后由
  `Mp3Exporter`（`Sources/FreeRecordCore/Mp3Exporter.swift`）用 `AVAssetReader` 解出 16 位交错 PCM，
  按裸 PCM 流写进内嵌 LAME 的 stdin 产出 `.mp3`，成功后删掉中间档。选了「麦克风 + 系统声音」时，
  两条轨由 `AVAssetReaderAudioMixOutput` 混成一条 —— MP3 容器只装得下一条音轨。
- `RecordingCoordinator`（`Sources/FreeRecordApp/RecordingCoordinator.swift`）是唯一的状态机：`idle → recording ⇄ paused → finishing → idle`，负责创建 writer、启动采集、停止并收尾。界面上所有按钮最终都只调它。
- **录制后的裁剪走 `CompositionEditor`（`Sources/FreeRecordCore/CompositionEditor.swift`）**：用 `AVMutableComposition`
  按「要保留的区间」重排时间轴，再用 `AVAssetExportPresetPassthrough` 只转封装 —— **不重新编码**，画质无损。
  视频轨与每条音轨**必须同步处理**，否则音画错位（与 `RecordingWriter.makeRetimed` 同一套约束）。

## 界面构成（纯代码，无 storyboard/xib）

菜单栏 `NSStatusItem`（`LSUIElement`，无常驻 Dock 图标）→ 首页窗口（历史列表 + 三个录制入口）→ 全屏选区层 → 预录制工具条 → 录制中浮动条 → 预览面板 / 设置面板 / 保存面板 / 音频录制窗 / 摄像头录制窗。

交互范式：**先选范围，再在浮动工具条里调参数，点确认才开始**；选区层悬停即高亮窗口、单击录该窗口、拖拽框选区域、双击桌面录全屏、ESC 取消。

## 新手最需要知道的 9 个实现点

1. **自己的 UI 不会进画面。** 靠两层保护，**缺一不可**（见 `ScreenCapture.ownHiddenWindows` 与各浮动面板的 `configureAsCaptureHiddenFloatingUI()`）：
   - `title = ScreenCapture.hiddenWindowTitle` + `SCContentFilter(display:excludingWindows:)` —— 只挡**自家** SCK 采集；
   - `sharingType = .none` —— **系统级**开关，Zoom / 会议 / QuickTime / 系统截图全挡。

   新增浮动面板时**统一调用 `configureAsCaptureHiddenFloatingUI()`**，不要只设其中一个（只设 title：会出现在别人的屏幕共享里；只设 sharingType：自家采集的过滤逻辑对不上账）。

   ⚠️ 例外：点击高亮窗口（`ClickHighlight`）**不要**调用 —— 它是刻意要被录进画面的效果。
2. **分片 MP4。** `movieFragmentInterval = 5s`（`RecordingWriter`），崩溃或被强杀时已录内容仍可播放。代价是收尾失败时文件已经"写出去一大截"，所以 `RecordingCoordinator` 在 finish 抛错后会检查文件是否仍可播放，能播就照常进预览。
3. **暂停是真压缩，不是打标记。** `RecordingWriter.makeRetimed` 用 `shift = 上一样本结束时间 − 当前样本相对 PTS` 把暂停时段从时间轴里挤掉，视频和每条音轨各自维护 shift。改这里要同时考虑三条轨。
4. **停录有竞态。** `SCStream.stopCapture` 返回后仍可能补发队列里的帧，若此时已 `markAsFinished`，整个 `AVAssetWriter` 会进入 failed 并报「这项工作无法完成」。所以 `finish()` 先置 `finishing` 标志丢弃迟到样本，再在同一把锁下 markAsFinished。
5. **macOS 12 录系统声音要靠虚拟声卡。** SCK 的系统音频捕获是 macOS 13+ 能力；12 上走 BlackHole + 「多输出设备」聚合（`SystemAudioSupport` 可一键创建聚合设备），从 BlackHole 采集写入系统声音轨。
6. **三套坐标系。** AppKit 屏幕坐标（左下原点）↔ CoreGraphics/显示器坐标（左上原点）↔ 像素（× `backingScaleFactor`）。区域录制在 `AppMain.prepareRegionTarget` / `beginConfirmedRecording` 里来回换算，写反就会出现"录到的区域上下颠倒/偏移"。
7. **权限按签名身份记账。** 见 [PERMISSIONS.md](PERMISSIONS.md)：ad-hoc 签名每次构建都换 cdhash，屏幕录制授权会失效；本地开发请建一张自签证书（`scripts/create-signing-cert.sh`）。
8. **MP3 只能靠 LAME，且它是子进程。** macOS 没有 MP3 编码器（`AVAssetWriter`、`AVAssetExportSession`、`ExtAudioFile`、`afconvert` 全都只解不编），`lame` 由 `scripts/build-mp3-encoder.sh` 从官方源码编成通用二进制放进 `Contents/Helpers/`，构建时先于 App 签名。三个约束：① 往子进程 stdin 写会因管道背压阻塞，读取-写入循环必须在后台线程；② 采样率要取自真正解出来的首包（`-s` 的单位是 kHz），写错整段成品变调又变速；③ 解码读不出连续 PCM、或包里没有编码器时必须报错/退回 .m4a 交付，不能静默丢音。
9. **构建脚本别用本机表现当准。** 本机 `/bin/bash` 是 3.2，GitHub runner 上是 Homebrew 的 bash 5.2：5.2 在 UTF-8 locale 下会把紧跟变量的全角标点字节算进变量名，`echo "$ARCH）"` 直接 `unbound variable` 中断；更糟的是 `trap 'rm -rf "$WORK"' EXIT` 里最后一条命令成功会把退出码压回 0，父脚本的 `set -e` 于是拦不住，CI 全绿但包里没有编码器。约定：中文里的变量一律写 `${VAR}`；EXIT trap 用 `st=$?; …; exit $st`；打包方只认产物不认退出码（`build.sh` 断言 `Helpers/lame` 存在且双架构，CI 的「校验成品」再断一次）。

## 关键约定

- 语言模式 Swift 5（`swift-tools-version: 5.7` 默认），并发标注用 `@MainActor`，跨线程状态用 `NSLock` 保护。
- 面向用户的文案与代码注释一律中文。
- 不链接第三方库，系统框架优先；唯一的例外是 MP3 编码 —— 它以独立可执行文件（LGPL 的 LAME）随包分发、用子进程调用，App 本体保持 MIT。
