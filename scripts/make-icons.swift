import AppKit
import CoreImage
let root = CommandLine.arguments[1]
func png(_ image: NSImage, size: Int, path: String) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
for (name, path) in [("codex", "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.icns"), ("claude", "/Applications/Claude.app/Contents/Resources/electron.icns")] {
    guard let source = NSImage(contentsOfFile: path), let tiff = source.tiffRepresentation, let input = CIImage(data: tiff) else { continue }
    let output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    let context = CIContext(options: [.useSoftwareRenderer: true])
    guard let cgImage = context.createCGImage(output, from: output.extent) else { continue }
    let image = NSImage(cgImage: cgImage, size: source.size)
    png(image, size: 64, path: root + "/Resources/" + name + ".png")
}
let icon = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let box = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(white: 0.28, alpha: 1), ending: NSColor(white: 0.10, alpha: 1))!.draw(in: box, angle: -90)
    NSColor(white: 0.6, alpha: 0.35).setStroke(); box.lineWidth = 3; box.stroke()
    let line = NSBezierPath()
    let points: [NSPoint] = [.init(x: 205, y: 500), .init(x: 340, y: 500), .init(x: 410, y: 660), .init(x: 510, y: 325), .init(x: 610, y: 600), .init(x: 677, y: 500), .init(x: 819, y: 500)]
    line.move(to: points[0]); for point in points.dropFirst() { line.line(to: point) }
    line.lineWidth = 39; line.lineCapStyle = .round; line.lineJoinStyle = .round
    NSColor(white: 0.94, alpha: 1).setStroke(); line.stroke()
    return true
}
let folder = root + "/build.noindex/Pulse.iconset"
try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    png(icon, size: size, path: folder + "/icon_\(size)x\(size).png")
    png(icon, size: size * 2, path: folder + "/icon_\(size)x\(size)@2x.png")
}
