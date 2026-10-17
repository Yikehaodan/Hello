import AppKit
let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.055, green: 0.17, blue: 0.15, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 214, yRadius: 214).fill()
NSColor(srgbRed: 0.72, green: 0.96, blue: 0.81, alpha: 1).setStroke()
let door = NSBezierPath()
door.move(to: NSPoint(x: 300, y: 210)); door.line(to: NSPoint(x: 300, y: 710))
door.curve(to: NSPoint(x: 650, y: 710), controlPoint1: NSPoint(x: 300, y: 940), controlPoint2: NSPoint(x: 650, y: 940))
door.line(to: NSPoint(x: 650, y: 210)); door.lineWidth = 34; door.lineCapStyle = .round; door.stroke()
NSColor(srgbRed: 0.72, green: 0.96, blue: 0.81, alpha: 1).setFill()
let openDoor = NSBezierPath(); openDoor.move(to: NSPoint(x: 340, y: 220));openDoor.line(to: NSPoint(x: 550, y: 300));openDoor.line(to: NSPoint(x: 550, y: 730));openDoor.line(to: NSPoint(x: 340, y: 790));openDoor.close();openDoor.fill()
NSColor(srgbRed: 0.055, green: 0.17, blue: 0.15, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 495, y: 492, width: 25, height: 25)).fill()
NSColor(srgbRed: 0.72, green: 0.96, blue: 0.81, alpha: 1).setStroke()
for (x,h) in [(730.0,70.0),(795.0,150.0),(860.0,90.0)] {
 let line = NSBezierPath();line.move(to: NSPoint(x:x,y:505-h/2));line.line(to:NSPoint(x:x,y:505+h/2));line.lineWidth=22;line.lineCapStyle = .round;line.stroke()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:output))
