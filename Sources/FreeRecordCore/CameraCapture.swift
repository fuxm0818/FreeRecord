import AVFoundation
import CoreMedia
import Foundation

/// 摄像头采集（录制摄像头模式）：AVCaptureSession 出画面 + 麦克风声音，交给 RecordingWriter 写盘。
/// 预览和录制共用同一个 session，避免两次占用摄像头。
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public enum CameraError: LocalizedError {
        case noCamera
        case cannotConfigure
        case noAudioInput

        public var errorDescription: String? {
            switch self {
            case .noCamera: return "没有找到可用的摄像头"
            case .cannotConfigure: return "无法配置摄像头"
            case .noAudioInput: return "没有找到可用的麦克风"
            }
        }
    }

    public let session = AVCaptureSession()
    public private(set) var hasAudioTrack = false
    public var onError: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "freerec.camera.session")
    private let videoQueue = DispatchQueue(label: "freerec.camera.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "freerec.camera.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var writer: RecordingWriter?

    public override init() {
        super.init()
    }

    public func configure(hasAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotConfigure }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotConfigure }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }

        if hasAudio, let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                hasAudioTrack = true
            }
        }
    }

    public func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    public func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    public func attach(writer: RecordingWriter) {
        lock.lock(); defer { lock.unlock() }
        self.writer = writer
    }

    public func detachWriter() {
        lock.lock(); defer { lock.unlock() }
        writer = nil
    }

    private func currentWriter() -> RecordingWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let writer = currentWriter() else { return }
        if output is AVCaptureVideoDataOutput {
            _ = writer.appendVideo(sampleBuffer)
        } else {
            _ = writer.appendAudio(sampleBuffer, track: .microphone)
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 摄像头丢帧不致命，写盘端会自己算丢帧
    }
}
