import AppKit
import Quartz

@MainActor
final class ClickHighlightController: NSObject {
    static let shared = ClickHighlightController()

    private var overlay: NSWindow?
    private var overlayView: HighlightOverlayView?
    private var monitor: Any?
    private var running = false

    func start() {
        guard !running else { return }
        // 鼠标全局监听不需要「辅助功能」权限（那是键盘事件/CGEventTap 的要求），
        // 用 CGEventTap 会在录制开始时弹系统授权框
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let point = NSEvent.mouseLocation
            let down = event.type == .leftMouseDown
            Task { @MainActor in
                self?.showHighlight(at: point, down: down)
            }
        }
        showOverlayIfNeeded()
        running = true
    }

    func stop() {
        guard running else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        overlay?.orderOut(nil)
        overlay = nil
        overlayView = nil
        running = false
    }

    private func showOverlayIfNeeded() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        ensureOverlay(on: screen)
    }

    private func showHighlight(at point: CGPoint, down: Bool) {
        // NSEvent.mouseLocation 已是 AppKit 全局坐标（主屏左下原点），换算到点击所在屏的本地坐标
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        ensureOverlay(on: screen)
        let local = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        if down {
            overlayView?.addHighlight(at: local)
        } else {
            overlayView?.endHighlight()
        }
    }

    private func ensureOverlay(on screen: NSScreen) {
        if let overlay, overlay.screen == screen { return }
        overlay?.orderOut(nil)
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .floating + 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = HighlightOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.orderFrontRegardless()
        overlay = window
        overlayView = view
    }
}

final class HighlightOverlayView: NSView {
    private struct Puff {
        var center: CGPoint
        var birth: CFTimeInterval
    }

    private var puffs: [Puff] = []
    private var active: Puff?
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    func addHighlight(at point: CGPoint) {
        let puff = Puff(center: point, birth: CACurrentMediaTime())
        active = puff
        puffs.append(puff)
        startTimer()
    }

    func endHighlight() {
        active = nil
        needsDisplay = true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func animate() {
        let now = CACurrentMediaTime()
        puffs.removeAll { now - $0.birth > 0.7 }
        if puffs.isEmpty && active == nil {
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        // 按住期间：实心扩散圈
        if let active {
            let age = now - active.birth
            let radius = 16 + min(18, age * 45)
            let alpha = max(0, 0.55 - age * 0.35)
            drawCircle(center: active.center, radius: radius, alpha: alpha, ring: false)
            drawCircle(center: active.center, radius: 26, alpha: 0.9, ring: true)
        }
        // 松开后：残留光环淡出
        for puff in puffs {
            let age = now - puff.birth
            guard age < 0.7 else { continue }
            let progress = age / 0.7
            drawCircle(center: puff.center, radius: 26 + progress * 22, alpha: 0.7 * (1 - progress), ring: true)
        }
    }

    private func drawCircle(center: CGPoint, radius: CGFloat, alpha: CGFloat, ring: Bool) {
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)
        let color = NSColor.systemYellow.withAlphaComponent(alpha)
        if ring {
            color.setStroke()
            path.lineWidth = 5
            path.stroke()
        } else {
            color.withAlphaComponent(alpha * 0.5).setFill()
            path.fill()
        }
    }
}
