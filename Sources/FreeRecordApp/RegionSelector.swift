import AppKit
import FreeRecordCore
import ScreenCaptureKit

/// 统一选区层：
/// 悬停哪个窗口就高亮哪个，单击录这个窗口；拖拽框选录区域；点在桌面录全屏；ESC 取消。
@MainActor
final class RegionSelector {
    var onRegionSelected: ((NSScreen, CGRect) -> Void)?
    var onWindowSelected: ((SCWindow) -> Void)?
    var onScreenSelected: ((NSScreen) -> Void)?
    var onCancelled: (() -> Void)?
    /// 拿不到可共享窗口（通常是没给屏幕录制权限）
    var onUnavailable: (() -> Void)?

    private var panels: [RegionOverlayPanel] = []
    private var views: [RegionOverlayView] = []
    private var keyMonitor: Any?
    private var moveMonitor: Any?
    private var windowsByID: [CGWindowID: SCWindow] = [:]
    private var hovered: (rect: CGRect, label: String, window: SCWindow)?
    private var isLoading = false

    func show() {
        hide()
        for screen in NSScreen.screens {
            let panel = RegionOverlayPanel(contentRect: screen.frame)
            let view = RegionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.selector = self
            view.screen = screen
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
            views.append(view)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.refreshHover()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        refreshHover()
        loadWindows()
    }

    func hide() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let moveMonitor {
            NSEvent.removeMonitor(moveMonitor)
            self.moveMonitor = nil
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        views.removeAll()
        windowsByID.removeAll()
        hovered = nil
        isLoading = false
    }

    private func loadWindows() {
        isLoading = true
        applyHover()
        Task { [weak self] in
            guard let self else { return }
            let content = try? await ScreenCapture.loadShareableContent()
            guard !self.panels.isEmpty else { return }
            self.isLoading = false
            guard let content else {
                self.hide()
                self.onUnavailable?()
                return
            }
            let ownBundle = Bundle.main.bundleIdentifier
            var map: [CGWindowID: SCWindow] = [:]
            for window in content.windows where window.isOnScreen {
                if let own = ownBundle, window.owningApplication?.bundleIdentifier == own { continue }
                map[window.windowID] = window
            }
            self.windowsByID = map
            self.refreshHover()
        }
    }

    /// 返回鼠标下最上层的可录制窗口（需要先加载 windowsByID）
    private func candidate() -> (rect: CGRect, label: String, window: SCWindow)? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: mouse.x, y: mainMaxY - mouse.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80,
                  bounds.contains(point),
                  let number = info[kCGWindowNumber as String] as? Int,
                  let window = windowsByID[CGWindowID(number)] else { continue }
            let app = window.owningApplication?.applicationName ?? ""
            let title = window.title?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = title.isEmpty ? app : "\(app) — \(title)"
            return (bounds, label, window)
        }
        return nil
    }

    private func refreshHover() {
        let hit = candidate()
        hovered = hit.map { ($0.rect, $0.label, $0.window) }
        applyHover()
    }

    private func applyHover() {
        let mouse = NSEvent.mouseLocation
        for view in views {
            guard let screen = view.screen else { continue }
            var localRect: NSRect?
            var label: String?
            if let hovered, screen.frame.contains(mouse) {
                let rect = CGRect(
                    x: hovered.rect.minX - screen.frame.minX,
                    y: screen.frame.maxY - hovered.rect.maxY,
                    width: hovered.rect.width,
                    height: hovered.rect.height
                )
                localRect = rect.intersection(NSRect(origin: .zero, size: screen.frame.size))
                label = hovered.label
            }
            view.apply(highlight: localRect, label: label, loading: isLoading)
        }
    }

    /// 空桌面单击不动作（避免误触全屏），双击才录全屏；悬停窗口单击录制
    fileprivate func pickHovered(in screen: NSScreen?, doubleClick: Bool) {
        if let hovered {
            hide()
            onWindowSelected?(hovered.window)
            return
        }
        guard doubleClick, let screen else {
            return
        }
        hide()
        onScreenSelected?(screen)
    }

    fileprivate func select(screen: NSScreen, rect: CGRect) {
        hide()
        onRegionSelected?(screen, rect)
    }

    fileprivate func cancel() {
        hide()
        onCancelled?()
    }
}

final class RegionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        // 悬停选窗依赖 mouseMoved，无边框面板默认不接收
        acceptsMouseMovedEvents = true
        // 选区层只给用户看，任何捕获 API（含第三方录屏）都拍不到
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(contentRect, display: true)
    }
}

final class RegionOverlayView: NSView {
    weak var selector: RegionSelector?
    var screen: NSScreen?

    private var dragStart: NSPoint?
    private var dragRect: NSRect = .zero
    private var highlight: NSRect?
    private var highlightLabel: String?
    private var loading = false

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func apply(highlight: NSRect?, label: String?, loading: Bool) {
        if self.highlight != highlight || highlightLabel != label || self.loading != loading {
            self.highlight = highlight
            self.highlightLabel = label
            self.loading = loading
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if dragRect.width > 1, dragRect.height > 1 {
            drawSelection(frame: dragRect, label: "\(Int(dragRect.width)) × \(Int(dragRect.height))", labelColor: .systemGreen, labelInverted: false)
        } else if let highlight, highlight.width > 1, highlight.height > 1 {
            drawSelection(frame: highlight, label: highlightLabel, labelColor: .systemGreen, labelInverted: true)
        } else {
            let text = loading ? "正在识别窗口…" : "单击录制窗口 · 拖拽框选区域 · 双击桌面录全屏 · ESC 取消"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.55),
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 70), withAttributes: attributes)
        }
    }

    private func drawSelection(frame rect: NSRect, label: String?, labelColor: NSColor, labelInverted: Bool) {
        rect.fill(using: .clear)
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()
        drawCornerBrackets(in: rect, length: 18, lineWidth: 3.5, color: .systemGreen)

        guard let label, !label.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: labelInverted ? .white : NSColor.systemGreen,
            .backgroundColor: labelInverted
                ? NSColor.systemGreen.withAlphaComponent(0.92)
                : NSColor.black.withAlphaComponent(0.6),
        ]
        let size = label.size(withAttributes: attributes)
        let origin = labelInverted
            ? NSPoint(x: min(max(bounds.minX + 4, rect.minX), bounds.maxX - size.width - 4), y: min(rect.maxY + 4, bounds.maxY - size.height))
            : NSPoint(x: min(max(bounds.minX, rect.minX), bounds.maxX - size.width), y: max(bounds.minY, rect.minY - size.height - 6))
        label.draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragRect = Self.rect(from: start, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let end = convert(event.locationInWindow, from: nil)
        let rect = Self.rect(from: start, to: end)
        if rect.width >= 20, rect.height >= 20, let screen {
            let global = convert(rect, to: nil)
            selector?.select(screen: screen, rect: global)
            return
        }
        dragRect = .zero
        needsDisplay = true
        // 没拖动 = 单击：选悬停窗口；空桌面单击不动作，双击录全屏
        if hypot(end.x - start.x, end.y - start.y) <= 6 {
            selector?.pickHovered(in: screen, doubleClick: event.clickCount >= 2)
        }
    }

    private static func rect(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }
}

/// 选定区域后的绿框：确认录制前可拖动移动、四角四边缩放；
/// 开始录制后转为只读提示。标题带隐藏标记，不会进画面。
@MainActor
final class RegionFrameController {
    /// 编辑中选区变化（屏幕坐标，NS 系），拖动/缩放过程中持续回调
    var onChange: ((NSRect) -> Void)?
    var onDragEnded: (() -> Void)?
    private(set) var currentRect: NSRect?
    private var panel: RegionFramePanel?

    func show(screen: NSScreen, rect: CGRect, editable: Bool) {
        hide()
        currentRect = rect
        let panel = RegionFramePanel(contentRect: rect, editable: editable)
        let view = RegionFrameView(frame: NSRect(origin: .zero, size: rect.size))
        view.controller = self
        view.screen = screen
        view.editable = editable
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// 同步外部改的尺寸（预录制条宽高字段），不回触发 onChange
    func update(rect: CGRect) {
        currentRect = rect
        panel?.setFrame(rect, display: true)
        if let view = panel?.contentView as? RegionFrameView {
            view.regionSize = rect.size
            view.needsDisplay = true
        }
    }

    func setEditable(_ editable: Bool) {
        panel?.ignoresMouseEvents = !editable
        if let view = panel?.contentView as? RegionFrameView {
            view.editable = editable
            view.needsDisplay = true
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        currentRect = nil
    }

    fileprivate func regionChanged(to rect: NSRect) {
        currentRect = rect
        onChange?(rect)
    }

    fileprivate func dragEnded() {
        onDragEnded?()
    }
}

final class RegionFramePanel: NSPanel {
    convenience init(contentRect: NSRect, editable: Bool) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !editable
        acceptsMouseMovedEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        title = ScreenCapture.hiddenWindowTitle
        setFrame(contentRect, display: true)
    }
}

final class RegionFrameView: NSView {
    weak var controller: RegionFrameController?
    var screen: NSScreen?
    var editable = false
    var regionSize: NSSize = .zero

    private enum Handle { case nw, n, ne, e, se, s, sw, w, move, none }
    private static let edgeZone: CGFloat = 10
    private static let cornerZone: CGFloat = 20
    private static let minSize: CGFloat = 40

    private var activeHandle: Handle = .none
    private var dragStart: NSPoint?
    private var originalRect: NSRect = .zero

    override func resetCursorRects() {
        guard editable else { return }
        addCursorRect(bounds, cursor: .pointingHand)
        let zones: [(NSRect, NSCursor)] = [
            (cornerRect(.nw), .crosshair), (cornerRect(.ne), .crosshair),
            (cornerRect(.sw), .crosshair), (cornerRect(.se), .crosshair),
            (edgeRect(.n), .resizeUpDown), (edgeRect(.s), .resizeUpDown),
            (edgeRect(.w), .resizeLeftRight), (edgeRect(.e), .resizeLeftRight),
        ]
        for (rect, cursor) in zones where rect.width > 0 {
            addCursorRect(rect, cursor: cursor)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.0, dy: 1.0))
        border.lineWidth = 1.5
        border.stroke()
        drawCornerBrackets(in: bounds, length: 20, lineWidth: 4, color: .systemGreen)

        if editable {
            drawHandles()
        }

        let size = regionSize.width > 0 ? regionSize : bounds.size
        let label = "\(Int(size.width)) × \(Int(size.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.9),
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: bounds.maxX - labelSize.width - 6,
                y: bounds.minY + 4
            ),
            withAttributes: attributes
        )
    }

    private func drawHandles() {
        NSColor.systemGreen.setFill()
        for handle in [Handle.nw, .n, .ne, .e, .se, .s, .sw, .w] {
            NSBezierPath(rect: handleVisualRect(handle)).fill()
        }
    }

    // MARK: - 手柄与命中

    private func cornerRect(_ handle: Handle) -> NSRect {
        let zone = Self.cornerZone
        switch handle {
        case .nw: return NSRect(x: bounds.minX, y: bounds.maxY - zone, width: zone, height: zone)
        case .ne: return NSRect(x: bounds.maxX - zone, y: bounds.maxY - zone, width: zone, height: zone)
        case .sw: return NSRect(x: bounds.minX, y: bounds.minY, width: zone, height: zone)
        case .se: return NSRect(x: bounds.maxX - zone, y: bounds.minY, width: zone, height: zone)
        default: return .zero
        }
    }

    private func edgeRect(_ handle: Handle) -> NSRect {
        let zone = Self.edgeZone
        let inset = Self.cornerZone
        switch handle {
        case .n: return NSRect(x: bounds.minX + inset, y: bounds.maxY - zone, width: bounds.width - inset * 2, height: zone)
        case .s: return NSRect(x: bounds.minX + inset, y: bounds.minY, width: bounds.width - inset * 2, height: zone)
        case .w: return NSRect(x: bounds.minX, y: bounds.minY + inset, width: zone, height: bounds.height - inset * 2)
        case .e: return NSRect(x: bounds.maxX - zone, y: bounds.minY + inset, width: zone, height: bounds.height - inset * 2)
        default: return .zero
        }
    }

    private func handleVisualRect(_ handle: Handle) -> NSRect {
        let length: CGFloat = 14
        let thickness: CGFloat = 5
        let midX = bounds.midX, midY = bounds.midY
        switch handle {
        case .n: return NSRect(x: midX - length / 2, y: bounds.maxY - thickness, width: length, height: thickness)
        case .s: return NSRect(x: midX - length / 2, y: bounds.minY, width: length, height: thickness)
        case .w: return NSRect(x: bounds.minX, y: midY - length / 2, width: thickness, height: length)
        case .e: return NSRect(x: bounds.maxX - thickness, y: midY - length / 2, width: thickness, height: length)
        case .nw: return NSRect(x: bounds.minX, y: bounds.maxY - thickness, width: thickness * 3, height: thickness)
        case .ne: return NSRect(x: bounds.maxX - thickness * 3, y: bounds.maxY - thickness, width: thickness * 3, height: thickness)
        case .sw: return NSRect(x: bounds.minX, y: bounds.minY, width: thickness * 3, height: thickness)
        case .se: return NSRect(x: bounds.maxX - thickness * 3, y: bounds.minY, width: thickness * 3, height: thickness)
        default: return .zero
        }
    }

    private func handle(at point: NSPoint) -> Handle {
        if cornerRect(.nw).contains(point) { return .nw }
        if cornerRect(.ne).contains(point) { return .ne }
        if cornerRect(.sw).contains(point) { return .sw }
        if cornerRect(.se).contains(point) { return .se }
        if edgeRect(.n).contains(point) { return .n }
        if edgeRect(.s).contains(point) { return .s }
        if edgeRect(.w).contains(point) { return .w }
        if edgeRect(.e).contains(point) { return .e }
        if bounds.contains(point) { return .move }
        return .none
    }

    // MARK: - 拖动 / 缩放

    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        let point = convert(event.locationInWindow, from: nil)
        activeHandle = handle(at: point)
        dragStart = point
        originalRect = bounds
    }

    override func mouseDragged(with event: NSEvent) {
        guard editable, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        var rect = originalRect

        switch activeHandle {
        case .move:
            rect.origin.x += delta.x
            rect.origin.y += delta.y
        case .nw:
            rect.origin.x += delta.x
            rect.size.width -= delta.x
            rect.size.height += delta.y
        case .ne:
            rect.size.width += delta.x
            rect.size.height += delta.y
        case .sw:
            rect.origin.x += delta.x
            rect.size.width -= delta.x
            rect.size.height -= delta.y
        case .se:
            rect.size.width += delta.x
            rect.size.height -= delta.y
        case .n:
            rect.size.height += delta.y
        case .s:
            rect.size.height -= delta.y
        case .w:
            rect.origin.x += delta.x
            rect.size.width -= delta.x
        case .e:
            rect.size.width += delta.x
        case .none:
            return
        }
        rect = Self.normalized(rect)
        apply(rect: rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard editable else { return }
        dragStart = nil
        activeHandle = .none
        controller?.dragEnded()
    }

    private func apply(rect: NSRect) {
        guard let window else { return }
        var global = window.convertToScreen(convert(rect, to: nil))
        if let screenFrame = screen?.frame {
            let clamped = global.intersection(screenFrame)
            // 拖出屏幕时别把选区压到小于最小尺寸，保持原位即可
            if clamped.width >= Self.minSize, clamped.height >= Self.minSize {
                global = clamped
            }
        }
        window.setFrame(global, display: true)
        regionSize = global.size
        needsDisplay = true
        controller?.regionChanged(to: global)
    }

    private static func normalized(_ rect: NSRect) -> NSRect {
        var rect = rect
        if rect.width < minSize { rect.size.width = minSize }
        if rect.height < minSize { rect.size.height = minSize }
        return rect.standardized
    }
}

func drawCornerBrackets(in rect: NSRect, length: CGFloat, lineWidth: CGFloat, color: NSColor) {
    color.setStroke()
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round

    let corners: [(NSPoint, NSPoint, NSPoint)] = [
        (NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.maxY - length), NSPoint(x: rect.minX + length, y: rect.maxY)),
        (NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY - length), NSPoint(x: rect.maxX - length, y: rect.maxY)),
        (NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.minX, y: rect.minY + length), NSPoint(x: rect.minX + length, y: rect.minY)),
        (NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY + length), NSPoint(x: rect.maxX - length, y: rect.minY)),
    ]
    for (start, mid, end) in corners {
        path.move(to: start)
        path.line(to: mid)
        path.move(to: start)
        path.line(to: end)
    }
    path.stroke()
}
