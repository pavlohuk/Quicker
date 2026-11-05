import AppKit
import QuartzCore

/// Glass HUD with the display's name, its brightness in percent and a bar that can be clicked or
/// dragged to set an exact brightness. Stays up while the cursor is over it.
final class BrightnessHUD {
    /// The user clicked, dragged or scrolled on the bar.
    var onSet: ((CGDirectDisplayID, Double, _ animated: Bool) -> Void)?
    /// Screen frame of Quicker's menu bar icon, when it is shown; the HUD is placed under it.
    var menuBarIcon: (() -> NSRect?)?

    private var panel: NSPanel?
    private let content: NSView
    private let hover = HoverView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let bar: BrightnessBar
    private var displayID: CGDirectDisplayID?
    private var hideWork: DispatchWorkItem?

    private let visibleFor: TimeInterval = 1.5

    init() {
        bar = BrightnessBar()

        // Sizes measured on the system's volume HUD (macOS 26): 292 × 64 pt, corner radius 24, 16 pt side margins,
        // the bar's line 40 pt from the top.
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .center
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        badge.layer?.cornerRadius = 8
        badge.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(percentLabel)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            percentLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            // The label draws 3 pt of its own on each side: 6 pt from the edge to the digits.
            percentLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 3),
            percentLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -3),
        ])

        let header = NSStackView(views: [titleLabel, badge])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        let row = NSStackView(views: [Self.sun("sun.min", size: 11), bar, Self.sun("sun.max", size: 14)])
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        bar.widthAnchor.constraint(equalToConstant: 215).isActive = true

        let stack = NSStackView(views: [header, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Inside the glass view the stack does not keep its insets on its own (see SpaceIndicator).
        for view in [header, row] {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
        }
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
        // The title row keeps its natural width, so the badge is never stretched.
        header.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
        badge.setContentHuggingPriority(.required, for: .horizontal)

        hover.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hover.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: hover.trailingAnchor),
            stack.topAnchor.constraint(equalTo: hover.topAnchor),
            stack.bottomAnchor.constraint(equalTo: hover.bottomAnchor),
        ])
        content = SpaceIndicator.background(around: hover, cornerRadius: 24)

        bar.onSet = { [weak self] value, animated in
            guard let self, let id = self.displayID else { return }
            self.onSet?(id, value, animated)
        }
        bar.onDragEnded = { [weak self] in self?.scheduleHide() }
        hover.onEnter = { [weak self] in self?.bar.showsKnob = true }
        hover.onExit = { [weak self] in
            self?.bar.showsKnob = false
            self?.scheduleHide()
        }
    }

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private static func sun(_ name: String, size: CGFloat) -> NSImageView {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .labelColor
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    /// Up or coming up; false once it starts to go away.
    private(set) var isVisible = false
    /// Holds the glass, scaled from its top edge as the HUD comes and goes, like the system's.
    private let container: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    func show(_ display: BrightnessController.Display, value: Double, corner: IndicatorCorner) {
        displayID = display.id
        titleLabel.stringValue = display.name
        update(value)

        hideWork?.cancel()
        if let panel, isVisible {
            // Already up: keep it, so a drag in progress is not cut off.
            panel.setFrame(frame(on: display.screen, corner: corner), display: true)
        } else {
            // A fresh panel joins every Space (see SpaceIndicator.show).
            if let old = panel {
                old.orderOut(nil)
                old.contentView = nil
            }
            let panel = Self.makePanel()
            self.panel = panel
            panel.contentView = container
            panel.setFrame(frame(on: display.screen, corner: corner), display: true)
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            if content.superview !== container { container.addSubview(content) }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isVisible = true
            appear(panel)
        }
        scheduleHide()
    }

    /// New brightness of `id`, when the HUD shows that display.
    func update(_ id: CGDirectDisplayID, _ value: Double) {
        guard id == displayID, isVisible else { return }
        update(value)
    }

    private func update(_ value: Double) {
        percentLabel.stringValue = "\(Int((value * 100).rounded()))%"
        bar.value = value
    }

    private func frame(on screen: NSScreen, corner: IndicatorCorner) -> NSRect {
        hover.layoutSubtreeIfNeeded()
        let size = hover.fittingSize
        guard let icon = menuBarIcon?() else {
            return SpaceIndicator.frame(for: size, corner: corner, on: screen)
        }
        // Centred under Quicker's menu bar icon, like the volume HUD under its control. The icon
        // is drawn in one menu bar only; on another display, put it the same distance from the
        // right edge, where the menu bar icons line up.
        let iconScreen = NSScreen.screens.first { NSPointInRect(NSPoint(x: icon.midX, y: icon.midY), $0.frame) }
        let midX = iconScreen == screen || iconScreen == nil
            ? icon.midX
            : screen.frame.maxX - (iconScreen!.frame.maxX - icon.midX)
        // Top edge level with the volume HUD's (measured side by side); at least 6 pt from the sides.
        let side: CGFloat = 6
        let x = min(screen.frame.maxX - size.width - side, max(screen.frame.minX + side, midX - size.width / 2))
        let y = screen.visibleFrame.maxY - size.height - 9
        return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: work)
    }

    private func hide() {
        guard let panel, isVisible else { return }
        if hover.isInside || bar.isDragging { return }  // shown again on exit / drag end
        isVisible = false
        animate(scale: 0.902, omega: 15, opacity: 0, fade: 0.5, delay: 0.016,
                curve: CAMediaTimingFunction(controlPoints: 0.1, 0.6, 0.3, 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
            guard let self, self.panel === panel, !self.isVisible else { return }
            panel.orderOut(nil)
        }
    }

    /// Grows from a little smaller, anchored at the top edge, and fades in.
    private func appear(_ panel: NSPanel) {
        container.layer?.opacity = 0
        container.layer?.transform = scale(0.92)
        panel.alphaValue = 1
        animate(scale: 1, omega: 14.5, opacity: 1, fade: 0.44,
                curve: CAMediaTimingFunction(controlPoints: 0, 0, 0.4, 0.9))
    }

    // Fitted to the system's volume HUD, recorded at 120 fps: it scales about its top edge on a
    // critically damped spring (from 92% on the way in, to 90% on the way out) and fades along
    // the given curves. It is never blurred.
    private func animate(scale factor: CGFloat, omega: Double, opacity: Float, fade: TimeInterval,
                         delay: TimeInterval = 0, curve: CAMediaTimingFunction) {
        guard let layer = container.layer else { return }
        let from = layer.presentation()
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = from?.transform ?? layer.transform
        spring.toValue = scale(factor)
        spring.mass = 1
        spring.stiffness = omega * omega
        spring.damping = 2 * omega  // critical: no overshoot
        spring.duration = spring.settlingDuration
        if delay > 0 {
            spring.beginTime = CACurrentMediaTime() + delay
            spring.fillMode = .backwards
        }
        layer.transform = scale(factor)
        layer.add(spring, forKey: "scale")

        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = from?.opacity ?? layer.opacity
        fadeAnimation.toValue = opacity
        fadeAnimation.duration = fade
        fadeAnimation.timingFunction = curve
        if delay > 0 {
            fadeAnimation.beginTime = CACurrentMediaTime() + delay
            fadeAnimation.fillMode = .backwards
        }
        layer.opacity = opacity
        layer.add(fadeAnimation, forKey: "fade")
    }

    /// Scale about the top centre of the HUD.
    private func scale(_ factor: CGFloat) -> CATransform3D {
        let bounds = container.bounds
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.maxY, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.maxY, 0)
    }

    private static func makePanel() -> NSPanel {
        let panel = IndicatorPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}

/// Knows whether the cursor is over the HUD.
private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private(set) var isInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        onExit?()
    }
}

/// The brightness bar with a dot under it for every step of the brightness keys, and a knob that
/// shows while the cursor is over the HUD, like the system's volume HUD: a white capsule that turns
/// into a larger glass one while it is dragged.
private final class BrightnessBar: NSView {
    var onSet: ((Double, _ animated: Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    private(set) var isDragging = false
    var value: Double = 0 {
        didSet {
            needsDisplay = true
            placeKnob()
        }
    }
    /// The cursor is over the HUD.
    var showsKnob = false { didSet { updateKnob(animated: true) } }

    private let thickness: CGFloat = 4
    private let dot: CGFloat = 2
    /// Steps of the brightness keys; a dot marks each.
    private let marks = 16
    private let knob = BrightnessKnob()
    private let knobSize = NSSize(width: 18, height: 14)
    /// The volume HUD's knob grows by about 1.35 when it is taken (measured side by side).
    private let liftedSize = NSSize(width: 24, height: 19)
    /// Where in the knob the drag grabbed it, so grabbing it does not make it jump.
    private var grabOffset: CGFloat = 0

    init() {
        super.init(frame: .zero)
        knob.alphaValue = 0
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 21) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var barY: CGFloat { ((bounds.height - thickness) / 2).rounded(.down) }

    override func layout() {
        super.layout()
        placeKnob()
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: barY, width: bounds.width, height: thickness)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        if value > 0 {
            var fill = track
            fill.size.width = max(thickness, bounds.width * value)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: fill, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }

        NSColor.white.withAlphaComponent(0.35).setFill()
        let dotY = barY - 5 - dot
        // A little in from both ends of the bar.
        let inset: CGFloat = 4
        for i in 0...marks {
            let x = inset + (bounds.width - 2 * inset - dot) * CGFloat(i) / CGFloat(marks)
            NSBezierPath(ovalIn: NSRect(x: x, y: dotY, width: dot, height: dot)).fill()
        }
    }

    // MARK: Knob

    private func knobFrame(size: NSSize) -> NSRect {
        let x = min(bounds.width - knobSize.width / 2, max(knobSize.width / 2, bounds.width * value))
        let y = barY + thickness / 2
        return NSRect(x: (x - size.width / 2).rounded(), y: (y - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private func placeKnob() {
        knob.frame = knobFrame(size: lifted ? liftedSize : knobSize)
        updateLens(for: knob.frame)
    }

    private var lifted: Bool { isDragging }

    private func updateLens(for frame: NSRect) {
        knob.barThickness = thickness
        knob.fillEnd = bounds.width * value - frame.minX
    }

    private func updateKnob(animated: Bool) {
        let visible = showsKnob || lifted
        let frame = knobFrame(size: lifted ? liftedSize : knobSize)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.18 : 0
            context.allowsImplicitAnimation = true
            knob.animator().alphaValue = visible ? 1 : 0
            knob.animator().frame = frame
            updateLens(for: frame)
            knob.setLifted(lifted)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let center = knob.frame.midX
        isDragging = true
        if knob.alphaValue > 0, abs(x - center) <= liftedSize.width / 2 {
            // Grabbed the knob: keep it under the cursor where it was taken.
            grabOffset = center - x
        } else {
            grabOffset = 0
            set(from: event, animated: true)
        }
        updateKnob(animated: true)
    }

    override func mouseDragged(with event: NSEvent) { set(from: event, animated: false) }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        updateKnob(animated: true)
        onDragEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30
        guard delta != 0 else { return }
        onSet?(min(1, max(0, value + Double(delta))), false)
    }

    private func set(from event: NSEvent, animated: Bool) {
        let x = convert(event.locationInWindow, from: nil).x + grabOffset
        let value = min(1, max(0, Double(x / bounds.width)))
        // Exact percent, as shown in the badge.
        onSet?((value * 100).rounded() / 100, animated)
    }
}

/// White capsule at rest. While dragged, a clear lens like the system's volume HUD: the bar
/// shows through it a little magnified, with a thin dark rim, a light edge at the top and a soft
/// shadow. Drawn by hand, so it looks the same over any background.
private final class BrightnessKnob: NSView {
    private let solid = NSView()
    private let lens = KnobLens()

    /// Where the bar's fill ends, in this view's coordinates, and how thick the bar is.
    var fillEnd: CGFloat = 0 { didSet { lens.fillEnd = fillEnd } }
    var barThickness: CGFloat = 4 { didSet { lens.barThickness = barThickness } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        solid.wantsLayer = true
        solid.layer?.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
        solid.layer?.shadowColor = NSColor.black.cgColor
        solid.layer?.shadowOpacity = 0.2
        solid.layer?.shadowRadius = 2
        solid.layer?.shadowOffset = CGSize(width: 0, height: -1)
        lens.wantsLayer = true
        lens.layer?.shadowColor = NSColor.black.cgColor
        lens.layer?.shadowOpacity = 0.4
        lens.layer?.shadowRadius = 5
        lens.layer?.shadowOffset = CGSize(width: 0, height: -3)
        lens.alphaValue = 0
        for view in [lens, solid] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the bar under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        solid.layer?.cornerRadius = bounds.height / 2
    }

    func setLifted(_ lifted: Bool) {
        lens.animator().alphaValue = lifted ? 1 : 0
        solid.animator().alphaValue = lifted ? 0 : 1
    }
}

private final class KnobLens: NSView {
    var fillEnd: CGFloat = 0 { didSet { needsDisplay = true } }
    var barThickness: CGFloat = 4 { didSet { needsDisplay = true } }
    private let magnification: CGFloat = 1.4

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.white.withAlphaComponent(0.08).setFill()
        rect.fill()
        // The bar seen through the lens, magnified about its centre.
        let thickness = barThickness * magnification
        let track = NSRect(x: 0, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()
        let end = bounds.midX + (fillEnd - bounds.midX) * magnification
        if end > 0 {
            var fill = track
            fill.size.width = min(bounds.width, end)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: fill, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }
        // Light catching the upper edge.
        let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])
        NSGraphicsContext.saveGraphicsState()
        let ring = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        ring.append(NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5).reversed)
        ring.addClip()
        highlight?.draw(in: rect, angle: -70)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()

        // Thin dark rim.
        NSColor.black.withAlphaComponent(0.55).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}
