import AVFoundation
import Foundation

public enum AudioSource: String, CaseIterable, Codable, Identifiable, Hashable {
    case none
    case microphone
    case system
    case microphoneAndSystem

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "静音"
        case .microphone: return "麦克风"
        case .system: return "系统声音"
        case .microphoneAndSystem: return "麦克风+系统声音"
        }
    }

    public var wantsMicrophone: Bool {
        self == .microphone || self == .microphoneAndSystem
    }

    public var wantsSystemAudio: Bool {
        self == .system || self == .microphoneAndSystem
    }
}

public struct CaptureSettings {
    public var fps: Int
    /// 0 = 原始像素分辨率；>0 = 目标输出高度（像素）
    public var targetHeight: Int
    public var showsCursor: Bool
    public var audio: AudioSource
    /// 源（点）到输出（像素）的换算系数，Retina 屏为 2
    public var pixelScale: Double

    public init(
        fps: Int = 30,
        targetHeight: Int = 0,
        showsCursor: Bool = true,
        audio: AudioSource = .none,
        pixelScale: Double = 1
    ) {
        self.fps = fps
        self.targetHeight = targetHeight
        self.showsCursor = showsCursor
        self.audio = audio
        self.pixelScale = pixelScale
    }
}

public enum CaptureError: LocalizedError {
    case noDisplay
    case unsupportedOS(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "没有找到可录制的显示器"
        case .unsupportedOS(let message): return message
        }
    }
}
