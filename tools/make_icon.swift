// Renders Resources/AppIcon.icns from pure Core Graphics drawing.
// Run: swift tools/make_icon.swift

import AppKit

func renderIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // ——— Background: rounded square with diagonal gradient ———
    let cornerRadius = size * 0.2236 // Apple squircle ratio
    let bg = NSRect(x: 0, y: 0, width: size, height: size)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: cornerRadius, yRadius: cornerRadius)
    bgPath.addClip()

    let gradColors = [
        NSColor(red: 0.40, green: 0.49, blue: 0.92, alpha: 1).cgColor, // indigo
        NSColor(red: 0.58, green: 0.27, blue: 0.78, alpha: 1).cgColor, // violet
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: gradColors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // Subtle top highlight
    ctx.saveGState()
    let hiPath = NSBezierPath(roundedRect: bg, xRadius: cornerRadius, yRadius: cornerRadius)
    hiPath.addClip()
    let hiGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        hiGrad,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: size * 0.55),
        options: []
    )
    ctx.restoreGState()

    // ——— Back card (stack hint) ———
    let backW = size * 0.48
    let backH = size * 0.60
    let backX = (size - backW) / 2 + size * 0.055
    let backY = (size - backH) / 2 - size * 0.055
    let backRect = NSRect(x: backX, y: backY, width: backW, height: backH)
    let backCorner = size * 0.045
    let backPath = NSBezierPath(roundedRect: backRect, xRadius: backCorner, yRadius: backCorner)
    NSColor.white.withAlphaComponent(0.35).setFill()
    backPath.fill()

    // ——— Front clipboard body ———
    let bodyW = size * 0.50
    let bodyH = size * 0.62
    let bodyX = (size - bodyW) / 2 - size * 0.02
    let bodyY = (size - bodyH) / 2 + size * 0.015
    let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)
    let bodyCorner = size * 0.045
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: bodyCorner, yRadius: bodyCorner)

    // Soft shadow under body
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.02),
        blur: size * 0.06,
        color: NSColor.black.withAlphaComponent(0.25).cgColor
    )
    NSColor.white.setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // ——— Top clip (dark bar at top of clipboard) ———
    let clipW = bodyW * 0.42
    let clipH = size * 0.075
    let clipX = bodyX + (bodyW - clipW) / 2
    let clipY = bodyY + bodyH - clipH * 0.55
    let clipRect = NSRect(x: clipX, y: clipY, width: clipW, height: clipH)
    let clipCorner = size * 0.022
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: clipCorner, yRadius: clipCorner)
    NSColor(red: 0.18, green: 0.18, blue: 0.24, alpha: 1).setFill()
    clipPath.fill()

    // ——— Content lines ———
    let lineX = bodyX + bodyW * 0.14
    let lineW = bodyW * 0.72
    let lineH = size * 0.028
    let lineSpacing = size * 0.075
    let firstLineY = bodyY + bodyH * 0.55
    let widthFactors: [CGFloat] = [1.0, 0.82, 0.55]
    let colors: [NSColor] = [
        NSColor(red: 0.58, green: 0.27, blue: 0.78, alpha: 0.85),
        NSColor(red: 0.70, green: 0.70, blue: 0.75, alpha: 1),
        NSColor(red: 0.70, green: 0.70, blue: 0.75, alpha: 1),
    ]
    for i in 0..<3 {
        let y = firstLineY - CGFloat(i) * lineSpacing
        let w = lineW * widthFactors[i]
        let r = NSRect(x: lineX, y: y, width: w, height: lineH)
        let p = NSBezierPath(roundedRect: r, xRadius: lineH / 2, yRadius: lineH / 2)
        colors[i].setFill()
        p.fill()
    }

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, pixelSize: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize),
        pixelsHigh: Int(pixelSize),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    try data.write(to: url)
}

func main() throws {
    let fm = FileManager.default
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    let iconset = cwd.appendingPathComponent("Resources/AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    let spec: [(pt: Int, scale: Int, name: String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png"),
    ]

    // Render once at 1024, downscale for each size
    let master = renderIcon(size: 1024)
    for (pt, scale, name) in spec {
        let px = CGFloat(pt * scale)
        try writePNG(master, pixelSize: px, to: iconset.appendingPathComponent(name))
    }
    print("Wrote iconset to \(iconset.path)")
}

try main()
