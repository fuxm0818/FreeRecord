import AppKit
import AVFoundation
import Combine
import FreeRecordCore
import ScreenCaptureKit

@main
final class AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, RecordingCoordinatorDelegate {
    private var statusItem: NSStatusItem?
    private let settings = AppSettings.shared
    private let coordinator = RecordingCoordinator()
    private let controlBar = ControlBarController()
    private let regionSelector = RegionSelector()
    private let regionFrame = RegionFrameController()
    private let preRecordBar = PreRecordBarController()
    private let savePanel = SavePanelController()
    private let audioWindow = AudioRecordWindowController()
    private let cameraWindow = CameraRecordWindowController()

    /// 已选好、等待在预录制工具栏里确认的目标
    private enum PendingTarget {
        case screen(display: SCDisplay, screen: NSScreen)
        case window(SCWindow)
        /// rect 统一用屏幕全局坐标（NS 系，主屏左下原点），开录时才换算到显示器本地坐标
        case region(display: SCDisplay, screen: NSScreen, rect: CGRect)
    }
    private var pendingTarget: PendingTarget?
    /// 本次录制范围的屏幕坐标（NS 系），用于把录制条摆到右下角
    private var recordingAnchor: NSRect?
    private lazy var settingsPanel = SettingsPanelController(settings: settings)
    private lazy var previewPanel = PreviewPanelController()
    private lazy var home = HomeWindowController(settings: settings)
    private let countdown = CountdownController()
    private let clickHighlight = ClickHighlightController()
    private let hotkeys = HotKeyController()
    private var statusTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.delegate = self
        coordinator.saveDirectory = settings.saveDirectory

        // 授权只对新调用生效：从系统设置切回来时自动复查，权限就绪就续上没启动成的录制
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.coordinator.retryPendingStartIfReady() }
        }

        controlBar.onStop = { [weak self] in self?.coordinator.stop() }
        controlBar.onTogglePause = { [weak self] in self?.coordinator.togglePause() }
        controlBar.onScreenshot = { [weak self] in self?.takeScreenshot() }
        controlBar.onToggleMic = { [weak self] in
            guard let self else { return }
            let muted = !self.coordinator.isMicrophoneMuted
            self.coordinator.setMicrophoneMuted(muted)
            self.controlBar.setMicMuted(muted)
        }
        controlBar.elapsedProvider = { [weak self] in self?.coordinator.elapsed ?? 0 }

        hotkeys.onToggleRecord = { [weak self] in
            guard let self else { return }
            switch self.coordinator.state {
            case .recording, .paused:
                self.coordinator.stop()
            case .idle:
                // 门控等待期（采集已启动、state 仍是 idle）不能重入选区流程
                guard !self.coordinator.isPreparing else { return }
                self.openScreenRecording()
            default:
                break
            }
        }
        hotkeys.onTogglePause = { [weak self] in self?.coordinator.togglePause() }
        hotkeys.setEnabled(settings.hotkeysEnabled)
        regionSelector.onRegionSelected = { [weak self] screen, rect in
            self?.prepareRegionTarget(globalRect: rect, screen: screen)
        }
        regionSelector.onWindowSelected = { [weak self] window in
            self?.handlePickedWindow(window)
        }
        regionSelector.onScreenSelected = { [weak self] screen in
            self?.prepareScreenTarget(screen: screen)
        }
        regionSelector.onUnavailable = { [weak self] in
            guard let self else { return }
            self.rebuildMenu()
            self.alert("没有「屏幕录制」权限，无法选择录制范围。\n\n请在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 里授权，然后重新打开本 App。")
        }
        regionSelector.onCancelled = { [weak self] in self?.rebuildMenu() }

        preRecordBar.onStart = { [weak self] in self?.beginConfirmedRecording() }
        preRecordBar.onCancel = { [weak self] in
            guard let self else { return }
            self.preRecordBar.hide()
            self.regionFrame.hide()
            self.pendingTarget = nil
            self.rebuildMenu()
        }
        preRecordBar.onSizeEdited = { [weak self] newSize in
            self?.resizePendingRegion(to: newSize)
        }
        regionFrame.onChange = { [weak self] rect in
            self?.pendingRegionChanged(to: rect)
        }
        regionFrame.onDragEnded = { [weak self] in
            self?.preRecordBar.reposition()
        }

        home.onStart = { [weak self] in self?.openScreenRecording() }
        home.onPreview = { [weak self] item in
            guard let self else { return }
            let recording = SavedRecording(
                url: item.url,
                duration: item.duration,
                width: item.width,
                height: item.height,
                fileSizeMB: item.sizeMB,
                audioTrackCount: item.audioTrackCount
            )
            self.previewPanel.show(recording: recording)
        }
        home.onSettings = { [weak self] in self?.showSettings() }
        home.onStop = { [weak self] in self?.coordinator.stop() }
        home.onAudioRecord = { [weak self] in self?.showAudioRecorder() }
        home.onCameraRecord = { [weak self] in self?.showCameraRecorder() }
        settingsPanel.onSystemAudioHelp = { [weak self] in self?.showBlackHoleGuide() }
        settingsPanel.onCreateMultiOutput = { [weak self] in self?.createMultiOutput() }

        cameraWindow.onSaved = { [weak self] recording in
            guard let self else { return }
            self.home.reloadHistory()
            self.presentSaveAndPreview(recording)
        }
        cameraWindow.onFailed = { [weak self] message in self?.alert(message) }
        previewPanel.onFileChanged = { [weak self] in self?.home.reloadHistory() }

        audioWindow.onStart = { [weak self] audio in self?.startAudioRecording(audio) }
        audioWindow.onStop = { [weak self] in self?.coordinator.stop() }
        audioWindow.onTogglePause = { [weak self] in self?.coordinator.togglePause() }
        audioWindow.elapsedProvider = { [weak self] in self?.coordinator.elapsed ?? 0 }

        countdown.onTick = { [weak self] seconds in
            self?.showCountdownStatus(seconds: seconds)
        }

        settings.$clickHighlightEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            if enabled, self.coordinator.state != .idle {
                self.clickHighlight.start()
            } else {
                self.clickHighlight.stop()
            }
        }.store(in: &cancellables)
        settings.$hotkeysEnabled.dropFirst().sink { [weak self] enabled in
            self?.hotkeys.setEnabled(enabled)
        }.store(in: &cancellables)
        settings.$saveDirectory.dropFirst().sink { [weak self] url in
            guard let self else { return }
            self.coordinator.saveDirectory = url
            self.home.viewModel.history.updateDirectory(url)
            self.home.viewModel.history.reload()
        }.store(in: &cancellables)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusButton()
        rebuildMenu()

        Task { [weak self] in
            await self?.home.show()
        }
    }

    // MARK: - 菜单

    private func rebuildMenu() {
        guard let statusItem, statusItem.button != nil else { return }
        let menu = NSMenu()

        let stateTitle: String
        switch coordinator.state {
        case .idle: stateTitle = "自由录屏 · 准备就绪"
        case .recording, .finishing: stateTitle = "录制中 \(timeString(coordinator.elapsed))"
        case .paused: stateTitle = "已暂停 \(timeString(coordinator.elapsed))"
        }
        let stateItem = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        if coordinator.state == .idle {
            menu.addItem(actionItem("打开主界面", action: #selector(showHome), key: ""))
            menu.addItem(.separator())
            menu.addItem(actionItem("屏幕录制", action: #selector(startScreenRecording), key: "r", modifiers: [.command, .option]))
            menu.addItem(actionItem("录制音频…", action: #selector(showAudioRecorderMenu), key: ""))
            menu.addItem(actionItem("摄像头录制…", action: #selector(showCameraRecorderMenu), key: ""))
            menu.addItem(.separator())
        } else {
            let pauseTitle = coordinator.state == .paused ? "继续录制" : "暂停录制"
            menu.addItem(actionItem(pauseTitle, action: #selector(togglePauseRecording), key: "p", modifiers: [.command, .option]))
            menu.addItem(actionItem("停止并保存", action: #selector(stopRecording), key: "s"))
            menu.addItem(actionItem("取消录制", action: #selector(cancelRecording), key: ""))
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "录屏过程中系统不会进入睡眠模式", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem("设置…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 自由录屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        updateStatusButton()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: sender)
            return
        }
        // 空闲时左键点击 = 打开主界面；录制中左键把控制条带回前台
        if coordinator.state == .idle {
            showHome()
        } else if coordinator.sessionKind == .audio {
            audioWindow.bringToFront()
        } else {
            controlBar.bringToFront()
        }
    }

    private func actionItem(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func showBlackHoleGuide() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "安装 BlackHole 虚拟声卡"
        alert.informativeText = """
        在 macOS 12 上录制系统声音需要安装免费的 BlackHole 虚拟声卡（开源软件）。

        安装方式二选一：
        1. 用 Homebrew：brew install blackhole-2ch
        2. 从官网下载安装包

        安装完成后重新打开本 App，就能选「系统声音」了。
        """
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "https://existential.audio/blackhole/") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func createMultiOutput() {
        do {
            let result = try SystemAudioSupport.createMultiOutputAggregate()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = result.alreadyExisted ? "多输出设备已存在" : "已创建多输出设备"
            alert.informativeText = "要把系统声音同时送到扬声器和录制轨道，需要把系统输出切到「自由录屏多输出」。现在切换吗？（之后可随时在 系统设置→声音 切回）"
            alert.addButton(withTitle: "切换输出")
            alert.addButton(withTitle: "暂不")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = SystemAudioSupport.setDefaultOutput(to: result.deviceID)
            }
        } catch {
            alert("创建多输出设备失败：\(error.localizedDescription)")
        }
    }

    @objc private func showSettings() {
        settingsPanel.show()
    }

    @objc private func showHome() {
        Task { await home.show() }
    }

    @objc private func stopRecording() {
        coordinator.stop()
    }

    @objc private func togglePauseRecording() {
        coordinator.togglePause()
    }

    @objc private func cancelRecording() {
        coordinator.cancel()
    }

    private func takeScreenshot() {
        guard coordinator.sessionKind == .screen,
              coordinator.state == .recording || coordinator.state == .paused else { return }
        let url = coordinator.captureScreenshot()
        controlBar.showScreenshotResult(success: url != nil)
        if url != nil {
            home.reloadHistory()
        }
    }

    /// 屏幕录制只有一个入口：先进全屏选区层
    private func openScreenRecording() {
        guard coordinator.state == .idle, !coordinator.isPreparing else { return }
        guard !cameraWindow.isRecording else {
            alert("摄像头正在录制，请先停止摄像头录制。")
            return
        }
        cameraWindow.hide()
        audioWindow.hide()
        home.hide()
        // 预览/设置是普通窗口（没有「不入画」保护），开着开录会把
        // 上一段成片/设置内容拍进新录制
        previewPanel.hide()
        settingsPanel.hide()
        regionSelector.show()
    }

    @objc private func startScreenRecording() {
        openScreenRecording()
    }

    private func handlePickedWindow(_ window: SCWindow) {
        pendingTarget = .window(window)
        let scale = Self.screenScale(for: window.frame)
        preRecordBar.show(
            target: .windowRect(Self.nsRect(fromCG: window.frame)),
            settings: settings,
            pixelSize: NSSize(width: window.frame.width * scale, height: window.frame.height * scale),
            pixelScale: scale
        )
    }

    private func showAudioRecorder() {
        guard !cameraWindow.isRecording else {
            alert("摄像头正在录制，请先停止摄像头录制。")
            return
        }
        cameraWindow.hide()
        audioWindow.show(settings: settings)
    }

    @objc private func showAudioRecorderMenu() {
        showAudioRecorder()
    }

    private func showCameraRecorder() {
        guard coordinator.state == .idle else {
            alert("请先结束当前录制，再打开摄像头录制。")
            return
        }
        audioWindow.hide()
        cameraWindow.show(saveDirectory: settings.saveDirectory)
    }

    @objc private func showCameraRecorderMenu() {
        showCameraRecorder()
    }

    private func presentSaveAndPreview(_ recording: SavedRecording) {
        cameraWindow.hide()
        audioWindow.hide()
        guard settings.askNameOnSave else {
            previewPanel.show(recording: recording)
            return
        }
        savePanel.present(recording: recording, defaultDirectory: settings.saveDirectory) { [weak self] final in
            guard let self else { return }
            let saved = final ?? recording
            self.home.reloadHistory()
            self.previewPanel.show(recording: saved)
        }
    }

    private func startAudioRecording(_ audio: AudioSource) {
        // 只写「仅音频」场景自己的配置，不再覆写录屏的声音选择
        settings.setAudio(audio, for: .audioOnly)
        let capture = CaptureSettings(fps: 30, targetHeight: 0, showsCursor: false, audio: audio, pixelScale: 1)
        // 门控等待（权限预检 + 采集启动 + 等首帧）期间给「准备中」反馈，
        // 重复点击会被 coordinator 的 isPreparing 静默吞掉，不能让按钮装死
        audioWindow.setPreparing(true)
        Task { [weak self] in
            await self?.coordinator.startAudioOnly(settings: capture) { [weak self] level in
                self?.audioWindow.updateLevel(level)
            }
            self?.audioWindow.setPreparing(false)
        }
    }

    // MARK: - 启动录制（先选范围 → 弹预录制工具栏 → 确认开始）

    private func startWithCountdown(source: CaptureSource, settings captureSettings: CaptureSettings) {
        if settings.countdownEnabled {
            countdown.start(seconds: 3) { [weak self] in
                Task { await self?.coordinator.start(source: source, settings: captureSettings) }
            }
        } else {
            Task { await coordinator.start(source: source, settings: captureSettings) }
        }
    }

    private func currentCaptureSettings(scale: Double) -> CaptureSettings {
        CaptureSettings(
            fps: settings.fps,
            targetHeight: settings.targetHeight,
            showsCursor: settings.showsCursor,
            audio: settings.effectiveAudio,
            pixelScale: scale
        )
    }

    private func prepareScreenTarget(screen: NSScreen) {
        Task {
            do {
                let content = try await ScreenCapture.loadShareableContent()
                guard let displayID = screen.displayID,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    alert("没有找到对应的显示器。")
                    return
                }
                pendingTarget = .screen(display: display, screen: screen)
                let scale = screen.backingScaleFactor
                let size = NSSize(width: Double(display.width) * scale, height: Double(display.height) * scale)
                preRecordBar.show(target: .screen(screen), settings: settings, pixelSize: size, pixelScale: scale)
            } catch {
                alert("获取屏幕信息失败：\(error.localizedDescription)")
            }
        }
    }

    private func prepareRegionTarget(globalRect: CGRect, screen: NSScreen) {
        Task {
            do {
                let content = try await ScreenCapture.loadShareableContent()
                guard let displayID = screen.displayID,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    alert("没有找到对应的显示器。")
                    return
                }
                pendingTarget = .region(display: display, screen: screen, rect: globalRect)
                regionFrame.show(screen: screen, rect: globalRect, editable: true)
                let scale = screen.backingScaleFactor
                preRecordBar.show(
                    target: .region(screen, globalRect),
                    settings: settings,
                    pixelSize: NSSize(width: globalRect.width * scale, height: globalRect.height * scale),
                    pixelScale: scale
                )
            } catch {
                alert("获取屏幕信息失败：\(error.localizedDescription)")
            }
        }
    }

    /// 绿框拖动/缩放回调：同步 pendingTarget 与预录制条宽高（工具栏在拖动结束后才挪位）
    private func pendingRegionChanged(to rect: NSRect) {
        guard case .region(let display, let screen, _) = pendingTarget else { return }
        pendingTarget = .region(display: display, screen: screen, rect: rect)
        let scale = screen.backingScaleFactor
        preRecordBar.updateRegion(
            rect: rect,
            pixelSize: NSSize(width: rect.width * scale, height: rect.height * scale)
        )
    }

    private func resizePendingRegion(to newSize: NSSize) {
        guard case .region(let display, let screen, let oldRect) = pendingTarget else { return }
        var rect = NSRect(
            x: oldRect.midX - newSize.width / 2,
            y: oldRect.midY - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
        rect = rect.intersection(screen.frame)
        guard rect.width >= 16, rect.height >= 16 else { return }
        pendingTarget = .region(display: display, screen: screen, rect: rect)
        regionFrame.update(rect: rect)
        let scale = screen.backingScaleFactor
        preRecordBar.updateRegion(
            rect: rect,
            pixelSize: NSSize(width: rect.width * scale, height: rect.height * scale)
        )
        preRecordBar.reposition()
    }

    private func beginConfirmedRecording() {
        guard let pending = pendingTarget else { return }
        guard preRecordBar.applyTo(settings: settings) != nil else {
            alert("宽高无效：请输入 16 以上的整数。")
            return
        }
        preRecordBar.hide()
        pendingTarget = nil

        switch pending {
        case .region(let display, let screen, let rect):
            regionFrame.setEditable(false)
            // 屏幕全局坐标（NS 系）→ 显示器本地坐标（CG 系，左上原点）
            let x = rect.origin.x - screen.frame.origin.x
            let y = screen.frame.maxY - rect.maxY
            let cgRect = CGRect(x: x, y: y, width: rect.width, height: rect.height).integral
            recordingAnchor = rect
            // 区域模式：宽高就是选区本身（按像素录制），不再缩放
            var capture = currentCaptureSettings(scale: screen.backingScaleFactor)
            capture.targetHeight = 0
            startWithCountdown(source: .region(display: display, rect: cgRect), settings: capture)
        case .window(let window):
            recordingAnchor = Self.nsRect(fromCG: window.frame)
            startWithCountdown(
                source: .window(window),
                settings: currentCaptureSettings(scale: Self.screenScale(for: window.frame))
            )
        case .screen(let display, let screen):
            recordingAnchor = screen.frame
            startWithCountdown(
                source: .display(display),
                settings: currentCaptureSettings(scale: screen.backingScaleFactor)
            )
        }
    }

    /// CGWindow 坐标（主屏左上原点）→ AppKit 屏幕坐标（左下原点）
    private static func nsRect(fromCG rect: CGRect) -> NSRect {
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: mainMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screenScale(for rect: NSRect) -> CGFloat {
        let screenRect = Self.nsRect(fromCG: rect)
        return NSScreen.screens.first { $0.frame.intersects(screenRect) }?.backingScaleFactor ?? 2
    }

    // MARK: - 状态

    func recordingStateChanged() {
        let isAudio = coordinator.sessionKind == .audio
        switch coordinator.state {
        case .recording:
            if isAudio {
                audioWindow.setRecording(true, paused: false)
            } else {
                audioWindow.hide()
                // 真正开录后绿框就是残留：切到别的屏幕还挂着，容易被当成没清干净
                regionFrame.hide()
                controlBar.show(anchor: recordingAnchor, microphone: coordinator.hasMicrophoneTrack)
                controlBar.setPaused(false)
                if settings.clickHighlightEnabled { clickHighlight.start() }
            }
            startStatusTimer()
        case .paused:
            if isAudio {
                audioWindow.setRecording(true, paused: true)
            } else {
                controlBar.show(anchor: recordingAnchor, microphone: coordinator.hasMicrophoneTrack)
                controlBar.setPaused(true)
            }
        case .finishing:
            if isAudio {
                audioWindow.setRecording(true, paused: true)
            } else {
                controlBar.hide()
            }
            clickHighlight.stop()
        case .idle:
            controlBar.hide()
            clickHighlight.stop()
            stopStatusTimer()
            regionFrame.hide()
            recordingAnchor = nil
            if isAudio {
                audioWindow.setRecording(false, paused: false)
            }
        }
        home.viewModel.recordingState = switch coordinator.state {
        case .idle: "idle"
        case .recording: "recording"
        case .paused: "paused"
        case .finishing: "finishing"
        }
        rebuildMenu()
    }

    func recordingFailed(message: String) {
        regionFrame.hide()
        updateStatusButton()
        alert(message)
    }

    func recordingPermissionNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "本 App 暂时读不到「屏幕录制」权限"
        alert.informativeText = """
        如果系统设置里已经显示开启：关掉这个弹窗切回本 App 会自动重试；仍不行请点「重启 App」——App 重新打包后签名会变，旧授权随之失效，重启后在系统设置里关一次再开一次即可。

        如果还没开：点「打开系统设置」，在 隐私与安全性 → 屏幕与系统音频录制 里打开「自由录屏」，授权后切回本 App，录制会自动继续。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "重启 App")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else if response == .alertSecondButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundleURL.path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    func recordingSaved(_ recording: SavedRecording, askToSave: Bool) {
        home.reloadHistory()
        guard askToSave else { return }
        presentSaveAndPreview(recording)
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusButton()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        switch coordinator.state {
        case .recording, .finishing:
            button.image = statusImage("record.circle.fill", tint: .systemRed, description: "录制中")
            button.attributedTitle = statusAttributedTime(coordinator.elapsed, color: .systemRed)
        case .paused:
            button.image = statusImage("pause.circle.fill", tint: .systemYellow, description: "已暂停")
            button.attributedTitle = statusAttributedTime(coordinator.elapsed, color: .systemYellow)
        case .idle:
            button.image = statusImage("camera.on.rectangle", tint: nil, description: "自由录屏")
            button.attributedTitle = NSAttributedString()
        }
    }

    /// contentTintColor 管不到状态栏按钮的文字，时间要用 attributed string 上色
    private func statusAttributedTime(_ interval: TimeInterval, color: NSColor) -> NSAttributedString {
        let seconds = max(0, Int(interval))
        let text = String(format: " %02d:%02d", seconds / 60, seconds % 60)
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    private func statusImage(_ symbol: String, tint: NSColor?, description: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return nil }
        if let tint {
            image.isTemplate = false
            // SF Symbol 非模板后内容仍是黑的，用锁定的模板锁渲染成目标色
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            let tinted = image.withSymbolConfiguration(config) ?? image
            tinted.isTemplate = false
            return tinted
        }
        image.isTemplate = true
        return image
    }

    private func showCountdownStatus(seconds: Int) {
        guard coordinator.state == .idle, let button = statusItem?.button else { return }
        button.image = statusImage("record.circle", tint: .systemBlue, description: "即将开始录制")
        button.attributedTitle = NSAttributedString(string: " \(seconds) 秒后开始", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemBlue,
        ])
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "自由录屏"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
