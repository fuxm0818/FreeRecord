import AVFoundation
import Foundation

public final class AudioDeviceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public enum AudioError: LocalizedError {
        case deviceNotFound
        case cannotAddInput

        public var errorDescription: String? {
            switch self {
            case .deviceNotFound: return "没有找到可用的音频输入设备"
            case .cannotAddInput: return "无法添加音频输入"
            }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "freerec.audio", qos: .userInitiated)
    private let writer: RecordingWriter
    private let counters: CaptureCounters
    private let track: RecordingWriter.AudioTrack
    /// 音量电平（0…1），用于录制音频界面的能量条
    public var onLevel: ((Float) -> Void)?

    private let muteLock = NSLock()
    private var muted = false
    /// 录制中临时静音：仍然采集（电平条照常动），但不写入文件
    public var isMuted: Bool {
        get { muteLock.lock(); defer { muteLock.unlock() }; return muted }
        set { muteLock.lock(); muted = newValue; muteLock.unlock() }
    }

    public init(
        writer: RecordingWriter,
        counters: CaptureCounters,
        track: RecordingWriter.AudioTrack = .microphone
    ) {
        self.writer = writer
        self.counters = counters
        self.track = track
        super.init()
    }

    public static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .audio)
    }

    public static func defaultDeviceName() -> String? {
        audioDevices().first?.localizedName
    }

    public func start(deviceName: String?) throws {
        let devices = Self.audioDevices()
        guard let device = devices.first(where: { $0.localizedName == deviceName }) ?? devices.first else {
            throw AudioError.deviceNotFound
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]

        try queue.sync {
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw AudioError.cannotAddInput
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw AudioError.cannotAddInput
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
        }
    }

    public func stop() {
        queue.sync {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        counters.audioBuffer(track: track)
        if !isMuted {
            _ = writer.appendAudio(sampleBuffer, track: track)
        }
        guard let onLevel, let level = Self.rmsLevel(of: sampleBuffer) else { return }
        onLevel(level)
    }

    /// 计算 -60dB…0dB 映射到 0…1 的粗略电平
    public static func rmsLevel(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return nil
        }
        // 采集输出是交错 Float32，直接读 CMBlockBuffer 最稳
        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
           asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
           asbd.mBitsPerChannel == 32,
           let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            if CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == noErr, let pointer, length >= 4 {
                let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                var sum = 0.0
                let count = length / MemoryLayout<Float>.size
                for index in 0..<count {
                    let value = Double(samples[index])
                    sum += value * value
                }
                return level(sum: sum, count: count)
            }
        }
        // 平面格式兜底：逐 buffer 读取
        let maximumBuffers = 8
        let bufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        var sum = 0.0
        var count = 0
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<n {
                let value = Double(samples[index])
                sum += value * value
            }
            count += n
        }
        return level(sum: sum, count: count)
    }

    private static func level(sum: Double, count: Int) -> Float? {
        guard count > 0 else { return nil }
        let rms = (sum / Double(count)).squareRoot()
        guard rms > 0 else { return 0 }
        // -60dB…0dB 映射到 0…1，再用 0.6 次方压低低音量段，让轻声也能看到明显跳动
        let decibels = 20 * log10(rms)
        let normalized = (decibels + 60) / 60
        return Float(max(0, min(1, pow(max(0, normalized), 0.6))))
    }
}
