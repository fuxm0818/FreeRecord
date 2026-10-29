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
    private let cameraPip = CameraPiPController()

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
    /// 录制中的范围指示框钉在哪块屏、要不要跟随某个窗口
    private var rangeScreen: NSScreen?
    private var rangeWindowID: CGWindowID?
    private var rangeFollowTimer: Timer?
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
        controlBar.onToggleCamera = { [weak self] in
            guard let self else { return }
            // 统一走 settings.cameraEnabled，预录条开关与录制中开关共用一套副作用
            settings.cameraEnabled.toggle()
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
            self.hideCameraPreview()
            self.rebuildMenu()
        }
        preRecordBar.onSizeEdited = { [weak self] newSize in
            self?.resizePendingRegion(to: newSize)
        }
        preRecordBar.onCameraToggled = { [weak self] isOn in
            self?.cameraToggled(isOn)
        }
        cameraPip.onPlacementChanged = { [weak self] placement in
            guard let self else { return }
            self.settings.cameraCenterX = Double(placement.centerX)
            self.settings.cameraCenterY = Double(placement.centerY)
        }
        cameraPip.onSizeChanged = { [weak self] fraction in
            self?.settings.cameraSize = Double(fraction)
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
        settings.$cameraEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.preRecordBar.setCameraToggle(on: enabled)
            if self.isRecordingScreen {
                self.controlBar.setCameraOn(enabled)
                self.setCameraDuringRecording(enabled)
            } else if enabled {
                self.prepareCameraIfNeeded(enabled: true)
            } else {
                self.hideCameraPreview()
            }
        }.store(in: &cancellables)
        settings.$cameraMirrored.dropFirst().sink { [weak self] mirrored in
            self?.cameraPip.setMirrored(mirrored)
        }.store(in: &cancellables)
        settings.$cameraSize.dropFirst().sink { [weak self] size in
            self?.cameraPip.setSizeFraction(CGFloat(size))
        }.store(in: &cancellables)
        settings.$cameraDeviceID.dropFirst().sink { [weak self] _ in
            guard let self, self.settings.cameraEnabled,
                  self.coordinator.state == .idle else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cameraPip.stop()
                self.prepareCameraIfNeeded()
            }
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
        hideCameraPreview()
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
        prepareCameraIfNeeded()
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

    private func startWithCountdown(source: CaptureSource, settings captureSettings: CaptureSettings, camera: CameraOverlaySource?) {
        if settings.countdownEnabled {
            countdown.start(seconds: 3) { [weak self] in
                Task { await self?.coordinator.start(source: source, settings: captureSettings, cameraOverlay: camera) }
            }
        } else {
            Task { await coordinator.start(source: source, settings: captureSettings, cameraOverlay: camera) }
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

    // MARK: - 摄像头画中画

    private var currentCameraPlacement: CameraOverlayPlacement {
        CameraOverlayPlacement(
            centerX: CGFloat(settings.cameraCenterX),
            centerY: CGFloat(settings.cameraCenterY),
            widthFraction: CGFloat(settings.cameraSize),
            mirrored: settings.cameraMirrored
        )
    }

    /// 本次录制范围（屏幕坐标，NS 系），画中画位置按它归一化
    private func captureRect(for target: PendingTarget) -> NSRect {
        switch target {
        case .screen(_, let screen):
            return screen.frame
        case .window(let window):
            return Self.nsRect(fromCG: window.frame)
        case .region(_, _, let rect):
            return rect
        }
    }

    /// 目标选定后按需开启摄像头并显示预览；已开启则只更新位置与大小。
    /// `enabled` 由订阅方把刚发出的值传进来：@Published 在 willSet 就发值，
    /// 这里同步读 settings.cameraEnabled 会拿到旧值，导致关掉再打开时不生效。
    private func prepareCameraIfNeeded(enabled: Bool? = nil) {
        guard enabled ?? settings.cameraEnabled, pendingTarget != nil else { return }
        let placement = currentCameraPlacement
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.cameraPip.prepare(
                deviceID: self.settings.cameraDeviceID,
                mirrored: self.settings.cameraMirrored
            )
            guard ok else {
                self.settings.cameraEnabled = false
                self.preRecordBar.setCameraToggle(on: false)
                self.hideCameraPreview()
                self.alert("摄像头没能开启。\n\n请在 系统设置 → 隐私与安全性 → 摄像头 里授权后重试。")
                return
            }
            guard self.preRecordBar.isShowing, let target = self.pendingTarget else {
                // 等待授权期间目标已被取消，别把摄像头晾着
                await self.cameraPip.stop()
                return
            }
            self.cameraPip.showPreview(
                captureRect: self.captureRect(for: target),
                placement: placement,
                sizeFraction: CGFloat(self.settings.cameraSize),
                mirrored: self.settings.cameraMirrored
            )
        }
    }

    private func cameraToggled(_ isOn: Bool) {
        // 统一由 settings.$cameraEnabled 的订阅处理开关副作用
        settings.cameraEnabled = isOn
    }

    /// 录制中开关画中画。采集流不重建：合成器每帧读一次 source，
    /// 关掉时先把 widthFraction 置 0（下一帧起整帧透传），再收预览窗与采集会话。
    private func setCameraDuringRecording(_ on: Bool) {
        guard on else {
            cameraPip.suppressOverlay()
            hideCameraPreview()
            return
        }
        guard let rect = recordingAnchor, rect.width > 1, rect.height > 1 else { return }
        let placement = currentCameraPlacement
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.cameraPip.prepare(
                deviceID: self.settings.cameraDeviceID,
                mirrored: self.settings.cameraMirrored
            )
            guard ok else {
                self.settings.cameraEnabled = false
                self.alert("摄像头没能开启。\n\n请在 系统设置 → 隐私与安全性 → 摄像头 里授权后重试。")
                return
            }
            // 等授权/起会话这期间用户又关掉了，或录制已停止：别把小窗晾在画面上
            guard self.settings.cameraEnabled, self.isRecordingScreen else {
                await self.cameraPip.stop()
                return
            }
            self.cameraPip.showPreview(
                captureRect: rect,
                placement: placement,
                sizeFraction: CGFloat(self.settings.cameraSize),
                mirrored: self.settings.cameraMirrored
            )
            self.cameraPip.bringPreviewToFront()
        }
    }

    private func hideCameraPreview() {
        cameraPip.hidePreview()
        Task { [weak self] in
            await self?.cameraPip.stop()
        }
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
                prepareCameraIfNeeded()
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
                prepareCameraIfNeeded()
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
        cameraPip.updateCaptureRect(rect)
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
        cameraPip.updateCaptureRect(rect)
    }

    private func beginConfirmedRecording() {
        guard let pending = pendingTarget else { return }
        guard preRecordBar.applyTo(settings: settings) != nil else {
            alert("宽高无效：请输入 16 以上的整数。")
            return
        }
        preRecordBar.hide()
        pendingTarget = nil
        Task { [weak self] in
            guard let self else { return }
            // 开关是在选区阶段打开的，摄像头通常已在跑；这里兜住「刚打开就点开始」
            if self.settings.cameraEnabled {
                let placement = self.currentCameraPlacement
                let ok = await self.cameraPip.prepare(
                    deviceID: self.settings.cameraDeviceID,
                    mirrored: self.settings.cameraMirrored
                )
                if ok {
                    self.cameraPip.setPlacement(placement)
                    self.cameraPip.showPreview(
                        captureRect: self.captureRect(for: pending),
                        placement: placement,
                        sizeFraction: CGFloat(self.settings.cameraSize),
                        mirrored: self.settings.cameraMirrored
                    )
                } else {
                    self.settings.cameraEnabled = false
                    self.preRecordBar.setCameraToggle(on: false)
                    self.alert("摄像头没能开启，本次将只录制屏幕。\n\n请在 系统设置 → 隐私与安全性 → 摄像头 里授权后重试。")
                }
            }
            self.beginRecording(pending: pending)
        }
    }

    private func beginRecording(pending: PendingTarget) {
        // 屏幕类录制一律带上 source：录制中途才打开画中画时也有合成器可用，
        // 没帧时合成器整帧透传，不开摄像头等于零开销
        let camera = cameraPip.source
        switch pending {
        case .region(let display, let screen, let rect):
            regionFrame.setEditable(false)
            // 屏幕全局坐标（NS 系）→ 显示器本地坐标（CG 系，左上原点）
            let x = rect.origin.x - screen.frame.origin.x
            let y = screen.frame.maxY - rect.maxY
            let cgRect = CGRect(x: x, y: y, width: rect.width, height: rect.height).integral
            recordingAnchor = rect
            rangeScreen = screen
            rangeWindowID = nil
            // 区域模式：宽高就是选区本身（按像素录制），不再缩放
            var capture = currentCaptureSettings(scale: screen.backingScaleFactor)
            capture.targetHeight = 0
            startWithCountdown(source: .region(display: display, rect: cgRect), settings: capture, camera: camera)
        case .window(let window):
            let rect = Self.nsRect(fromCG: window.frame)
            recordingAnchor = rect
            rangeScreen = NSScreen.screens.first { $0.frame.intersects(rect) }
            rangeWindowID = CGWindowID(window.windowID)
            startWithCountdown(
                source: .window(window),
                settings: currentCaptureSettings(scale: Self.screenScale(for: window.frame)),
                camera: camera
            )
        case .screen(let display, let screen):
            recordingAnchor = screen.frame
            rangeScreen = screen
            rangeWindowID = nil
            startWithCountdown(
                source: .display(display),
                settings: currentCaptureSettings(scale: screen.backingScaleFactor),
                camera: camera
            )
        }
    }

    // MARK: - 录制中的范围指示

    private var isRecordingScreen: Bool {
        guard coordinator.state == .recording || coordinator.state == .paused else { return false }
        return coordinator.sessionKind != .audio
    }

    /// 录制一开始就把范围框钉住：区域/整屏/窗口三种目标都有框，
    /// 否则用户录到一半不知道自己录的是哪一块
    private func pinRecordingRange() {
        guard let screen = rangeScreen, let rect = recordingAnchor, rect.width > 1, rect.height > 1 else { return }
        regionFrame.show(screen: screen, rect: rect, editable: false)
        // 预览窗固定比范围框高一层，再抬一次只是保险：框是刚 orderFront 上来的
        cameraPip.bringPreviewToFront()
        startRangeFollow()
    }

    /// 窗口会被拖走，框得跟着走；整屏和区域的几何是固定的，不用轮询
    private func startRangeFollow() {
        rangeFollowTimer?.invalidate()
        rangeFollowTimer = nil
        guard let windowID = rangeWindowID else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followRecordingWindow(windowID) }
        }
        RunLoop.main.add(timer, forMode: .common)
        rangeFollowTimer = timer
    }

    private func stopRangeFollow() {
        rangeFollowTimer?.invalidate()
        rangeFollowTimer = nil
    }

    private func followRecordingWindow(_ windowID: CGWindowID) {
        guard isRecordingScreen else { return }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let cg = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            // 窗口被关掉/最小化：框留着只会指错地方
            regionFrame.hide()
            return
        }
        let rect = Self.nsRect(fromCG: cg)
        guard rect.width > 1, rect.height > 1 else { return }
        recordingAnchor = rect
        regionFrame.update(rect: rect)
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
                // 录制期间绿框保留：只读样式标出正在录的范围，停止或取消后统一收起。
                pinRecordingRange()
                controlBar.show(
                    anchor: recordingAnchor,
                    microphone: coordinator.hasMicrophoneTrack,
                    camera: settings.cameraEnabled
                )
                controlBar.setPaused(false)
                if settings.clickHighlightEnabled { clickHighlight.start() }
            }
            startStatusTimer()
        case .paused:
            if isAudio {
                audioWindow.setRecording(true, paused: true)
            } else {
                regionFrame.bringToFront()
                cameraPip.bringPreviewToFront()
                controlBar.show(
                    anchor: recordingAnchor,
                    microphone: coordinator.hasMicrophoneTrack,
                    camera: settings.cameraEnabled
                )
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
            stopRangeFollow()
            regionFrame.hide()
            hideCameraPreview()
            recordingAnchor = nil
            rangeScreen = nil
            rangeWindowID = nil
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
        hideCameraPreview()
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
