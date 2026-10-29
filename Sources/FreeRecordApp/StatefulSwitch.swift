import AppKit

/// 状态色固定的开关控件（用于替代深色面板上的 `NSSwitch`）。
///
/// `NSSwitch` 的轨道色跟随系统强调色：graphite 等低饱和强调色下，开与关的
/// 轨道几乎同色（实测反馈「左滑右滑底色一样」），在自绘深色面板上完全无法
/// 辨识。本控件自绘轨道与滑块并**固定状态色**：开 = 绿色轨道 + 滑块靠右，
/// 关 = 低透明白轨道 + 滑块靠左，不随外观 / 强调色变化。
final class StatefulSwitch: NSView {

    /// 程序赋值只更新外观；用户点击才触发 `onToggle`
    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            refresh(animated: true)
        }
    }

    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    /// 用户点击开关后的回调（程序赋值 `isOn` 不触发）
    var onToggle: (@MainActor (Bool) -> Void)?

    var onColor: NSColor = .systemGreen
    var offColor: NSColor = NSColor.white.withAlphaComponent(0.22)
    var knobColor: NSColor = .white

    private let knobLayer = CALayer()
    private static let preferredSize = NSSize(width: 38, height: 20)

    init(isOn: Bool = false) {
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        wantsLayer = true
        layer?.cornerRadius = Self.preferredSize.height / 2
        knobLayer.cornerRadius = (Self.preferredSize.height - 4) / 2
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.35
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        knobLayer.shadowRadius = 1.5
        knobLayer.backgroundColor = knobColor.cgColor
        layer?.addSublayer(knobLayer)
        // layer 就绪后再赋值：否则 didSet 会白跑一次动画事务
        self.isOn = isOn
        refresh(animated: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = bounds.height / 2
        layer?.addSublayer(knobLayer)
        refresh(animated: false)
    }

    override var intrinsicContentSize: NSSize { Self.preferredSize }

    // MARK: - 无障碍（AppKit 无障碍 API 是可重写的方法，不是属性）

    /// 语义标签：同一窗口有多个开关时（如「麦克风」「系统声音」）必须可区分
    var accessibilityLabelText = "开关"

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }

    override func accessibilityLabel() -> String? { accessibilityLabelText }

    override func accessibilityValue() -> Any? { isOn ? "开" : "关" }

    /// VoiceOver / 键盘操作入口
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        onToggle?(isOn)
        return true
    }

    override func layout() {
        super.layout()
        refresh(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            NSSound.beep()
            return
        }
        isOn.toggle()
        onToggle?(isOn)
    }

    private func refresh(animated: Bool) {
        let knobSize = bounds.height - 4
        let target = NSRect(
            x: isOn ? bounds.width - knobSize - 2 : 2,
            y: 2,
            width: knobSize,
            height: knobSize)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        knobLayer.frame = target
        layer?.backgroundColor = (isOn ? onColor : offColor).cgColor
        CATransaction.commit()
    }
}
