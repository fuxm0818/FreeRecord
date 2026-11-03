import AVFoundation
import AVKit
import AppKit
import FreeRecordCore

/// 录制成品的裁剪窗：左侧播放器预览，右侧设定要保留 / 要删除的时间区间，
/// 确认后用 `CompositionEditor` 导出。视频只转封装（零损耗）；
/// 音频成品是 MP3，容器写不回原样，只能解码后重新编码。
@MainActor
final class TrimPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

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
    /// 原片画面尺寸与音轨数：裁剪不改变这两项，导出后要原样回传给预览面板
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourceAudioTracks = 0
    private var isAudio = false
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
        sourceWidth = recording.width
        sourceHeight = recording.height
        sourceAudioTracks = recording.audioTrackCount
        isAudio = HistoryItem.audioExtensions.contains(recording.url.pathExtension.lowercased())
        // 挂载播放器：预览是该窗口的核心交互（拖进度定位起止点）。
        // 漏了这一步的话窗口只会是黑屏 + 浮动控制条，用户只能盲填秒数
        let player = AVPlayer(url: recording.url)
        self.player = player
        playerView?.player = player
        startField?.stringValue = Self.timeText(0)
        endField?.stringValue = Self.timeText(recording.duration)
        refreshDurations()
        hintLabel?.stringValue = ""
        isExporting = false
        exportGeneration += 1
        exportButton?.isEnabled = true
        exportButton?.title = L("导出裁剪")

        window.title = isAudio ? L("裁剪录音") : L("裁剪录制")
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
        window.title = L("裁剪录制")
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
        startField.delegate = self
        endField.delegate = self
        self.startField = startField
        self.endField = endField

        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: [L("只保留选中区间"), L("删除选中区间")])
        modePopup.font = .systemFont(ofSize: 12)
        modePopup.toolTip = L("选择裁剪方式")
        modePopup.target = self
        modePopup.action = #selector(trimInputsChanged)
        self.modePopup = modePopup

        let hint = label("")
        hint.textColor = .systemRed
        hint.font = .systemFont(ofSize: 10)
        hintLabel = hint

        let export = NSButton(title: L("导出裁剪"), target: self, action: #selector(exportClicked))
        export.bezelStyle = .rounded
        export.controlSize = .regular
        export.keyEquivalent = "\r"
        exportButton = export

        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancelClicked))
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
        panel.addSubview(hint)
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

            hint.leadingAnchor.constraint(equalTo: startLabel.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            hint.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -14),

            buttonRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18),
        ])
        self.window = window
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: L(text))
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

    /// 起止点输入与裁剪方式变动时，右栏时长要跟着算
    @objc private func trimInputsChanged() {
        refreshDurations()
    }

    nonisolated func controlTextDidChange(_ obj: Notification) {
        Task { @MainActor in self.refreshDurations() }
    }

    /// 右栏两个时长随输入实时计算：它们一直显示「—」会让人以为裁剪功能没生效
    private func refreshDurations() {
        valueLabels["原片时长"]?.stringValue = Self.durationText(duration)
        let range = clampedRange
        let kept = modePopup?.indexOfSelectedItem == Mode.remove.rawValue
            ? range.lo + max(0, duration - range.hi)
            : range.hi - range.lo
        valueLabels["裁剪后时长"]?.stringValue = Self.durationText(kept)
    }

    /// 输入框里的起止点，夹到 `[0, 原片时长]` 并保证终点不早于起点
    private var clampedRange: (lo: Double, hi: Double) {
        let lo = min(max(0, startField?.doubleValue ?? 0), duration)
        let hi = max(lo, min(endField?.doubleValue ?? duration, duration))
        return (lo, hi)
    }

    @objc private func exportClicked() {
        guard !isExporting, let url else { return }
        guard duration > 0.001 else {
            hintLabel?.stringValue = L("文件时长无效，无法裁剪")
            return
        }

        let (lo, hi) = clampedRange

        guard hi - lo > 0.05 else {
            hintLabel?.stringValue = L("裁剪区间太短（至少 0.05 秒）")
            return
        }
        guard hi - lo < duration - 0.05 else {
            hintLabel?.stringValue = L("裁剪后时长需比原片至少短 0.05 秒")
            return
        }

        let keep: [CompositionEditor.Segment]
        if modePopup?.indexOfSelectedItem == Mode.remove.rawValue {
            keep = [CompositionEditor.Segment(start: 0, end: lo),
                      CompositionEditor.Segment(start: hi, end: duration)]
        } else {
            keep = [CompositionEditor.Segment(start: lo, end: hi)]
        }

        // 输出为 `<原文件名>-裁剪.<后缀>`，与原片同目录。
        // 纯音频固定出 MP3（没有编码器时才留 .m4a），视频保持原容器
        let base = url.deletingPathExtension().lastPathComponent
        let ext = isAudio
            ? (Mp3Exporter.isAvailable ? "mp3" : "m4a")
            : url.pathExtension
        let output = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-裁剪")
            .appendingPathExtension(ext)

        isExporting = true
        exportButton?.isEnabled = false
        exportButton?.title = L("导出中…")
        hintLabel?.stringValue = isAudio ? L("正在导出…") : L("正在无损导出…")

        let plan = CompositionEditor.Plan(
            sourceURL: url, keepSegments: keep, outputURL: output)

        let generation = exportGeneration
        let audio = isAudio
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = audio
                    ? try await CompositionEditor.exportAudio(plan: plan)
                    : try await CompositionEditor.export(plan: plan)
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
        exportButton?.title = L("导出裁剪")
        hintLabel?.stringValue = LF(
            "已导出：%.1f 秒 / %.1f MB", result.duration, result.fileSizeMB)
        onExported?(SavedRecording(
            url: result.url,
            duration: result.duration,
            width: isAudio ? 0 : sourceWidth,
            height: isAudio ? 0 : sourceHeight,
            fileSizeMB: result.fileSizeMB,
            audioTrackCount: isAudio ? 1 : sourceAudioTracks
        ))
        window?.performClose(nil)
    }

    private func failExport(message: String) {
        isExporting = false
        exportButton?.isEnabled = true
        exportButton?.title = L("导出裁剪")
        hintLabel?.stringValue = LF("导出失败：%@", message)
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

    private static func durationText(_ seconds: Double) -> String {
        LF("%.1f 秒", max(0, seconds))
    }
}
