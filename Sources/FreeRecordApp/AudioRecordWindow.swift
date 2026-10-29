import AppKit
import FreeRecordCore

/// 录制音频窗口：能量条 + 计时 + 音源开关。
@MainActor
final class AudioRecordWindowController {
    var onStart: ((AudioSource) -> Void)?
    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var elapsedProvider: (() -> TimeInterval)?

    private var panel: NSPanel?
    private var micSwitch: StatefulSwitch?
    private var systemSwitch: StatefulSwitch?
    private var timerLabel: NSTextField?
    private var meter: AudioLevelMeter?
    private var startButton: NSButton?
    private var pauseButton: NSButton?
    private var hintLabel: NSTextField?
    private var timer: Timer?
    private var level: Float = 0
    private var recording = false
    private var paused = false
    /// 启动门控进行中（权限预检 + 采集启动 + 等首帧，最长约 2.5 秒）
    private var preparing = false

    func show(settings: AppSettings) {
        if panel == nil {
            build(settings: settings)
        }
        let sceneAudio = settings.audio(for: .audioOnly)
        micSwitch?.isOn = sceneAudio.wantsMicrophone
        systemSwitch?.isOn = sceneAudio.wantsSystemAudio
        if micSwitch?.isOn != true, systemSwitch?.isOn != true {
            micSwitch?.isOn = true
        }
        updateUI()
        panel?.centerOnActiveScreen()
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        startTimer()
    }

    func hide() {
        stopTimer()
        panel?.orderOut(nil)
    }

    func bringToFront() {
        panel?.orderFrontRegardless()
    }

    func setRecording(_ recording: Bool, paused: Bool) {
        self.recording = recording
        self.paused = paused
        if recording {
            startTimer()
        } else {
            level = 0
            meter?.level = 0
        }
        updateUI()
    }

    /// 启动门控开始/结束：期间禁用按钮并给出「准备中」反馈，
    /// 否则用户在等待首帧的几秒里重复点击会被 coordinator 静默吞掉
    func setPreparing(_ value: Bool) {
        preparing = value
        updateUI()
    }

    func updateLevel(_ value: Float) {
        level = max(level * 0.6, value)
    }

    private func build(settings: AppSettings) {
        let width: CGFloat = 420
        let height: CGFloat = 168
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
        let background = ControlBarView(frame: container.bounds)
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)

        let title = NSTextField(labelWithString: "录制音频")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white

        let timeLabel = NSTextField(labelWithString: "00:00")
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        timeLabel.textColor = .white
        timerLabel = timeLabel

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭") ?? NSImage(),
            target: self,
            action: #selector(closeClicked)
        )
        close.isBordered = false
        close.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        close.setFrameSize(NSSize(width: 20, height: 20))

        let headerRow = NSStackView(views: [title, NSView(), timeLabel, close])
        headerRow.orientation = .horizontal
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerRow)

        let meter = AudioLevelMeter(frame: .zero)
        meter.translatesAutoresizingMaskIntoConstraints = false
        self.meter = meter
        container.addSubview(meter)

        // 自绘开关：开/关轨道色固定（绿/暗），不随系统强调色变成「开合同色」
        let micSwitch = StatefulSwitch()
        micSwitch.accessibilityLabelText = "麦克风"
        micSwitch.onToggle = { [weak self] _ in self?.switchChanged() }
        let systemSwitch = StatefulSwitch()
        systemSwitch.accessibilityLabelText = "系统声音"
        systemSwitch.onToggle = { [weak self] _ in self?.switchChanged() }
        self.micSwitch = micSwitch
        self.systemSwitch = systemSwitch

        let micLabel = NSTextField(labelWithString: "麦克风")
        let systemLabel = NSTextField(labelWithString: settings.supportsSystemAudio ? "系统声音" : "系统声音(BlackHole)")
        for label in [micLabel, systemLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = NSColor.white.withAlphaComponent(0.85)
        }
        systemSwitch.isEnabled = settings.supportsSystemAudio || SystemAudioSupport.findBlackHole() != nil

        let start = NSButton(title: "开始录制", target: self, action: #selector(startClicked))
        start.bezelStyle = .rounded
        start.controlSize = .large
        start.contentTintColor = .systemRed
        startButton = start

        let pause = NSButton(title: "暂停", target: self, action: #selector(pauseClicked))
        pause.bezelStyle = .rounded
        pause.controlSize = .large
        pause.isHidden = true
        pauseButton = pause

        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
        hint.lineBreakMode = .byTruncatingTail
        hintLabel = hint

        let controlsRow = NSStackView(views: [micSwitch, micLabel, systemSwitch, systemLabel, NSView(), hint, pause, start])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 6
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlsRow)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            headerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            meter.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),
            meter.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            meter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            meter.heightAnchor.constraint(equalToConstant: 30),

            controlsRow.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 16),
            controlsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            controlsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            controlsRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        panel.contentView = container
        self.panel = panel
    }

    private func selectedAudio() -> AudioSource {
        let mic = micSwitch?.isOn == true
        let system = systemSwitch?.isOn == true
        switch (mic, system) {
        case (true, true): return .microphoneAndSystem
        case (true, false): return .microphone
        case (false, true): return .system
        default: return .microphone
        }
    }

    private func updateUI() {
        micSwitch?.isEnabled = !recording && !preparing
        systemSwitch?.isEnabled = !recording && !preparing && (AppSettings.shared.supportsSystemAudio || SystemAudioSupport.findBlackHole() != nil)
        pauseButton?.isHidden = !recording
        startButton?.title = recording ? "停止并保存" : (preparing ? "准备中…" : "开始录制")
        startButton?.isEnabled = recording || (!preparing && (micSwitch?.isOn == true || systemSwitch?.isOn == true))
        startButton?.contentTintColor = .systemRed
        pauseButton?.title = paused ? "继续" : "暂停"
        hintLabel?.stringValue = recording
            ? (paused ? "已暂停" : "正在录制")
            : (preparing ? "正在启动声音采集…" : "")
        timerLabel?.textColor = paused ? .systemYellow : .white
        updateTime()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateTime()
                if !self.paused {
                    self.meter?.level = self.level
                    self.level *= 0.75
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTime() {
        guard recording else {
            timerLabel?.stringValue = "00:00"
            return
        }
        let seconds = max(0, Int(elapsedProvider?() ?? 0))
        timerLabel?.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func startClicked() {
        if recording {
            onStop?()
        } else {
            onStart?(selectedAudio())
        }
    }

    @objc private func pauseClicked() {
        onTogglePause?()
    }

    @objc private func switchChanged() {
        updateUI()
    }

    @objc private func closeClicked() {
        if recording {
            NSSound.beep()
            return
        }
        hide()
    }
}

/// 分段能量条
final class AudioLevelMeter: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let segments = 48
        let gap: CGFloat = 2
        let segmentWidth = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let lit = Int((level.clamped(to: 0...1)) * Float(segments))
        for index in 0..<segments {
            let rect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: 0,
                width: segmentWidth,
                height: bounds.height
            )
            let color: NSColor
            if index < lit {
                let ratio = Float(index) / Float(segments)
                color = ratio < 0.6 ? .systemGreen : (ratio < 0.85 ? .systemYellow : .systemRed)
            } else {
                color = NSColor.white.withAlphaComponent(0.14)
            }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
