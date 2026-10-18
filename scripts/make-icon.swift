import AppKit

// The same greeting bubble is used in docs/assets/hello-mark.svg and hero.svg.
let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)
let tile = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 214, yRadius: 214)
NSGradient(starting: color(0x244E43), ending: color(0x0D2B28))!.draw(in: tile, angle: 45)
NSColor.white.withAlphaComponent(0.1).setStroke()
tile.lineWidth = 2; tile.stroke()

let bubble = NSBezierPath()
bubble.move(to: NSPoint(x: 360, y: 250)); bubble.line(to: NSPoint(x: 600, y: 250))
bubble.curve(to: NSPoint(x: 780, y: 430), controlPoint1: NSPoint(x: 710, y: 250), controlPoint2: NSPoint(x: 780, y: 320))
bubble.line(to: NSPoint(x: 780, y: 490))
bubble.curve(to: NSPoint(x: 600, y: 670), controlPoint1: NSPoint(x: 780, y: 600), controlPoint2: NSPoint(x: 710, y: 670))
bubble.line(to: NSPoint(x: 420, y: 670)); bubble.line(to: NSPoint(x: 265, y: 780))
bubble.curve(to: NSPoint(x: 248, y: 766), controlPoint1: NSPoint(x: 245, y: 792), controlPoint2: NSPoint(x: 245, y: 782))
bubble.line(to: NSPoint(x: 270, y: 654))
bubble.curve(to: NSPoint(x: 160, y: 460), controlPoint1: NSPoint(x: 190, y: 620), controlPoint2: NSPoint(x: 160, y: 550))
bubble.line(to: NSPoint(x: 160, y: 430))
bubble.curve(to: NSPoint(x: 360, y: 250), controlPoint1: NSPoint(x: 160, y: 320), controlPoint2: NSPoint(x: 235, y: 250))
bubble.close()
NSGradient(starting: color(0xEDFFE9), ending: color(0xB8EFCC))!.draw(in: bubble, angle: 90)

color(0x244E43).setFill()
for x in [365.0, 535.0] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 400, width: 38, height: 62), xRadius: 19, yRadius: 19).fill()
}
color(0x244E43).setStroke()
let smile = NSBezierPath()
smile.move(to: NSPoint(x: 405, y: 524))
smile.curve(to: NSPoint(x: 545, y: 524), controlPoint1: NSPoint(x: 443, y: 578), controlPoint2: NSPoint(x: 507, y: 578))
smile.lineWidth = 28; smile.lineCapStyle = .round; smile.stroke()

color(0xB8EFCC).setStroke()
for (x1, y1, x2, y2) in [(706.0, 190.0, 718.0, 153.0), (773.0, 222.0, 806.0, 191.0), (815.0, 282.0, 857.0, 269.0)] {
    let ray = NSBezierPath(); ray.move(to: NSPoint(x: x1, y: y1)); ray.line(to: NSPoint(x: x2, y: y2))
    ray.lineWidth = 22; ray.lineCapStyle = .round; ray.stroke()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
