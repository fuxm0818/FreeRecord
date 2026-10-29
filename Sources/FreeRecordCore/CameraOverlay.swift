import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// 摄像头画中画的摆放：归一化坐标（0...1），原点在左下角，
/// 与 CIImage / AppKit 屏幕坐标系一致，预览窗位置可以直接换算。
public struct CameraOverlayPlacement: Equatable, Sendable {
    /// 画中画宽度比例的可用区间：预览窗拖角/滚轮与设置滑杆共用这一份上下限
    public static let minSizeFraction: CGFloat = 0.08
    public static let maxSizeFraction: CGFloat = 0.60

    public static func clampedSizeFraction(_ value: CGFloat) -> CGFloat {
        min(max(value, minSizeFraction), maxSizeFraction)
    }

    /// 中心横坐标，0 = 画面左缘，1 = 右缘
    public var centerX: CGFloat
    /// 中心纵坐标，0 = 画面下缘，1 = 上缘
    public var centerY: CGFloat
    /// 画中画宽度占录制画面宽度的比例
    public var widthFraction: CGFloat
    public var mirrored: Bool

    public init(centerX: CGFloat = 0.82, centerY: CGFloat = 0.20,
                widthFraction: CGFloat = 0.24, mirrored: Bool = true) {
        self.centerX = centerX
        self.centerY = centerY
        self.widthFraction = widthFraction
        self.mirrored = mirrored
    }
}

/// 采集线程与合成线程之间的交接点：只保留最新一帧（迟到帧直接丢，录屏不补帧）。
public final class CameraOverlaySource: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var placementValue = CameraOverlayPlacement()

    public init() {}

    public var placement: CameraOverlayPlacement {
        get {
            lock.lock(); defer { lock.unlock() }
            return placementValue
        }
        set {
            lock.lock()
            placementValue = newValue
            lock.unlock()
        }
    }

    func submit(_ buffer: CVPixelBuffer) {
        lock.lock()
        self.buffer = buffer
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }

    func snapshot() -> (buffer: CVPixelBuffer, placement: CameraOverlayPlacement)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, placementValue)
    }
}

/// 摄像头采集：只出一路视频帧给画中画合成，不写文件、不碰音频。
public final class CameraPiPCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum CameraError: LocalizedError {
        case permissionDenied
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有摄像头权限"
            case .noCamera: return "没有找到可用的摄像头"
            case .cannotAddInput: return "摄像头无法接入采集会话"
            case .cannotAddOutput: return "摄像头数据输出不可用"
            }
        }
    }

    public let source = CameraOverlaySource()
    public let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "freerec.camera.frames", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "freerec.camera.session", qos: .userInitiated)
    private var configured = false
    public private(set) var deviceID: String?

    public static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// 首次调用会弹系统授权框
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public func start(deviceID: String?) async throws {
        guard Self.hasPermission else { throw CameraError.permissionDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configure(deviceID: deviceID)
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.source.clear()
                continuation.resume()
            }
        }
    }

    private func configure(deviceID: String?) throws {
        let devices = Self.availableDevices()
        let device: AVCaptureDevice? = {
            if let deviceID, !deviceID.isEmpty {
                return devices.first { $0.uniqueID == deviceID }
                    ?? AVCaptureDevice.default(for: .video)
                    ?? devices.first
            }
            return AVCaptureDevice.default(for: .video) ?? devices.first
        }()
        guard let device else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        for input in session.inputs {
            session.removeInput(input)
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        self.deviceID = device.uniqueID

        if !configured {
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: frameQueue)
            configured = true
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        source.submit(buffer)
    }
}

/// 逐帧把摄像头画面合进屏幕帧：圆角、白边、镜像都在这里完成，
/// 输出的 CMSampleBuffer 保持原始 PTS/时长，写入器的音画对齐逻辑不受影响。
public final class CameraOverlayCompositor {
    private let source: CameraOverlaySource
    private let context: CIContext
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var format: CMVideoFormatDescription?

    /// 画中画按 16:9 裁切，避免不同摄像头比例导致画面尺寸跳变
    private static let aspect: CGFloat = 16.0 / 9.0

    public init(source: CameraOverlaySource) {
        self.source = source
        self.context = CIContext(options: [.cacheIntermediates: false])
    }

    public func composite(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let screenBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let snapshot = source.snapshot(),
              snapshot.placement.widthFraction > 0 else { return sampleBuffer }
        let width = CVPixelBufferGetWidth(screenBuffer)
        let height = CVPixelBufferGetHeight(screenBuffer)
        guard width > 1, height > 1,
              let destination = makeDestination(width: width, height: height),
              let formatDescription = makeFormat(destination) else { return sampleBuffer }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let composed = composited(
            camera: snapshot.buffer,
            placement: snapshot.placement,
            over: screenImage,
            bounds: bounds
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return sampleBuffer }
        context.render(composed, to: destination, bounds: bounds, colorSpace: colorSpace)

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )
        if !timing.duration.isValid || timing.duration.seconds <= 0 {
            timing.duration = CMTime(value: 1, timescale: 60)
        }
        var output: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: destination,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        return output ?? sampleBuffer
    }

    private func composited(
        camera camBuffer: CVPixelBuffer,
        placement: CameraOverlayPlacement,
        over screen: CIImage,
        bounds: CGRect
    ) -> CIImage {
        let width = bounds.width
        let height = bounds.height

        var pipWidth = max(64, min(width, placement.widthFraction * width))
        var pipHeight = pipWidth / Self.aspect
        if pipHeight > height {
            pipHeight = height * 0.9
            pipWidth = pipHeight * Self.aspect
        }
        let halfW = pipWidth / 2
        let halfH = pipHeight / 2
        let centerX = min(max(placement.centerX * width, halfW), width - halfW)
        let centerY = min(max(placement.centerY * height, halfH), height - halfH)
        let pipRect = CGRect(
            x: centerX - halfW,
            y: centerY - halfH,
            width: pipWidth,
            height: pipHeight
        )

        var camera = CIImage(cvPixelBuffer: camBuffer)
        if placement.mirrored {
            let extent = camera.extent
            camera = camera.transformed(by: CGAffineTransform(
                a: -1, b: 0, c: 0, d: 1,
                tx: extent.minX + extent.maxX, ty: 0
            ))
        }
        let cameraExtent = camera.extent
        guard cameraExtent.width > 1, cameraExtent.height > 1 else { return screen }
        let scale = max(pipWidth / cameraExtent.width, pipHeight / cameraExtent.height)
        camera = camera.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = camera.extent
        camera = camera.transformed(by: CGAffineTransform(
            translationX: pipRect.midX - scaledExtent.midX,
            y: pipRect.midY - scaledExtent.midY
        ))

        let radius = min(pipWidth, pipHeight) * 0.12
        let rimWidth = max(1.5, pipWidth * 0.006)
        let outerMask = roundedMask(radius: radius, rect: pipRect)
        let rim = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92))
            .cropped(to: pipRect)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: pipRect),
                kCIInputMaskImageKey: outerMask,
            ])
        let innerRect = pipRect.insetBy(dx: rimWidth, dy: rimWidth)
        let innerMask = roundedMask(radius: max(1, radius - rimWidth), rect: innerRect)
        let innerCamera = camera
            .cropped(to: innerRect)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: innerRect),
                kCIInputMaskImageKey: innerMask,
            ])
        return innerCamera.composited(over: rim).composited(over: screen)
    }

    private func roundedMask(radius: CGFloat, rect: CGRect) -> CIImage {
        // CIRoundedRectangleGenerator 是内建滤镜但没有对应 Swift 类型，按名字构造
        let filter = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        return filter?.outputImage?.cropped(to: rect)
            ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: rect)
    }

    private func makeDestination(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolWidth = width
            poolHeight = height
            format = nil
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func makeFormat(_ buffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        lock.lock(); defer { lock.unlock() }
        if let format { return format }
        var newFormat: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &newFormat
        )
        format = newFormat
        return newFormat
    }
}
