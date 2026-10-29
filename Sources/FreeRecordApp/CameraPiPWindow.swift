import AppKit
import AVFoundation
import FreeRecordCore

private final class CameraPreviewPanel: NSPanel {
    // 非激活面板不要试图成为 key：应用不在前台时点击会被吞掉，落不到预览视图上
    override var canBecomeKey: Bool { false }
}

private let pipMinSizeFraction = CameraOverlayPlacement.minSizeFraction
private let pipMaxSizeFraction = CameraOverlayPlacement.maxSizeFraction
/// 四边和四角各 14pt 的带内按下是改尺寸，其余地方按下是移动
private let pipResizeBand: CGFloat = 14
/// 选区绿框用 .screenSaver，预览窗取它 +1：永远压在绿框之上才点得到
private let pipWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

/// 右下角的三点抓手：只做视觉提示，命中测试让开，
/// 否则 AppKit 把事件交给它（没有 mouseDown 实现），按在抓手上就变成死区
private final class ResizeGripDots: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dot: CGFloat = 3
        let gap: CGFloat = 5
        NSColor.white.withAlphaComponent(0.9).setFill()
        for i in 0..<3 {
            for j in 0..<(3 - i) {
                let rect = NSRect(
                    x: bounds.maxX - dot - CGFloat(i) * gap,
                    y: bounds.minY + CGFloat(j) * gap,
                    width: dot,
                    height: dot
                )
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

private final class CameraPreviewView: NSView {
    /// 拖边或滚轮得到的新宽度（点）与热区，钳制与落库由控制器负责
    var onResizeWidth: ((CGFloat, ResizeZone) -> Void)?
    /// 拖边结束：窗口是程序化挪位的，不会触发 windowDidMove，位置要在这里补记
    var onResizeEnded: (() -> Void)?
    /// 当前录制范围宽度（点），滚轮按它换算步长
    var captureWidthProvider: (() -> CGFloat)?

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isResizing = false
    private var resizeZone: ResizeZone?
    private var resizeStartWidth: CGFloat = 0
    private var resizeStartMouse: NSPoint?
    private weak var grip: NSView?
    private var hoverTracking: NSTrackingArea?

    // 非激活浮窗用 performDrag/isMovableByWindowBackground 拖不动或坐标错乱，这里按屏幕坐标手动跟手
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 只登记 addCursorRect 时这个非激活浮窗不刷光标，改为跟踪悬停位置自己设
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        applyHoverCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        applyHoverCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyHoverCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func applyHoverCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (ResizeZone.cursor(at: point, in: bounds, band: pipResizeBand) ?? .arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        let point = convert(event.locationInWindow, from: nil)
        if let zone = ResizeZone.zone(at: point, in: bounds, band: pipResizeBand) {
            isResizing = true
            resizeZone = zone
            resizeStartWidth = bounds.width
            resizeStartMouse = NSEvent.mouseLocation
            zone.cursor.set()
            return
        }
        isResizing = false
        resizeZone = nil
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        if isResizing, let zone = resizeZone {
            guard let start = resizeStartMouse else { return }
            let now = NSEvent.mouseLocation
            zone.cursor.set()
            // 小窗锁 16:9，纵向位移换算成宽度（往下/往上 1pt 等于宽度 16/9pt）。
            // 一律相对按下起点算：绝对「光标 x - 窗口左缘」在窗口被边界夹住时会越算越小。
            // 角上有两个方向，取更跟手的那个
            var grow: [CGFloat] = []
            if zone.touchesRight { grow.append(now.x - start.x) }
            if zone.touchesLeft { grow.append(start.x - now.x) }
            if zone.touchesTop { grow.append((now.y - start.y) * 16.0 / 9.0) }
            if zone.touchesBottom { grow.append((start.y - now.y) * 16.0 / 9.0) }
            onResizeWidth?(resizeStartWidth + (grow.max() ?? 0), zone)
            return
        }
        guard let start = dragStartMouse, let origin = dragStartOrigin else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: origin.x + now.x - start.x,
            y: origin.y + now.y - start.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            resizeZone = nil
            resizeStartMouse = nil
            onResizeEnded?()
            applyHoverCursor(for: event)
            return
        }
        isResizing = false
        dragStartMouse = nil
        dragStartOrigin = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.01, bounds.width > 1 else { return }
        let captureWidth = max(captureWidthProvider?() ?? 0, 1)
        let step = event.scrollingDeltaY > 0 ? 0.02 : -0.02
        // 滚轮没有方向，沿用「左缘钉住往右长、纵向绕中心长」
        onResizeWidth?(bounds.width + CGFloat(step) * captureWidth, .right)
    }

    /// 四边四角都是改尺寸的把手，光标按方向给足提示
    override func resetCursorRects() {
        for (rect, cursor) in ResizeZone.cursorZones(in: bounds, band: pipResizeBand) {
            addCursorRect(rect, cursor: cursor)
        }
    }

    /// 右下角的三点抓手：提示这块能拖着改大小
    func installResizeGrip() {
        guard grip == nil else { return }
        let dots = ResizeGripDots(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        addSubview(dots)
        grip = dots
    }

    /// 容器尺寸变了要重新贴回右下角（autoresizing 会把抓手留在老边距上）
    func positionResizeGrip() {
        grip?.frame = NSRect(x: max(bounds.maxX - 17, 0), y: 2, width: 16, height: 16)
        if let window { window.invalidateCursorRects(for: self) }
    }
}

/// 摄像头画中画：持有采集会话 + 可拖动的预览窗。
/// 预览窗本身不入画（标题带隐藏标记 + sharingType none），
/// 画面由合成器按预览窗在录制范围里的归一化位置画进视频。
@MainActor
final class CameraPiPController: NSObject, NSWindowDelegate {
    /// 拖动结束后写回归一化位置，供持久化
    var onPlacementChanged: ((CameraOverlayPlacement) -> Void)?
    /// 预览窗上滚轮/拖角改完尺寸后写回，供持久化
    var onSizeChanged: ((CGFloat) -> Void)?

    private(set) var isRunning = false
    private let capture = CameraPiPCapture()
    private var panel: NSPanel?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewView: CameraPreviewView?
    private var captureRect: NSRect = .zero
    private var placement = CameraOverlayPlacement()
    private var sizeFraction: CGFloat = 0.24
    private var mirrored = true
    private var isProgrammaticMove = false
    private var isSuppressed = false
    private var snapWorkItem: DispatchWorkItem?

    var source: CameraOverlaySource { capture.source }

    func prepare(deviceID: String?, mirrored: Bool) async -> Bool {
        self.mirrored = mirrored
        if !CameraPiPCapture.hasPermission {
            let granted = await CameraPiPCapture.requestPermission()
            guard granted else { return false }
        }
        do {
            try await capture.start(deviceID: deviceID)
            isRunning = true
            capture.source.placement = placement
            applyMirroring()
            return true
        } catch {
            isRunning = false
            return false
        }
    }

    func stop() async {
        hidePreview()
        guard isRunning else { return }
        await capture.stop()
        isRunning = false
    }

    /// 显示/更新预览窗。captureRect 为本次录制范围（屏幕坐标，NS 系）。
    func showPreview(
        captureRect: NSRect,
        placement: CameraOverlayPlacement,
        sizeFraction: CGFloat,
        mirrored: Bool
    ) {
        guard captureRect.width > 1, captureRect.height > 1 else { return }
        snapWorkItem?.cancel()
        snapWorkItem = nil
        isSuppressed = false
        let fraction = min(max(sizeFraction, pipMinSizeFraction), pipMaxSizeFraction)
        self.captureRect = captureRect
        self.sizeFraction = fraction
        self.mirrored = mirrored
        self.placement = placement
        self.placement.widthFraction = fraction
        self.placement.mirrored = mirrored

        if panel == nil {
            buildPanel()
        }
        guard let panel, let previewLayer else { return }
        if previewLayer.session !== capture.session {
            previewLayer.session = capture.session
        }
        applyMirroring()
        isProgrammaticMove = true
        layoutPanel()
        positionPanel()
        isProgrammaticMove = false
        capture.source.placement = self.placement
        panel.orderFrontRegardless()
    }

    func hidePreview() {
        snapWorkItem?.cancel()
        snapWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
        previewView = nil
        previewLayer = nil
    }

    /// 录制范围变化（区域改大小/位置）时同步，保持画中画相对位置不跳
    func updateCaptureRect(_ rect: NSRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        captureRect = rect
        guard let panel else { return }
        isProgrammaticMove = true
        layoutPanel()
        positionPanel()
        isProgrammaticMove = false
        panel.orderFrontRegardless()
    }

    /// 调整画中画大小：录制中改也立即生效（合成器每帧读最新 placement）
    func setSizeFraction(_ fraction: CGFloat) {
        let clamped = clampedFraction(forWidth: fraction * max(captureRect.width, 1))
        guard abs(clamped - sizeFraction) > 0.001 else { return }
        sizeFraction = clamped
        guard !isSuppressed else { return }
        placement.widthFraction = clamped
        capture.source.placement = placement
        guard panel != nil else { return }
        isProgrammaticMove = true
        layoutPanel()
        positionPanel()
        isProgrammaticMove = false
    }

    /// 拖边/拖角或滚轮改宽度：被拖的那条边跟手，对侧边钉住；顶到录制范围边界时整体挪回范围内。
    /// 这里不能走 positionPanel —— 那会按归一化中心把窗口挪回去，下一帧「光标 x - 窗口左缘」
    /// 就变小了，小窗贴着边界（默认位置就是这样）时表现为拖不动、改不了大小。
    func resizeToWidth(_ widthPoints: CGFloat, zone: ResizeZone) {
        guard let panel else { return }
        let fraction = clampedFraction(forWidth: widthPoints)
        guard abs(fraction - sizeFraction) > 0.001 else { return }
        let pinnedX = pinnedEdge(panel.frame, zone.xAnchor, horizontal: true)
        let pinnedY = pinnedEdge(panel.frame, zone.yAnchor, horizontal: false)
        sizeFraction = fraction
        if !isSuppressed {
            placement.widthFraction = fraction
            capture.source.placement = placement
        }
        isProgrammaticMove = true
        layoutPanel()
        let width = panel.frame.width, height = panel.frame.height
        var x = pinnedX
        switch zone.xAnchor {
        case .maxEdge: x = pinnedX - width
        case .center: x = pinnedX - width / 2
        case .minEdge: break
        }
        var y = pinnedY
        switch zone.yAnchor {
        case .maxEdge: y = pinnedY - height
        case .center: y = pinnedY - height / 2
        case .minEdge: break
        }
        x = min(max(x, captureRect.minX), max(captureRect.maxX - width, captureRect.minX))
        y = min(max(y, captureRect.minY), max(captureRect.maxY - height, captureRect.minY))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        isProgrammaticMove = false
        // 顶到边界时钉不住，不补记中心的话成片里的小窗还在老位置，和预览对不上
        syncPlacementToPanel()
        onSizeChanged?(sizeFraction)
    }

    /// 该热区在缩放中被钉住的那条边的当前坐标（对侧跟手）
    private func pinnedEdge(_ frame: NSRect, _ anchor: ResizeZone.Anchor, horizontal: Bool) -> CGFloat {
        switch anchor {
        case .minEdge: return horizontal ? frame.minX : frame.minY
        case .maxEdge: return horizontal ? frame.maxX : frame.maxY
        case .center: return horizontal ? frame.midX : frame.midY
        }
    }

    /// 拖角改完尺寸后按最终窗口位置补记归一化中心，保证成片与预览一致
    func commitDraggedPlacement() {
        syncPlacementToPanel()
        isProgrammaticMove = true
        positionPanel()
        isProgrammaticMove = false
    }

    /// 以预览窗当前位置为准回写归一化中心（合成器与持久化都用它）
    private func syncPlacementToPanel() {
        guard let panel, captureRect.width > 1, captureRect.height > 1 else { return }
        placement.centerX = min(max((panel.frame.midX - captureRect.minX) / captureRect.width, 0), 1)
        placement.centerY = min(max((panel.frame.midY - captureRect.minY) / captureRect.height, 0), 1)
        if !isSuppressed { capture.source.placement = placement }
        onPlacementChanged?(placement)
    }

    /// 宽度（点）→ 占录制范围的比例，上下限与实际渲染的像素限制对齐
    private func clampedFraction(forWidth widthPoints: CGFloat) -> CGFloat {
        var lower = pipMinSizeFraction
        var upper = pipMaxSizeFraction
        let captureWidth = max(captureRect.width, 1)
        if captureRect.width > 1 {
            lower = max(lower, 120 / captureRect.width)
            let maxWidth = max(60, min(captureRect.width, captureRect.height * 16.0 / 9.0))
            upper = min(upper, maxWidth / captureRect.width)
        }
        return min(max(widthPoints / captureWidth, lower), upper)
    }

    func setMirrored(_ flag: Bool) {
        mirrored = flag
        placement.mirrored = flag
        capture.source.placement = placement
        applyMirroring()
    }

    func setPlacement(_ newPlacement: CameraOverlayPlacement) {
        placement = newPlacement
        placement.widthFraction = sizeFraction
        placement.mirrored = mirrored
        capture.source.placement = placement
        guard panel != nil else { return }
        isProgrammaticMove = true
        positionPanel()
        isProgrammaticMove = false
    }

    var isShowingPreview: Bool { panel != nil }

    /// 抬到本层最前：预览窗本身已高范围框一层，这里管的是同层别的浮窗（倒计时、别的 App 的全屏层）
    func bringPreviewToFront() {
        panel?.orderFrontRegardless()
    }

    /// 立刻不再往画面里画小窗：合成器读到 widthFraction <= 0 就整帧透传，
    /// 不等采集会话收尾（stopRunning 要几百毫秒，这期间老帧还会继续合进视频）
    func suppressOverlay() {
        isSuppressed = true
        placement.widthFraction = 0
        capture.source.placement = placement
    }

    // MARK: - 窗口

    private func buildPanel() {
        let panel = CameraPreviewPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 180)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 必须比选区绿框高一层：两者同为 screenSaver 时，绿框一旦被抬起（拖动/录制状态变化重新 orderFront）
        // 就会盖住预览窗，按在画中画上的点击全落到绿框上，表现为拖不动也改不了大小
        panel.configureAsCaptureHiddenFloatingUI(level: pipWindowLevel)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        let container = CameraPreviewView(frame: NSRect(origin: .zero, size: NSSize(width: 320, height: 180)))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        container.layer?.borderWidth = 2
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        container.toolTip = "拖动移动 · 拖四边四角或滚轮调整大小"
        container.captureWidthProvider = { [weak self] in self?.captureRect.width ?? 0 }
        container.onResizeWidth = { [weak self] width, zone in self?.resizeToWidth(width, zone: zone) }
        container.onResizeEnded = { [weak self] in self?.commitDraggedPlacement() }
        container.installResizeGrip()

        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = container.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer?.addSublayer(layer)

        panel.contentView = container
        self.panel = panel
        self.previewLayer = layer
        self.previewView = container
    }

    private func layoutPanel() {
        guard let panel else { return }
        let maxWidth = max(60, min(captureRect.width, captureRect.height * 16.0 / 9.0))
        let width = min(max(120, sizeFraction * captureRect.width), maxWidth)
        let height = width * 9.0 / 16.0
        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
        if let container = panel.contentView {
            container.frame = NSRect(origin: .zero, size: frame.size)
            container.layer?.cornerRadius = min(width, height) * 0.12
        }
        previewView?.positionResizeGrip()
        previewLayer?.frame = panel.contentView?.bounds ?? .zero
    }

    private func positionPanel() {
        guard let panel else { return }
        let width = panel.frame.width
        let height = panel.frame.height
        guard captureRect.width > width, captureRect.height > height else { return }
        let nx = min(max(placement.centerX, 0), 1)
        let ny = min(max(placement.centerY, 0), 1)
        let centerX = min(
            max(captureRect.minX + nx * captureRect.width, captureRect.minX + width / 2),
            captureRect.maxX - width / 2
        )
        let centerY = min(
            max(captureRect.minY + ny * captureRect.height, captureRect.minY + height / 2),
            captureRect.maxY - height / 2
        )
        panel.setFrameOrigin(NSPoint(x: centerX - width / 2, y: centerY - height / 2))
    }

    private func applyMirroring() {
        guard let connection = previewLayer?.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, captureRect.width > 1, !isProgrammaticMove else { return }
        // 拖动中只记录位置、不在这里改窗口坐标；松手后的延迟吸附负责收回录制范围
        let frame = panel.frame
        let centerX = (frame.midX - captureRect.minX) / captureRect.width
        let centerY = (frame.midY - captureRect.minY) / captureRect.height
        placement.centerX = min(max(centerX, 0), 1)
        placement.centerY = min(max(centerY, 0), 1)
        capture.source.placement = placement
        onPlacementChanged?(placement)
        scheduleSnapAfterDrag()
    }

    private func scheduleSnapAfterDrag() {
        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.snapIntoCaptureRect() }
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 拖动结束后把预览窗吸附回录制范围内，保证预览与成片位置一致
    private func snapIntoCaptureRect() {
        snapWorkItem = nil
        guard panel != nil else { return }
        isProgrammaticMove = true
        positionPanel()
        isProgrammaticMove = false
    }
}
