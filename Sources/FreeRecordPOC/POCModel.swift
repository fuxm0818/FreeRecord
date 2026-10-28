import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import FreeRecordCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class POCModel: ObservableObject {
    enum Phase {
        case idle
        case running
        case finished
    }

    @Published var phase: Phase = .idle
    @Published var duration = 60
    @Published var fps = 30
    @Published var height = 1080
    @Published var audio: AudioSource = .none
    @Published var stressMode = false
    @Published var liveStats = "等待开始"
    @Published var summary = ""
    @Published var errorMessage: String?
    @Published var reportURL: URL?
    @Published var videoURL: URL?
    @Published var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published var permissionStatus = ""
    @Published var supportsSystemAudio = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
    )

    private var writer: RecordingWriter?
    private var screen: ScreenCapture?
    private var deviceAudio: AudioDeviceCapture?
    private var counters: CaptureCounters?
    private var sampler: MetricsSampler?
    private var ticker: Timer?
    private var endTask: Task<Void, Never>?
    private var startedAt: Date?
    private var recordingSize: (width: Int, height: Int)?
    private var isFinishing = false
    private var stressWindow: StressWindowController?
    private var driftSamplesMS: [Double] = []

    func refreshPermission() {
        permissionStatus = "检查中…"
        Task {
            let granted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
            hasScreenPermission = granted
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            permissionStatus = granted
                ? "已授权（\(time) 检查）。可以直接开始测试。"
                : "仍未授权（\(time) 检查）。若系统设置里已勾选，请退出本 App 再打开——权限只在重新启动后生效。"
        }
    }

    func resetScreenPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            permissionStatus = "已重置屏幕录制权限。请退出本 App 并重新打开，再点「开始测试」重新授权。"
        } catch {
            permissionStatus = "重置失败：\(error.localizedDescription)。请在系统设置的「屏幕与系统音频录制」里手动把本 App 删掉（减号）再重开。"
        }
    }

    func openScreenSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func start() {
        guard phase == .idle else { return }
        Task { await run() }
    }

    func finishNow() {
        guard phase == .running else { return }
        Task { await complete() }
    }

    func reset() {
        guard phase == .finished else { return }
        phase = .idle
        summary = ""
        errorMessage = nil
        reportURL = nil
        videoURL = nil
        liveStats = "等待开始"
    }

    func revealReport() {
        if let reportURL {
            NSWorkspace.shared.activateFileViewerSelecting([reportURL])
        } else if let videoURL {
            NSWorkspace.shared.activateFileViewerSelecting([videoURL])
        }
    }

    private func run() async {
        errorMessage = nil
        summary = ""
        reportURL = nil
        videoURL = nil
        isFinishing = false
        driftSamplesMS = []

        let screenGranted = await Task.detached { CGPreflightScreenCaptureAccess() }.value
        guard screenGranted else {
            // 同步调用会卡住主线程，放到后台等系统弹窗
            _ = await Task.detached { CGRequestScreenCaptureAccess() }.value
            hasScreenPermission = false
            permissionStatus = "未授权。若弹窗没出现，说明这条权限记录属于旧版本：点「重置屏幕录制权限」，退出重开再试。"
            errorMessage = "没有「屏幕录制」权限，所以录不了屏。"
            return
        }
        hasScreenPermission = true

        if audio == .microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                errorMessage = "需要麦克风权限。"
                return
            }
        }

        do {
            let content = try await ScreenCapture.loadShareableContent()
            guard let display = pickDisplay(from: content) else {
                errorMessage = "没有找到可录制的显示器。"
                return
            }

            let size = outputSize(for: display)
            recordingSize = size
            let url = try outputFileURL()
            let willCaptureAudio = audio == .microphone || (audio == .system && supportsSystemAudio)
            let bitrate = max(2_000_000, Int(Double(size.width * size.height * fps) * 0.08))

            let writer = try RecordingWriter(
                url: url,
                width: size.width,
                height: size.height,
                fps: fps,
                hasMicTrack: audio == .microphone,
                hasSystemTrack: audio == .system && supportsSystemAudio,
                bitrate: bitrate
            )
            let counters = CaptureCounters()
            let screen = ScreenCapture(writer: writer, counters: counters, systemAudio: audio == .system)
            screen.onError = { [weak self] message in
                Task { @MainActor in
                    self?.errorMessage = message
                }
            }

            if stressMode, let targetScreen = screenUnderMouse() {
                let window = StressWindowController()
                window.show(on: targetScreen)
                stressWindow = window
            }

            do {
                try await screen.start(
                    source: .display(display),
                    settings: CaptureSettings(fps: fps, targetHeight: height, showsCursor: true, audio: audio)
                )
            } catch {
                hideStressWindow()
                writer.cancel()
                throw error
            }

            self.writer = writer
            self.screen = screen
            self.counters = counters

            if audio == .microphone {
                let deviceAudio = AudioDeviceCapture(writer: writer, counters: counters)
                do {
                    try deviceAudio.start(deviceName: nil)
                    self.deviceAudio = deviceAudio
                } catch {
                    hideStressWindow()
                    await screen.stop()
                    writer.cancel()
                    self.writer = nil
                    self.screen = nil
                    self.counters = nil
                    errorMessage = "麦克风启动失败：\(error.localizedDescription)"
                    phase = .idle
                    return
                }
            }

            self.videoURL = url
            self.startedAt = Date()

            let sampler = MetricsSampler()
            sampler.start()
            self.sampler = sampler

            phase = .running
            startTicker()
            scheduleEnd()
        } catch {
            hideStressWindow()
            errorMessage = "启动失败：\(error.localizedDescription)"
            phase = .idle
        }
    }

    private func hideStressWindow() {
        stressWindow?.hide()
        stressWindow = nil
    }

    private func scheduleEnd() {
        let seconds = duration
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.complete()
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLiveStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func updateLiveStats() {
        guard let counters, let sampler, let startedAt else { return }
        let snapshot = counters.snapshot()
        let elapsed = Date().timeIntervalSince(startedAt)
        let actualFPS = elapsed > 0 ? Double(snapshot.written) / elapsed : 0
        var text = String(
            format: "已录 %.0f 秒 · %.1f fps · 写入 %d 帧 · 丢帧 %d · CPU %.0f%% · 系统 %.0f%% · 内存 %.0f MB",
            elapsed,
            actualFPS,
            snapshot.written,
            snapshot.droppedTotal,
            sampler.cpuAverage,
            sampler.systemCpuAverage,
            sampler.peakRSSMB
        )
        if let writer,
           let lastVideo = writer.lastVideoSeconds,
           let lastAudio = writer.lastAudioSeconds,
           lastVideo > 0, lastAudio > 0 {
            let drift = (lastAudio - lastVideo) * 1_000
            driftSamplesMS.append(drift)
            text += String(format: "\n音画时间差 %+.0f ms（只测麦克风时钟漂移，数值稳就是好）", drift)
        }
        liveStats = text
    }

    private func complete() async {
        guard phase == .running, !isFinishing else { return }
        isFinishing = true

        endTask?.cancel()
        endTask = nil
        ticker?.invalidate()
        ticker = nil

        let sampler = self.sampler
        sampler?.stop()

        if let screen {
            await screen.stop()
        }
        deviceAudio?.stop()
        deviceAudio = nil
        hideStressWindow()

        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard let counters, let writer, let size = recordingSize else {
            phase = .idle
            isFinishing = false
            return
        }
        let snapshot = counters.snapshot()
        let lastVideo = writer.lastVideoSeconds
        let lastAudio = writer.lastAudioSeconds
        let audioSamples = writer.appendedAudioSamples

        do {
            let url = try await writer.finish()
            let report = makeReport(
                url: url,
                size: size,
                elapsed: elapsed,
                snapshot: snapshot,
                audioSamples: audioSamples,
                lastVideo: lastVideo,
                lastAudio: lastAudio
            )
            let reportURL = url.deletingPathExtension().appendingPathExtension("json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL)

            self.reportURL = reportURL
            self.videoURL = url
            var lines = [
                "完成：\(String(format: "%.0f", elapsed)) 秒，\(size.width)×\(size.height) @ \(fps)fps",
                "写入 \(snapshot.written) 帧（目标 \(report.expectedFrames) 帧，达成 \(String(format: "%.0f", report.captureRatio * 100))%），丢帧 \(snapshot.droppedTotal)",
                "实际 \(String(format: "%.1f", report.averageFPS)) fps",
                "本 App CPU 平均 \(String(format: "%.0f", report.cpuAveragePercent))%，峰值 \(String(format: "%.0f", report.cpuPeakPercent))%",
                "整机 CPU 平均 \(String(format: "%.0f", report.systemCpuAveragePercent))%，峰值 \(String(format: "%.0f", report.systemCpuPeakPercent))%",
                "内存峰值 \(String(format: "%.0f", report.rssPeakMB)) MB · 文件 \(String(format: "%.1f", report.fileSizeMB)) MB"
            ]
            if let start = report.driftStartMS, let end = report.driftEndMS, let growth = report.driftGrowthMS {
                lines.append(String(
                    format: "音画漂移：起点 %+.0f ms，终点 %+.0f ms，累计变化 %.0f ms",
                    start,
                    end,
                    growth
                ))
            }
            self.summary = lines.joined(separator: "\n")
            phase = .finished
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            phase = .idle
        }

        self.writer = nil
        self.screen = nil
        self.counters = nil
        self.sampler = nil
        self.startedAt = nil
        self.recordingSize = nil
        isFinishing = false
    }

    private func makeReport(
        url: URL,
        size: (width: Int, height: Int),
        elapsed: Double,
        snapshot: CaptureCounters.Snapshot,
        audioSamples: Int,
        lastVideo: Double?,
        lastAudio: Double?
    ) -> PerformanceReport {
        var drift: Double?
        if let lastVideo, let lastAudio {
            drift = abs(lastVideo - lastAudio) * 1_000
        }
        let averageFPS = elapsed > 0 ? Double(snapshot.written) / elapsed : 0
        let expectedFrames = max(Int((Double(fps) * elapsed).rounded()), 1)
        let driftStart = driftSamplesMS.first
        let driftEnd = driftSamplesMS.last
        let driftMaxAbs = driftSamplesMS.map { abs($0) }.max()
        var driftGrowth: Double?
        if let driftStart, let driftEnd {
            driftGrowth = abs(driftEnd - driftStart)
        }
        return PerformanceReport(
            date: ISO8601DateFormatter().string(from: Date()),
            machine: machineModel(),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: architecture,
            targetFPS: fps,
            width: size.width,
            height: size.height,
            durationSeconds: elapsed,
            framesCaptured: snapshot.captured,
            framesWritten: snapshot.written,
            droppedBusy: snapshot.droppedBusy,
            droppedInvalid: snapshot.droppedInvalid,
            expectedFrames: expectedFrames,
            captureRatio: Double(snapshot.written) / Double(expectedFrames),
            averageFPS: averageFPS,
            cpuAveragePercent: sampler?.cpuAverage ?? 0,
            cpuPeakPercent: sampler?.cpuPeak ?? 0,
            systemCpuAveragePercent: sampler?.systemCpuAverage ?? 0,
            systemCpuPeakPercent: sampler?.systemCpuPeak ?? 0,
            rssPeakMB: sampler?.peakRSSMB ?? 0,
            fileSizeMB: fileSizeMB(url),
            audioBuffers: snapshot.audioBuffers,
            audioSamplesAppended: audioSamples,
            avDriftMS: drift,
            driftStartMS: driftStart,
            driftEndMS: driftEnd,
            driftMaxAbsMS: driftMaxAbs,
            driftGrowthMS: driftGrowth,
            stressMode: stressMode,
            videoPath: url.path
        )
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func pickDisplay(from content: SCShareableContent) -> SCDisplay? {
        if let displayID = screenUnderMouse()?.displayID,
           let display = content.displays.first(where: { $0.displayID == displayID }) {
            return display
        }
        return content.displays.first
    }

    private func outputSize(for display: SCDisplay) -> (width: Int, height: Int) {
        var width = display.width
        var targetHeight = display.height
        if height > 0, height < targetHeight {
            let scale = Double(height) / Double(targetHeight)
            width = Int((Double(width) * scale).rounded())
            targetHeight = height
        }
        width -= width % 2
        targetHeight -= targetHeight % 2
        return (width, targetHeight)
    }

    private func outputFileURL() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/FreeRecPerformance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return directory.appendingPathComponent("test-\(formatter.string(from: Date())).mp4")
    }

    private func fileSizeMB(_ url: URL) -> Double {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        return size / 1_024 / 1_024
    }

    private func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

struct PerformanceReport: Codable {
    let date: String
    let machine: String
    let os: String
    let arch: String
    let targetFPS: Int
    let width: Int
    let height: Int
    let durationSeconds: Double
    let framesCaptured: Int
    let framesWritten: Int
    let droppedBusy: Int
    let droppedInvalid: Int
    let expectedFrames: Int
    let captureRatio: Double
    let averageFPS: Double
    let cpuAveragePercent: Double
    let cpuPeakPercent: Double
    let systemCpuAveragePercent: Double
    let systemCpuPeakPercent: Double
    let rssPeakMB: Double
    let fileSizeMB: Double
    let audioBuffers: Int
    let audioSamplesAppended: Int
    let avDriftMS: Double?
    let driftStartMS: Double?
    let driftEndMS: Double?
    let driftMaxAbsMS: Double?
    let driftGrowthMS: Double?
    let stressMode: Bool
    let videoPath: String
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
