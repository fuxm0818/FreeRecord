import AVFoundation
import AppKit
import Combine
import FreeRecordCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct HistoryItem: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let date: Date
    var duration: TimeInterval
    var sizeMB: Double
    var width: Int
    var height: Int
    var audioTrackCount: Int
    var thumbnail: NSImage?

    var isScreenshot: Bool {
        url.pathExtension.lowercased() == "png"
    }

    var isAudio: Bool {
        url.pathExtension.lowercased() == "m4a"
    }

    var dimensionsText: String {
        width > 0 ? "\(width) × \(height)" : "—"
    }

    var durationText: String {
        guard duration > 0 else { return "—" }
        let seconds = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    var sizeText: String {
        guard sizeMB > 0 else { return "—" }
        return String(format: "%.1f MB", sizeMB)
    }
}

@MainActor
final class RecordingHistory: ObservableObject {
    @Published var items: [HistoryItem] = []
    @Published var isLoading = false
    private var directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func updateDirectory(_ url: URL) {
        directory = url
    }

    func reload() {
        isLoading = true
        let dir = directory
        Task { [weak self] in
            let loaded = await Self.load(from: dir)
            self?.items = loaded
            self?.isLoading = false
        }
    }

    private static func load(from directory: URL) async -> [HistoryItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let files = urls
            .filter { ["mp4", "mov", "m4a", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }

        return await withTaskGroup(of: HistoryItem?.self) { group in
            for url in files.prefix(50) {
                group.addTask {
                    await Self.probe(url: url)
                }
            }
            var result: [HistoryItem] = []
            for await item in group {
                if let item { result.append(item) }
            }
            return result.sorted { $0.date > $1.date }
        }
    }

    private static func probe(url: URL) async -> HistoryItem? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate ?? Date()
        let sizeMB = Double(values?.fileSize ?? 0) / 1_048_576

        var duration: TimeInterval = 0
        var width = 0
        var height = 0
        var audioCount = 0
        if url.pathExtension.lowercased() == "png",
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        } else if url.pathExtension.lowercased() == "m4a" {
            let asset = AVURLAsset(url: url)
            if let loaded = try? await asset.load(.duration) {
                duration = loaded.seconds
            }
            if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
                audioCount = audioTracks.count
            }
        } else {
            let asset = AVURLAsset(url: url)
            if let loaded = try? await asset.load(.duration) {
                duration = loaded.seconds
            }
            if let tracks = try? await asset.loadTracks(withMediaType: .video), let first = tracks.first {
                let size = (try? await first.load(.naturalSize)) ?? .zero
                width = Int(size.width)
                height = Int(size.height)
            }
            if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
                audioCount = audioTracks.count
            }
        }

        return HistoryItem(
            id: url,
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            date: date,
            duration: duration,
            sizeMB: sizeMB,
            width: width,
            height: height,
            audioTrackCount: audioCount,
            thumbnail: await Self.makeThumbnail(url: url)
        )
    }

    private static func makeThumbnail(url: URL) async -> NSImage? {
        if url.pathExtension.lowercased() == "png" {
            return NSImage(contentsOf: url)
        }
        if url.pathExtension.lowercased() == "m4a" {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 200)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                continuation.resume(returning: image.map { NSImage(cgImage: $0, size: .zero) })
            }
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var permissionGranted = true
    @Published var recordingState = "idle"
    let history: RecordingHistory
    private var historyObserver: AnyCancellable?

    init(directory: URL) {
        history = RecordingHistory(directory: directory)
        // RecordingHistory 是嵌套 ObservableObject，不转发的话列表永远不刷新
        historyObserver = history.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isRecording: Bool {
        recordingState == "recording" || recordingState == "paused" || recordingState == "finishing"
    }
}

@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    let viewModel: HomeViewModel
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onPreview: ((HistoryItem) -> Void)?
    var onResetPermission: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAudioRecord: (() -> Void)?
    var onCameraRecord: (() -> Void)?
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        viewModel = HomeViewModel(directory: settings.saveDirectory)
        super.init()
        // 从系统设置切回来时自动复查：授权只对新进程生效，读不到时要给用户可执行的下一步
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    private func refreshPermission() {
        Task { @MainActor in
            let granted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
            if viewModel.permissionGranted != granted {
                viewModel.permissionGranted = granted
            }
        }
    }

    func show(openPermissionPageIfDenied: Bool = false) async {
        viewModel.permissionGranted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
        if window == nil {
            let hosting = NSHostingController(rootView: HomeView(
                viewModel: viewModel,
                onStart: { [weak self] in self?.onStart?() },
                onStop: { [weak self] in self?.onStop?() },
                onPreview: { [weak self] item in self?.onPreview?(item) },
                onRecheckPermission: { [weak self] in self?.recheckPermissionWithFeedback() },
                onResetPermission: { [weak self] in self?.resetPermissionRecord() },
                onSettings: { [weak self] in self?.onSettings?() },
                onAudioRecord: { [weak self] in self?.onAudioRecord?() },
                onCameraRecord: { [weak self] in self?.onCameraRecord?() }
            ))
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.title = "自由录屏"
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.setContentSize(NSSize(width: 420, height: 620))
            win.centerOnActiveScreen()
            self.window = win
        }
        viewModel.history.updateDirectory(AppSettings.shared.saveDirectory)
        viewModel.history.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadHistory() {
        viewModel.history.reload()
    }

    /// 开始录屏前先收起主窗口，避免把自己录进去
    func hide() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 用户在系统设置里打开了开关后点「已授权」：能读到就直接收起横幅，读不到要说清原因和下一步。
    private func recheckPermissionWithFeedback() {
        Task { @MainActor in
            let granted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
            viewModel.permissionGranted = granted
            guard !granted else { return }

            let alert = NSAlert()
            alert.messageText = "系统设置里已开启，但本 App 仍读不到权限"
            alert.informativeText = """
            常见原因只有两个：
            1. 授权只对新启动的进程生效——开关打开后，本 App 没有真正退出再打开（关窗口不算退出，它常驻在菜单栏）。
            2. App 重新打包或更新过，签名变化导致系统里那条旧授权失效，但开关看起来还是开着的。

            点「重启 App」可以解决第 1 种；重启后仍读不到，就点「重新授权…」重置这条记录，再打开开关。
            """
            alert.addButton(withTitle: "重启 App")
            alert.addButton(withTitle: "重新授权…")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                relaunchApp()
            case .alertSecondButtonReturn:
                resetPermissionRecord()
            default:
                break
            }
        }
    }

    /// 新开一个进程再退出当前进程，让 TCC 对新进程重新判定
    private func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundleURL.path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    /// 版本更新后 ad-hoc 签名变化会使旧授权失效（开关显示已开但对本进程无效），重置后重新授权即可。
    private func resetPermissionRecord() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.fuxiangming.freerec"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // 忽略：失败时用户仍可手动在系统设置中操作
        }
        let alert = NSAlert()
        alert.messageText = "已重置屏幕录制授权记录"
        alert.informativeText = """
        接下来：
        1. 点击「打开系统设置」，在列表中找到「自由录屏」并打开开关
        2. 完全退出本 App（菜单栏图标 → 退出）后重新打开
        """
        alert.addButton(withTitle: "立即授权")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            Task.detached {
                _ = CGRequestScreenCaptureAccess()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    let onStart: () -> Void
    let onStop: () -> Void
    let onPreview: (HistoryItem) -> Void
    let onRecheckPermission: () -> Void
    let onResetPermission: () -> Void
    let onSettings: () -> Void
    let onAudioRecord: () -> Void
    let onCameraRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !viewModel.permissionGranted {
                permissionBanner
            }
            Divider().padding(.vertical, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modeCards
                    if viewModel.isRecording {
                        stopSection
                    }
                    Divider()
                    historySection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 400, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 权限横幅

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("尚未获得「屏幕录制」权限")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("去授权") { openSystemSettings() }
                Button("重新检查") { onRecheckPermission() }
            }
            Text("在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 中打开「自由录屏」，然后完全退出本 App 再打开（关窗口不算退出，它常驻菜单栏）。App 重新打包后旧授权会失效，可点「重置授权记录」重新授权。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重置授权记录…") { onResetPermission() }
                .font(.caption)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func openSystemSettings() {
        // 先发起系统权限请求（App 不在列表里时会注册并弹系统提示），再强制拉起设置面板兜底
        Task.detached {
            _ = CGRequestScreenCaptureAccess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 主控制台

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("自由录屏")
                .font(.title2.bold())
            Spacer()
            if viewModel.isRecording {
                Label(recordingTitle, systemImage: "record.circle")
                    .foregroundColor(.red)
                    .font(.callout.bold())
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var recordingTitle: String {
        switch viewModel.recordingState {
        case "paused": return "已暂停"
        case "finishing": return "保存中…"
        default: return "录制中"
        }
    }

    private var modeCards: some View {
        HStack(spacing: 10) {
            modeCard(title: "屏幕录制", icon: "display", selected: true) {
                if viewModel.permissionGranted {
                    onStart()
                } else {
                    openSystemSettings()
                }
            }
            modeCard(title: "摄像头", icon: "video", selected: false, action: onCameraRecord)
            modeCard(title: "录音", icon: "waveform", selected: false, action: onAudioRecord)
        }
    }

    private func modeCard(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(selected ? .accentColor : .primary)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var stopSection: some View {
        Button {
            onStop()
        } label: {
            HStack {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 16))
                Text("停止录制")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    // MARK: - 录制列表

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("录制列表")
                    .font(.headline)
                if viewModel.history.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    viewModel.history.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if viewModel.history.items.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "video")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                        Text("无视频")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("录制的视频会出现在这里")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.history.items) { item in
                        historyRow(item)
                        if item.id != viewModel.history.items.last?.id {
                            Divider().padding(.leading, 112)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 100, height: 56)
                        .clipped()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color(nsColor: .quaternaryLabelColor))
                        Image(systemName: item.isAudio ? "waveform" : "video")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 100, height: 56)
                }
                if !item.isScreenshot && !item.isAudio {
                    // 播放角标：白色圆底 + 深色三角
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 24, height: 24)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.black.opacity(0.75))
                        .offset(x: 0.5)
                }
            }
            .frame(width: 100, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isNewest(item) {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.16, green: 0.72, blue: 0.29)))
                    }
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle(item))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    iconButton("folder", help: "在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    iconButton("trash", help: "删除") {
                        delete(item)
                    }
                    iconButton("doc.on.doc", help: "复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.url.path, forType: .string)
                    }
                    ShareButton(url: item.url)
                        .fixedSize()
                        .frame(width: 26, height: 26)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(item) }
        .contextMenu {
            Button(item.isScreenshot ? "打开" : "播放") { open(item) }
            Button("重命名…") { rename(item) }
            Divider()
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button("删除", role: .destructive) { delete(item) }
        }
    }

    private func open(_ item: HistoryItem) {
        if item.isScreenshot {
            NSWorkspace.shared.open(item.url)
        } else {
            onPreview(item)
        }
    }

    private func isNewest(_ item: HistoryItem) -> Bool {
        viewModel.history.items.first?.id == item.id
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func subtitle(_ item: HistoryItem) -> String {
        // 大小 | 时长 | 格式
        let ext = item.url.pathExtension.lowercased()
        if item.isScreenshot {
            return "\(item.sizeText) | \(item.dimensionsText) | \(ext)"
        }
        return "\(item.sizeText) | \(item.durationText) | \(ext)"
    }

    private func rename(_ item: HistoryItem) {
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = "只改名，扩展名保持不变。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }
        let target = item.url.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(item.url.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            let warn = NSAlert()
            warn.messageText = "已有同名文件"
            warn.informativeText = target.lastPathComponent
            warn.addButton(withTitle: "好")
            warn.runModal()
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            viewModel.history.reload()
        } catch {
            let warn = NSAlert()
            warn.messageText = "重命名失败"
            warn.informativeText = error.localizedDescription
            warn.addButton(withTitle: "好")
            warn.runModal()
        }
    }

    private func delete(_ item: HistoryItem) {
        let alert = NSAlert()
        alert.messageText = "删除这个文件吗？"
        alert.informativeText = item.name
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(at: item.url)
            viewModel.history.reload()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// SwiftUI 里没有 macOS 12 可用的分享按钮，包一层 NSButton 调 NSSharingServicePicker。
struct ShareButton: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "分享")
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.share(_:))
        button.toolTip = "分享"
        button.setFrameSize(NSSize(width: 18, height: 18))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.url = url
    }

    final class Coordinator: NSObject {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: [url]).show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
        }
    }
}
