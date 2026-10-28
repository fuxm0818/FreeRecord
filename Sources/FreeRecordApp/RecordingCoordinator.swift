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
    private var screen: ScreenCapture?
    private var systemAudioStream: SystemAudioStreamCapture?
    private var mic: AudioDeviceCapture?
    private var systemAudioCapture: AudioDeviceCapture?
    private var currentSize: (width: Int, height: Int)?
    /// 因缺屏幕录制权限而没启动成的录制，授权后自动续上
    private var pendingStart: (source: CaptureSource?, settings: CaptureSettings)?

    /// App 变为活跃时调用：权限已就绪就自动开始之前未启动成的录制
    func retryPendingStartIfReady() async {
        guard state == .idle, let pending = pendingStart else { return }
        let granted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
        guard granted else { return }
        pendingStart = nil
        await startSession(source: pending.source, settings: pending.settings)
    }

    func start(source: CaptureSource, settings: CaptureSettings) async {
        await startSession(source: source, settings: settings)
    }

    /// 录制音频（无画面），输出 .m4a
    func startAudioOnly(settings: CaptureSettings, onLevel: ((Float) -> Void)?) async {
        await startSession(source: nil, settings: settings, levelHandler: onLevel)
    }

    private func startSession(source: CaptureSource?, settings: CaptureSettings, levelHandler: ((Float) -> Void)? = nil) async {
        guard state == .idle else { return }
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
                pendingStart = (source, settings)
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
            var screen: ScreenCapture?
            if let source {
                let capture = ScreenCapture(writer: writer, counters: counters, systemAudio: hasSystem)
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
                    await screen?.stop()
                    writer.cancel()
                    self.writer = nil
                    self.screen = nil
                    self.currentSize = nil
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
                        writer.cancel()
                        self.writer = nil
                        self.currentSize = nil
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
                    await screen?.stop()
                    writer.cancel()
                    self.writer = nil
                    self.screen = nil
                    self.currentSize = nil
                    delegate?.recordingFailed(message: "麦克风启动失败：\(error.localizedDescription)")
                    return
                }
            }

            startedAt = Date()
            accumulatedPaused = 0
            pausedSince = nil
            state = .recording
            createSleepAssertion()
            delegate?.recordingStateChanged()
        } catch {
            createdWriter?.cancel()
            self.writer = nil
            self.screen = nil
            self.currentSize = nil
            delegate?.recordingFailed(message: "启动录制失败：\(error.localizedDescription)")
        }
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

        do {
            let url = try await writer.finish()
            reportSaved(url: url, writer: writer, size: size, duration: duration, askToSave: askToSave)
        } catch {
            // 分片 MP4 的 moov 在文件头，收尾失败时已录内容大概率仍可播放，别让用户白录
            if Self.isPlayableMovie(writer.url) {
                reportSaved(url: writer.url, writer: writer, size: size, duration: duration, askToSave: askToSave)
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
        ), askToSave: true)
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
        state = .finishing
        delegate?.recordingStateChanged()
        Task { [weak self] in
            await self?.complete(save: true, askToSave: false)
            self?.delegate?.recordingFailed(message: "采集中断，已保存已录部分。\n\(message)")
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
