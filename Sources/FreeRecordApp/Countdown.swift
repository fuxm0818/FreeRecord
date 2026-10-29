import AppKit
import FreeRecordCore

@MainActor
final class CountdownController: NSObject {
    private var windows: [NSWindow] = []
    private var labels: [NSTextField] = []
    private var timer: Timer?
    private var remaining = 3
    private var onFinished: (() -> Void)?
    var onTick: ((Int) -> Void)?
    private(set) var isRunning = false

    func start(seconds: Int = 3, onFinished: @escaping () -> Void) {
        cancel()
        self.onFinished = onFinished
        remaining = max(1, seconds)
        isRunning = true

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.title = ScreenCapture.hiddenWindowTitle
            // 倒计时数字全屏悬停数秒，必须两层保护都齐：系统级也不可见
            // （否则会出现在别人的屏幕共享/截图里）
            window.sharingType = .none

            let label = NSTextField(labelWithString: String(remaining))
            label.font = NSFont.systemFont(ofSize: 220, weight: .bold)
            label.textColor = NSColor.white
            label.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                shadow.shadowBlurRadius = 12
                shadow.shadowOffset = NSSize(width: 0, height: -3)
                return shadow
            }()
            label.translatesAutoresizingMaskIntoConstraints = false

            // 倒计时页面直接提示快捷键，省去再去设置里找
            let hint = NSTextField(labelWithString: "开始/停止 ⌥⌘R   暂停 ⌥⌘P")
            hint.font = NSFont.systemFont(ofSize: 17, weight: .medium)
            hint.textColor = NSColor.white.withAlphaComponent(0.85)
            hint.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                shadow.shadowBlurRadius = 8
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                return shadow
            }()
            hint.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
            container.addSubview(label)
            container.addSubview(hint)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                hint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            ])
            window.contentView = container
            window.orderFrontRegardless()
            windows.append(window)
            labels.append(label)
        }
        startTimer()
        onTick?(remaining)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        labels.removeAll()
        isRunning = false
        onFinished = nil
    }

    private func startTimer() {
        updateLabels(fade: false)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            let finished = onFinished
            cancel()
            finished?()
            return
        }
        updateLabels(fade: true)
        onTick?(remaining)
    }

    private func updateLabels(fade: Bool) {
        let text = String(remaining)
        for label in labels {
            label.stringValue = text
            if fade, let layer = label.layer {
                layer.add(CATransition.fadeIn, forKey: "countdown-fade")
            }
        }
    }
}

private extension CATransition {
    static var fadeIn: CATransition {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.25
        return transition
    }
}
