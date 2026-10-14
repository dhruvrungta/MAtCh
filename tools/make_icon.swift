// Draws Match's app icon: a matchstick whose flame is the Wi-Fi signal.
//
//     swift tools/make_icon.swift            (writes Match/Resources/AppIcon.icns and docs/icon.png)
//     swift tools/make_icon.swift preview    (also writes build/icon-preview.png)
//
// The icon is drawn from these shapes at every size, rather than scaled down from one
// big picture, so that small sizes stay crisp.

import AppKit
import Foundation

struct Palette {
    static let tile = NSColor(srgbRed: 0.106, green: 0.141, blue: 0.251, alpha: 1)      // #1B2440
    static let innerArc = NSColor(srgbRed: 1.000, green: 0.702, blue: 0.278, alpha: 1)  // #FFB347
    static let middleArc = NSColor(srgbRed: 1.000, green: 0.541, blue: 0.239, alpha: 1) // #FF8A3D
    static let outerArc = NSColor(srgbRed: 1.000, green: 0.369, blue: 0.227, alpha: 1)  // #FF5E3A
    static let stick = NSColor(srgbRed: 0.949, green: 0.867, blue: 0.714, alpha: 1)     // #F2DDB6
    static let head = NSColor(srgbRed: 0.910, green: 0.263, blue: 0.180, alpha: 1)      // #E8432E
    static let headShade = NSColor(srgbRed: 0.722, green: 0.176, blue: 0.122, alpha: 1) // #B82D1F
}

/// Draws the icon into a square of `size` points, using a 1024-unit design grid.
func drawIcon(size: CGFloat) {
    let scale = size / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // macOS app icons sit on a rounded square inset from the canvas edge.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    Palette.tile.setFill()
    tile.fill()

    // AppKit's y axis points up, so the match stands with its head at y = 424 and
    // the signal radiating upwards from it.
    let head = NSPoint(x: 512, y: 424)

    let arcs: [(radius: CGFloat, color: NSColor)] = [
        (150, Palette.innerArc), (250, Palette.middleArc), (350, Palette.outerArc),
    ]
    for arc in arcs {
        let path = NSBezierPath()
        path.appendArc(withCenter: head, radius: arc.radius, startAngle: 40, endAngle: 140)
        path.lineWidth = 58
        path.lineCapStyle = .round
        arc.color.setStroke()
        path.stroke()
    }

    let stick = NSBezierPath(roundedRect: NSRect(x: 482, y: 204, width: 60, height: 196), xRadius: 16, yRadius: 16)
    Palette.stick.setFill()
    stick.fill()

    // The head: a rounded blob with a darker underside.
    let headRect = NSRect(x: head.x - 62, y: head.y - 72, width: 124, height: 144)
    Palette.headShade.setFill()
    NSBezierPath(ovalIn: headRect).fill()
    Palette.head.setFill()
    NSBezierPath(ovalIn: headRect.insetBy(dx: 6, dy: 6).offsetBy(dx: 0, dy: 8)).fill()
}

func png(size: Int) -> Data {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: work.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: work.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Match/Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", work.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")

// A copy for the README.
let readmeIcon = root.appendingPathComponent("docs/icon.png")
try FileManager.default.createDirectory(at: readmeIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
try png(size: 256).write(to: readmeIcon)
print("Wrote \(readmeIcon.path)")

if CommandLine.arguments.contains("preview") {
    // The icon at the sizes people actually see, side by side.
    let sizes = [512, 128, 64, 32, 16]
    let width = sizes.reduce(0) { $0 + $1 + 40 } + 40
    let sheet = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 592, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 592).fill()
    var x = 40
    for size in sizes {
        NSGraphicsContext.saveGraphicsState()
        let move = NSAffineTransform()
        move.translateX(by: CGFloat(x), yBy: 40)
        move.concat()
        drawIcon(size: CGFloat(size))
        NSGraphicsContext.restoreGraphicsState()
        x += size + 40
    }
    NSGraphicsContext.restoreGraphicsState()
    let preview = root.appendingPathComponent("build/icon-preview.png")
    try sheet.representation(using: .png, properties: [:])!.write(to: preview)
    print("Wrote \(preview.path)")
}
