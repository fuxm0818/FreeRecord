#!/usr/bin/env swift
// 生成 Resources/AppIcon.icns：相机字形与菜单栏 camera.on.rectangle 一致。
// 画布必须满幅不透明：macOS 26 会给带透明边距的旧式图标再套一层底板，
// 满幅图标则由系统按自己的超椭圆裁形；旧系统显示为方形底板。
// 用法：swift scripts/make-icon.swift
import AppKit

let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.icns")
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FreeRecord.iconset", isDirectory: true)

func roundedRect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

// 字形几何都按方框宽度 W 的比例定义，任意像素尺寸下等比缩放
func cameraGlyph(box: NSRect, dx: CGFloat) -> (window: NSBezierPath, body: NSBezierPath, lens: NSRect, dot: NSRect) {
    let W = box.width
    let x0 = box.minX + dx
    let window = roundedRect(
        NSRect(x: x0 + 0.02 * W, y: box.minY + 0.30 * W, width: 0.66 * W, height: 0.56 * W),
        0.105 * W
    )
    let bodyRect = NSRect(x: x0 + 0.18 * W, y: box.minY + 0.06 * W, width: 0.72 * W, height: 0.50 * W)
    let body = roundedRect(bodyRect, 0.095 * W)
    let hump = roundedRect(
        NSRect(x: bodyRect.midX - 0.15 * W, y: bodyRect.maxY - 0.055 * W, width: 0.30 * W, height: 0.115 * W),
        0.045 * W
    )
    body.append(hump)
    let lens = NSRect(
        x: bodyRect.midX - 0.125 * W,
        y: bodyRect.minY + 0.075 * W,
        width: 0.25 * W,
        height: 0.25 * W
    )
    let dot = NSRect(
        x: bodyRect.maxX - 0.155 * W,
        y: bodyRect.maxY - 0.165 * W,
        width: 0.06 * W,
        height: 0.06 * W
    )
    return (window, body, lens, dot)
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("无法创建位图") }

    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("无法创建上下文") }
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.setShouldAntialias(true)

    // 满幅画布：Alpha 必须覆盖到四边，否则 macOS 26 会再套一层底板
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // 浅色渐变底
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.90, blue: 0.925, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -90)

    // 顶部柔光，避免纯白底板发平
    ctx.saveGState()
    ctx.clip(to: rect)
    let glow = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.55),
        NSColor.white.withAlphaComponent(0),
    ])!
    glow.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    ctx.restoreGState()

    // ---- 字形：窗口描边 + 实心相机，与菜单栏 camera.on.rectangle 同构 ----
    let baseScale: CGFloat = pixels >= 64 ? 0.58 : 0.72
    let W = size * baseScale
    let glyphH = W * 0.86
    var box = NSRect(x: (size - W) / 2, y: (size - glyphH) / 2 - 0.030 * W, width: W, height: glyphH)
    var dx: CGFloat = 0.04 * W
    if pixels < 64 {
        // 小尺寸窗口描边会糊成一团，只保留相机；按机身（含凸起）而非整块字形居中
        box.origin.y = size / 2 - 0.34 * W
        dx = -0.04 * W
    }
    let parts = cameraGlyph(box: box, dx: dx)
    let detail = pixels >= 64 ? size * 0.030 : size * 0.040
    let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    let bgTone = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)

    if pixels >= 64 {
        // 先画窗口，实心相机再盖住交叠处
        parts.window.lineWidth = detail
        ink.setStroke()
        parts.window.stroke()
    }

    // 相机投影
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.007),
        blur: size * 0.016,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    ink.setFill()
    parts.body.fill()
    ctx.restoreGState()

    // 机身渐变，让实心块有体积
    ctx.saveGState()
    parts.body.addClip()
    let bodyGradient = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.24, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
    ])!
    bodyGradient.draw(in: box, angle: -90)
    ctx.restoreGState()

    // 镜头：底色环 + 内孔
    let lensRingWidth = detail * (pixels >= 64 ? 0.95 : 1.05)
    bgTone.setStroke()
    let lensRing = NSBezierPath(ovalIn: parts.lens.insetBy(dx: lensRingWidth / 2, dy: lensRingWidth / 2))
    lensRing.lineWidth = lensRingWidth
    lensRing.stroke()
    bgTone.withAlphaComponent(0.45).setFill()
    NSBezierPath(ovalIn: parts.lens.insetBy(dx: lensRingWidth * 1.6, dy: lensRingWidth * 1.6)).fill()

    // 镜头高光
    if pixels >= 128 {
        ctx.saveGState()
        ctx.translateBy(x: parts.lens.midX, y: parts.lens.midY)
        ctx.rotate(by: .pi / 4)
        let spec = NSRect(
            x: -parts.lens.width * 0.30,
            y: parts.lens.height * 0.06,
            width: parts.lens.width * 0.60,
            height: parts.lens.height * 0.22
        )
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: spec).fill()
        ctx.restoreGState()
    }

    // 录制红点
    NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(ovalIn: parts.dot).fill()
    if pixels >= 128 {
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: parts.dot.minX + parts.dot.width * 0.18,
            y: parts.dot.minY + parts.dot.height * 0.50,
            width: parts.dot.width * 0.42,
            height: parts.dot.height * 0.28
        )).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let data = drawIcon(pixels: variant.pixels).representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败：\(variant.name)")
    }
    try data.write(to: iconsetURL.appendingPathComponent(variant.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil 失败") }
print("已生成 \(outputURL.path)")
