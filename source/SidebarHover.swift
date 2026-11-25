import AppKit
import QuartzCore
import SwiftUI

/// A decorative tracking surface keeps hover changes out of the SwiftUI button tree.
struct SidebarHoverBackground: NSViewRepresentable {
    let selected: Bool
    let pressed: Bool
    let selectedColor: Color
    let hoverColor: Color
    var cornerRadius: CGFloat = 12
    var hoverDuration: CFTimeInterval = 0

    func makeNSView(context: Context) -> SidebarHoverSurface { SidebarHoverSurface() }

    func updateNSView(_ view: SidebarHoverSurface, context: Context) {
        view.configure(selected: selected, pressed: pressed,
                       selectedColor: NSColor(selectedColor), hoverColor: NSColor(hoverColor),
                       cornerRadius: cornerRadius, hoverDuration: hoverDuration)
    }
}

final class SidebarHoverSurface: NSView {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var selected = false
    private var pressed = false
    private var selectedColor = NSColor.clear
    private var hoverColor = NSColor.clear
    private var hoverDuration: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The tracking surface never intercepts the button's click or keyboard handling.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    func configure(selected: Bool, pressed: Bool, selectedColor: NSColor, hoverColor: NSColor,
                   cornerRadius: CGFloat = 12, hoverDuration: CFTimeInterval = 0) {
        guard self.selected != selected || self.pressed != pressed
                || self.selectedColor != selectedColor || self.hoverColor != hoverColor
                || layer?.cornerRadius != cornerRadius || self.hoverDuration != hoverDuration else { return }
        self.selected = selected
        self.pressed = pressed
        self.selectedColor = selectedColor
        self.hoverColor = hoverColor
        self.hoverDuration = hoverDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        CATransaction.commit()
        updateFill()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        updateFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        if !selected { updateFill(animated: true) }
    }

    private func updateFill(animated: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let layer else { return }
            // Resume from the visible color when the pointer reverses during a fade.
            let previousColor = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            let color = (selected ? selectedColor : hovered || pressed ? hoverColor : .clear).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color
            CATransaction.commit()
            layer.removeAnimation(forKey: "hoverFill")
            if animated, hoverDuration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               let previousColor, previousColor != color {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = previousColor
                fade.toValue = color
                fade.duration = hoverDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(fade, forKey: "hoverFill")
            }
        }
    }
}
