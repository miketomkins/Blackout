import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("Blackout.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func png(_ size: Int, _ name: String) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let base = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 206, yRadius: 206)
    NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
        ending: NSColor(calibratedRed: 0.035, green: 0.04, blue: 0.065, alpha: 1))!.draw(in: base, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    base.lineWidth = 3
    base.stroke()
    let display = NSBezierPath(roundedRect: NSRect(x: 184, y: 323, width: 656, height: 433), xRadius: 37, yRadius: 37)
    NSColor(calibratedRed: 0.84, green: 0.9, blue: 1, alpha: 1).setStroke()
    display.lineWidth = 28
    display.stroke()
    let screen = NSBezierPath(roundedRect: NSRect(x: 215, y: 355, width: 594, height: 369), xRadius: 15, yRadius: 15)
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    NSGradient(
        starting: NSColor(calibratedRed: 0.44, green: 0.67, blue: 0.96, alpha: 1),
        ending: NSColor(calibratedRed: 0.2, green: 0.36, blue: 0.57, alpha: 1))!.draw(in: screen, angle: 135)
    let eclipse = NSBezierPath(ovalIn: NSRect(x: 385, y: 308, width: 565, height: 520))
    NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.09, alpha: 1).setFill()
    eclipse.fill()
    NSGraphicsContext.restoreGraphicsState()
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 512, y: 307))
    stand.line(to: NSPoint(x: 512, y: 234))
    stand.move(to: NSPoint(x: 398, y: 225))
    stand.line(to: NSPoint(x: 626, y: 225))
    stand.lineWidth = 29
    stand.lineCapStyle = .round
    NSColor(calibratedRed: 0.84, green: 0.9, blue: 1, alpha: 1).setStroke()
    stand.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
for n in [16, 32, 128, 256, 512] {
    try png(n, "icon_\(n)x\(n).png")
    try png(n * 2, "icon_\(n)x\(n)@2x.png")
}
print(iconset.path)
