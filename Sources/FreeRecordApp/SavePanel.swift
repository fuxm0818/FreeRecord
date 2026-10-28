import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// 停止录制后的保存弹窗：文件名 / 格式 / 目录。
@MainActor
final class SavePanelController {
    private var isPresenting = false

    func present(recording: SavedRecording, defaultDirectory: URL, completion: @escaping (SavedRecording?) -> Void) {
        guard !isPresenting else { return }
        isPresenting = true

        // 先把文件挪到临时目录，避免默认目录里同名文件触发「替换」询问
        let staged = stage(recording)

        let panel = NSSavePanel()
        panel.title = "保存录制"
        panel.prompt = "保存"
        panel.message = "选择文件名、格式和保存位置"
        panel.canCreateDirectories = true
        panel.directoryURL = defaultDirectory
        panel.nameFieldStringValue = staged.url.lastPathComponent
        if staged.width == 0 {
            panel.allowedContentTypes = [.mpeg4Audio]
        } else {
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        }
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.level = .modalPanel

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isPresenting = false
            guard response == .OK, let destination = panel.url else {
                completion(self.restore(staged, to: defaultDirectory))
                return
            }
            self.move(recording: staged, to: destination, completion: completion)
        }
    }

    private func stage(_ recording: SavedRecording) -> SavedRecording {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FreeRec-Staging", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(recording.url.lastPathComponent)
        guard recording.url.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL else {
            return recording
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: recording.url, to: destination)
            return rebuild(recording, url: destination)
        } catch {
            return recording
        }
    }

    private func restore(_ recording: SavedRecording, to directory: URL) -> SavedRecording {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(recording.url.lastPathComponent)
        guard recording.url.standardizedFileURL != destination.standardizedFileURL else {
            return recording
        }
        guard !fm.fileExists(atPath: destination.path) else { return recording }
        do {
            try fm.moveItem(at: recording.url, to: destination)
            return rebuild(recording, url: destination)
        } catch {
            return recording
        }
    }

    private func move(recording: SavedRecording, to destination: URL, completion: @escaping (SavedRecording?) -> Void) {
        let source = recording.url
        if source.standardizedFileURL == destination.standardizedFileURL {
            completion(recording)
            return
        }

        let sourceExt = source.pathExtension.lowercased()
        let targetExt = destination.pathExtension.lowercased()

        if sourceExt == targetExt {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
                completion(rebuild(recording, url: destination))
            } catch {
                reportFailure(error)
                completion(recording)
            }
            return
        }

        export(source: source, to: destination) { [weak self] error in
            if let error {
                self?.reportFailure(error)
                completion(recording)
                return
            }
            try? FileManager.default.removeItem(at: source)
            completion(self?.rebuild(recording, url: destination) ?? recording)
        }
    }

    /// 换容器（mp4 ↔ mov）只转封装，不重新编码，画质无损且快。
    private func export(source: URL, to destination: URL, completion: @escaping (Error?) -> Void) {
        let asset = AVURLAsset(url: source)
        let type: AVFileType = destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(NSError(domain: "自由录屏", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建导出任务"]))
            return
        }
        session.outputURL = destination
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = false
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status == .completed {
                    completion(nil)
                } else {
                    completion(session.error ?? NSError(domain: "自由录屏", code: -2, userInfo: [NSLocalizedDescriptionKey: "导出失败"]))
                }
            }
        }
    }

    private func rebuild(_ recording: SavedRecording, url: URL) -> SavedRecording {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        return SavedRecording(
            url: url,
            duration: recording.duration,
            width: recording.width,
            height: recording.height,
            fileSizeMB: size / 1_048_576,
            audioTrackCount: recording.audioTrackCount
        )
    }

    private func reportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "保存到所选位置失败"
        alert.informativeText = "\(error.localizedDescription)\n\n录制文件仍保留在原来的位置。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
