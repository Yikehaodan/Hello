import AppKit

@main struct SidebarHoverTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let surface = SidebarHoverSurface(frame: NSRect(x: 0, y: 0, width: 178, height: 42))
        let button = NSButton(frame: surface.frame)
        button.addSubview(surface)
        let window = NSWindow(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = button
        surface.updateTrackingAreas()
        let area = surface.trackingAreas.first!
        let originalFrame = surface.frame
        let enter = event(.mouseEntered, window: window)
        let exit = event(.mouseExited, window: window)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            surface.appearance = NSAppearance(named: appearance)
            let selection = NSColor(srgbRed: 0.8, green: 0.82, blue: 0.84, alpha: 1)
            let hover = NSColor(srgbRed: 0.9, green: 0.91, blue: 0.92, alpha: 1)
            surface.configure(selected: false, pressed: false, selectedColor: selection, hoverColor: hover)
            for _ in 0..<200 {
                surface.mouseEntered(with: enter)
                surface.mouseEntered(with: enter)
                assertFill(surface, equals: hover)
                precondition(surface.layer?.animationKeys()?.isEmpty ?? true, "Hover must not queue flashing transitions")
                precondition(surface.frame == originalFrame, "Hover must preserve the hit region")
                surface.updateTrackingAreas()
                precondition(surface.trackingAreas.count == 1 && surface.trackingAreas.first === area,
                             "Drawing must not replace the mouse tracking area")
                surface.mouseExited(with: exit)
                assertFill(surface, equals: .clear)
            }
            surface.configure(selected: true, pressed: false, selectedColor: selection, hoverColor: hover)
            for _ in 0..<200 {
                surface.mouseEntered(with: enter)
                assertFill(surface, equals: selection)
                surface.mouseExited(with: exit)
                assertFill(surface, equals: selection)
            }
            surface.configure(selected: false, pressed: true, selectedColor: selection, hoverColor: hover)
            assertFill(surface, equals: hover)
            surface.configure(selected: false, pressed: false, selectedColor: selection, hoverColor: hover)
            assertFill(surface, equals: .clear)
            precondition(surface.hitTest(NSPoint(x: 20, y: 20)) == nil, "Decoration must not consume clicks")
            precondition(button.hitTest(NSPoint(x: 20, y: 20)) === button, "Button must retain its click target")
        }
        window.close()
        print("PASS: sidebar hover remains stable through repeated entry/exit in light and dark appearances; selection, press and click routing preserved")
    }

    @MainActor private static func event(_ type: NSEvent.EventType, window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    @MainActor private static func assertFill(_ surface: SidebarHoverSurface, equals color: NSColor) {
        let actual = NSColor(cgColor: surface.layer!.backgroundColor!)!.usingColorSpace(.deviceRGB)!
        let expected = color.usingColorSpace(.deviceRGB)!
        for (a, b) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent, actual.alphaComponent],
                          [expected.redComponent, expected.greenComponent, expected.blueComponent, expected.alphaComponent]) {
            precondition(abs(a - b) < 0.001, "Unexpected hover fill")
        }
    }
}
