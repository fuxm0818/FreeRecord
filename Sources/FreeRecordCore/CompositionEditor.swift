import AVFoundation
import CoreMedia
import Foundation

/// 基于 `AVMutableComposition` 的时间轴重排 —— 用来对录制成品做**无损**裁剪。
///
/// 与「重新编码」的本质区别：composition 只描述「输出的第 N 秒 = 源文件的第 M 秒」，
/// 导出时配合 `AVAssetExportPresetPassthrough` 直接搬运已压缩的样本，
/// 不经解码→编码，因此画质零损失、耗时几乎只有 I/O。
/// 这是 AVFoundation 对「剪辑已有媒体」的标准用法。
public enum CompositionEditor {

    // MARK: - 输入

    /// 要保留的一段（单位：秒，相对源时间轴 0 点）
    public struct Segment: Equatable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = Swift.min(start, end)
            self.end = Swift.max(start, end)
        }

        public var duration: Double { end - start }
    }

    /// 一次裁剪任务
    public struct Plan {
        public let sourceURL: URL
        public let keepSegments: [Segment]
        public let outputURL: URL

        public init(sourceURL: URL, keepSegments: [Segment], outputURL: URL) {
            self.sourceURL = sourceURL
            self.keepSegments = keepSegments
            self.outputURL = outputURL
        }

        /// 保留部分的总时长
        public var keptDuration: TimeInterval {
            keepSegments.reduce(0) { $0 + $1.duration }
        }
    }

    /// 裁剪结果
    public struct Result {
        public let url: URL
        public let duration: TimeInterval
        public let fileSizeMB: Double
    }

    // MARK: - 错误

    public enum EditorError: LocalizedError {
        case emptySegments
        case noTracks
        case insertFailed(String)
        case exportFailed(String)
        case exportCancelled

        public var errorDescription: String? {
            switch self {
            case .emptySegments:
                return "没有选择要保留的片段"
            case .noTracks:
                return "文件里没有可导出的音视频轨道"
            case .insertFailed(let message):
                return "裁剪时间轴失败：\(message)"
            case .exportFailed(let message):
                return "导出失败：\(message)"
            case .exportCancelled:
                return "导出已取消"
            }
        }
    }

    // MARK: - 构造计划

    /// 去掉中间一段（其余全部保留）
    public static func planRemoving(sourceURL: URL, outputURL: URL, range: ClosedRange<Double>) -> Plan {
        let asset = AVURLAsset(url: sourceURL)
        let total = asset.duration.seconds
        let start = Swift.max(0, Swift.min(range.lowerBound, total))
        let end = Swift.max(start, Swift.min(range.upperBound, total))
        var segments: [Segment] = []
        if start > 0.001 { segments.append(Segment(start: 0, end: start)) }
        if end < total - 0.001 { segments.append(Segment(start: end, end: total)) }
        return Plan(sourceURL: sourceURL, keepSegments: segments, outputURL: outputURL)
    }

    /// 只保留中间一段（掐头去尾）
    public static func planKeepingOnly(sourceURL: URL, outputURL: URL, range: ClosedRange<Double>) -> Plan {
        let asset = AVURLAsset(url: sourceURL)
        let total = asset.duration.seconds
        let start = Swift.max(0, Swift.min(range.lowerBound, total))
        let end = Swift.max(start, Swift.min(range.upperBound, total))
        return Plan(sourceURL: sourceURL,
                    keepSegments: [Segment(start: start, end: end)],
                    outputURL: outputURL)
    }

    // MARK: - 核心：构建 composition

    /// 把 `keepSegments` 依次拼进一条新的 composition。
    ///
    /// **三条轨必须同步处理** —— 视频、麦克风、系统声各自独立成轨，
    /// 任何一条漏删都会导致音画错位。这与 `RecordingWriter.makeRetimed`
    /// 里「每条轨各自维护 shift」是同一套约束。
    public static func makeComposition(plan: Plan) async throws -> AVComposition {
        let asset = AVURLAsset(url: plan.sourceURL)
        let composition = AVMutableComposition()

        // CMTime 换算统一用 600（AVFoundation 常用时基，可被 24/25/30/60/120 整除），
        // 避免跨 timescale 相减导致的样本间隔抖动（历史 -11800 坑）。
        let timescale: CMTimeScale = 600

        var tracksBuilt = 0

        // 视频轨
        if let source = try await asset.loadTracks(withMediaType: .video).first {
            let track = composition.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
            if let track {
                track.preferredTransform =
                    (try? await source.load(.preferredTransform)) ?? .identity
                var cursor = CMTime.zero
                for segment in plan.keepSegments where segment.duration > 0.001 {
                    let range = CMTimeRange(
                        start: CMTime(seconds: segment.start, preferredTimescale: timescale),
                        duration: CMTime(seconds: segment.duration, preferredTimescale: timescale)
                    )
                    do {
                        try track.insertTimeRange(range, of: source, at: cursor)
                        cursor = cursor + range.duration
                    } catch {
                        throw EditorError.insertFailed(error.localizedDescription)
                    }
                }
                tracksBuilt += 1
            }
        }

        // 音轨：逐条独立搬运，保持原始分轨关系
        for source in try await asset.loadTracks(withMediaType: .audio) {
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor = CMTime.zero
            for segment in plan.keepSegments where segment.duration > 0.001 {
                let range = CMTimeRange(
                    start: CMTime(seconds: segment.start, preferredTimescale: timescale),
                duration: CMTime(seconds: segment.duration, preferredTimescale: timescale))
                do {
                    try track.insertTimeRange(range, of: source, at: cursor)
                    cursor = cursor + range.duration
                } catch {
                    throw EditorError.insertFailed(error.localizedDescription)
                }
            }
            tracksBuilt += 1
        }

        guard tracksBuilt > 0 else { throw EditorError.noTracks }
        return composition
    }

    // MARK: - 导出

    /// 导出裁剪结果。用 passthrough 预设：**只转封装，不重新编码**。
    public static func export(plan: Plan, progress: ((Double) -> Void)? = nil) async throws -> Result {
        guard !plan.keepSegments.isEmpty, plan.keptDuration > 0.001 else {
            throw EditorError.emptySegments
        }
        let composition = try await makeComposition(plan: plan)

        let fm = FileManager.default
        try? fm.createDirectory(at: plan.outputURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: plan.outputURL)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough) else {
            throw EditorError.exportFailed("无法创建导出任务")
        }
        session.outputURL = plan.outputURL
        session.outputFileType = plan.outputURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = false

        let poller = Task.detached { [weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let session else { return }
                let value = Double(session.progress)
                await MainActor.run { progress?(value) }
            }
        }
        defer { poller.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            let values = try? plan.outputURL.resourceValues(forKeys: [.fileSizeKey])
            let bytes = Double(values?.fileSize ?? 0)
            return Result(url: plan.outputURL,
                          duration: plan.keptDuration,
                          fileSizeMB: bytes / 1_048_576)
        case .cancelled:
            throw EditorError.exportCancelled
        default:
            let message = CompositionEditor.describe(session.error)
                ?? "导出未完成（状态 \(session.status.rawValue)）"
            throw EditorError.exportFailed(message)
        }
    }

    /// 逐层展开底层错误（`-11800` 背后常是 `NSOSStatusErrorDomain -16341` 之类）
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

    // MARK: - 查询

    /// 读取文件的真实时长（秒）；读不到返回 nil
    public static func duration(of url: URL) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let duration = try? await AVURLAsset(url: url).load(.duration),
              duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
