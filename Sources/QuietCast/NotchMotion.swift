import AppKit
import SwiftUI
import QuartzCore

/// Owns the actual window frame, so interruption starts at the visible size
/// and carries velocity instead of restarting an AppKit resize animation.
@MainActor
final class NotchFrameAnimator: NSObject {
    private weak var window: NSWindow?
    private var timer: Timer?
    private var target = NSRect.zero
    private var velocity = NSSize.zero
    private var lastTime = CACurrentMediaTime()
    private var frequency: CGFloat = 48
    private var completion: (() -> Void)?

    init(window: NSWindow) { self.window = window }

    func move(to frame: NSRect, animated: Bool, closing: Bool, completion: @escaping () -> Void) {
        guard let window else { return }
        target = frame
        self.completion = completion
        frequency = closing ? 58 : 48
        guard animated, window.frame != frame else {
            cancel()
            window.setFrame(frame, display: true)
            completion()
            return
        }
        if timer == nil {
            velocity = .zero
            lastTime = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 0.001
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func cancel() {
        timer?.invalidate(); timer = nil
        velocity = .zero; completion = nil
    }
    @objc private func tick() {
        guard let window else { cancel(); return }
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - lastTime)))
        lastTime = now
        let size = window.frame.size
        let width = step(size.width, velocity.width, target.width, dt)
        let height = step(size.height, velocity.height, target.height, dt)
        velocity = NSSize(width: width.velocity, height: height.velocity)
        if abs(width.value - target.width) < 0.2, abs(height.value - target.height) < 0.2,
           abs(width.velocity) < 8, abs(height.velocity) < 8 {
            let done = completion
            cancel()
            window.setFrame(target, display: true)
            done?()
        } else {
            let next = NSRect(x: target.midX - width.value / 2, y: target.maxY - height.value,
                              width: max(1, width.value), height: max(1, height.value))
            window.setFrame(next, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
    // Exact critically damped spring step; stable across varying frame rates.
    private func step(_ value: CGFloat, _ velocity: CGFloat, _ goal: CGFloat, _ dt: CGFloat) -> (value: CGFloat, velocity: CGFloat) {
        let distance = value - goal
        let coefficient = velocity + frequency * distance
        let decay = exp(-frequency * dt)
        return (goal + (distance + coefficient * dt) * decay,
                (velocity - frequency * coefficient * dt) * decay)
    }
}

/// One native, fully opaque sRGB-black silhouette behind the entire SwiftUI
/// tree. There are no separately composited cap/body fills or vibrant materials.
@MainActor
final class NotchSurfaceView: NSView {
    private let content: NSView
    private let silhouette: (CGRect) -> CGPath

    init(content: NSView, silhouette: @escaping (CGRect) -> CGPath) {
        self.content = content; self.silhouette = silhouette
        super.init(frame: .zero)
        wantsLayer = true
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    override func makeBackingLayer() -> CALayer {
        let layer = CAShapeLayer()
        layer.fillColor = Palette.nativeBlack.cgColor
        layer.strokeColor = nil
        layer.backgroundColor = NSColor.clear.cgColor
        return layer
    }
    override func layout() {
        super.layout()
        content.frame = bounds
        guard let surface = layer as? CAShapeLayer else { return }
        // SwiftUI's path has a top-left origin; this native view is unflipped.
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.path = silhouette(CGRect(origin: .zero, size: bounds.size)).copy(using: &flip)
        surface.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}

/// Native events prompt a coordinate check, not a Boolean tied to the resizing
/// view. Mouse monitors cover the stable grace region outside the native window.
@MainActor
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var pointerChanged: (() -> Void)?
    private var area: NSTrackingArea?
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows resize automatically; replacing the area on
        // every animation frame would synthesize spurious leave/enter events.
        guard area == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); self.area = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let area, event.trackingArea === area { pointerChanged?() }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let area, event.trackingArea === area { pointerChanged?() }
    }
}

struct NotchActivity: NSViewRepresentable {
    let playing: Bool
    let buffering: Bool
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> ActivityBars { ActivityBars() }
    func updateNSView(_ view: ActivityBars, context: Context) {
        view.update(animated: active && playing && !buffering && !reduceMotion, playing: playing)
    }
    static func dismantleNSView(_ view: ActivityBars, coordinator: ()) { view.stop() }
}

/// Three tiny compositor-animated bars, not a SwiftUI render loop while playing.
final class ActivityBars: NSView {
    private var bars: [CALayer] = []
    private var animated = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for _ in 0..<3 {
            let bar = CALayer()
            bar.cornerRadius = 1
            layer?.addSublayer(bar); bars.append(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 2, height: 12)
            bar.position = CGPoint(x: bounds.midX + CGFloat(index - 1) * 5, y: bounds.midY)
        }
        CATransaction.commit()
    }
    func update(animated: Bool, playing: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = NSColor(white: playing ? 0.85 : 0.4, alpha: 1).cgColor
            bar.transform = CATransform3DMakeScale(1, playing ? [CGFloat(0.55), 1, 0.7][index] : 0.45, 1)
        }
        CATransaction.commit()
        guard self.animated != animated else { return }
        self.animated = animated
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if animated {
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = [0.3, 0.6, 0.4][index]
                animation.toValue = [0.8, 1.0, 0.9][index]
                animation.duration = [0.45, 0.6, 0.5][index]
                animation.autoreverses = true; animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(animation, forKey: "playing")
            }
        }
    }
    func stop() { bars.forEach { $0.removeAllAnimations() }; animated = false }
}
