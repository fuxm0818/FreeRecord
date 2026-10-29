import AVFoundation
import FreeRecordCore
import Foundation
import ImageIO
import IOKit.pwr_mgt
import ScreenCaptureKit

struct SavedRecording {
    let url: URL
    let duration: TimeInterval
    let width: Int
    let height: Int
    let fileSizeMB: Double
    let audioTrackCount: Int
}

@MainActor
protocol RecordingCoordinatorDelegate: AnyObject {
    func recordingStateChanged()
    func recordingFailed(message: String)
    /// 开始录制时缺「屏幕录制」权限：授权只对新进程生效，授权后切回来自动续上
    func recordingPermissionNeeded()
    func recordingSaved(_ recording: SavedRecording, askToSave: Bool)
}

@MainActor
final class RecordingCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case finishing
    }

    enum SessionKind {
        case screen
        case audio
    }

    private(set) var state: State = .idle
    private(set) var sessionKind: SessionKind = .screen
    private(set) var startedAt: Date?
    private var pausedSince: Date?
    private var accumulatedPaused: TimeInterval = 0
    private var sleepAssertionID: IOPMAssertionID = 0
    var saveDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/自由录屏", isDirectory: true)

    weak var delegate: (any RecordingCoordinatorDelegate)?

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        var total = Date().timeIntervalSince(startedAt) - accumulatedPaused
        if let pausedSince { total -= Date().timeIntervalSince(pausedSince) }
        return max(0, total)
    }

    private var writer: RecordingWriter?
    private var counters: CaptureCounters?
    private var stallWatchdog: Task<Void, Never>?
    private var screen: ScreenCapture?
    private var systemAudioStream: SystemAudioStreamCapture?
    private var mic: AudioDeviceCapture?
    private var systemAudioCapture: AudioDeviceCapture?
    private var currentSize: (width: Int, height: Int)?
    /// 因缺屏幕录制权限而没启动成的录制，授权后自动续上
    private var pendingStart: (source: CaptureSource?, settings: CaptureSettings, cameraOverlay: CameraOverlaySource?)?
    /// 启动门控进行中（采集已启动、尚未宣布 recording）：挡住重复点击开始
    /// 采集源已启动、门控等待中（此时 state 仍为 idle，入口必须据此挡住重复触发）
    private(set) var isPreparing = false

    /// App 变为活跃时调用：权限已就绪就自动开始之前未启动成的录制
    func retryPendingStartIfReady() async {
        guard state == .idle, !isPreparing, let pending = pendingStart else { return }
        let granted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
        guard granted else { return }
        pendingStart = nil
        await startSession(source: pending.source, settings: pending.settings, cameraOverlay: pending.cameraOverlay)
    }

    func start(source: CaptureSource, settings: CaptureSettings, cameraOverlay: CameraOverlaySource? = nil) async {
        await startSession(source: source, settings: settings, cameraOverlay: cameraOverlay)
    }

    /// 录制音频（无画面），输出 .m4a
    func startAudioOnly(settings: CaptureSettings, onLevel: ((Float) -> Void)?) async {
        await startSession(source: nil, settings: settings, levelHandler: onLevel)
    }

    private func startSession(
        source: CaptureSource?,
        settings: CaptureSettings,
        levelHandler: ((Float) -> Void)? = nil,
        cameraOverlay: CameraOverlaySource? = nil
    ) async {
        guard state == .idle, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        pendingStart = nil

        let hasMic = settings.audio.wantsMicrophone
        let systemOn13 = settings.audio.wantsSystemAudio
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
            )
        let blackHole = systemOn13 ? nil : (settings.audio.wantsSystemAudio ? SystemAudioSupport.findBlackHole() : nil)
        let hasSystem = systemOn13 || blackHole != nil

        if source == nil, !hasMic, !hasSystem {
            delegate?.recordingFailed(message: "录制音频至少要选择麦克风或系统声音。")
            return
        }

        // 纯音频 + 系统声音（macOS 13+）走 SCK，也需要屏幕录制权限
        let needsScreenPermission = source != nil || (source == nil && systemOn13)
        if needsScreenPermission {
            let screenGranted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
            guard screenGranted else {
                pendingStart = (source, settings, cameraOverlay)
                delegate?.recordingPermissionNeeded()
                return
            }
        }

        if hasMic {
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard micGranted else {
                delegate?.recordingFailed(message: "没有麦克风权限。\n\n可以在 系统设置 → 隐私与安全性 → 麦克风 里授权，或改选其他声音来源。")
                return
            }
        }

        let size: (width: Int, height: Int)
        if let source {
            size = ScreenCapture.plannedSize(
                source: source,
                targetHeight: settings.targetHeight,
                pixelScale: settings.pixelScale
            )
        } else {
            size = (0, 0)
        }
        let bitrate = max(2_000_000, Int(Double(size.width * size.height * settings.fps) * 0.08))

        var createdWriter: RecordingWriter?
        do {
            let url = Self.outputURL(in: saveDirectory, audioOnly: source == nil)
            let writer: RecordingWriter
            if source == nil {
                writer = try RecordingWriter(
                    audioOnlyURL: url,
                    hasMicTrack: hasMic,
                    hasSystemTrack: hasSystem
                )
            } else {
                writer = try RecordingWriter(
                    url: url,
                    width: size.width,
                    height: size.height,
                    fps: settings.fps,
                    hasMicTrack: hasMic,
                    hasSystemTrack: hasSystem,
                    bitrate: bitrate
                )
            }
            createdWriter = writer

            let counters = CaptureCounters()
            self.counters = counters
            var screen: ScreenCapture?
            if let source {
                let capture = ScreenCapture(writer: writer, counters: counters, systemAudio: hasSystem, cameraOverlay: cameraOverlay)
                capture.onError = { [weak self] message in
                    Task { @MainActor in self?.captureInterrupted(message: message) }
                }
                try await capture.start(source: source, settings: settings)
                screen = capture
            }
            sessionKind = source == nil ? .audio : .screen

            self.writer = writer
            self.screen = screen
            self.currentSize = size

            if hasSystem, let blackHole {
                let systemCapture = AudioDeviceCapture(writer: writer, counters: counters, track: .system)
                if let levelHandler {
                    systemCapture.onLevel = { level in
                        Task { @MainActor in levelHandler(level) }
                    }
                }
                do {
                    try systemCapture.start(deviceName: blackHole.name)
                    self.systemAudioCapture = systemCapture
                } catch {
                    systemCapture.stop()
                    await teardownStartedSources(cancelWriter: writer)
                    delegate?.recordingFailed(message: "虚拟声卡（\(blackHole.name)）启动失败：\(error.localizedDescription)")
                    return
                }
            }

            if source == nil, systemOn13 {
                if #available(macOS 13.0, *) {
                    do {
                        let content = try await ScreenCapture.loadShareableContent()
                        guard let display = Self.displayUnderMouse(in: content) else {
                            throw CaptureError.noDisplay
                        }
                        let stream = SystemAudioStreamCapture(writer: writer, counters: counters)
                        if let levelHandler {
                            stream.onLevel = { level in
                                Task { @MainActor in levelHandler(level) }
                            }
                        }
                        stream.onError = { [weak self] message in
                            Task { @MainActor in self?.captureInterrupted(message: message) }
                        }
                        try await stream.start(display: display)
                        self.systemAudioStream = stream
                    } catch {
                        await teardownStartedSources(cancelWriter: writer)
                        delegate?.recordingFailed(message: "系统声音启动失败：\(error.localizedDescription)")
                        return
                    }
                }
            }

            if hasMic {
                let deviceAudio = AudioDeviceCapture(writer: writer, counters: counters, track: .microphone)
                if let levelHandler {
                    deviceAudio.onLevel = { level in
                        Task { @MainActor in levelHandler(level) }
                    }
                }
                do {
                    try deviceAudio.start(deviceName: nil)
                    self.mic = deviceAudio
                } catch {
                    deviceAudio.stop()
                    // 此前已启动的系统声采集（黑声卡 / SCK 流）必须一并收掉，
                    // 否则它会在后台继续空转，占用音频硬件与 CPU
                    await teardownStartedSources(cancelWriter: writer)
                    delegate?.recordingFailed(message: "麦克风启动失败：\(error.localizedDescription)")
                    return
                }
            }

            // 启动门控：等所有已启用音源产出首帧再开始计时。
            // 各源 start() 返回只是管线就绪，首帧回调是异步的（SCK 系统声可达数百毫秒），
            // 不等就宣布录制，用户立刻说话/播放的声音会落在音频轨起点之前——开头丢声。
            // 超时兜底 2.5 秒：系统完全静音或设备异常时照常放行，不卡死开录。
            // 门控等待期间样本已在写入（writer 以首个样本建时间轴），
            // 计时起点回拨等待时长，界面计时才与文件时长对得上
            let gateWaited = await AudioStartGate.wait(counters: counters, mic: hasMic, system: hasSystem)

            startedAt = Date().addingTimeInterval(-gateWaited)
            accumulatedPaused = 0
            pausedSince = nil
            state = .recording
            createSleepAssertion()
            startStallWatchdog()
            delegate?.recordingStateChanged()
        } catch {
            await teardownStartedSources(cancelWriter: createdWriter)
            delegate?.recordingFailed(message: "启动录制失败：\(error.localizedDescription)")
        }
    }

    /// 统一收掉已启动的采集源与 writer。
    /// 所有失败路径必须走这里：历史上麦克风失败分支漏停了系统声采集，
    /// 导致一个采集会话在后台空转直到下一次成功开录。新增采集源时只需改这里。
    private func teardownStartedSources(cancelWriter: RecordingWriter?) async {
        await screen?.stop()
        await systemAudioStream?.stop()
        systemAudioCapture?.stop()
        mic?.stop()
        cancelWriter?.cancel()
        self.screen = nil
        self.systemAudioStream = nil
        self.systemAudioCapture = nil
        self.mic = nil
        self.writer = nil
        self.currentSize = nil
    }

    func stop() {
        finish(save: true)
    }

    func cancel() {
        finish(save: false)
    }

    var hasMicrophoneTrack: Bool {
        mic != nil
    }

    var isMicrophoneMuted: Bool {
        mic?.isMuted ?? false
    }

    func setMicrophoneMuted(_ muted: Bool) {
        mic?.isMuted = muted
    }

    func togglePause() {
        guard state == .recording || state == .paused else { return }
        let newPaused = state == .recording
        if newPaused {
            pausedSince = Date()
            state = .paused
        } else {
            accumulatedPaused += Date().timeIntervalSince(pausedSince ?? Date())
            pausedSince = nil
            state = .recording
        }
        writer?.setPaused(newPaused)
        delegate?.recordingStateChanged()
    }

    /// 录制中截图：把最近一帧写成 PNG 到录制目录，返回文件 URL
    func captureScreenshot() -> URL? {
        guard let image = screen?.latestFrameImage() else { return nil }
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let fileURL = saveDirectory.appendingPathComponent("截图 \(formatter.string(from: Date())).png")
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return fileURL
    }

    /// 录制中每秒巡检：采集还在进帧、写入却 3 秒没动静，就当成编码器停摆主动收尾，
    /// 明确告诉用户停在第几秒，而不是悄悄给一个只有前半段的文件。
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            var last = self?.counters?.snapshot()
            var stalledTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard self.state == .recording, let counters = self.counters else {
                    last = self.counters?.snapshot()
                    stalledTicks = 0
                    if self.state == .idle { return }
                    continue
                }
                if let failure = self.writer?.failureDescription {
                    self.captureInterrupted(message: "编码器报错：\(failure)")
                    return
                }
                let now = counters.snapshot()
                if let previous = last, now.captured > previous.captured, now.written == previous.written {
                    stalledTicks += 1
                } else {
                    stalledTicks = 0
                }
                last = now
                if stalledTicks >= 3 {
                    let seconds = Int(self.elapsed.rounded())
                    self.captureInterrupted(message: "第 \(seconds) 秒起编码器没有响应，已保存前 \(seconds) 秒。\n建议重启 App 后再录。")
                    return
                }
            }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    private func createSleepAssertion() {
        guard sleepAssertionID == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "自由录屏正在录制" as CFString,
            &sleepAssertionID
        )
    }

    private func releaseSleepAssertion() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    private func finish(save: Bool) {
        guard state == .recording || state == .paused else { return }
        if state == .paused {
            accumulatedPaused += Date().timeIntervalSince(pausedSince ?? Date())
            pausedSince = nil
        }
        state = .finishing
        delegate?.recordingStateChanged()
        Task { await complete(save: save) }
    }

    private func complete(save: Bool, askToSave: Bool = true) async {
        stopStallWatchdog()
        let duration = elapsed
        let screen = self.screen
        self.screen = nil
        await screen?.stop()
        let audioStream = self.systemAudioStream
        self.systemAudioStream = nil
        await audioStream?.stop()
        mic?.stop()
        mic = nil
        systemAudioCapture?.stop()
        systemAudioCapture = nil
        releaseSleepAssertion()

        let writer = self.writer
        let size = self.currentSize
        self.writer = nil
        self.currentSize = nil
        self.startedAt = nil
        self.pausedSince = nil
        self.accumulatedPaused = 0

        guard save, let writer, let size else {
            writer?.cancel()
            state = .idle
            delegate?.recordingStateChanged()
            return
        }

        // 上报文件真实时长：墙钟 elapsed 只说明录了多久，说明不了文件里有多少
        do {
            let url = try await writer.finish()
            Self.appendAlignmentLog(writer: writer)
            let real = await Self.movieDuration(url)
            reportSaved(url: url, writer: writer, size: size, duration: real ?? duration, askToSave: askToSave)
        } catch {
            // 分片 MP4 的 moov 在文件头，收尾失败时已录内容大概率仍可播放，别让用户白录
            if Self.isPlayableMovie(writer.url) {
                let real = await Self.movieDuration(writer.url)
                reportSaved(url: writer.url, writer: writer, size: size, duration: real ?? duration, askToSave: askToSave)
            } else {
                state = .idle
                delegate?.recordingStateChanged()
                delegate?.recordingFailed(message: "保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func reportSaved(url: URL, writer: RecordingWriter, size: (width: Int, height: Int), duration: TimeInterval, askToSave: Bool) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSizeMB = ((attributes?[.size] as? NSNumber)?.doubleValue ?? 0) / 1_048_576
        state = .idle
        delegate?.recordingStateChanged()
        delegate?.recordingSaved(SavedRecording(
            url: url,
            duration: duration,
            width: size.width,
            height: size.height,
            fileSizeMB: fileSizeMB,
            audioTrackCount: writer.audioTrackCount
        ), askToSave: askToSave)
    }

    private static func movieDuration(_ url: URL) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let duration = try? await AVURLAsset(url: url).load(.duration),
              duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// 诊断日志统一写到 ~/Library/Logs/FreeRecord/，录制输出目录只留成品与截图
    static var diagnosticsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/FreeRecord", isDirectory: true)
    }

    /// 把音画对齐数据追加到诊断目录的 音画对齐诊断.log（排查音画不同步的实锤数据）
    private static func appendAlignmentLog(writer: RecordingWriter) {
        guard let report = writer.alignmentReport() else { return }
        append(report + "\n\n", to: diagnosticsDirectory.appendingPathComponent("音画对齐诊断.log"))
    }

    /// 把写入器现场追加到诊断目录的 编码器诊断.log，返回路径供弹窗提示
    private static func appendDiagnostics(writer: RecordingWriter?, message: String) -> String? {
        guard let writer else { return nil }
        let logURL = diagnosticsDirectory.appendingPathComponent("编码器诊断.log")
        append("触发：\(message)\n" + writer.diagnostics() + "\n\n", to: logURL)
        return logURL.path
    }

    private static func append(_ text: String, to logURL: URL) {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private static func isPlayableMovie(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard asset.duration.seconds > 0.5 else { return false }
        return !asset.tracks.isEmpty
    }

    private func captureInterrupted(message: String) {
        guard state == .recording || state == .paused else { return }
        if state == .paused {
            accumulatedPaused += Date().timeIntervalSince(pausedSince ?? Date())
            pausedSince = nil
        }
        // -16341 这类错误没有明文原因，先把现场落到文件里，下次就能看着现场修而不是猜
        let logPath = Self.appendDiagnostics(writer: writer, message: message)
        let elapsedSeconds = Int(elapsed.rounded())
        var shown = message
        if let logPath { shown += "\n诊断已写入：\(logPath)" }
        if elapsedSeconds <= 3 {
            shown += "\n\n开录几秒就失败通常是编码器扛不住当前分辨率/帧率，建议降到 1080p 或 30fps 再试。"
        }
        state = .finishing
        delegate?.recordingStateChanged()
        Task { [weak self] in
            await self?.complete(save: true, askToSave: false)
            self?.delegate?.recordingFailed(message: "采集中断，已保存已录部分。\n\(shown)")
        }
    }

    private static func displayUnderMouse(in content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let displayID = screen?.displayID,
           let display = content.displays.first(where: { $0.displayID == displayID }) {
            return display
        }
        return content.displays.first
    }

    static func outputURL(in directory: URL, audioOnly: Bool = false) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let prefix = audioOnly ? "AUD" : "REC"
        let ext = audioOnly ? "m4a" : "mp4"
        return directory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).\(ext)")
    }
}
