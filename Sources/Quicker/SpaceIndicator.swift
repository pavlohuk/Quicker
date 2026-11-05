import AppKit

enum IndicatorCorner: String, CaseIterable {
    case topCenter
    case topRight
    case topLeft
    case bottomCenter
    case bottomRight
    case bottomLeft

    var title: String {
        switch self {
        case .topCenter: return L("position.topCenter")
        case .topRight: return L("position.topRight")
        case .topLeft: return L("position.topLeft")
        case .bottomCenter: return L("position.bottomCenter")
        case .bottomRight: return L("position.bottomRight")
        case .bottomLeft: return L("position.bottomLeft")
        }
    }
}

/// Small HUD at the top of the screen (or in a corner) that names the space the user is on after a switch.
final class SpaceIndicator {
    /// Recreated for every show, see `show`.
    private var panel: NSPanel?
    private let content: NSView
    private let titleLabel = NSTextField(labelWithString: "")
    private let dots = SpaceDotsView()
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    private let visibleFor: TimeInterval = 1.0
    private let fadeOut: TimeInterval = 0.2
    private let margin: CGFloat = 12

    init() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let stack = NSStackView(views: [titleLabel, dots])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        // Inside the glass view the stack does not grow to fit its views across, so the dots
        // overflowed with many spaces and long names reached the edges. Keep both inside the insets.
        for view in [titleLabel, dots] {
            view.leadingAnchor.constraint(greaterThanOrEqualTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
            view.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
        }
        content = Self.background(around: stack)
    }

    private static func makePanel() -> NSPanel {
        let panel = IndicatorPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 60),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Like the volume HUD, which keeps white text in both light and dark mode.
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    static let cornerRadius: CGFloat = 24

    /// Liquid Glass like the system's own HUDs (volume, brightness) on macOS 26 and later, a
    /// blurred HUD material before that.
    static func background(around content: NSView, cornerRadius: CGFloat = cornerRadius) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // The look of the system's volume and brightness HUDs. Measured beside the volume HUD
            // on a light wallpaper and over a dark window, private variant 9 matched its colour
            // within a few RGB steps on both, while no public style with a fixed tint did.
            let hudVariant = NSSelectorFromString("set_variant:")
            if glass.responds(to: hudVariant) { glass.setValue(9, forKey: "_variant") }
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        // The blur behind the window ignores the layer's corner radius and fills the corners
        // with a square backdrop; only a mask image clips it.
        blur.maskImage = roundedMask(radius: cornerRadius)
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    func show(_ snapshot: SpaceSnapshot, corner: IndicatorCorner) {
        guard snapshot.current >= 0, snapshot.current < snapshot.count else { return }
        titleLabel.stringValue = Self.name(of: snapshot.current, in: snapshot)
        dots.update(types: snapshot.types, current: snapshot.current)

        // Appear instantly; only the disappearance is animated.
        generation += 1
        hideWork?.cancel()
        // A panel reused across switches loses its place on every space: after a while macOS keeps
        // it on only a few of them (seen: the full-screen space and the desktop next to it) and it
        // is not drawn anywhere else. A fresh panel joins all spaces, so build one for every show.
        if let old = panel {
            old.orderOut(nil)
            old.contentView = nil
        }
        let panel = Self.makePanel()
        self.panel = panel
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setFrame(frame(for: content.fittingSize, corner: corner), display: true)
        panel.orderFrontRegardless()

        let shown = generation
        let title = titleLabel.stringValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, shown == self.generation else { return }
            log.info("indicator '\(title, privacy: .public)': visible=\(panel.occlusionState.contains(.visible)) onActiveSpace=\(panel.isOnActiveSpace)")
        }
        let work = DispatchWorkItem { [weak self] in self?.hide(ifStill: shown) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: work)
    }

    /// A stretchable rounded rectangle: the corners keep their radius at any size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The space's position (what ⌘N jumps to) for desktops, the app name for full-screen spaces.
    static func name(of index: Int, in snapshot: SpaceSnapshot) -> String {
        switch snapshot.types[index] {
        case 0:
            return String(index + 1)
        case 4:
            let pid = snapshot.pids[index]
            if pid > 0, let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
            return L("indicator.fullscreenApp")
        default:
            return String(index + 1)
        }
    }

    // MARK: Private

    private func hide(ifStill shown: Int) {
        guard shown == generation, let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Frame at the requested position on the screen under the mouse, inside its visible area
    /// (below the menu bar, clear of the Dock).
    private func frame(for size: NSSize, corner: IndicatorCorner) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return Self.frame(for: size, corner: corner, on: screen, margin: margin)
    }

    /// Frame at the requested position on `screen`, inside its visible area.
    static func frame(for size: NSSize, corner: IndicatorCorner, on screen: NSScreen?, margin: CGFloat = 12) -> NSRect {
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Gap below the menu bar.
        let top: CGFloat = 18
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topCenter: x = area.midX - size.width / 2; y = area.maxY - size.height - top
        case .topRight: x = area.maxX - size.width - margin; y = area.maxY - size.height - top
        case .topLeft: x = area.minX + margin; y = area.maxY - size.height - top
        case .bottomCenter: x = area.midX - size.width / 2; y = area.minY + margin
        case .bottomRight: x = area.maxX - size.width - margin; y = area.minY + margin
        case .bottomLeft: x = area.minX + margin; y = area.minY + margin
        }
        return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}

/// Never takes focus, so showing it does not disturb the frontmost app.
final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Liquid Glass in a window without active appearance is drawn flat and frosted. This panel
    /// is never key, so claim active appearance (private AppKit hook) to get the full glass.
    @objc var _hasActiveAppearance: Bool { true }
}

/// One mark per space in Dock order: a dot for a desktop, a short pill for a full-screen app.
/// The current space is drawn solid, the others dimmed.
private final class SpaceDotsView: NSView {
    private var types: [Int32] = []
    private var current = 0

    private let height: CGFloat = 7
    private let desktopWidth: CGFloat = 7
    private let fullscreenWidth: CGFloat = 14
    private let spacing: CGFloat = 6

    func update(types: [Int32], current: Int) {
        self.types = types
        self.current = current
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let widths = types.map(width(of:))
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        return NSSize(width: total, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for (index, type) in types.enumerated() {
            let w = width(of: type)
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: w, height: height)
            let color = index == current ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.28)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            x += w + spacing
        }
    }

    private func width(of type: Int32) -> CGFloat {
        type == 4 ? fullscreenWidth : desktopWidth
    }
}
