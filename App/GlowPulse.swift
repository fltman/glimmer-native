import AppKit
import SwiftUI

/// The glow behind the app's icon, breathing slowly (Anders, 2026-11-16; the same in Flimmer
/// and Jämmer). Only the glow moves: its strength eases between about 60 % and 100 % and its
/// radius follows a little, one breath in about four seconds.
///
/// It is a Core Animation shadow, animated by the window server, so the app itself does no
/// work per frame. It stands still, at its ordinary strength, with Reduce Motion on, and it
/// does not run while its window is hidden, minimised or covered, or while the app is in the
/// background. Nothing about it is exposed to accessibility: no element, no changing value.
///
/// Use as a background of the icon, with the icon's own corner radius:
/// `.background(GlowPulse(color: …, strength: 0.35, radius: 24, cornerRadius: 40))`
struct GlowPulse: NSViewRepresentable {
    var color: NSColor
    /// The glow's opacity when it stands still (what the design had before it moved).
    var strength: Double
    var radius: Double
    var cornerRadius: Double

    func makeNSView(context: Context) -> GlowPulseView { GlowPulseView() }

    func updateNSView(_ view: GlowPulseView, context: Context) {
        view.configure(color: color, strength: strength, radius: radius, cornerRadius: cornerRadius)
    }
}

final class GlowPulseView: NSView {
    private let glow = CALayer()
    private var strength = 0.35, radius = 24.0, cornerRadius = 0.0
    private var observers: [NSObjectProtocol] = []
    static let animationKey = "breath"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        glow.shadowOffset = .zero
        glow.masksToBounds = false
        layer?.addSublayer(glow)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never in the way of a click or a drop

    func configure(color: NSColor, strength: Double, radius: Double, cornerRadius: Double) {
        self.strength = strength; self.radius = radius; self.cornerRadius = cornerRadius
        glow.shadowColor = color.cgColor
        glow.shadowOpacity = Float(strength)
        glow.shadowRadius = radius
        needsLayout = true
        refresh()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        glow.shadowPath = CGPath(roundedRect: bounds, cornerWidth: min(cornerRadius, bounds.width / 2), cornerHeight: min(cornerRadius, bounds.height / 2), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        guard let window else { glow.removeAnimation(forKey: Self.animationKey); return }
        let again: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main, using: again))
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: again))
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: again))
        refresh()
    }

    /// Whether the glow should be moving right now.
    var shouldBreathe: Bool {
        guard let window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    var isBreathing: Bool { glow.animation(forKey: Self.animationKey) != nil }

    private func refresh() {
        guard shouldBreathe else { glow.removeAnimation(forKey: Self.animationKey); return }
        guard !isBreathing else { return }
        // "100 %" is a little above the still glow and "60 %" of that a little below it, so the
        // average is what the design had.
        let peak = min(1, strength * 1.25)
        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = peak * 0.6; opacity.toValue = peak
        let size = CABasicAnimation(keyPath: "shadowRadius")
        size.fromValue = radius * 0.92; size.toValue = radius * 1.12
        let breath = CAAnimationGroup()
        breath.animations = [opacity, size]
        breath.duration = 2            // in, then out: four seconds a breath
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breath, forKey: Self.animationKey)
    }
}
