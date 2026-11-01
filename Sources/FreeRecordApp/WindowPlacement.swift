import AppKit
import FreeRecordCore

/// 预录制条 / 录制控制条必须比选区绿框（`.screenSaver`）高一层。
///
/// 绿框可编辑时 `ignoresMouseEvents = false`，落在选区里的点击全被它吃掉；
/// 工具栏一旦因为贴边退进选区，按钮就点不动了。画中画预览窗在 +1，工具栏用 +2。
let toolbarWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

/// 工具栏贴边放置：优先目标正下方，放不下放上方，都放不下才压进目标底部。
/// 压进去时靠 `toolbarWindowLevel` 保证仍然可点。
func floatingToolbarOrigin(near rect: NSRect, panelSize: NSSize, visible: NSRect) -> NSPoint {
    let gap: CGFloat = 10
    let margin: CGFloat = 8
    let x = min(
        max(rect.midX - panelSize.width / 2, visible.minX + margin),
        visible.maxX - panelSize.width - margin
    )
    let below = rect.minY - gap - panelSize.height
    if below >= visible.minY + margin {
        return NSPoint(x: x, y: below)
    }
    let above = rect.maxY + gap
    if above + panelSize.height <= visible.maxY - margin {
        return NSPoint(x: x, y: above)
    }
    let y = min(
        max(rect.minY + gap, visible.minY + margin),
        visible.maxY - panelSize.height - margin
    )
    return NSPoint(x: x, y: y)
}

extension NSWindow {
    /// 居中到鼠标所在屏幕，避免多显示器下窗口跑到另一块屏。
    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { center(); return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }
}

extension NSPanel {
    /// 浮动 UI 的"不入画"配置 —— 两层保护缺一不可。
    ///
    /// | 机制 | 防护范围 |
    /// |---|---|
    /// | `title = hiddenWindowTitle` + `SCContentFilter(display:excludingWindows:)` | **只挡自家** SCK 采集 |
    /// | `sharingType = .none` | **系统级**：Zoom / 会议 / QuickTime / 截图全挡 |
    ///
    /// 只设 title 的后果：录制条不会进自己录的视频，但会**出现在别人的屏幕共享里**。
    ///
    /// ⚠️ 例外：点击高亮窗口（`ClickHighlight`）**不要**调用本方法 —— 它是刻意要被录进画面的效果。
    func configureAsCaptureHiddenFloatingUI(level newLevel: NSWindow.Level = .floating) {
        title = ScreenCapture.hiddenWindowTitle
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        level = newLevel
    }
}
