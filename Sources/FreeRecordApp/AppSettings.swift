import AppKit
import CoreServices
import FreeRecordCore
import ServiceManagement

enum RecordMode: String, CaseIterable {
    case fullScreen
    case window
    case region

    var title: String {
        switch self {
        case .fullScreen: return "全屏"
        case .window: return "窗口…"
        case .region: return "区域…"
        }
    }
}

/// 声音配置的使用场景：录屏与仅音频各存一份，互不串扰。
enum AudioScene: String {
    case screen
    case audioOnly
}

struct QualityPreset: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let targetHeight: Int
    let fps: Int
    let audio: AudioSource
}

enum Presets {
    static let list: [QualityPreset] = [
        QualityPreset(id: "hd-demo", name: "高清演示 · 1080p 30fps · 麦克风", targetHeight: 1080, fps: 30, audio: .microphone),
        QualityPreset(id: "hd-course", name: "高清教学 · 1080p 30fps · 系统声音", targetHeight: 1080, fps: 30, audio: .system),
        QualityPreset(id: "smooth", name: "流畅录制 · 原始分辨率 60fps · 系统声音", targetHeight: 0, fps: 60, audio: .system),
        QualityPreset(id: "light", name: "轻量记录 · 720p 30fps · 静音", targetHeight: 720, fps: 30, audio: .none),
    ]

    static func match(targetHeight: Int, fps: Int) -> QualityPreset? {
        list.first { $0.targetHeight == targetHeight && $0.fps == fps }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var mode: RecordMode {
        didSet { defaults.set(mode.rawValue, forKey: "mode") }
    }
    /// 录屏时的声音来源（全屏/窗口/区域共用）
    @Published var audioForScreen: AudioSource {
        didSet { defaults.set(audioForScreen.rawValue, forKey: "audio.screen") }
    }
    /// 仅音频录制时的声音来源；与录屏互不影响——此前是全局单份，
    /// 「仅音频」的选择会覆写下次录屏的声音配置
    @Published var audioForAudioOnly: AudioSource {
        didSet { defaults.set(audioForAudioOnly.rawValue, forKey: "audio.audioOnly") }
    }
    @Published var targetHeight: Int {
        didSet { defaults.set(targetHeight, forKey: "targetHeight") }
    }
    @Published var fps: Int {
        didSet { defaults.set(fps, forKey: "fps") }
    }
    @Published var showsCursor: Bool {
        didSet { defaults.set(showsCursor, forKey: "showsCursor") }
    }
    @Published var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: "saveDirectory") }
    }
    @Published var askNameOnSave: Bool {
        didSet { defaults.set(askNameOnSave, forKey: "askNameOnSave") }
    }
    @Published var countdownEnabled: Bool {
        didSet { defaults.set(countdownEnabled, forKey: "countdownEnabled") }
    }
    @Published var clickHighlightEnabled: Bool {
        didSet { defaults.set(clickHighlightEnabled, forKey: "clickHighlightEnabled") }
    }
    @Published var hotkeysEnabled: Bool {
        didSet { defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            Self.applyLoginItem(enabled: launchAtLogin)
        }
    }

    var supportsSystemAudio: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        )
    }

    /// 按场景读取声音配置
    func audio(for scene: AudioScene) -> AudioSource {
        switch scene {
        case .screen: return audioForScreen
        case .audioOnly: return audioForAudioOnly
        }
    }

    /// 按场景写入声音配置
    func setAudio(_ value: AudioSource, for scene: AudioScene) {
        switch scene {
        case .screen: audioForScreen = value
        case .audioOnly: audioForAudioOnly = value
        }
    }

    /// 录屏实际生效的声音配置（老系统不支持系统声采集时降级）
    var effectiveAudio: AudioSource {
        let audio = audioForScreen
        guard audio.wantsSystemAudio, !supportsSystemAudio else { return audio }
        return audio.wantsMicrophone ? .microphone : .none
    }

    init() {
        let d = defaults
        mode = RecordMode(rawValue: d.string(forKey: "mode") ?? "") ?? .fullScreen
        // 迁移：旧版只有一份全局 "audio"，作为两种场景的初值
        let legacyAudio = AudioSource(rawValue: d.string(forKey: "audio") ?? "") ?? .microphone
        audioForScreen = AudioSource(rawValue: d.string(forKey: "audio.screen") ?? "") ?? legacyAudio
        audioForAudioOnly = AudioSource(rawValue: d.string(forKey: "audio.audioOnly") ?? "") ?? legacyAudio
        targetHeight = d.object(forKey: "targetHeight") as? Int ?? 1080
        fps = d.object(forKey: "fps") as? Int ?? 30
        showsCursor = d.object(forKey: "showsCursor") as? Bool ?? true
        countdownEnabled = d.object(forKey: "countdownEnabled") as? Bool ?? true
        clickHighlightEnabled = d.object(forKey: "clickHighlightEnabled") as? Bool ?? false
        hotkeysEnabled = d.object(forKey: "hotkeysEnabled") as? Bool ?? true
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
        if let path = d.string(forKey: "saveDirectory") {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/自由录屏", isDirectory: true)
        }
        askNameOnSave = d.object(forKey: "askNameOnSave") as? Bool ?? false
        if !supportsSystemAudio, audioForScreen.wantsSystemAudio {
            audioForScreen = audioForScreen.wantsMicrophone ? .microphone : .none
        }
        if !supportsSystemAudio, audioForAudioOnly.wantsSystemAudio {
            audioForAudioOnly = audioForAudioOnly.wantsMicrophone ? .microphone : .none
        }
    }

    private static func applyLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            guard let service = try? SMAppService.mainApp else { return }
            do {
                if enabled { try service.register() } else { try service.unregister() }
            } catch {}
        } else {
            guard let list = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue() else { return }
            let bundleURL = Bundle.main.bundleURL as CFURL
            let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
            for item in snapshot {
                if let resolved = LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() as URL?,
                   resolved.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
                    LSSharedFileListItemRemove(list, item)
                }
            }
            if enabled {
                LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast.takeRetainedValue(), nil, nil, bundleURL, nil, nil)
            }
        }
    }

    func applyPreset(_ preset: QualityPreset) {
        targetHeight = preset.targetHeight
        fps = preset.fps
        if preset.audio.wantsSystemAudio, !supportsSystemAudio {
            setAudio(preset.audio.wantsMicrophone ? .microphone : .none, for: .screen)
        } else {
            setAudio(preset.audio, for: .screen)
        }
    }
}
