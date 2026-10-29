import AppKit
import AVFoundation
import FreeRecordCore
import SwiftUI

@MainActor
final class SettingsPanelController {
    var onSystemAudioHelp: (() -> Void)?
    var onCreateMultiOutput: (() -> Void)?

    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let root = SettingsView(
                settings: settings,
                onSystemAudioHelp: { [weak self] in self?.onSystemAudioHelp?() },
                onCreateMultiOutput: { [weak self] in self?.onCreateMultiOutput?() }
            )
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.title = "设置"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.centerOnActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onSystemAudioHelp: () -> Void
    let onCreateMultiOutput: () -> Void
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("保存位置")
                    .frame(width: 72, alignment: .leading)
                    .foregroundColor(.secondary)
                Text(settings.saveDirectory.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("选择…") { chooseDirectory() }
            }

            Divider()

            Text("录制")
                .font(.headline)
            Toggle("在录制画面中显示鼠标指针", isOn: $settings.showsCursor)
            Toggle("停止录制后询问文件名和保存位置", isOn: $settings.askNameOnSave)
            Toggle("开始前 3 秒倒计时", isOn: $settings.countdownEnabled)
            Toggle("鼠标点击高亮（黄色圆圈）", isOn: $settings.clickHighlightEnabled)

            Divider()

            Text("摄像头画中画")
                .font(.headline)
            Toggle("录屏时显示摄像头画面", isOn: $settings.cameraEnabled)
            HStack {
                Text("摄像头")
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.cameraDeviceID) {
                    Text("系统默认").tag("")
                    ForEach(cameras, id: \.uniqueID) { camera in
                        Text(camera.localizedName).tag(camera.uniqueID)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Toggle("左右镜像", isOn: $settings.cameraMirrored)
            }
            HStack {
                Text("画中画大小")
                    .foregroundColor(.secondary)
                Slider(value: $settings.cameraSize, in: AppSettings.cameraSizeRange)
                    .frame(width: 180)
                Text("\(Int((settings.cameraSize * 100).rounded()))%")
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .trailing)
                Spacer()
            }
            Text("拖动预览小窗改位置，拖它的四条边、四个角或滚轮改大小；录制过程中也能随时调整，成片与预览一致。")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("通用")
                .font(.headline)
            Toggle("启用全局快捷键（⌥⌘R 开始/停止 · ⌥⌘P 暂停）", isOn: $settings.hotkeysEnabled)
            Toggle("开机自动启动", isOn: $settings.launchAtLogin)

            Divider()

            Text("系统声音")
                .font(.headline)
            if settings.supportsSystemAudio {
                Text("系统声音可直接录制，无需额外设置。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("当前 macOS 版本需要 BlackHole 虚拟声卡才能录制系统声音。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("安装 BlackHole 虚拟声卡…", action: onSystemAudioHelp)
                    Button("创建多输出设备（边录边听）…", action: onCreateMultiOutput)
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 500)
        .onAppear {
            cameras = CameraPiPCapture.availableDevices()
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.saveDirectory = url
            }
        }
    }
}
