import AppKit
import ApplicationServices

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let settings = Settings.shared

    var onSettingsChanged: (() -> Void)?

    /// Screen frame of the menu bar icon; nil when it is hidden (behind the notch, by a menu bar
    /// manager, or the menu bar is hidden).
    var iconFrame: NSRect? {
        guard item.isVisible, let window = item.button?.window, window.isVisible, window.occlusionState.contains(.visible)
        else { return nil }
        return window.frame
    }
    /// Shows a rounded backdrop behind the icon, like the one the system draws behind the
    /// volume icon while its HUD is up. The button's own highlight does not draw it.
    func setHighlighted(_ highlighted: Bool) {
        guard let bar = item.button?.window?.contentView else { return }
        if highlighted {
            let height = min(24, bar.bounds.height)
            highlight.frame = NSRect(x: 0, y: ((bar.bounds.height - height) / 2).rounded(),
                                     width: bar.bounds.width, height: height)
            if highlight.superview !== bar {
                bar.addSubview(highlight, positioned: .below, relativeTo: bar.subviews.first)
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = highlighted ? 0.1 : 0.25
            highlight.animator().alphaValue = highlighted ? 1 : 0
        }
    }
    private let highlight = StatusItemHighlight()

    var isAccessibilityGranted: (() -> Bool)?
    var isInterceptActive: (() -> Bool)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    func updateIcon() {
        guard let button = item.button else { return }
        let ready = settings.enabled && (isInterceptActive?() ?? false)
        let symbol = ready ? "ipad.sizes" : "rectangle.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Quicker")
            ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Quicker")
        image?.isTemplate = true
        button.image = image
        button.toolTip = ready ? L("status.tooltip.active") : L("status.tooltip.inactive")
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        menu.addItem(header("Quicker \(version)"))

        let granted = isAccessibilityGranted?() ?? false
        let fingers = SystemGestureCheck.systemSwipeFingers()
        if !granted {
            menu.addItem(header(L("status.needAccessibility")))
            menu.addItem(action(L("status.grantAccessibility"), #selector(openAccessibility), indent: 1))
        } else if let fingers {
            menu.addItem(header(L("status.swipeReady", fingers)))
        }
        if fingers == nil {
            menu.addItem(header(L("status.swipeOff")))
            menu.addItem(header(L("status.swipeOffHint")))
            menu.addItem(action(L("status.openTrackpad"), #selector(openTrackpadSettings), indent: 1))
        }
        menu.addItem(.separator())

        menu.addItem(check(L("menu.enabled"), on: settings.enabled, #selector(toggleEnabled)))
        if settings.followActivatedApp && SystemGestureCheck.systemSwitchOnActivateEnabled() {
            menu.addItem(header(L("menu.followApp.systemOn")))
            menu.addItem(action(L("menu.followApp.openSettings"), #selector(openDesktopSettings), indent: 1))
        }
        menu.addItem(.separator())

        menu.addItem(check(L("menu.scroll.smooth"), on: settings.smoothScroll, #selector(toggleSmoothScroll)))
        menu.addItem(check(L("menu.indicator.quick"), on: settings.indicatorEnabled, #selector(toggleIndicator)))
        menu.addItem(check(L("menu.dock.quick"), on: settings.dockShownOnExternalDisplay, #selector(toggleDockExternal)))
        menu.addItem(.separator())

        menu.addItem(action(L("menu.settings"), #selector(openSettings), key: ","))
        menu.addItem(action(L("menu.quit"), #selector(quit), key: "q"))
    }

    // MARK: Item helpers

    private func header(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", indent: Int = 0) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        mi.target = self
        mi.indentationLevel = indent
        return mi
    }

    private func check(_ title: String, on: Bool, _ selector: Selector, indent: Int = 0) -> NSMenuItem {
        let mi = action(title, selector, indent: indent)
        mi.state = on ? .on : .off
        return mi
    }

    private func changed() {
        onSettingsChanged?()
        updateIcon()
        settingsWindow.refresh()
    }

    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController()
        controller.onChange = { [weak self] in
            self?.onSettingsChanged?()
            self?.updateIcon()
        }
        return controller
    }()

    @objc func openSettings() { settingsWindow.show() }

    // MARK: Actions

    @objc private func toggleEnabled() { settings.enabled.toggle(); changed() }

    @objc private func toggleIndicator() { settings.indicatorEnabled.toggle(); changed() }
    @objc private func toggleDockExternal() { settings.dockShownOnExternalDisplay.toggle(); changed() }
    @objc private func openDesktopSettings() { SystemGestureCheck.openDesktopAndDockSettings() }

    @objc private func toggleSmoothScroll() { settings.smoothScroll.toggle(); changed() }

    @objc private func openTrackpadSettings() { SystemGestureCheck.openTrackpadSettings() }
    @objc private func openAccessibility() {
        // Re-asking puts Quicker back into the Accessibility list if its entry was removed.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        SystemGestureCheck.openAccessibilitySettings()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// The rounded backdrop behind a highlighted menu bar icon; follows the menu bar's appearance.
private final class StatusItemHighlight: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        autoresizingMask = [.width, .minYMargin, .maxYMargin]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
