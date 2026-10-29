import AppKit

/// 矩形框的 8 个缩放手区（四边 + 四角）。画中画预览窗和选区绿框共用同一套判定与光标，
/// 两处手感一致；按在热区外就是移动。
enum ResizeZone: CaseIterable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    /// 按下点在不在某个热区里（rect 为视图/窗口自身坐标，band 为每条边的容差）
    static func zone(at point: NSPoint, in rect: NSRect, band: CGFloat) -> ResizeZone? {
        let nearLeft = point.x <= rect.minX + band
        let nearRight = point.x >= rect.maxX - band
        let nearBottom = point.y <= rect.minY + band
        let nearTop = point.y >= rect.maxY - band
        if nearTop {
            if nearLeft { return .topLeft }
            if nearRight { return .topRight }
            return .top
        }
        if nearBottom {
            if nearLeft { return .bottomLeft }
            if nearRight { return .bottomRight }
            return .bottom
        }
        if nearLeft { return .left }
        if nearRight { return .right }
        return nil
    }

    /// 该点命中的热区光标；不在任何热区里返回 nil（调用方自己决定退回什么光标）
    static func cursor(at point: NSPoint, in rect: NSRect, band: CGFloat) -> NSCursor? {
        zone(at: point, in: rect, band: band)?.cursor
    }

    /// 8 块互不重叠的光标区域（角落优先，剩下的算边）
    static func cursorZones(in bounds: NSRect, band: CGFloat) -> [(NSRect, NSCursor)] {
        let corner = NSRect(x: bounds.minX, y: bounds.minY, width: band, height: band)
        let edgeOnly = bounds.insetBy(dx: band, dy: band)
        var result: [(NSRect, NSCursor)] = []
        if edgeOnly.width > 0, edgeOnly.height > 0 {
            result.append((NSRect(x: edgeOnly.minX, y: bounds.maxY - band, width: edgeOnly.width, height: band), ResizeZone.top.cursor))
            result.append((NSRect(x: edgeOnly.minX, y: bounds.minY, width: edgeOnly.width, height: band), ResizeZone.bottom.cursor))
            result.append((NSRect(x: bounds.minX, y: edgeOnly.minY, width: band, height: edgeOnly.height), ResizeZone.left.cursor))
            result.append((NSRect(x: bounds.maxX - band, y: edgeOnly.minY, width: band, height: edgeOnly.height), ResizeZone.right.cursor))
        }
        for (zone, rect) in [
            (ResizeZone.topLeft, corner.offsetBy(dx: 0, dy: bounds.maxY - band - corner.minY)),
            (ResizeZone.topRight, corner.offsetBy(dx: bounds.maxX - band - corner.minX, dy: bounds.maxY - band - corner.minY)),
            (ResizeZone.bottomLeft, corner),
            (ResizeZone.bottomRight, corner.offsetBy(dx: bounds.maxX - band - corner.minX, dy: 0)),
        ] {
            result.append((rect, zone.cursor))
        }
        return result
    }

    var touchesLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    var touchesRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    var touchesTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }

    var touchesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }

    /// 缩放时钉住的边：另一头跟手
    enum Anchor {
        case minEdge
        case maxEdge
        case center
    }

    var xAnchor: Anchor {
        if touchesLeft { return .maxEdge }
        if touchesRight { return .minEdge }
        return .center
    }

    var yAnchor: Anchor {
        if touchesTop { return .minEdge }
        if touchesBottom { return .maxEdge }
        return .center
    }

    /// 该热区对应的系统缩放光标（macOS 15 起有八向对角光标，更早系统退回轴向光标）
    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.__frameResize(from: frameResizePosition, in: .all)
        }
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: return .resizeLeftRight
        }
    }

    @available(macOS 15.0, *)
    private var frameResizePosition: NSCursor.FrameResizePosition {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }
}
