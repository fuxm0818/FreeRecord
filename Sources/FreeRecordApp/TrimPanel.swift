import AVFoundation
import AVKit
import AppKit
import FreeRecordCore

/// 录制成品的裁剪窗：左侧播放器预览，右侧设定要保留 / 要删除的时间区间，
/// 确认后用 `CompositionEditor` 无损导出（只转封装、不重编码）。
@MainActor
final class TrimPanelController: NSObject, NSWindowDelegate {

    private enum Mode: Int {
        case keep = 0    // 只保留选中区间
        case remove = 1  // 删除选中区间
    }

    var onExported: ((SavedRecording) -> Void)?

    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var startField: NSTextField?
    private var endField: NSTextField?
    private var modePopup: NSPopUpButton?
    private var exportButton: NSButton?
    private var hintLabel: NSTextField?

    private var url: URL?
    private var duration: Double = 0
    private var isExporting = false
    /// 会话代号：show() 递增，导出回调只认最新会话，
    /// 防止旧导出完成后把重新打开的新会话一起关掉
    private var exportGeneration = 0

    /// 右侧信息区的键值标签
    private var valueLabels: [String: NSTextField] = [:]

    func show(recording: SavedRecording) {
        if window == nil { buildWindow() }
        guard let window else { return }

        url = recording.url
        duration = recording.duration
        // 挂载播放器：预览是该窗口的核心交互（拖进度定位起止点）。
        // 漏了这一步的话窗口只会是黑屏 + 浮动控制条，用户只能盲填秒数
        let player = AVPlayer(url: recording.url)
        self.player = player
        playerView?.player = player
        startField?.stringValue = Self.timeText(0)
        endField?.stringValue = Self.timeText(recording.duration)
        hintLabel?.stringValue = ""
        isExporting = false
        exportGeneration += 1
        exportButton?.isEnabled = true
        exportButton?.title = "导出裁剪"

        window.centerOnActiveScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    // MARK: - 窗口

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 470),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "裁剪录制"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 660, height: 420)

        let root = NSView()

        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let playerView = AVPlayerView(frame: .zero)
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(playerView)
        self.playerView = playerView

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let startLabel = label("起点（秒）")
        let endLabel = label("终点（秒）")
        let startField = numberField("0.0")
        let endField = numberField("0.0")
        self.startField = startField
        self.endField = endField

        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["只保留选中区间", "删除选中区间"])
        modePopup.font = .systemFont(ofSize: 12)
        modePopup.toolTip = "选择裁剪方式"
        self.modePopup = modePopup

        let hint = label("")
        hint.textColor = .systemRed
        hint.font = .systemFont(ofSize: 10)
        hintLabel = hint

        let export = NSButton(title: "导出裁剪", target: self, action: #selector(exportClicked))
        export.bezelStyle = .rounded
        export.controlSize = .regular
        export.keyEquivalent = "\r"
        exportButton = export

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .regular

        let buttonRow = NSStackView(views: [cancel, export])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 10
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        for title in ["原片时长", "裁剪后时长"] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let key = label(title)
            key.alignment = .left
            key.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let value = label("—")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            valueLabels[title] = value
            row.addArrangedSubview(key)
            row.addArrangedSubview(value)
            infoStack.addArrangedSubview(row)
        }

        panel.addSubview(startLabel)
        panel.addSubview(startField)
        panel.addSubview(endLabel)
        panel.addSubview(endField)
        panel.addSubview(modePopup)
        panel.addSubview(infoStack)
        panel.addSubview(buttonRow)

        root.addSubview(backdrop)
        root.addSubview(panel)
        window.contentView = root

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            backdrop.trailingAnchor.constraint(equalTo: panel.leadingAnchor),

            playerView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 300),

            startLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            startLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22),

            startField.leadingAnchor.constraint(equalTo: startLabel.leadingAnchor),
            startField.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            startField.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 4),

            endLabel.leadingAnchor.constraint(equalTo: startLabel.leadingAnchor),
            endLabel.topAnchor.constraint(equalTo: startField.bottomAnchor, constant: 16),

            endField.leadingAnchor.constraint(equalTo: startLabel.leadingAnchor),
            endField.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            endField.topAnchor.constraint(equalTo: endLabel.bottomAnchor, constant: 4),

            modePopup.leadingAnchor.constraint(equalTo: startLabel.leadingAnchor),
            modePopup.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            modePopup.topAnchor.constraint(equalTo: endField.bottomAnchor, constant: 18),

            infoStack.leadingAnchor.constraint(equalTo: startLabel.leadingAnchor),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -18),
            infoStack.topAnchor.constraint(equalTo: modePopup.bottomAnchor, constant: 22),

            buttonRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18),
        ])
        self.window = window
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func numberField(_ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.drawsBackground = true
        // 本窗口是标准 titled 窗口，右栏跟随系统外观：
        // 白色半透明底在浅色模式下几乎隐形，必须用语义色让系统自动适配
        field.backgroundColor = .controlBackgroundColor
        field.focusRingType = .none
        field.isBordered = false
        field.alignment = .left
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    // MARK: - 操作

    @objc private func exportClicked() {
        guard !isExporting, let url else { return }
        guard duration > 0.001 else {
            hintLabel?.stringValue = "文件时长无效，无法裁剪"
            return
        }

        let start = startField?.doubleValue ?? 0
        let end = endField?.doubleValue ?? duration
        let lo = min(max(0, start), duration)
        let hi = max(lo, min(end, duration))

        guard hi - lo > 0.05 else {
            hintLabel?.stringValue = "裁剪区间太短（至少 0.05 秒）"
            return
        }
        guard hi - lo < duration - 0.05 else {
            hintLabel?.stringValue = "裁剪后时长需比原片至少短 0.05 秒"
            return
        }

        let keep: [CompositionEditor.Segment]
        if modePopup?.indexOfSelectedItem == Mode.remove.rawValue {
            keep = [CompositionEditor.Segment(start: 0, end: lo),
                      CompositionEditor.Segment(start: hi, end: duration)]
        } else {
            keep = [CompositionEditor.Segment(start: lo, end: hi)]
        }

        // 输出为 `<原文件名>-裁剪.<原后缀>`，与原片同目录
        let base = url.deletingPathExtension().lastPathComponent
        let output = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-裁剪")
            .appendingPathExtension(url.pathExtension)

        isExporting = true
        exportButton?.isEnabled = false
        exportButton?.title = "导出中…"
        hintLabel?.stringValue = "正在无损导出…"

        let plan = CompositionEditor.Plan(
            sourceURL: url, keepSegments: keep, outputURL: output)

        let generation = exportGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await CompositionEditor.export(plan: plan)
                guard generation == self.exportGeneration else { return }
                await self.continueAfterExport(result: result)
            } catch {
                guard generation == self.exportGeneration else { return }
                await self.failExport(message: error.localizedDescription)
            }
        }
    }

    private func continueAfterExport(result: CompositionEditor.Result) {
        isExporting = false
        exportButton?.isEnabled = true
        exportButton?.title = "导出裁剪"
        hintLabel?.stringValue = String(
            format: "已导出：%.1f 秒 / %.1f MB", result.duration, result.fileSizeMB)
        onExported?(SavedRecording(
            url: result.url,
            duration: result.duration,
            width: 0,
            height: 0,
            fileSizeMB: result.fileSizeMB,
            audioTrackCount: 0
        ))
        window?.performClose(nil)
    }

    private func failExport(message: String) {
        isExporting = false
        exportButton?.isEnabled = true
        exportButton?.title = "导出裁剪"
        hintLabel?.stringValue = "导出失败：\(message)"
    }

    @objc private func cancelClicked() {
        player?.pause()
        window?.performClose(nil)
    }

    /// 点红色关闭按钮也要暂停（`cancelClicked` 只覆盖了取消按钮路径）
    func windowWillClose(_ notification: Notification) {
        player?.pause()
    }

    // MARK: - 工具

    /// 秒 → `12.3` 形式，供文本框直接读写
    private static func timeText(_ seconds: Double) -> String {
        String(format: "%.1f", seconds)
    }
}
