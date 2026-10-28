import AppKit
import FreeRecordCore
import SwiftUI

struct ContentView: View {
    @StateObject private var model = POCModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("自由录屏 · 性能测试").font(.title2).bold()
                Text("先确认这台机器能不能稳住目标画质。结果写到 ~/Movies/FreeRecPerformance/")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !model.hasScreenPermission {
                permissionBanner
            }

            settings

            Divider()

            HStack(spacing: 10) {
                if model.phase == .running {
                    Button("结束并保存") { model.finishNow() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("开始测试") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.phase == .running)
                }

                if model.phase == .finished {
                    Button("再测一次") { model.reset() }
                    Button("在 Finder 中显示") { model.revealReport() }
                }

                Spacer()
            }

            Text(model.liveStats)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.summary.isEmpty {
                ScrollView {
                    Text(model.summary)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
            }
        }
        .padding(20)
        .frame(width: 580, alignment: .leading)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要「屏幕录制」权限").font(.callout).bold()
                    Text("授权后请完全退出并重新打开本 App。").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("打开系统设置") { model.openScreenSettings() }
                Button("重新检查") { model.refreshPermission() }
            }
            if !model.permissionStatus.isEmpty {
                Text(model.permissionStatus)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("重置屏幕录制权限（重新打包后用这个）") { model.resetScreenPermission() }
                .font(.caption)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("时长") {
                Picker("", selection: $model.duration) {
                    Text("30 秒").tag(30)
                    Text("60 秒").tag(60)
                    Text("180 秒").tag(180)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            row("分辨率") {
                Picker("", selection: $model.height) {
                    Text("原始").tag(0)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            row("帧率") {
                Picker("", selection: $model.fps) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            row("声音") {
                Picker("", selection: $model.audio) {
                    Text("静音").tag(AudioSource.none)
                    Text("麦克风").tag(AudioSource.microphone)
                    if model.supportsSystemAudio {
                        Text("系统声音").tag(AudioSource.system)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }

            row("压力画面") {
                Toggle("全屏动态画面（测吞吐上限）", isOn: $model.stressMode)
                    .toggleStyle(.checkbox)
            }

            if model.stressMode {
                Text("整屏会铺一层移动条纹。桌面静止时录屏帧率本来就低，打开它才测得出真实上限。控制窗口会浮在上面。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.supportsSystemAudio {
                Text("这台 Mac 是 macOS 12：系统声音需要虚拟声卡（正式版会内置），本次测试请先测麦克风或静音。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.phase == .running)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 52, alignment: .leading)
                .foregroundColor(.secondary)
            content()
            Spacer(minLength: 0)
        }
    }
}
