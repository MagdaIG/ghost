#!/usr/bin/env swift
// Genera AppIcon.icns para Ghost.app sin assets binarios en el repo:
// dibuja un "squircle" oscuro con el SF Symbol eye.slash.fill y lo empaqueta con iconutil.
// Uso: swift scripts/make-icon.swift <ruta/salida/AppIcon.icns>

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("uso: swift make-icon.swift <salida.icns>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("Ghost-\(UUID().uuidString).iconset", isDirectory: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    // Rejilla de iconos de macOS: el cuerpo ocupa ~80 % del lienzo.
    let tile = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let shape = NSBezierPath(roundedRect: tile, xRadius: side * 0.18, yRadius: side * 0.18)

    NSGradient(
        starting: NSColor(calibratedWhite: 0.22, alpha: 1),
        ending: NSColor(calibratedWhite: 0.03, alpha: 1)
    )?.draw(in: shape, angle: -90)

    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    shape.lineWidth = max(1, side * 0.004)
    shape.stroke()

    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.34, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(calibratedWhite: 0.96, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let target = NSRect(
            x: (side - size.width) / 2,
            y: (side - size.height) / 2,
            width: size.width,
            height: size.height
        )
        tinted.draw(in: target)
    }

    return bitmap.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

do {
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    for variant in variants {
        guard let png = renderIcon(pixels: variant.pixels) else {
            throw NSError(domain: "GhostIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No se pudo renderizar \(variant.name)"])
        }
        try png.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    try? fileManager.removeItem(at: iconsetURL)
    exit(iconutil.terminationStatus)
} catch {
    try? fileManager.removeItem(at: iconsetURL)
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
