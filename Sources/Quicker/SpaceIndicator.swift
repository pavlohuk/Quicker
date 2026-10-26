import AppKit

enum IndicatorCorner: String, CaseIterable {
    case topCenter
    case topRight
    case topLeft
    case bottomRight
    case bottomLeft

    var title: String {
        switch self {
        case .topCenter: return L("position.topCenter")
        case .topRight: return L("position.topRight")
        case .topLeft: return L("position.topLeft")
        case .bottomRight: return L("position.bottomRight")
        case .bottomLeft: return L("position.bottomLeft")
        }
    }
}

/// Small HUD at the top of the screen (or in a corner) that names the space the user is on after a switch.
final class SpaceIndicator {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let dots = SpaceDotsView()
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    private let visibleFor: TimeInterval = 1.0
    private let fadeOut: TimeInterval = 0.2
    private let margin: CGFloat = 12

    init() {
        panel = IndicatorPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 60),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        let stack = NSStackView(views: [titleLabel, dots])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 13, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        panel.contentView = background
    }

    func show(_ snapshot: SpaceSnapshot, corner: IndicatorCorner) {
        guard snapshot.current >= 0, snapshot.current < snapshot.count else { return }
        titleLabel.stringValue = Self.name(of: snapshot.current, in: snapshot)
        dots.update(types: snapshot.types, current: snapshot.current)

        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setFrame(frame(for: size, corner: corner), display: true)

        // Appear instantly; only the disappearance is animated.
        generation += 1
        hideWork?.cancel()
        panel.alphaValue = 1
        // A panel still on screen from a full-screen space stays tied to that space and is not
        // drawn on the desktop we switched to, so take it off screen and order it in afresh.
        if panel.isVisible { panel.orderOut(nil) }
        panel.orderFrontRegardless()

        let shown = generation
        let title = titleLabel.stringValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, shown == self.generation else { return }
            log.info("indicator '\(title, privacy: .public)': visible=\(self.panel.occlusionState.contains(.visible)) onActiveSpace=\(self.panel.isOnActiveSpace) alpha=\(Double(self.panel.alphaValue))")
        }
        let work = DispatchWorkItem { [weak self] in self?.hide(ifStill: shown) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: work)
    }

    /// "Desktop N" for desktops, the app name for full-screen spaces.
    static func name(of index: Int, in snapshot: SpaceSnapshot) -> String {
        switch snapshot.types[index] {
        case 0:
            return L("indicator.desktop", snapshot.desktopNumber(at: index) ?? index + 1)
        case 4:
            let pid = snapshot.pids[index]
            if pid > 0, let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
            return L("indicator.fullscreenApp")
        default:
            return L("indicator.space", index + 1)
        }
    }

    // MARK: Private

    private func hide(ifStill shown: Int) {
        guard shown == generation else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, shown == self.generation else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Frame at the requested position on the screen under the mouse, inside its visible area
    /// (below the menu bar, clear of the Dock).
    private func frame(for size: NSSize, corner: IndicatorCorner) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topCenter: x = area.midX - size.width / 2; y = area.maxY - size.height - margin
        case .topRight: x = area.maxX - size.width - margin; y = area.maxY - size.height - margin
        case .topLeft: x = area.minX + margin; y = area.maxY - size.height - margin
        case .bottomRight: x = area.maxX - size.width - margin; y = area.minY + margin
        case .bottomLeft: x = area.minX + margin; y = area.minY + margin
        }
        return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}

/// Never takes focus, so showing it does not disturb the frontmost app.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
