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
    private var stream: SCStream?
    private let frameLock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?
    private static let imageContext = CIContext(options: nil)

    public var onError: ((String) -> Void)?

    public func latestFrameImage() -> CGImage? {
        frameLock.lock()
        let pixelBuffer = lastPixelBuffer
        frameLock.unlock()
        guard let pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return Self.imageContext.createCGImage(image, from: image.extent)
    }

    public init(writer: RecordingWriter, counters: CaptureCounters, systemAudio: Bool) {
        self.writer = writer
        self.counters = counters
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

    /// 排除本 App 的 UI 窗口（控制条/倒计时/选区框），鼠标高亮窗口不带隐藏标记、保留在画面里。
    private static func ownHiddenWindows(display: SCDisplay) async -> [SCWindow] {
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        guard !ourBundle.isEmpty else { return [] }
        guard let content = try? await loadShareableContent() else { return [] }
        guard content.displays.contains(where: { $0.displayID == display.displayID }) else { return [] }
        return content.windows.filter { window in
            guard window.isOnScreen, window.owningApplication?.bundleIdentifier == ourBundle else { return false }
            return window.title == hiddenWindowTitle || window.windowLayer >= 1000
        }
    }

    public static let hiddenWindowTitle = "\u{200B}freerec-ui-hidden\u{200B}"

    public func start(source: CaptureSource, settings: CaptureSettings) async throws {
        let filter: SCContentFilter
        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: await Self.ownHiddenWindows(display: display))
        case .region(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: await Self.ownHiddenWindows(display: display))
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
    }

    public func stop() async {
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
            counters.frameCaptured()
            frameLock.lock()
            lastPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            frameLock.unlock()
            switch writer.appendVideo(sampleBuffer) {
            case .written: counters.frameWritten()
            case .notReady: counters.frameDroppedBusy()
            case .invalid: counters.frameDroppedInvalid()
            case .paused: break
            }
        case .audio:
            counters.audioBuffer()
            _ = writer.appendAudio(sampleBuffer, track: .system)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("采集中断：\(error.localizedDescription)")
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
