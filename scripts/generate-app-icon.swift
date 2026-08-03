#!/usr/bin/env swift

import AppKit

let rootURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetURL = rootURL.appendingPathComponent("AppBundle/AppIcon.iconset")

try FileManager.default.createDirectory(
    at: iconsetURL,
    withIntermediateDirectories: true
)

let outputs = [
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

func drawIcon(name: String, size: Int) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphicsContext.cgContext
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let background = NSBezierPath(
        roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960),
        xRadius: 224,
        yRadius: 224
    )
    NSColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1).setFill()
    background.fill()

    let outline = NSColor(red: 0.25, green: 0.12, blue: 0.08, alpha: 1)
    let bodyColor = NSColor(red: 0.88, green: 0.48, blue: 0.20, alpha: 1)
    let innerEar = NSColor(red: 0.96, green: 0.68, blue: 0.43, alpha: 1)
    let cheekColor = NSColor(red: 0.91, green: 0.36, blue: 0.29, alpha: 0.72)
    let tongueColor = NSColor(red: 0.96, green: 0.43, blue: 0.39, alpha: 1)

    let leftEar = NSBezierPath()
    leftEar.move(to: CGPoint(x: 245, y: 733))
    leftEar.curve(
        to: CGPoint(x: 420, y: 719),
        controlPoint1: CGPoint(x: 176, y: 824),
        controlPoint2: CGPoint(x: 246, y: 948)
    )
    leftEar.curve(
        to: CGPoint(x: 245, y: 733),
        controlPoint1: CGPoint(x: 363, y: 705),
        controlPoint2: CGPoint(x: 294, y: 710)
    )
    leftEar.close()

    let rightEar = NSBezierPath()
    rightEar.move(to: CGPoint(x: 610, y: 720))
    rightEar.curve(
        to: CGPoint(x: 822, y: 753),
        controlPoint1: CGPoint(x: 716, y: 778),
        controlPoint2: CGPoint(x: 780, y: 928)
    )
    rightEar.curve(
        to: CGPoint(x: 610, y: 720),
        controlPoint1: CGPoint(x: 788, y: 703),
        controlPoint2: CGPoint(x: 691, y: 681)
    )
    rightEar.close()

    innerEar.setFill()
    outline.setStroke()
    for ear in [leftEar, rightEar] {
        ear.lineWidth = 32
        ear.lineJoinStyle = .round
        ear.fill()
        ear.stroke()
    }

    let body = NSBezierPath()
    body.move(to: CGPoint(x: 219, y: 742))
    body.curve(to: CGPoint(x: 805, y: 747), controlPoint1: CGPoint(x: 376, y: 775), controlPoint2: CGPoint(x: 670, y: 753))
    body.curve(to: CGPoint(x: 828, y: 226), controlPoint1: CGPoint(x: 843, y: 584), controlPoint2: CGPoint(x: 839, y: 348))
    body.curve(to: CGPoint(x: 205, y: 213), controlPoint1: CGPoint(x: 657, y: 180), controlPoint2: CGPoint(x: 364, y: 196))
    body.curve(to: CGPoint(x: 219, y: 742), controlPoint1: CGPoint(x: 165, y: 390), controlPoint2: CGPoint(x: 175, y: 603))
    body.close()
    bodyColor.setFill()
    outline.setStroke()
    body.lineWidth = 34
    body.fill()
    body.stroke()

    if size >= 64 {
        NSColor(red: 0.98, green: 0.66, blue: 0.26, alpha: 0.34).setStroke()
        for (start, end) in [
            (CGPoint(x: 250, y: 670), CGPoint(x: 740, y: 638)),
            (CGPoint(x: 230, y: 610), CGPoint(x: 770, y: 582)),
            (CGPoint(x: 254, y: 292), CGPoint(x: 751, y: 321)),
        ] {
            let stroke = NSBezierPath()
            stroke.move(to: start)
            stroke.line(to: end)
            stroke.lineWidth = 18
            stroke.lineCapStyle = .round
            stroke.stroke()
        }
    }

    let leftEye = NSBezierPath(ovalIn: NSRect(x: 347, y: 549, width: 55, height: 63))
    let rightEye = NSBezierPath(ovalIn: NSRect(x: 607, y: 526, width: 62, height: 72))
    outline.setFill()
    leftEye.fill()
    rightEye.fill()

    cheekColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: 260, y: 448, width: 103, height: 56)).fill()
    NSBezierPath(ovalIn: NSRect(x: 659, y: 420, width: 135, height: 82)).fill()

    let mouth = NSBezierPath(ovalIn: NSRect(x: 335, y: 292, width: 352, height: 284))
    outline.setFill()
    mouth.fill()
    tongueColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: 388, y: 310, width: 246, height: 108)).fill()

    let tooth = NSBezierPath()
    tooth.move(to: CGPoint(x: 447, y: 558))
    tooth.line(to: CGPoint(x: 514, y: 558))
    tooth.line(to: CGPoint(x: 486, y: 491))
    tooth.close()
    NSColor.white.setFill()
    tooth.fill()

    representation.size = NSSize(width: size, height: size)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

for (name, size) in outputs {
    let outputURL = iconsetURL.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    try drawIcon(name: name, size: size)
}

func drawMenuBarMascot(name: String, size: Int) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(size) / 18
    let mascot = NSBezierPath()
    mascot.move(to: CGPoint(x: 2 * scale, y: 14 * scale))
    mascot.line(to: CGPoint(x: 5 * scale, y: 17 * scale))
    mascot.line(to: CGPoint(x: 7 * scale, y: 14 * scale))
    mascot.line(to: CGPoint(x: 13 * scale, y: 16 * scale))
    mascot.line(to: CGPoint(x: 16 * scale, y: 13 * scale))
    mascot.line(to: CGPoint(x: 16 * scale, y: 2 * scale))
    mascot.line(to: CGPoint(x: 2 * scale, y: 2 * scale))
    mascot.close()
    NSColor.black.setFill()
    mascot.fill()

    graphicsContext.cgContext.setBlendMode(.copy)
    NSColor.clear.setFill()
    NSBezierPath(ovalIn: NSRect(x: 6 * scale, y: 4 * scale, width: 7 * scale, height: 6 * scale)).fill()
    representation.size = NSSize(width: 18, height: 18)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: rootURL.appendingPathComponent("AppBundle/\(name)"))
}

try drawMenuBarMascot(name: "MenuBarMascot.png", size: 18)
try drawMenuBarMascot(name: "MenuBarMascot@2x.png", size: 36)
