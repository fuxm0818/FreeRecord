import AVFoundation
import CoreMedia
import Foundation

public final class RecordingWriter {
    public enum AppendResult {
        case written
        case notReady
        case invalid
        case paused
    }

    public enum WriterError: LocalizedError {
        case setupFailed(String)
        case noFrames
        case finishFailed(String)

        public var errorDescription: String? {
            switch self {
            case .setupFailed(let message): return message
            case .noFrames: return "没有采集到任何数据"
            case .finishFailed(let message): return message
            }
        }
    }

    public enum AudioTrack: Int {
        case microphone = 0
        case system = 1
    }

    public let url: URL
    public let audioTrackCount: Int
    public let hasVideo: Bool
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private var audioInputs: [AVAssetWriterInput?]
    private let lock = NSLock()

    private var originPTS: CMTime?
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: [CMTime]
    private var sessionStarted = false
    private var audioSamplesAppended = 0
    private var paused = false
    // 一旦开始收尾就丢弃迟到的样本：SCStream stopCapture 返回后仍可能补发
    // 队列里的帧，此时 append 到已 markAsFinished 的 input 会让整个 writer 变 failed
    private var finishing = false
    private var videoShift: CMTime = .zero
    private var audioShift: [CMTime] = [.zero, .zero]
    private var videoShiftDirty = false
    private var audioShiftDirty = [false, false]

    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    public func setPaused(_ newPaused: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard paused != newPaused else { return }
        paused = newPaused
        if newPaused {
            videoShiftDirty = true
            for track in 0..<2 { audioShiftDirty[track] = true }
        }
    }

    public convenience init(url: URL, width: Int, height: Int, fps: Int, hasMicTrack: Bool, hasSystemTrack: Bool, bitrate: Int) throws {
        try self.init(
            url: url,
            fileType: .mp4,
            width: width,
            height: height,
            fps: fps,
            hasMicTrack: hasMicTrack,
            hasSystemTrack: hasSystemTrack,
            bitrate: bitrate
        )
    }

    /// 纯音频录制（录制音频模式），输出 .m4a
    public convenience init(audioOnlyURL url: URL, hasMicTrack: Bool, hasSystemTrack: Bool) throws {
        guard hasMicTrack || hasSystemTrack else {
            throw WriterError.setupFailed("没有选择声音来源")
        }
        try self.init(
            url: url,
            fileType: .m4a,
            width: 0,
            height: 0,
            fps: 0,
            hasMicTrack: hasMicTrack,
            hasSystemTrack: hasSystemTrack,
            bitrate: 0
        )
    }

    private init(url: URL, fileType: AVFileType, width: Int, height: Int, fps: Int, hasMicTrack: Bool, hasSystemTrack: Bool, bitrate: Int) throws {
        self.url = url
        self.audioTrackCount = (hasMicTrack ? 1 : 0) + (hasSystemTrack ? 1 : 0)
        self.hasVideo = width > 0 && height > 0
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw WriterError.setupFailed("无法创建文件：\(error.localizedDescription)")
        }

        var video: AVAssetWriterInput?
        if hasVideo {
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: max(1, fps * 2),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ])
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else {
                throw WriterError.setupFailed("无法添加视频轨道")
            }
            assetWriter.add(input)
            video = input

            // 分片 MP4：moov 索引在文件头，崩溃/强杀时已录内容仍可播放
            assetWriter.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        }

        var inputs: [AVAssetWriterInput?] = [nil, nil]
        let slots: [(AudioTrack, Bool)] = [(.microphone, hasMicTrack), (.system, hasSystemTrack)]
        for (track, enabled) in slots where enabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                inputs[track.rawValue] = input
            }
        }

        guard assetWriter.startWriting() else {
            throw WriterError.setupFailed(assetWriter.error?.localizedDescription ?? "无法开始写入")
        }

        self.writer = assetWriter
        self.videoInput = video
        self.audioInputs = inputs
        self.lastAudioPTS = [.invalid, .invalid]
    }

    public var lastVideoSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastVideoPTS.isValid ? lastVideoPTS.seconds : nil
    }

    public var lastAudioSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        let valid = lastAudioPTS.filter { $0.isValid }.map { $0.seconds }
        return valid.max()
    }

    public var lastMicrophoneSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        let pts = lastAudioPTS[AudioTrack.microphone.rawValue]
        return pts.isValid ? pts.seconds : nil
    }

    public var appendedAudioSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return audioSamplesAppended
    }

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) -> AppendResult {
        lock.lock(); defer { lock.unlock() }
        if finishing { return .invalid }
        if paused {
            videoShiftDirty = true
            return .paused
        }
        guard let videoInput else { return .invalid }
        guard videoInput.isReadyForMoreMediaData else { return .notReady }
        guard let retimed = makeRetimed(sampleBuffer, shift: &videoShift, shiftDirty: &videoShiftDirty, referencePTS: lastVideoPTS) else { return .invalid }
        let pts = CMSampleBufferGetPresentationTimeStamp(retimed)
        if lastVideoPTS.isValid, CMTimeCompare(pts, lastVideoPTS) <= 0 { return .invalid }
        guard videoInput.append(retimed) else { return .invalid }
        lastVideoPTS = pts
        return .written
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrack = .microphone) -> AppendResult {
        lock.lock(); defer { lock.unlock() }
        let index = track.rawValue
        if finishing { return .invalid }
        if paused {
            audioShiftDirty[index] = true
            return .paused
        }
        guard let audioInput = audioInputs[index] else { return .invalid }
        guard audioInput.isReadyForMoreMediaData else { return .notReady }
        guard let retimed = makeRetimed(sampleBuffer, shift: &audioShift[index], shiftDirty: &audioShiftDirty[index], referencePTS: lastAudioPTS[index]) else { return .invalid }
        let pts = CMSampleBufferGetPresentationTimeStamp(retimed)
        let previous = lastAudioPTS[index]
        if previous.isValid, CMTimeCompare(pts, previous) <= 0 { return .invalid }
        guard audioInput.append(retimed) else { return .invalid }
        lastAudioPTS[index] = pts
        audioSamplesAppended += 1
        return .written
    }

    public func finish() async throws -> URL {
        // 先挡住所有迟到样本，再 markAsFinished：两者在同一把锁下，不会交错
        beginFinishing()
        let started = markInputsFinished()

        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw WriterError.noFrames
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            throw WriterError.finishFailed(Self.describe(writer.error) ?? "写入未完成")
        }
        return url
    }

    static func describe(_ error: Error?) -> String? {
        guard let nsError = error as NSError? else { return nil }
        return "\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）"
    }

    private func beginFinishing() {
        lock.lock(); defer { lock.unlock() }
        finishing = true
    }

    private func markInputsFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let started = sessionStarted
        videoInput?.markAsFinished()
        for input in audioInputs where input != nil {
            input?.markAsFinished()
        }
        return started
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        finishing = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private func makeRetimed(_ sampleBuffer: CMSampleBuffer, shift: inout CMTime, shiftDirty: inout Bool, referencePTS: CMTime) -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0 else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return nil }

        if originPTS == nil {
            originPTS = pts
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        guard let origin = originPTS else { return nil }

        let firstRelative = CMTimeSubtract(pts, origin)
        if shiftDirty {
            shiftDirty = false
            if referencePTS.isValid {
                let duration = CMSampleBufferGetDuration(sampleBuffer)
                let nextFree = duration.isValid && duration.seconds > 0
                    ? CMTimeAdd(referencePTS, duration)
                    : CMTimeAdd(referencePTS, CMTime(value: 1, timescale: 60))
                shift = CMTimeSubtract(nextFree, firstRelative)
            } else {
                shift = .zero
            }
        }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        for index in 0..<count {
            var timing = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: index, timingInfoOut: &timing)
            if timing.presentationTimeStamp.isValid {
                let relative = CMTimeAdd(CMTimeSubtract(timing.presentationTimeStamp, origin), shift)
                timing.presentationTimeStamp = CMTimeMaximum(relative, .zero)
            }
            timings[index] = timing
        }

        var output: CMSampleBuffer?
        let status = timings.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: count,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &output
            )
        }
        guard status == noErr else { return nil }
        return output
    }
}
