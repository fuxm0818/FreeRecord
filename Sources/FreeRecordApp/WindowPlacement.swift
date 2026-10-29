import AppKit
import FreeRecordCore

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
