#!/usr/bin/env swift
// 生成 Resources/AppIcon.icns：绿底圆角方块 + 白色选区角标 + 红色录制点。
// 用法：swift scripts/make-icon.swift
import AppKit

let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.icns")
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("FreeRecord.iconset", isDirectory: true)

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
    ctx.interpolationQuality = .high

    // 圆角方块的几何：留出 macOS 图标网格要求的边距
    let inset = size * 0.084
    let squircle = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = squircle.width * 0.225
    let shape = NSBezierPath(roundedRect: squircle, xRadius: radius, yRadius: radius)

    // 底板投影
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.008),
        blur: size * 0.022,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    // 绿色渐变底
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.263, green: 0.855, blue: 0.451, alpha: 1),
        NSColor(srgbRed: 0.070, green: 0.545, blue: 0.266, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -90)

    // 顶部高光边，避免纯色底板发闷
    let highlight = NSBezierPath(
        roundedRect: squircle.insetBy(dx: size * 0.006, dy: size * 0.006),
        xRadius: radius,
        yRadius: radius
    )
    NSColor.white.withAlphaComponent(0.22).setStroke()
    highlight.lineWidth = max(1, size * 0.007)
    highlight.stroke()

    // 选区角标（小于 64px 时省略，避免糊成一团）
    if pixels >= 64 {
        let frame = squircle.insetBy(dx: squircle.width * 0.20, dy: squircle.width * 0.20)
        let length = frame.width * 0.30
        let lineWidth = size * 0.042
        let brackets = NSBezierPath()
        brackets.lineWidth = lineWidth
        brackets.lineCapStyle = .round
        brackets.lineJoinStyle = .round
        let corners: [(NSPoint, NSPoint, NSPoint)] = [
            (NSPoint(x: frame.minX, y: frame.maxY), NSPoint(x: frame.minX, y: frame.maxY - length), NSPoint(x: frame.minX + length, y: frame.maxY)),
            (NSPoint(x: frame.maxX, y: frame.maxY), NSPoint(x: frame.maxX, y: frame.maxY - length), NSPoint(x: frame.maxX - length, y: frame.maxY)),
            (NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.minX, y: frame.minY + length), NSPoint(x: frame.minX + length, y: frame.minY)),
            (NSPoint(x: frame.maxX, y: frame.minY), NSPoint(x: frame.maxX, y: frame.minY + length), NSPoint(x: frame.maxX - length, y: frame.minY)),
        ]
        for (start, mid, end) in corners {
            brackets.move(to: start)
            brackets.line(to: mid)
            brackets.move(to: start)
            brackets.line(to: end)
        }
        NSColor.white.withAlphaComponent(0.96).setStroke()
        brackets.stroke()
    }

    // 中心录制点
    let dotRadius = size * (pixels >= 64 ? 0.088 : 0.15)
    let dotRect = NSRect(
        x: size / 2 - dotRadius,
        y: size / 2 - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    let dot = NSBezierPath(ovalIn: dotRect)
    let dotGradient = NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.400, blue: 0.337, alpha: 1),
        NSColor(srgbRed: 0.851, green: 0.157, blue: 0.157, alpha: 1),
    ])!
    dotGradient.draw(in: dot, angle: -90)
    // 白色描边让红点在绿底上有分界
    NSColor.white.withAlphaComponent(0.9).setStroke()
    dot.lineWidth = max(1, size * 0.010)
    dot.stroke()

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
