// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

// Generates the original Vorkraft angular V mark and macOS icon assets.
import AppKit

// Current macOS misreads PNG payloads in the legacy small chunks. It downsamples
// ic07 for 1x and uses the explicit ic11/ic12 representations on Retina displays.
let iconSizes: [(name: String, px: Int, icnsType: String?)] = [
    ("icon_16x16", 16, nil), ("icon_16x16@2x", 32, "ic11"),
    ("icon_32x32", 32, nil), ("icon_32x32@2x", 64, "ic12"),
    ("icon_128x128", 128, "ic07"), ("icon_128x128@2x", 256, "ic13"),
    ("icon_256x256", 256, "ic08"), ("icon_256x256@2x", 512, "ic14"),
    ("icon_512x512", 512, "ic09"), ("icon_512x512@2x", 1024, "ic10"),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let projectDir = scriptDir.deletingLastPathComponent()
// A geometric V with a short forge-spark accent; no upstream artwork is used.
func drawVorkraftMark(in rect: CGRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 100, yBy: rect.height / 100)
    transform.concat()
    color.setFill()
    let v = NSBezierPath()
    v.move(to: NSPoint(x: 4, y: 88))
    v.line(to: NSPoint(x: 27, y: 88))
    v.line(to: NSPoint(x: 50, y: 30))
    v.line(to: NSPoint(x: 74, y: 88))
    v.line(to: NSPoint(x: 97, y: 88))
    v.line(to: NSPoint(x: 61, y: 6))
    v.line(to: NSPoint(x: 39, y: 6))
    v.close()
    v.fill()
    let spark = NSBezierPath(rect: NSRect(x: 44, y: 78, width: 12, height: 17))
    spark.fill()
    NSGraphicsContext.restoreGraphicsState()
}

let logo = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
    drawVorkraftMark(in: rect, color: .black)
    return true
}
guard let logoTIFF = logo.tiffRepresentation,
      let logoRep = NSBitmapImageRep(data: logoTIFF) else { exit(1) }
let appIconMaster = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let shape = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                             xRadius: 200, yRadius: 200)
    NSGradient(colors: [NSColor(calibratedRed: 0.06, green: 0.14, blue: 0.25, alpha: 1),
                        NSColor(calibratedRed: 0.02, green: 0.40, blue: 0.46, alpha: 1)])!
        .draw(in: shape, angle: 45)
    drawVorkraftMark(in: NSRect(x: 240, y: 220, width: 544, height: 584),
                    color: NSColor(calibratedRed: 0.55, green: 1, blue: 0.83, alpha: 1))
    return true
}

/// Bounding box of visible (non-transparent) pixels, so the mark can be
/// centered optically regardless of padding in the source file.
func contentBounds(of rep: NSBitmapImageRep) -> CGRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX > minX, maxY > minY else {
        return CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let bounds = contentBounds(of: logoRep)
// NSImage draws bottom-up while colorAt() is top-down — flip Y for drawing.
let sourceRect = CGRect(x: bounds.minX,
                        y: CGFloat(logoRep.pixelsHigh) - bounds.maxY,
                        width: bounds.width,
                        height: bounds.height)

func bitmapCanvas(_ px: Int, _ py: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)
}

/// Draws the trimmed mark fitted into `target`, preserving aspect ratio.
func drawMark(into target: CGRect) {
    let scale = min(target.width / sourceRect.width, target.height / sourceRect.height)
    let size = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
    let rect = CGRect(x: target.midX - size.width / 2,
                      y: target.midY - size.height / 2,
                      width: size.width, height: size.height)
    logo.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1,
              respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
}

// MARK: - App icon

func renderAppIcon(px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = bitmapCanvas(px, px), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: size, height: size)

    // Every renderer in MakeIcon.swift focuses the graphics context before
    // drawing; without this the draws land nowhere and the PNGs come out empty.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // The exported Default rendition is the finished icon design: background,
    // layering and system-grid margins are baked in, so it maps onto the canvas
    // 1:1 instead of being re-framed like the old mark-on-squircle composite.
    // Source rect = the ENTIRE master, in the MASTER's coordinate space
    // (appIconMaster.size), never the target's — a size-sized source rect would
    // crop the bottom-left corner of the 1024x1024 master instead of scaling.
    // (This SDK's draw(in:from:...) types from: as non-optional NSRect, so
    // full-source must be spelled out rather than passed as nil.)
    appIconMaster.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                       from: NSRect(origin: .zero, size: appIconMaster.size),
                       operation: .sourceOver, fraction: 1,
                       respectFlipped: false,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Menu bar glyph (template)

// The compact V needs similar ink height to adjacent menu-bar symbols.
// Center its trimmed bounds without the old wide upstream mark's downward
// optical adjustment; that offset made the V sit below neighboring icons.
let menuBarGlyphHeight: CGFloat = 14
let menuBarGlyphDrop: CGFloat = 0

let menuBarCanvas = (width: 26, height: 20)

func renderMenuBarIcon(scale: Int) -> Data? {
    let width = menuBarCanvas.width * scale, height = menuBarCanvas.height * scale
    guard let rep = bitmapCanvas(width, height), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: menuBarCanvas.width, height: menuBarCanvas.height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // Height-limited target spanning the full canvas width: drawMark keeps the
    // aspect ratio and centers, landing the mark at 24.6×12.5 pt. Coordinates
    // are bottom-up, so dropping it lowers y.
    let ink = menuBarGlyphHeight * CGFloat(scale)
    let y = (CGFloat(height) - ink) / 2 - menuBarGlyphDrop * CGFloat(scale)
    drawMark(into: CGRect(x: 0, y: y, width: CGFloat(width), height: ink))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

func appendUInt32BE(_ value: Int, to data: inout Data) {
    let clamped = UInt32(value)
    data.append(UInt8((clamped >> 24) & 0xff))
    data.append(UInt8((clamped >> 16) & 0xff))
    data.append(UInt8((clamped >> 8) & 0xff))
    data.append(UInt8(clamped & 0xff))
}

func writeICNS(entries: [(type: String, data: Data)], to url: URL) throws {
    let totalLength = 8 + entries.reduce(0) { $0 + 8 + $1.data.count }
    var icns = Data()
    appendFourCC("icns", to: &icns)
    appendUInt32BE(totalLength, to: &icns)
    for entry in entries {
        appendFourCC(entry.type, to: &icns)
        appendUInt32BE(8 + entry.data.count, to: &icns)
        icns.append(entry.data)
    }
    try icns.write(to: url)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var icnsEntries: [(type: String, data: Data)] = []
for (name, px, icnsType) in iconSizes {
    guard let data = renderAppIcon(px: px) else {
        print("failed to render \(name)")
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    if let icnsType {
        icnsEntries.append((type: icnsType, data: data))
    }
}
try writeICNS(entries: icnsEntries, to: URL(fileURLWithPath: "\(outDir)/../AppIcon.icns"))

for scale in [1, 2] {
    guard let data = renderMenuBarIcon(scale: scale) else {
        print("failed to render menu bar icon @\(scale)x")
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@2x"
    try data.write(to: URL(fileURLWithPath: "\(outDir)/../MenuBarIcon\(suffix).png"))
}

// Trimmed mark for in-app use (panel header, onboarding, About).
let markWidth = 640
let markHeight = Int(CGFloat(markWidth) * sourceRect.height / sourceRect.width)
if let rep = bitmapCanvas(markWidth, markHeight), let ctx = NSGraphicsContext(bitmapImageRep: rep) {
    rep.size = NSSize(width: markWidth, height: markHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawMark(into: CGRect(x: 0, y: 0, width: CGFloat(markWidth), height: CGFloat(markHeight)))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: "\(outDir)/../BrandMark.png"))
    }
}
print("iconset written to \(outDir)")
