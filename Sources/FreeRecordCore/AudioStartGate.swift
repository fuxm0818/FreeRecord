import Foundation

/// 音频启动门控：等所有已启用的音源产出首帧后再宣布「录制中」。
///
/// 各采集源 `start()` 返回只代表管线搭好了，首个样本回调是异步到达的
/// （SCK 系统声流尤其明显，可达数百毫秒）。不等待就开始计时，用户看到
/// 「录制中」立刻说话/播放的声音就会落在音频轨起点之前——开头丢声。
///
/// 超时兜底：系统完全静音时 SCK 可能不推样本、或设备硬件异常，
/// 超时后照常放行，降级为既有行为，不会卡死开录。
public enum AudioStartGate {
    /// 轮询分轨计数，直到所有启用音源首帧到达或超时。
    /// - Parameters:
    ///   - mic: 是否等待麦克风首帧
    ///   - system: 是否等待系统声首帧（SCK 流与 BlackHole 都计入 system 轨）
    ///   - timeout: 最长等待；0 表示不等待
    public static func wait(
        counters: CaptureCounters,
        mic: Bool,
        system: Bool,
        timeout: TimeInterval = 2.5
    ) async {
        guard mic || system else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = counters.snapshot()
            let micReady = !mic || s.audioMicrophone > 0
            let systemReady = !system || s.audioSystem > 0
            if micReady && systemReady { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
