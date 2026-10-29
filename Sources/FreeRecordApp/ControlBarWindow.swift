import AppKit
import FreeRecordCore

@MainActor
final class ControlBarController: NSObject {
    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onScreenshot: (() -> Void)?
    /// 录制中静音/恢复麦克风
    var onToggleMic: (() -> Void)?
    var elapsedProvider: (() -> TimeInterval)?

    private var panel: NSPanel?
    private var timeLabel: NSTextField?
    private var pauseButton: NSButton?
    private var screenshotButton: NSButton?
    private var micButton: NSButton?
    private var timer: Timer?
    private var screenshotFeedbackTask: Task<Void, Never>?
    private(set) var isPaused = false
    private(set) var isMicMuted = false

    private static let panelSize = NSSize(width: 280, height: 50)

    func show(anchor: NSRect? = nil, microphone: Bool = false) {
        if panel == nil {
            buildPanel()
        }
        setPaused(false)
        setMicVisible(microphone)
        setMicMuted(false)
        reposition(anchor: anchor)
        panel?.orderFrontRegardless()
        startTimer()
    }

    func setMicVisible(_ visible: Bool) {
        micButton?.isHidden = !visible
    }

    func setMicMuted(_ muted: Bool) {
        isMicMuted = muted
        let symbol = muted ? "mic.slash.fill" : "mic.fill"
        micButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: muted ? "取消静音" : "静音麦克风")
        micButton?.toolTip = muted ? "取消静音" : "静音麦克风"
        micButton?.contentTintColor = muted ? .systemRed : .white
    }

    func bringToFront() {
        panel?.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        let symbol = paused ? "play.circle.fill" : "pause.circle.fill"
        pauseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: paused ? "继续录制" : "暂停录制")
        pauseButton?.toolTip = paused ? "继续录制" : "暂停录制"
        timeLabel?.textColor = paused ? .systemYellow : .white
        updateLabel()
    }

    func showScreenshotResult(success: Bool) {
        screenshotFeedbackTask?.cancel()
        guard let screenshotButton else { return }
        screenshotButton.image = NSImage(
            systemSymbolName: success ? "checkmark.circle.fill" : "xmark.circle.fill",
            accessibilityDescription: success ? "截图已保存" : "截图失败"
        )
        screenshotButton.contentTintColor = success ? .systemGreen : .systemRed
        screenshotButton.toolTip = success ? "截图已保存" : "截图失败"
        screenshotFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.screenshotButton?.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "截图")
            self.screenshotButton?.contentTintColor = .white
            self.screenshotButton?.toolTip = "截图（保存到录制目录）"
        }
    }

    private func buildPanel() {
        let size = Self.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.configureAsCaptureHiddenFloatingUI()
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let background = ControlBarView(frame: container.bounds)
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)

        let pause = NSButton(
            image: NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "暂停录制") ?? NSImage(),
            target: self,
            action: #selector(pauseClicked)
        )
        pause.isBordered = false
        pause.contentTintColor = .white
        pause.toolTip = "暂停录制"
        pause.setFrameSize(NSSize(width: 26, height: 26))
        pauseButton = pause

        let label = NSTextField(labelWithString: "00:00")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.toolTip = "录制时长"
        timeLabel = label

        let screenshot = NSButton(
            image: NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "截图") ?? NSImage(),
            target: self,
            action: #selector(screenshotClicked)
        )
        screenshot.isBordered = false
        screenshot.contentTintColor = .white
        screenshot.toolTip = "截图（保存到录制目录）"
        screenshot.setFrameSize(NSSize(width: 24, height: 24))
        screenshotButton = screenshot

        let mic = NSButton(
            image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "静音麦克风") ?? NSImage(),
            target: self,
            action: #selector(micClicked)
        )
        mic.isBordered = false
        mic.contentTintColor = .white
        mic.toolTip = "静音麦克风"
        mic.setFrameSize(NSSize(width: 24, height: 24))
        mic.isHidden = true
        micButton = mic

        // 右侧一个红色停止键，不再单独放取消键
        let stop = NSButton(title: " 停止", target: self, action: #selector(stopClicked))
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止并保存")
        stop.imagePosition = .imageLeading
        stop.bezelStyle = .rounded
        stop.controlSize = .regular
        stop.font = .systemFont(ofSize: 13, weight: .semibold)
        stop.contentTintColor = .systemRed
        stop.toolTip = "停止录制并保存"
        stop.setFrameSize(NSSize(width: 74, height: 28))
        stop.keyEquivalent = "\r"

        let stack = NSStackView(views: [pause, label, screenshot, mic, NSView(), stop])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let spacer = stack.arrangedSubviews.first(where: { $0 is NSView && !( $0 is NSControl) && !( $0 is NSSwitch) }) {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        panel.contentView = container
        panel.setFrameOrigin(Self.defaultOrigin(for: panel))
        self.panel = panel
    }

    /// 贴在录制范围右下角，放不下就退到选区下方
    private func reposition(anchor: NSRect?) {
        guard let panel else { return }
        let size = panel.frame.size
        let hostScreen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = hostScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if let anchor, anchor.width >= size.width + 24, anchor.height >= size.height + 24 {
            origin = NSPoint(x: anchor.maxX - size.width - 12, y: anchor.minY + 12)
        } else if let anchor {
            origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 8)
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    private static func defaultOrigin(for panel: NSPanel) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return NSPoint(x: 100, y: 100) }
        return NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24)
    }

    private func startTimer() {
        timer?.invalidate()
        updateLabel()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateLabel() {
        let seconds = max(0, Int(elapsedProvider?() ?? 0))
        timeLabel?.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func stopClicked() { onStop?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func screenshotClicked() { onScreenshot?() }
    @objc private func micClicked() { onToggleMic?() }
}

final class ControlBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.85).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
