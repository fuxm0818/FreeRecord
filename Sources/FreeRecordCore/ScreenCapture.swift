import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 12.3, *)
public enum CaptureSource {
    case display(SCDisplay)
    /// rect 为显示器坐标（points），原点在左上角
    case region(display: SCDisplay, rect: CGRect)
    case window(SCWindow)
}

@available(macOS 12.3, *)
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public let queue = DispatchQueue(label: "freerec.screen", qos: .userInitiated)

    private let writer: RecordingWriter
    private let counters: CaptureCounters
    private let useSystemAudio: Bool
    /// 摄像头画中画：不为 nil 时每帧先合成再写入
    private let compositor: CameraOverlayCompositor?
    private var stream: SCStream?
    private let frameLock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?
    private static let imageContext = CIContext(options: nil)
    /// macOS 12 的窗口/区域流只在内容变化时出帧，静止画面会得到几帧就结束的短片。
    /// 画面停了超过 `pumpGap` 就用上一帧补一帧；显示流本身连续，不会触发。
    private var pumpTimer: DispatchSourceTimer?
    private var lastRawSampleBuffer: CMSampleBuffer?
    private var pumpDuration = CMTime(value: 1, timescale: 30)
    private static let pumpGap = CMTime(seconds: 0.5, preferredTimescale: 600)
    /// 真实帧 PTS 与主机时钟的固定差：SCK 用哪个时钟域都不影响补帧
    private var pumpPTSOffset = CMTime.invalid
    /// 已写入的最后一个样本 PTS（补帧用，只在 queue 上访问）
    private var lastEncodedPTS = CMTime.invalid
    /// 最后一个样本进入 writer 的主机时刻：用来看画面停了多久
    private var lastEncodedHostTime = CMTime.invalid

    public var onError: ((String) -> Void)?

    public func latestFrameImage() -> CGImage? {
        frameLock.lock()
        let pixelBuffer = lastPixelBuffer
        frameLock.unlock()
        guard let pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return Self.imageContext.createCGImage(image, from: image.extent)
    }

    public init(writer: RecordingWriter, counters: CaptureCounters, systemAudio: Bool,
                cameraOverlay: CameraOverlaySource? = nil) {
        self.writer = writer
        self.counters = counters
        self.compositor = cameraOverlay.map { CameraOverlayCompositor(source: $0) }
        if #available(macOS 13.0, *) {
            self.useSystemAudio = systemAudio
        } else {
            self.useSystemAudio = false
        }
        super.init()
    }

    public static func loadShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCShareableContent, Error>) in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: error ?? CaptureError.noDisplay)
                }
            }
        }
    }

    public static func plannedSize(source: CaptureSource, targetHeight: Int, pixelScale: Double = 1) -> (width: Int, height: Int) {
        let scale = max(pixelScale, 1)
        var width: Int
        var height: Int
        switch source {
        case .display(let display):
            width = Int((Double(display.width) * scale).rounded())
            height = Int((Double(display.height) * scale).rounded())
        case .region(_, let rect):
            width = max(Int((rect.width * scale).rounded()), 2)
            height = max(Int((rect.height * scale).rounded()), 2)
        case .window(let window):
            width = max(Int((window.frame.width * scale).rounded()), 2)
            height = max(Int((window.frame.height * scale).rounded()), 2)
        }
        if targetHeight > 0, targetHeight < height {
            let ratio = Double(targetHeight) / Double(height)
            width = Int((Double(width) * ratio).rounded())
            height = targetHeight
        }
        width = max(width - width % 2, 2)
        height = max(height - height % 2, 2)
        return (width, height)
    }

    /// 排除本 App 的所有屏幕窗口（控制条/倒计时/选区框/菜单栏图标），
    /// 只有带 `recordedWindowTitle` 的窗口（点击高亮效果）保留在画面里。
    ///
    /// 这里刻意在列表为空时也不回退到 `excludingWindows: []`：
    /// macOS 12.7.6 上空排除列表会让整屏采集一帧都收不到（startCapture 成功但 0 帧），
    /// 只要排除里有一个在屏窗口就正常。本 App 运行时菜单栏图标窗口一定在屏，
    /// 因此正常使用中列表不会为空。
    private static func ownExcludedWindows(display: SCDisplay) async -> [SCWindow] {
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        guard !ourBundle.isEmpty else { return [] }
        guard let content = try? await loadShareableContent() else { return [] }
        guard content.displays.contains(where: { $0.displayID == display.displayID }) else { return [] }
        return content.windows.filter { window in
            window.isOnScreen
                && window.owningApplication?.bundleIdentifier == ourBundle
                && window.title != recordedWindowTitle
        }
    }

    public static let hiddenWindowTitle = "\u{200B}freerec-ui-hidden\u{200B}"
    /// 要被录进画面的自家窗口（点击高亮层）用这个标题，采集时不排除。
    public static let recordedWindowTitle = "\u{200B}freerec-recorded\u{200B}"

    public func start(source: CaptureSource, settings: CaptureSettings) async throws {
        let filter: SCContentFilter
        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: await Self.ownExcludedWindows(display: display))
        case .region(let display, _):
            filter = SCContentFilter(display: display, excludingWindows: await Self.ownExcludedWindows(display: display))
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = SCStreamConfiguration()
        let size = Self.plannedSize(source: source, targetHeight: settings.targetHeight, pixelScale: settings.pixelScale)
        configuration.width = size.width
        configuration.height = size.height
        if case .region(_, let rect) = source {
            configuration.sourceRect = rect
        }

        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.fps)))
        configuration.queueDepth = 6
        configuration.showsCursor = settings.showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        if #available(macOS 13.0, *), useSystemAudio {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if #available(macOS 13.0, *), useSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        self.stream = stream
        startFramePump(fps: settings.fps)
    }

    public func stop() async {
        // 定时器状态全部在 queue 上，取消也回 queue 做，避免与 didOutput 抢着改。
        // 顺手补一帧收尾：画面若是静止的，最后一帧可能停在这么久之前，轨道会短一截。
        queue.sync { [weak self] in
            guard let self else { return }
            self.pumpTimer?.cancel()
            self.pumpTimer = nil
            self.appendPumpedFrameIfNeeded()
        }
        guard let stream else { return }
        self.stream = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in
                continuation.resume()
            }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            let output = compositor?.composite(sampleBuffer) ?? sampleBuffer
            counters.frameCaptured()
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if now.isValid, rawPTS.isValid {
                let offset = CMTimeSubtract(now, rawPTS)
                if offset.isValid { pumpPTSOffset = offset }
            }
            frameLock.lock()
            lastPixelBuffer = CMSampleBufferGetImageBuffer(output)
            frameLock.unlock()
            lastRawSampleBuffer = sampleBuffer
            switch writer.appendVideo(output) {
            case .written:
                counters.frameWritten()
                if rawPTS.isValid { lastEncodedPTS = rawPTS }
                if now.isValid { lastEncodedHostTime = now }
            case .notReady: counters.frameDroppedBusy()
            case .invalid: counters.frameDroppedInvalid()
            case .paused: break
            }
        case .audio:
            counters.audioBuffer(track: .system)
            _ = writer.appendAudio(sampleBuffer, track: .system)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(LF("采集中断：%@", error.localizedDescription))
    }

    /// 定时器整个生命周期都在采集 queue 上：启动、补帧、取消互不抢状态
    private func startFramePump(fps: Int) {
        queue.async { [weak self] in
            guard let self, self.pumpTimer == nil else { return }
            self.pumpDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            let interval = max(1, 1_000_000_000 / max(1, fps))
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + .nanoseconds(interval),
                repeating: .nanoseconds(interval),
                leeway: .milliseconds(2)
            )
            timer.setEventHandler { [weak self] in self?.pumpFrameIfNeeded() }
            self.pumpTimer = timer
            timer.resume()
        }
    }

    private func pumpFrameIfNeeded() {
        guard let raw = lastRawSampleBuffer, pumpPTSOffset.isValid,
              !writer.isPaused, lastEncodedHostTime.isValid else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard now.isValid else { return }
        // 画面一直在变就什么都不用做；静止超过 pumpGap 才补一帧，避免把文件撑大
        let silent = CMTimeSubtract(now, lastEncodedHostTime)
        guard silent.isValid, CMTimeCompare(silent, Self.pumpGap) >= 0 else { return }
        appendPumpedFrame(from: raw, at: now)
    }

    private func appendPumpedFrameIfNeeded() {
        guard let raw = lastRawSampleBuffer, pumpPTSOffset.isValid, !writer.isPaused else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard now.isValid else { return }
        appendPumpedFrame(from: raw, at: now)
    }

    /// 时间戳落在真实帧的同一时钟域上；故意比真实时间晚一帧，
    /// 让刚到的真实帧永远排在新补帧之后，避免写入器把整条轨往回重定时。
    private func appendPumpedFrame(from sampleBuffer: CMSampleBuffer, at now: CMTime) {
        let pts = CMTimeSubtract(CMTimeSubtract(now, pumpPTSOffset), pumpDuration)
        guard pts.isValid,
              !lastEncodedPTS.isValid || CMTimeCompare(pts, lastEncodedPTS) > 0,
              let frame = makePumpedFrame(from: sampleBuffer, pts: pts) else { return }
        switch writer.appendVideo(frame) {
        case .written:
            counters.frameWritten()
            lastEncodedPTS = pts
            lastEncodedHostTime = now
        case .notReady, .invalid, .paused:
            break
        }
    }

    private func makePumpedFrame(from sampleBuffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        let image = compositor?.composite(sampleBuffer) ?? sampleBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(image) else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: pumpDuration,
            presentationTimeStamp: pts,
            decodeTimeStamp: pts
        )
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawValue) else {
            return false
        }
        return status == .complete
    }
}
