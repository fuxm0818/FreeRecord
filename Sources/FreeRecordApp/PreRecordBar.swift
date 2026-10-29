import AppKit
import FreeRecordCore

enum PreRecordTarget {
    case screen(NSScreen)
    case region(NSScreen, CGRect)
    case windowRect(NSRect)

    var preferredBarOrigin: NSPoint? {
        switch self {
        case .screen(let screen):
            let frame = screen.visibleFrame
            return NSPoint(x: frame.midX, y: frame.minY + 80)
        case .region(_, let rect):
            return NSPoint(x: rect.midX, y: rect.minY)
        case .windowRect(let rect):
            return NSPoint(x: rect.midX, y: rect.minY)
        }
    }
}

/// 预录制工具栏（640×50 单行）：
/// 宽高 · 分辨率/帧率 · 麦克风/系统声音/点击高亮/摄像头画中画开关 · 开始录制。
@MainActor
final class PreRecordBarController: NSObject {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 仅区域模式：用户在工具栏里改宽/高时回调（用于同步移动选区绿框）
    var onSizeEdited: ((NSSize) -> Void)?
    /// 摄像头画中画开关（需要异步申请权限，交给上层处理）
    var onCameraToggled: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var micButton: NSButton?
    private var systemButton: NSButton?
    private var mouseButton: NSButton?
    private var cameraButton: NSButton?
    private var widthField: NSTextField?
    private var heightField: NSTextField?
    private var resolutionPopup: NSPopUpButton?
    private var fpsPopup: NSPopUpButton?
    private var target: PreRecordTarget?
    private var basePixelSize: NSSize = .zero
    private var pixelScale: Double = 1
    private weak var settingsRef: AppSettings?

    private static let panelSize = NSSize(width: 640, height: 50)

    func show(target: PreRecordTarget, settings: AppSettings, pixelSize: NSSize, pixelScale: Double = 1) {
        hide()
        self.target = target
        self.basePixelSize = pixelSize
        self.pixelScale = max(pixelScale, 1)
        self.settingsRef = settings

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

        let widthField = makeSizeField("\(Int(pixelSize.width))")
        widthField.toolTip = "宽度（像素）"
        let heightField = makeSizeField("\(Int(pixelSize.height))")
        heightField.toolTip = "高度（像素）"
        self.widthField = widthField
        self.heightField = heightField

        let timesLabel = NSTextField(labelWithString: "×")
        timesLabel.font = .systemFont(ofSize: 11)
        timesLabel.textColor = NSColor.white.withAlphaComponent(0.5)

        let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        resolutionPopup.addItems(withTitles: ["原始分辨率", "1080P", "720P"])
        resolutionPopup.toolTip = "录制分辨率"
        resolutionPopup.selectItem(at: settings.targetHeight == 0 ? 0 : (settings.targetHeight == 1080 ? 1 : 2))
        stylePopup(resolutionPopup)
        self.resolutionPopup = resolutionPopup

        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: ["15FPS", "30FPS", "60FPS"])
        fpsPopup.toolTip = "帧率"
        fpsPopup.selectItem(at: settings.fps == 15 ? 0 : (settings.fps == 30 ? 1 : 2))
        stylePopup(fpsPopup)
        self.fpsPopup = fpsPopup

        let systemAvailable = systemAudioAvailable(settings)
        let micButton = makeToggle(
            symbol: "mic.fill",
            tip: "麦克风",
            isOn: settings.audio(for: .screen).wantsMicrophone
        )
        let systemButton = makeToggle(
            symbol: "speaker.wave.2.fill",
            tip: systemAvailable ? "系统声音" : "系统声音需 macOS 13 或 BlackHole",
            isOn: settings.audio(for: .screen).wantsSystemAudio && systemAvailable
        )
        systemButton.isEnabled = systemAvailable
        let mouseButton = makeToggle(
            symbol: "cursorarrow.click.2",
            tip: "点击高亮",
            isOn: settings.clickHighlightEnabled
        )
        let cameraButton = makeToggle(
            symbol: "person.crop.rectangle",
            tip: "摄像头画中画",
            isOn: settings.cameraEnabled
        )
        cameraButton.target = self
        cameraButton.action = #selector(cameraClicked(_:))
        self.micButton = micButton
        self.systemButton = systemButton
        self.mouseButton = mouseButton
        self.cameraButton = cameraButton

        let startButton = NSButton(title: "开始录制", target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .regular
        startButton.font = .systemFont(ofSize: 13, weight: .semibold)
        startButton.contentTintColor = .systemRed
        startButton.toolTip = "开始录制"
        startButton.keyEquivalent = "\r"

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "取消") ?? NSImage(),
            target: self,
            action: #selector(closeClicked)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        closeButton.toolTip = "取消"
        closeButton.setFrameSize(NSSize(width: 20, height: 20))

        // 弹性占位：单独持有再设低抱合力。
        // 不能用 first(where: 非NSControl) 查找——NSBox 不是 NSControl，
        // 会误命中第一条分隔线，窗口拉宽时竖线被拉出空白段
        let spacer = NSView()
        let stack = NSStackView(views: [
            widthField, timesLabel, heightField,
            makeSeparator(),
            resolutionPopup, fpsPopup,
            makeSeparator(),
            micButton, systemButton, mouseButton, cameraButton,
            spacer,
            startButton, closeButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        panel.contentView = container
        panel.setFrameOrigin(Self.barOrigin(for: target, panelSize: size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        target = nil
        micButton = nil
        systemButton = nil
        mouseButton = nil
        cameraButton = nil
        widthField = nil
        heightField = nil
        resolutionPopup = nil
        fpsPopup = nil
    }

    var isShowing: Bool { panel != nil }

    /// 摄像头权限失败等场景由上层把开关拨回去
    func setCameraToggle(on: Bool) {
        guard let cameraButton else { return }
        cameraButton.state = on ? .on : .off
        applyToggleStyle(cameraButton)
    }

    /// 选区绿框拖动/缩放或字段联动后同步：更新锚点与像素宽高（拖动过程中不挪工具栏，拖完再挪）
    func updateRegion(rect: NSRect, pixelSize: NSSize) {
        guard case .region(let screen, _) = target else { return }
        target = .region(screen, rect)
        basePixelSize = pixelSize
        widthField?.stringValue = "\(Int(pixelSize.width.rounded()))"
        heightField?.stringValue = "\(Int(pixelSize.height.rounded()))"
    }

    /// 按当前目标重新贴到选区旁
    func reposition() {
        guard let panel, let target else { return }
        panel.setFrameOrigin(Self.barOrigin(for: target, panelSize: panel.frame.size))
    }

    /// 读取工具栏当前参数，写回 AppSettings 并返回像素宽高
    func applyTo(settings: AppSettings) -> (pixelWidth: Int, pixelHeight: Int)? {
        guard let widthText = widthField?.stringValue, let heightText = heightField?.stringValue,
              let width = Int(widthText), let height = Int(heightText),
              width >= 16, height >= 16 else {
            return nil
        }
        let mic = micButton?.state == .on
        let system = systemButton?.state == .on
        settings.setAudio(mic && system ? .microphoneAndSystem : (mic ? .microphone : (system ? .system : .none)), for: .screen)
        settings.clickHighlightEnabled = mouseButton?.state == .on
        settings.fps = [15, 30, 60][max(0, fpsPopup?.indexOfSelectedItem ?? 1)]
        // 高度低于原始尺寸才算缩放；等于原始或用户没改就是原始分辨率
        settings.targetHeight = height < Int(basePixelSize.height) ? height : 0
        return (width, height)
    }

    // MARK: - 控件

    private func makeSizeField(_ text: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.10)
        field.focusRingType = .none
        field.isBordered = false
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        return field
    }

    private func stylePopup(_ popup: NSPopUpButton) {
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(parameterChanged)
        popup.contentTintColor = .white
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func makeToggle(symbol: String, tip: String, isOn: Bool) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
            target: self,
            action: #selector(toggleChanged(_:))
        )
        button.isBordered = false
        button.setButtonType(.toggle)
        button.toolTip = tip
        button.state = isOn ? .on : .off
        button.wantsLayer = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.layer?.cornerRadius = 6
        applyToggleStyle(button)
        return button
    }

    private func applyToggleStyle(_ button: NSButton) {
        let on = button.state == .on
        // 开/关必须一眼可辨：开 = 绿底白图标，关 = 暗底淡图标
        button.contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.35)
        button.layer?.backgroundColor = on
            ? NSColor.systemGreen.withAlphaComponent(0.85).cgColor
            : NSColor.white.withAlphaComponent(0.10).cgColor
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    private func systemAudioAvailable(_ settings: AppSettings) -> Bool {
        settings.supportsSystemAudio || SystemAudioSupport.findBlackHole() != nil
    }

    private static func barOrigin(for target: PreRecordTarget, panelSize: NSSize) -> NSPoint {
        guard let preferred = target.preferredBarOrigin else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSPoint(x: screen.midX - panelSize.width / 2, y: screen.midY - panelSize.height / 2)
        }
        let screen = NSScreen.screens.first { screen in
            let point = NSPoint(x: preferred.x, y: preferred.y + panelSize.height)
            return NSMouseInRect(point, screen.frame, false)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = preferred.x - panelSize.width / 2
        var y = preferred.y - panelSize.height - 10
        if y < visible.minY + 8 {
            y = preferred.y + 10
        }
        x = min(max(x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        return NSPoint(x: x, y: y)
    }

    @objc private func parameterChanged() {
        guard let widthField, let heightField else { return }
        let target = [0.0, 1080.0, 720.0][max(0, resolutionPopup?.indexOfSelectedItem ?? 0)]
        guard target > 0, basePixelSize.height > 0 else {
            widthField.stringValue = "\(Int(basePixelSize.width))"
            heightField.stringValue = "\(Int(basePixelSize.height))"
            return
        }
        let factor = target / basePixelSize.height
        widthField.stringValue = "\(max(2, Int((basePixelSize.width * factor).rounded())))"
        heightField.stringValue = "\(Int(target))"
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        applyToggleStyle(sender)
        // 开关立即生效，不必等开始录制
        guard let settings = settingsRef else { return }
        let mic = micButton?.state == .on
        let system = systemButton?.state == .on
        settings.setAudio(mic && system ? .microphoneAndSystem : (mic ? .microphone : (system ? .system : .none)), for: .screen)
        settings.clickHighlightEnabled = mouseButton?.state == .on
    }

    @objc private func cameraClicked(_ sender: NSButton) {
        applyToggleStyle(sender)
        onCameraToggled?(sender.state == .on)
    }

    @objc private func startClicked() {
        // 先结束文本框编辑（触发 controlTextDidEndEditing → 同步选区绿框），再开始
        panel?.makeFirstResponder(nil)
        onStart?()
    }

    @objc private func closeClicked() {
        onCancel?()
    }
}

extension PreRecordBarController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        guard field == widthField || field == heightField else { return }
        guard case .region = target else { return }
        if let width = Int(widthField?.stringValue ?? ""), let height = Int(heightField?.stringValue ?? ""),
           width >= 16, height >= 16 {
            // 工具栏里是像素值，选区绿框是点坐标
            let scale = pixelScale
            onSizeEdited?(NSSize(width: Double(width) / scale, height: Double(height) / scale))
        }
    }
}

extension NSSwitch {
    var isChecked: Bool { state == .on }
}
