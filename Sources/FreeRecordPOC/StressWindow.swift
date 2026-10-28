import AppKit

@MainActor
final class StressWindowController {
    private var panel: NSPanel?
    private var view: StressView?

    func show(on screen: NSScreen) {
        hide()

        let view = StressView(frame: screen.frame)
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 压在普通窗口下面：控制窗口还能看见也能点，其余屏幕区域都在持续变化
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()

        view.startAnimation()
        self.panel = panel
        self.view = view
    }

    func hide() {
        view?.stopAnimation()
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }
}

final class StressView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]

    override var isOpaque: Bool { true }

    func startAnimation() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 9
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let stripe = bounds.width / 9
        let offset = phase.truncatingRemainder(dividingBy: stripe * 2)
        for index in -1...10 {
            let x = CGFloat(index) * stripe * 2 + offset
            let rect = NSRect(x: x, y: 0, width: stripe * 0.55, height: bounds.height)
            colors[abs(index) % colors.count].withAlphaComponent(0.8).setFill()
            rect.fill()
        }

        let radius = bounds.height * 0.14
        let travel = bounds.width + radius * 2
        let centerX = (phase * 3).truncatingRemainder(dividingBy: travel) - radius
        let centerY = bounds.midY + CGFloat(sin(Double(phase) / 40)) * bounds.height * 0.25
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: centerX - radius,
            y: centerY - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }
}
