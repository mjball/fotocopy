#!/usr/bin/env swift

import AppKit

func createIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    let padding = size * 0.0625
    let iconRect = NSRect(x: padding, y: padding, width: size - padding * 2, height: size - padding * 2)
    let cornerRadius = size * 0.1875
    let path = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.2, alpha: 1.0),
        NSColor(calibratedRed: 0.9, green: 0.45, blue: 0.1, alpha: 1.0)
    ])
    gradient?.draw(in: path, angle: -90)

    NSColor.black.withAlphaComponent(0.15).setStroke()
    path.lineWidth = max(1, size / 128)
    path.stroke()

    if let birdSymbol = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil) {
        let birdSize = size * 0.5
        let birdRect = NSRect(
            x: (size - birdSize) / 2,
            y: (size - birdSize) / 2 + size * 0.08,
            width: birdSize,
            height: birdSize
        )
        let whiteBird = tintedImage(birdSymbol, with: .white, size: NSSize(width: birdSize, height: birdSize))
        whiteBird.draw(in: birdRect)
    }

    if let lensSymbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil) {
        let lensSize = size * 0.22
        let lensRect = NSRect(
            x: size * 0.58,
            y: size * 0.12,
            width: lensSize,
            height: lensSize
        )
        let whiteLens = tintedImage(lensSymbol, with: NSColor.white.withAlphaComponent(0.85), size: NSSize(width: lensSize, height: lensSize))
        whiteLens.draw(in: lensRect)
    }

    image.unlockFocus()
    return image
}

func tintedImage(_ symbol: NSImage, with color: NSColor, size: NSSize) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size.width * 0.8, weight: .regular)
        .applying(.init(paletteColors: [color]))

    if let tinted = symbol.withSymbolConfiguration(config) {
        let result = NSImage(size: size)
        result.lockFocus()
        let symbolSize = tinted.size
        let x = (size.width - symbolSize.width) / 2
        let y = (size.height - symbolSize.height) / 2
        tinted.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
        result.unlockFocus()
        return result
    }
    return symbol
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(path)")
        return
    }

    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("Created: \(path)")
    } catch {
        print("Failed to write \(path): \(error)")
    }
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let baseDir = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
let iconsetPath = "\(baseDir)/Resources/AppIcon.iconset"

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

for (name, size) in sizes {
    let icon = createIcon(size: size)
    savePNG(icon, to: "\(iconsetPath)/\(name).png")
}

print("\nConverting to icns...")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", "\(baseDir)/Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created: \(baseDir)/Resources/AppIcon.icns")
    try? fileManager.removeItem(atPath: iconsetPath)
} else {
    print("iconutil failed with status \(process.terminationStatus)")
}
