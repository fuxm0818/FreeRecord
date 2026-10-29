import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 纯系统声音采集（macOS 13+，无需 BlackHole）：只订阅 SCK 音频流，不写视频。
public final class SystemAudioStreamCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public var onError: ((String) -> Void)?
    public var onLevel: ((Float) -> Void)?

    private let writer: RecordingWriter
    private let counters: CaptureCounters
    private let queue = DispatchQueue(label: "freerec.systemaudio", qos: .userInitiated)
    private var stream: SCStream?

    public init(writer: RecordingWriter, counters: CaptureCounters) {
        self.writer = writer
        self.counters = counters
        super.init()
    }

    @available(macOS 13.0, *)
    public func start(display: SCDisplay) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // 只要声音：视频参数压到最小以降低开销
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 2
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
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
        guard #available(macOS 13.0, *) else { return }
        guard outputType == .audio, sampleBuffer.isValid else { return }
        counters.audioBuffer(track: .system)
        _ = writer.appendAudio(sampleBuffer, track: .system)
        if let onLevel, let level = AudioDeviceCapture.rmsLevel(of: sampleBuffer) {
            onLevel(level)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("系统声音采集中断：\(error.localizedDescription)")
    }
}
