import AVFoundation
import AppKit
import FreeRecordCore

/// 摄像头录制窗口：实时预览 + 录制/暂停/停止。
@MainActor
final class CameraRecordWindowController: NSObject {
    var onSaved: ((SavedRecording) -> Void)?
    var onFailed: ((String) -> Void)?

    private let capture = CameraCapture()
    private var panel: NSPanel?
    private var previewContainer: NSView?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var timerLabel: NSTextField?
    private var startButton: NSButton?
    private var pauseButton: NSButton?
    private var statusLabel: NSTextField?
    private var timer: Timer?
    private var writer: RecordingWriter?
    private var outputURL: URL?

    private var accumulated: TimeInterval = 0
    private var resumedAt: Date?
    private var pauseStarted: Date?
    private var isFinishing = false

    var isRecording: Bool { writer != nil && !isFinishing }
    var isShowing: Bool { panel != nil }

    private var elapsed: TimeInterval {
        guard let resumedAt else { return accumulated }
        var total = accumulated + Date().timeIntervalSince(resumedAt)
        if let pauseStarted { total -= Date().timeIntervalSince(pauseStarted) }
        return max(0, total)
    }

    func show(saveDirectory: URL) {
        self.saveDirectory = saveDirectory
        if let panel {
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            capture.startRunning()
            return
        }
        Task { [weak self] in
            await self?.prepare(saveDirectory: saveDirectory)
        }
    }

    func hide() {
        stopTimer()
        capture.stopRunning()
        panel?.orderOut(nil)
    }

    private func prepare(saveDirectory: URL) async {
        let cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        guard cameraGranted else {
            onFailed?("没有摄像头权限。\n\n请在 系统设置 → 隐私与安全性 → 摄像头 里授权后重试。")
            return
        }
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        do {
            try capture.configure(hasAudio: micGranted)
        } catch {
            onFailed?("摄像头启动失败：\(error.localizedDescription)")
            return
        }
        buildPanel(saveDirectory: saveDirectory)
        capture.startRunning()
    }

    private func buildPanel(saveDirectory: URL) {
        let width: CGFloat = 640
        let height: CGFloat = 430
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.configureAsCaptureHiddenFloatingUI()
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let preview = NSView(frame: NSRect(x: 0, y: 60, width: width, height: height - 60))
        preview.wantsLayer = true
        preview.autoresizingMask = [.width, .height]
        container.addSubview(preview)
        previewContainer = preview

        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = preview.bounds
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        preview.layer?.addSublayer(layer)
        previewLayer = layer

        let bottom = ControlBarView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        bottom.autoresizingMask = [.width, .height]
        container.addSubview(bottom)

        let title = NSTextField(labelWithString: "摄像头录制")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white

        let timerLabel = NSTextField(labelWithString: "00:00")
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timerLabel.textColor = .white
        self.timerLabel = timerLabel

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.55)
        statusLabel = status

        let start = NSButton(title: "开始录制", target: self, action: #selector(startClicked))
        start.bezelStyle = .rounded
        start.controlSize = .large
        start.contentTintColor = .systemRed
        startButton = start

        let pause = NSButton(title: "暂停", target: self, action: #selector(pauseClicked))
        pause.bezelStyle = .rounded
        pause.isHidden = true
        pauseButton = pause

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭") ?? NSImage(),
            target: self,
            action: #selector(closeClicked)
        )
        close.isBordered = false
        close.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        close.setFrameSize(NSSize(width: 20, height: 20))

        let row = NSStackView(views: [title, timerLabel, status, NSView(), pause, start, close])
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -30),
        ])

        panel.contentView = container
        panel.setFrameOrigin(Self.defaultOrigin(for: panel))
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        self.saveDirectory = saveDirectory
    }

    private var saveDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/自由录屏", isDirectory: true)

    private static func defaultOrigin(for panel: NSPanel) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2)
    }

    // MARK: - 录制

    @objc private func startClicked() {
        if writer != nil {
            stopRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        do {
            let url = RecordingCoordinator.outputURL(in: saveDirectory, audioOnly: false)
            let writer = try RecordingWriter(
                url: url,
                width: 1280,
                height: 720,
                fps: 30,
                hasMicTrack: capture.hasAudioTrack,
                hasSystemTrack: false,
                bitrate: 8_000_000
            )
            self.writer = writer
            self.outputURL = url
            accumulated = 0
            resumedAt = Date()
            pauseStarted = nil
            isFinishing = false
            capture.attach(writer: writer)
            startTimer()
            updateUI()
        } catch {
            onFailed?("开始录制失败：\(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let writer, !isFinishing else { return }
        if let pauseStarted {
            accumulated += Date().timeIntervalSince(pauseStarted)
            self.pauseStarted = nil
        }
        let duration = elapsed
        isFinishing = true
        capture.detachWriter()
        stopTimer()
        updateUI()

        Task { [weak self] in
            do {
                let url = try await writer.finish()
                guard let self else { return }
                self.writer = nil
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
                let recording = SavedRecording(
                    url: url,
                    duration: duration,
                    width: 1280,
                    height: 720,
                    fileSizeMB: size / 1_048_576,
                    audioTrackCount: writer.audioTrackCount
                )
                self.isFinishing = false
                self.updateUI()
                self.onSaved?(recording)
            } catch {
                guard let self else { return }
                self.writer = nil
                self.isFinishing = false
                self.updateUI()
                self.onFailed?("保存失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func pauseClicked() {
        guard let writer else { return }
        if let pauseStarted {
            accumulated += Date().timeIntervalSince(pauseStarted)
            self.pauseStarted = nil
            writer.setPaused(false)
        } else {
            pauseStarted = Date()
            writer.setPaused(true)
        }
        updateUI()
    }

    @objc private func closeClicked() {
        if writer != nil, !isFinishing {
            stopRecording()
        }
        hide()
    }

    private func updateUI() {
        let recording = writer != nil
        startButton?.title = isFinishing ? "保存中…" : (recording ? "停止并保存" : "开始录制")
        startButton?.isEnabled = !isFinishing
        pauseButton?.isHidden = !recording || isFinishing
        pauseButton?.title = pauseStarted != nil ? "继续" : "暂停"
        statusLabel?.stringValue = isFinishing ? "正在保存…" : (pauseStarted != nil ? "已暂停" : (recording ? "录制中" : ""))
        timerLabel?.textColor = pauseStarted != nil ? .systemYellow : .white
        updateTime()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTime() {
        guard writer != nil else {
            timerLabel?.stringValue = "00:00"
            return
        }
        let seconds = max(0, Int(elapsed))
        timerLabel?.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
