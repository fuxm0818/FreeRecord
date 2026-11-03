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
  按「要保留的区间」重排时间轴。视频用 `AVAssetExportPresetPassthrough` 只转封装 —— **不重新编码**，画质无损。
  纯音频成品走 `exportAudio`：`.m4a` 仍能 passthrough，`.mp3` 容器 AVFoundation 写不出来，只能把同一条
  composition 交给 `Mp3Exporter` 解码后重编码。时间轴重排两边共用 `makeComposition`。
  视频轨与每条音轨**必须同步处理**，否则音画错位（与 `RecordingWriter.makeRetimed` 同一套约束）。

## 界面构成（纯代码，无 storyboard/xib）

菜单栏 `NSStatusItem`（`LSUIElement`，无常驻 Dock 图标）→ 首页窗口（历史列表 + 三个录制入口）→ 全屏选区层 → 预录制工具条 → 录制中浮动条 → 预览面板 / 设置面板 / 保存面板 / 音频录制窗 / 摄像头录制窗。

交互范式：**先选范围，再在浮动工具条里调参数，点确认才开始**；选区层悬停即高亮窗口、单击录该窗口、拖拽框选区域、双击桌面录全屏、ESC 取消。

## 新手最需要知道的 12 个实现点

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
10. **LSUIElement App 默认不装主菜单，⌘Q 是死的。** `NSApp.mainMenu` 为 nil 时菜单条没有本 App 的菜单，退出 / 复制粘贴 / 关窗这些系统级键位全部没人接。`AppDelegate.installMainMenu()` 手建 App、编辑、窗口三份菜单：系统动作（`terminate:`、`copy:`、`performClose:`）留空 target 交给响应链，只有自家动作（设置…）绑 `self`。App 形态由 `refreshAppActivationPolicy()`（同文件）**单点**判定 —— 有可见的 titled 窗口就是 `.regular`（出 Dock 图标、菜单条显示本 App），只剩选区层与浮动工具条时退回 `.accessory`；状态栏窗口和这些浮层都是 borderless，不会被误判成 titled。实测 `.accessory` 且本 App 是当前应用时主菜单键位仍然生效，所以录制期间另加「忙」判定（`isCaptureSessionBusy`）保持不抢菜单条。**新窗口不要再自己调 `setActivationPolicy`**，几个窗口各自来回切会互相打架。

11. **App 名字有四个来源，别改错地方。** `Contents/Resources/<lang>.lproj/InfoPlist.strings` 决定 Finder / Dock / 关于面板 / 「系统设置 → 隐私与安全性」列表里的名字和授权弹窗文案（源文件在 `Resources/`，由 `scripts/build.sh` 整目录拷进包内 —— 漏这步，英文系统还是显示中文，且没有报错）；菜单条最粗的那个名字取 `CFBundleName`（`FreeRecord`），不受 `CFBundleDisplayName` 影响；`Info.plist` 里的值是「开发区域 zh-Hans」的兜底，只在缺对应 `.lproj` 时被用到；App 内部显示 App 名的地方走 `appDisplayName`（读 `CFBundleDisplayName`，跟着语言变），别再往代码里写死「自由录屏」。核验办法：同一份包用 `open FreeRecord.app --args -AppleLanguages "(en)"` 启动，`lsappinfo info -only name <pid>` 应报 `FreeRecord`，不带参数（zh-Hans-CN）应报「自由录屏」——LaunchServices 会缓存，改完包记得 `lsregister -f`。
12. **界面文案以中文原文当 key。** `FreeRecordCore/Localization.swift` 的 `L(_:)` 把中文原文既当 key 又当默认值，所以只有 `Resources/en.lproj/Localizable.strings` 需要维护，查不到就退回中文，永远不会出现空白；新增中文文案不用补 zh 文件，补英文才需要。SwiftUI 的 `Text` / `Button` / `Toggle` / `.help` 字面量框架自动查表，不用包；AppKit 手工赋值的（`NSAlert`、`NSMenuItem`、`NSButton.title`、`NSTextField`、`toolTip`、`accessibilityDescription`、`NSPopUpButton` 项）必须走 `L` / `LF`。两个坑：带变量的文案要用 `LF("…%@…", x)`，**不能**写 `L("…\(x)…")`——插值出来的 key 是动态的，永远查不中；一组控件的文案要在**辅助函数内部**查表（`label(_:)`、`iconButton(help:)`、`makeToggle(tip:)`、`actionItem(_:)`、`statusImage(description:)`），调用点保持中文原文，否则每个调用点都要包一层、字典键也会跟着语言变（`valueLabels` 就是靠中文原文做键的）。不按语言变的三类是刻意的：文件与目录名（`Movies/自由录屏`、`REC-`/`AUD-`/`截图`/`-裁剪`）跨语言要能接上历史，聚合设备「自由录屏多输出」按名字匹配用户已有的设备，诊断日志正文是给开发看的。第三个坑是布局：英文普遍比对应中文长（「帧率」12pt 约 24pt，"Frame rate" 61pt），为中文写死的定宽会裁字，所以信息列宽按本地化后的最宽标签实测、无边框面板按控件实测排布来定宽（`AudioRecordWindow.build` 要取空闲 / 录制 / 准备三种排布里最宽的一次，因为 `fittingSize` 只在 build 时量一次，而录制态会多出提示与暂停键）。核验办法同 11：强制英文启动后用 AX 读真实界面文本与坐标，逐窗口 grep 汉字，再看最右控件的边缘有没有落在面板内。

## 关键约定

- 语言模式 Swift 5（`swift-tools-version: 5.7` 默认），并发标注用 `@MainActor`，跨线程状态用 `NSLock` 保护。
- 面向用户的文案一律用中文原文书写（中文同时就是本地化 key），英文只维护 `Resources/en.lproj/Localizable.strings` 一份；代码注释一律中文。
- 不链接第三方库，系统框架优先；唯一的例外是 MP3 编码 —— 它以独立可执行文件（LGPL 的 LAME）随包分发、用子进程调用，App 本体保持 MIT。
