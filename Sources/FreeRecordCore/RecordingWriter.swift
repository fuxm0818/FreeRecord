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
    /// 各轨已写入内容的末端（PTS + 实际时长）：统一暂停恢复点用它计算
    private var lastVideoEnd: CMTime = .invalid
    private var lastAudioEnd: [CMTime]
    /// 各轨首个成功写入样本的原始 PTS：音画对齐诊断用（与 origin 的关系能看出启动错位）
    private var firstRawPTS: [CMTime?] = [nil, nil, nil] // 0=视频 1=麦克风 2=系统声
    /// 各轨末个成功写入样本的原始 PTS：诊断必须与首帧同用原始时钟，
    /// 混用重定时后的 lastVideoPTS 会算出跨时钟域的荒诞时长
    private var lastRawPTS: [CMTime?] = [nil, nil, nil]
    /// 暂停恢复的统一续接点：所有轨从同一输出时刻继续，暂停间隙等长，
    /// 恢复后各轨相对关系与暂停前一致（各轨独立续接会每次暂停累积几十毫秒错位）
    private var pendingResumePTS: CMTime = .invalid
    private var sessionStarted = false
    private var audioSamplesAppended = 0
    private var paused = false
    // 一旦开始收尾就丢弃迟到的样本：SCStream stopCapture 返回后仍可能补发
    // 队列里的帧，此时 append 到已 markAsFinished 的 input 会让整个 writer 变 failed
    private var finishing = false
    private let width: Int
    private let height: Int
    private let fps: Int
    private let bitrate: Int
    private var videoShift: CMTime = .zero
    private var audioShift: [CMTime] = [.zero, .zero]
    private var videoShiftDirty = false
    private var audioShiftDirty = [false, false]
    private let frameDuration: CMTime

    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// -16341 这类错误没有明文原因，没有现场就永远只能猜。出问题时把关键状态一次倒出来
    public func diagnostics() -> String {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        lines.append("时间：\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("文件：\(url.path)")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            lines.append("已写字节：\(size.intValue)")
        }
        lines.append("写入器状态：\(Self.statusName(writer.status))")
        if let failure = Self.describe(writer.error) { lines.append("错误：\(failure)") }
        lines.append("视频尺寸：\(width)x\(height) fps=\(fps) 码率=\(bitrate)")
        lines.append("分片间隔：\(writer.movieFragmentInterval.seconds) 秒")
        lines.append("会话已开始：\(sessionStarted) 暂停中：\(paused) 收尾中：\(finishing)")
        if let videoInput {
            lines.append("视频输入：ready=\(videoInput.isReadyForMoreMediaData) 最后PTS=\(ptsText(lastVideoPTS))")
        }
        for (index, input) in audioInputs.enumerated() {
            guard let input else { continue }
            let name = index == AudioTrack.microphone.rawValue ? "麦克风" : "系统声"
            lines.append("\(name)输入：ready=\(input.isReadyForMoreMediaData) 最后PTS=\(ptsText(lastAudioPTS[index])) 样本数=\(audioSamplesAppended)")
        }
        return lines.joined(separator: "\n")
    }

    private static func statusName(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "other(\(status.rawValue))"
        }
    }

    private func ptsText(_ time: CMTime) -> String {
        time.isValid ? String(format: "%.4f", time.seconds) : "invalid"
    }

    public func setPaused(_ newPaused: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard paused != newPaused else { return }
        paused = newPaused
        if newPaused {
            videoShiftDirty = true
            for track in 0..<2 { audioShiftDirty[track] = true }
        } else {
            // 恢复：取各轨已写内容末端的最大值作为统一续接点。
            // 此刻 lastXXXEnd 已定格（暂停时样本全被丢弃），两条轨恢复后
            // 都从这个输出时刻继续，暂停间隙等长、相对对齐不被破坏。
            var candidates: [CMTime] = []
            if lastVideoEnd.isValid { candidates.append(lastVideoEnd) }
            for end in lastAudioEnd where end.isValid { candidates.append(end) }
            if let common = candidates.max(by: { CMTimeCompare($0, $1) < 0 }) {
                pendingResumePTS = common
                videoShiftDirty = true
                for track in 0..<2 { audioShiftDirty[track] = true }
            }
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
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.hasVideo = width > 0 && height > 0
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
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
                // 实时采集不能让编码器重排帧：开了 B 帧的话，我们重定时后给出的
                // DTS（等于 PTS）是错的，媒体管线偶尔会因此判样本时间非法并让
                // 整个 writer 变 failed（-11800/-16341）。禁掉重排就没有 B 帧。
                AVVideoAllowFrameReorderingKey: false,
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

            // 分片 MP4：moov 索引在文件头，崩溃/强杀时已录内容仍可播放。
            // 实测过 1 秒一片：第一次落片（正好在第 1 秒）就会在部分机型/磁盘忙时
            // 触发 -11800（底层 OSStatus -16341，Apple 论坛归因于分片太小导致
            // 写盘 I/O 压力大）。改成 5 秒一片，落片压力降到 1/5，最坏也只丢 5 秒。
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
        self.lastAudioEnd = [.invalid, .invalid]
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

    /// 写入器自己报错时给出原因，供每帧巡检和看门狗使用
    public var failureDescription: String? {
        guard writer.status == .failed else { return nil }
        return Self.describe(writer.error) ?? "写入器未说明原因"
    }

    /// input 忙就 1ms 一步等（最多 10ms），
    /// 等不到才放弃这一帧。立刻丢帧会让编码器一卡就静默丢光后续所有内容。
    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        guard !input.isReadyForMoreMediaData else { return true }
        for _ in 0..<10 {
            lock.lock()
            let stop = finishing || paused
            lock.unlock()
            if stop { return false }
            Thread.sleep(forTimeInterval: 0.001)
            if input.isReadyForMoreMediaData { return true }
        }
        return input.isReadyForMoreMediaData
    }

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) -> AppendResult {
        guard let videoInput else { return .invalid }
        lock.lock()
        let aborted: AppendResult? = finishing ? .invalid : (paused ? .paused : nil)
        if paused { videoShiftDirty = true }
        lock.unlock()
        if let aborted { return aborted }

        guard waitUntilReady(videoInput) else { return .notReady }

        lock.lock(); defer { lock.unlock() }
        if finishing { return .invalid }
        if paused {
            videoShiftDirty = true
            return .paused
        }
        guard videoInput.isReadyForMoreMediaData else { return .notReady }
        guard let (retimed, pts) = prepare(sampleBuffer, shift: &videoShift, shiftDirty: &videoShiftDirty, previousPTS: lastVideoPTS) else { return .invalid }
        guard videoInput.append(retimed) else { return .invalid }
        lastVideoPTS = pts
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        lastVideoEnd = duration.isValid && duration.seconds > 0
            ? CMTimeAdd(pts, duration)
            : CMTimeAdd(pts, frameDuration)
        if firstRawPTS[0] == nil {
            firstRawPTS[0] = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
        lastRawPTS[0] = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return .written
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrack = .microphone) -> AppendResult {
        let index = track.rawValue
        guard let audioInput = audioInputs[index] else { return .invalid }
        lock.lock()
        let aborted: AppendResult? = finishing ? .invalid : (paused ? .paused : nil)
        if paused { audioShiftDirty[index] = true }
        lock.unlock()
        if let aborted { return aborted }

        guard waitUntilReady(audioInput) else { return .notReady }

        lock.lock(); defer { lock.unlock() }
        if finishing { return .invalid }
        if paused {
            audioShiftDirty[index] = true
            return .paused
        }
        guard audioInput.isReadyForMoreMediaData else { return .notReady }
        guard let (retimed, pts) = prepare(sampleBuffer, shift: &audioShift[index], shiftDirty: &audioShiftDirty[index], previousPTS: lastAudioPTS[index]) else { return .invalid }
        guard audioInput.append(retimed) else { return .invalid }
        lastAudioPTS[index] = pts
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        lastAudioEnd[index] = duration.isValid && duration.seconds > 0
            ? CMTimeAdd(pts, duration)
            : CMTimeAdd(pts, CMTime(value: 1024, timescale: 48000))
        let rawSlot = track == .microphone ? 1 : 2
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstRawPTS[rawSlot] == nil {
            firstRawPTS[rawSlot] = rawPTS
        }
        lastRawPTS[rawSlot] = rawPTS
        audioSamplesAppended += 1
        return .written
    }

    /// 时间戳回退（切显示器、系统时钟跳变、恢复边界）时把整条轨往后推一帧，
    /// 而不是像以前那样永久拒收后续所有样本。
    private func prepare(_ sampleBuffer: CMSampleBuffer, shift: inout CMTime, shiftDirty: inout Bool, previousPTS: CMTime) -> (CMSampleBuffer, CMTime)? {
        guard let retimed = makeRetimed(sampleBuffer, shift: &shift, shiftDirty: &shiftDirty, referencePTS: previousPTS) else { return nil }
        var pts = CMSampleBufferGetPresentationTimeStamp(retimed)
        guard previousPTS.isValid, CMTimeCompare(pts, previousPTS) <= 0 else { return (retimed, pts) }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let step = duration.isValid && duration.seconds > 0 ? duration : frameDuration
        let delta = CMTimeSubtract(CMTimeAdd(previousPTS, step), pts)
        guard delta.isValid, CMTimeCompare(delta, .zero) > 0,
              let fixed = makeRetimed(sampleBuffer, shift: &shift, shiftDirty: &shiftDirty, referencePTS: previousPTS, extraShift: delta) else { return nil }
        pts = CMSampleBufferGetPresentationTimeStamp(fixed)
        guard CMTimeCompare(pts, previousPTS) > 0 else { return nil }
        return (fixed, pts)
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

    /// -11800 这类笼统错误真正的线索在底层错误里，逐层展开给用户看
    static func describe(_ error: Error?) -> String? {
        guard let nsError = error as NSError? else { return nil }
        var parts = ["\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）"]
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            parts.append(reason)
        }
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let current = underlying, depth < 3 {
            parts.append("底层：\(current.localizedDescription)（\(current.domain) \(current.code)）")
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: "；")
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

    /// 音画对齐诊断：各轨原始 PTS 的首/末与相对视频首帧的偏移。
    /// 麦克风轨与视频轨来自不同时钟源（SCStream vs AVCaptureSession），
    /// 这份报告是判断「固定偏移」还是「渐进漂移」的唯一实锤。
    public func alignmentReport() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard sessionStarted, let origin = originPTS else { return nil }
        guard let videoFirst = firstRawPTS[0], videoFirst.isValid else { return nil }
        let videoLast = lastRawPTS[0]
        guard let videoLast, videoLast.isValid else { return nil }

        var lines: [String] = []
        lines.append("时间：\(ISO8601DateFormatter().string(from: Date()))")
        let reference = videoFirst.seconds
        func offsetText(_ raw: CMTime?) -> String {
            guard let raw, raw.isValid else { return "—" }
            return String(format: "%+.3f", raw.seconds - reference)
        }
        lines.append(String(format: "视频轨：首 %@  末 %@（时长 %.2fs）",
                            offsetText(videoFirst), offsetText(videoLast),
                            videoLast.seconds - videoFirst.seconds))
        let micNames = [(1, "麦克风轨"), (2, "系统声轨")]
        for (slot, name) in micNames {
            guard let first = firstRawPTS[slot], first.isValid,
                  let last = lastRawPTS[slot], last.isValid else { continue }
            let firstOffset = first.seconds - reference
            let lastOffset = last.seconds - reference
            // 首偏移 = 启动错位（时钟域固定差 + 启动顺序）；
            // 末偏移 − 首偏移 = 录制期间的相对漂移（时钟速率差 × 时长）
            lines.append(String(format: "%@：首 %@  末 %@（时长 %.2fs）",
                                name, offsetText(first), offsetText(last),
                                last.seconds - first.seconds))
            lines.append(String(format: "%@相对视频：启动错位 %+.3fs，漂移 %+.3fs",
                                name, firstOffset, lastOffset - firstOffset))
        }
        lines.append(String(format: "origin（首个样本原始 PTS，相对视频首帧）：%+.3fs", origin.seconds - reference))
        return lines.joined(separator: "\n")
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        finishing = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private func makeRetimed(_ sampleBuffer: CMSampleBuffer, shift: inout CMTime, shiftDirty: inout Bool, referencePTS: CMTime, extraShift: CMTime = .zero) -> CMSampleBuffer? {
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

        let originForFirst = pts.timescale == origin.timescale
            ? origin
            : CMTimeConvertScale(origin, timescale: pts.timescale, method: .roundHalfAwayFromZero)
        let firstRelative = CMTimeSubtract(pts, originForFirst)
        if shiftDirty {
            shiftDirty = false
            if pendingResumePTS.isValid {
                // 暂停恢复：统一续接点优先。各轨独立续接会让每次暂停
                // 累积几十毫秒的相对错位（两轨末端天然相差一个样本周期）
                shift = CMTimeSubtract(pendingResumePTS, firstRelative)
            } else if referencePTS.isValid {
                let duration = CMSampleBufferGetDuration(sampleBuffer)
                let nextFree = duration.isValid && duration.seconds > 0
                    ? CMTimeAdd(referencePTS, duration)
                    : CMTimeAdd(referencePTS, CMTime(value: 1, timescale: 60))
                shift = CMTimeSubtract(nextFree, firstRelative)
            } else {
                shift = .zero
            }
        }

        let totalShift = CMTimeAdd(shift, extraShift)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        var cachedScale: CMTimeScale = -1
        var localOrigin = CMTime.zero
        var localShift = CMTime.zero
        for index in 0..<count {
            var timing = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: index, timingInfoOut: &timing)

            // 偏移只在样本自己的 timescale 上做。跨 timescale 直接相减会被折算进两者中较大的那个
            // （PCM 的 1/48000 会被拉到 1e9），均匀网格变成 20833/20834 纳秒的抖动间隔，
            // 媒体管线在随机时刻判定样本时间非法，整个写入器以 -11800（底层 -16341）失败。
            let scale = timing.presentationTimeStamp.isValid
                ? timing.presentationTimeStamp.timescale
                : timing.decodeTimeStamp.timescale
            guard scale > 0 else {
                timings[index] = timing
                continue
            }
            if scale != cachedScale {
                cachedScale = scale
                localOrigin = CMTimeConvertScale(origin, timescale: scale, method: .roundHalfAwayFromZero)
                localShift = totalShift.timescale == scale
                    ? totalShift
                    : CMTimeConvertScale(totalShift, timescale: scale, method: .roundHalfAwayFromZero)
            }
            if timing.presentationTimeStamp.isValid {
                let relative = CMTimeAdd(CMTimeSubtract(timing.presentationTimeStamp, localOrigin), localShift)
                timing.presentationTimeStamp = CMTimeMaximum(relative, .zero)
            }
            if timing.decodeTimeStamp.isValid {
                // 解码时间戳也得跟着搬到相对轴上，否则留下 31269s 这种绝对值，比 PTS 大得多
                let relative = CMTimeAdd(CMTimeSubtract(timing.decodeTimeStamp, localOrigin), localShift)
                timing.decodeTimeStamp = CMTimeMaximum(relative, .zero)
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
