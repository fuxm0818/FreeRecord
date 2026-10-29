import AVKit
import AppKit
import FreeRecordCore

/// 停止录制后的预览窗：左侧播放器，右侧文件信息与重命名。
@MainActor
final class PreviewPanelController: NSObject, NSWindowDelegate {
    var onFileChanged: (() -> Void)?

    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var nameField: NSTextField?
    private var valueLabels: [String: NSTextField] = [:]
    private var shareButton: NSButton?
    private var url: URL?
    private var renameHint: NSTextField?

    /// 当前预览文件的元数据，裁剪后需要就地更新
    private var currentDuration: TimeInterval = 0
    private var currentWidth = 0
    private var currentHeight = 0
    private var currentFileSizeMB: Double = 0
    private var currentAudioTrackCount = 0

    /// 裁剪窗：按需懒加载，导出后回到预览并刷新信息
    private lazy var trimPanel = TrimPanelController()

    func show(recording: SavedRecording) {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }

        url = recording.url
        currentDuration = recording.duration
        currentWidth = recording.width
        currentHeight = recording.height
        currentFileSizeMB = recording.fileSizeMB
        currentAudioTrackCount = recording.audioTrackCount

        let player = AVPlayer(url: recording.url)
        self.player = player
        playerView?.player = player
        nameField?.stringValue = recording.url.deletingPathExtension().lastPathComponent
        renameHint?.stringValue = ""
        apply(recording: recording)

        window.centerOnActiveScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()

        Task { [weak self] in
            let details = await Self.metadata(for: recording)
            guard let self, self.url == recording.url else { return }
            for (key, value) in details {
                self.valueLabels[key]?.stringValue = value
            }
        }
    }

    // MARK: - 窗口

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 530),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "录制完成"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 460)
        self.window = window

        let root = NSView()

        let playerView = AVPlayerView(frame: .zero)
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        self.playerView = playerView

        let playerBackdrop = NSView()
        playerBackdrop.wantsLayer = true
        playerBackdrop.layer?.backgroundColor = NSColor.black.cgColor
        playerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        playerBackdrop.addSubview(playerView)

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let nameField = NSTextField(string: "")
        nameField.font = .systemFont(ofSize: 15, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(commitRename)
        self.nameField = nameField

        let renameButton = NSButton(title: "重命名", target: self, action: #selector(commitRename))
        renameButton.bezelStyle = .rounded
        renameButton.controlSize = .small
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .systemRed
        hint.translatesAutoresizingMaskIntoConstraints = false
        renameHint = hint

        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        for title in ["文件大小", "时长", "创建时间", "分辨率", "帧率", "格式"] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let key = NSTextField(labelWithString: title)
            key.font = .systemFont(ofSize: 12)
            key.textColor = .secondaryLabelColor
            key.alignment = .left
            key.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let value = NSTextField(labelWithString: "—")
            value.font = .systemFont(ofSize: 12)
            value.lineBreakMode = .byTruncatingMiddle
            valueLabels[title] = value
            row.addArrangedSubview(key)
            row.addArrangedSubview(value)
            infoStack.addArrangedSubview(row)
        }

        let finder = iconButton("folder", help: "在 Finder 中显示", action: #selector(revealInFinder))
        let trash = iconButton("trash", help: "删除", action: #selector(deleteFile))
        let copy = iconButton("doc.on.doc", help: "复制路径", action: #selector(copyPath))
        let share = iconButton("square.and.arrow.up", help: "分享", action: #selector(shareFile))
        shareButton = share
        let trim = iconButton("scissors", help: "裁剪（无损，不重新编码）", action: #selector(trimClicked))
        let actions = NSStackView(views: [finder, trash, copy, share, trim])
        actions.orientation = .horizontal
        actions.spacing = 16
        actions.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "完成", target: self, action: #selector(closePanel))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(nameField)
        panel.addSubview(renameButton)
        panel.addSubview(hint)
        panel.addSubview(infoStack)
        panel.addSubview(actions)
        panel.addSubview(close)

        root.addSubview(playerBackdrop)
        root.addSubview(panel)
        window.contentView = root

        NSLayoutConstraint.activate([
            playerBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
            playerBackdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            playerBackdrop.trailingAnchor.constraint(equalTo: panel.leadingAnchor),

            playerView.leadingAnchor.constraint(equalTo: playerBackdrop.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: playerBackdrop.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: playerBackdrop.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: playerBackdrop.bottomAnchor),

            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: 300),

            nameField.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            nameField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            nameField.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -8),

            renameButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            renameButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 3),

            infoStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),
            infoStack.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),

            actions.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            actions.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18),

            close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            close.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
        ])
    }

    private func iconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(),
            target: self,
            action: action
        )
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.imageScaling = .scaleProportionallyDown
        button.setFrameSize(NSSize(width: 22, height: 22))
        return button
    }

    // MARK: - 信息

    private func apply(recording: SavedRecording) {
        let ext = recording.url.pathExtension.uppercased()
        valueLabels["文件大小"]?.stringValue = String(format: "%.1f MB", recording.fileSizeMB)
        valueLabels["时长"]?.stringValue = Self.durationText(recording.duration)
        valueLabels["创建时间"]?.stringValue = Self.dateText(
            (try? recording.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        )
        if recording.width > 0 {
            valueLabels["分辨率"]?.stringValue = "\(recording.width) × \(recording.height)"
        } else {
            valueLabels["分辨率"]?.stringValue = recording.audioTrackCount > 0 ? "音频" : "—"
            valueLabels["帧率"]?.stringValue = "—"
        }
        valueLabels["格式"]?.stringValue = ext
    }

    private static func metadata(for recording: SavedRecording) async -> [String: String] {
        var result: [String: String] = [:]
        let ext = recording.url.pathExtension.uppercased()
        result["格式"] = ext
        if let size = (try? recording.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            result["文件大小"] = String(format: "%.1f MB", Double(size) / 1_048_576)
        }
        if let created = (try? recording.url.resourceValues(forKeys: [.creationDateKey]).creationDate) {
            result["创建时间"] = dateText(created)
        }
        if ext == "PNG" { return result }

        let asset = AVURLAsset(url: recording.url)
        var duration = recording.duration
        if duration <= 0, let loaded = try? await asset.load(.duration) {
            duration = loaded.seconds
        }
        result["时长"] = durationText(duration)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                result["帧率"] = String(format: "%.0f fps", rate)
            }
            if recording.width <= 0, let size = try? await track.load(.naturalSize) {
                result["分辨率"] = "\(Int(size.width)) × \(Int(size.height))"
            }
        }
        return result
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "—" }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 操作

    @objc private func commitRename() {
        guard let url, let field = nameField else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = url.deletingPathExtension().lastPathComponent
        guard !newName.isEmpty else {
            field.stringValue = current
            renameHint?.stringValue = "文件名不能为空"
            return
        }
        guard newName != current else {
            renameHint?.stringValue = ""
            return
        }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(url.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            renameHint?.stringValue = "已有同名文件"
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            self.url = target
            renameHint?.stringValue = ""
            let player = AVPlayer(url: target)
            self.player = player
            playerView?.player = player
            player.play()
            valueLabels["创建时间"]?.stringValue = Self.dateText(
                (try? target.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            )
            onFileChanged?()
        } catch {
            renameHint?.stringValue = "重命名失败：\(error.localizedDescription)"
        }
    }

    @objc private func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func shareFile() {
        guard let url, let shareButton else { return }
        NSSharingServicePicker(items: [url]).show(
            relativeTo: shareButton.bounds,
            of: shareButton,
            preferredEdge: .maxY
        )
    }

    @objc private func deleteFile() {
        guard let url else { return }
        let alert = NSAlert()
        alert.messageText = "删除这个文件吗？"
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        player?.pause()
        try? FileManager.default.removeItem(at: url)
        onFileChanged?()
        window?.performClose(nil)
    }

    @objc private func trimClicked() {
        guard let url else { return }
        let recording = SavedRecording(
            url: url, duration: currentDuration,
            width: currentWidth, height: currentHeight,
            fileSizeMB: currentFileSizeMB,
            audioTrackCount: currentAudioTrackCount
        )
        trimPanel.onExported = { [weak self] trimmed in
            guard let self else { return }
            self.url = trimmed.url
            self.currentDuration = trimmed.duration
            self.currentWidth = trimmed.width
            self.currentHeight = trimmed.height
            self.currentFileSizeMB = trimmed.fileSizeMB
            self.currentAudioTrackCount = trimmed.audioTrackCount
            self.nameField?.stringValue =
                trimmed.url.deletingPathExtension().lastPathComponent
            self.player = AVPlayer(url: trimmed.url)
            self.playerView?.player = self.player
            self.player?.play()
            self.apply(recording: trimmed)
            self.onFileChanged?()
        }
        trimPanel.show(recording: recording)
    }

    @objc private func closePanel() {
        window?.performClose(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.player?.pause()
        }
    }
}
