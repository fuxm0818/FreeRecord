import AVFoundation
import CoreMedia
import Foundation

/// 把录好的音频成品转成 MP3。
///
/// macOS 只带 MP3 解码器，AVAssetWriter / AVAssetExportSession / ExtAudioFile
/// 都写不出 .mp3，所以编码这一步交给 LAME 子进程：本进程解出裸 PCM，
/// 按 raw PCM 流写进它的 stdin。
/// LAME 以独立可执行文件随包分发（LGPL），不链接进主程序。
public final class Mp3Exporter {
    public enum ExportError: LocalizedError {
        case noEncoder
        case noAudioTrack
        case readerFailed(String)
        case unexpectedPCMFormat
        case encoderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noEncoder: return "找不到 MP3 编码器"
            case .noAudioTrack: return "文件里没有音轨"
            case .readerFailed(let message): return "读取音频失败：\(message)"
            case .unexpectedPCMFormat: return "解码出的音频格式不是 16 位交错 PCM"
            case .encoderFailed(let message): return "MP3 编码失败：\(message)"
            }
        }
    }

    /// 打包进 App 的编码器优先；开发构建（swift build 产物没有 Helpers）退到系统安装位置
    public static var encoderURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lame"),
            URL(fileURLWithPath: "/opt/homebrew/bin/lame"),
            URL(fileURLWithPath: "/usr/local/bin/lame"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var isAvailable: Bool { encoderURL != nil }

    /// CBR 而不是 VBR：老车机、老剪辑软件对 VBR 的时长估算不准，宁可大一点也要稳
    public var bitrateKbps = 192

    public init() {}

    public func export(from source: URL, to destination: URL) async throws {
        guard let encoder = Self.encoderURL else { throw ExportError.noEncoder }

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ExportError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.readerFailed(error.localizedDescription)
        }

        let output: AVAssetReaderOutput
        if tracks.count > 1 {
            // 麦克风轨与系统声轨是两条独立音轨，MP3 只有一条：交给系统的混音输出相加，
            // 比自己按样本对齐相加少一层时钟漂移的风险
            output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Self.pcmSettings)
        } else {
            output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: Self.pcmSettings)
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.readerFailed("音频格式不支持") }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("freerec-lame-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let bitrate = bitrateKbps
        let job = PCMJob(reader: reader, output: output)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.run(
                    encoder: encoder,
                    job: job,
                    bitrateKbps: bitrate,
                    destination: destination,
                    logURL: logURL
                )
                continuation.resume(with: result)
            }
        }
    }

    /// AVAssetReader / AVAssetReaderOutput 不是 Sendable，但整段搬运只在这一条后台线程上跑、
    /// 闭包独占持有，所以按「已核查过并发安全」处理，避免 Swift 6 的捕获告警
    private struct PCMJob: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
    }

    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// 在后台线程跑：往编码器 stdin 写数据会因管道背压阻塞，绝不能放在主线程。
    private static func run(
        encoder: URL,
        job: PCMJob,
        bitrateKbps: Int,
        destination: URL,
        logURL: URL
    ) -> Result<Void, Error> {
        let reader = job.reader
        let output = job.output
        var process: Process?
        var stdin: FileHandle?
        var failure: Error?
        var wroteAnySample = false

        while failure == nil, reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == noErr, let pointer else {
                // 读不出连续 PCM 就中止：继续的话这段音频会静默消失，
                // 用户以为录上了，文件里没有
                failure = ExportError.unexpectedPCMFormat
                break
            }
            if process == nil {
                // 采样率必须取自真正解出来的首包：写进 -s 的值错了，整段成品变调又变速
                guard let description = streamDescription(of: sample) else {
                    failure = ExportError.unexpectedPCMFormat
                    break
                }
                process = launch(
                    encoder: encoder,
                    sampleRate: Double(description.mSampleRate),
                    bitrateKbps: bitrateKbps,
                    destination: destination,
                    logURL: logURL
                )
                guard let started = process else {
                    failure = ExportError.encoderFailed("无法启动编码器")
                    break
                }
                stdin = (started.standardInput as? Pipe)?.fileHandleForWriting
            }
            wroteAnySample = true
            stdin?.write(Data(bytes: pointer, count: length))
        }

        stdin?.closeFile()
        process?.waitUntilExit()

        if failure == nil, reader.status == .failed {
            failure = ExportError.readerFailed(reader.error?.localizedDescription ?? "读取中断")
        }
        if failure == nil, let process, process.terminationStatus != 0 {
            let log = (try? Data(contentsOf: logURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = log.split(separator: "\n").first.map(String.init) ?? "退出码 \(process.terminationStatus)"
            failure = ExportError.encoderFailed(firstLine)
        }
        try? FileManager.default.removeItem(at: logURL)

        if let failure {
            try? FileManager.default.removeItem(at: destination)
            reader.cancelReading()
            return .failure(failure)
        }
        guard wroteAnySample else {
            // 一个样本都没解出来（空文件）：别交付一个 0 字节的 mp3
            try? FileManager.default.removeItem(at: destination)
            return .failure(ExportError.noAudioTrack)
        }
        return .success(())
    }

    private static func launch(
        encoder: URL,
        sampleRate: Double,
        bitrateKbps: Int,
        destination: URL,
        logURL: URL
    ) -> Process? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = encoder
        process.arguments = [
            "-r", // 裸 PCM 输入
            "-s", frequencyArgument(sampleRate),
            "--bitwidth", "16",
            "-b", String(bitrateKbps),
            "--quiet",
            "-",
            destination.path,
        ]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    /// lame 的 -s 用 kHz：48000 要写成 48，44100 写成 44.1
    private static func frequencyArgument(_ sampleRate: Double) -> String {
        let kHz = sampleRate / 1_000
        return kHz == kHz.rounded() ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
    }

    private static func streamDescription(of sample: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              asbd.mBitsPerChannel == 16,
              asbd.mSampleRate > 0
        else { return nil }
        return asbd
    }
}
