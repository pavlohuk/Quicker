import AppKit
import ApplicationServices

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let settings = Settings.shared

    var onSettingsChanged: (() -> Void)?
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
        let symbol = ready ? "rectangle.2.swap" : "rectangle.slash"
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
        menu.addItem(check(L("menu.invertSwipe"), on: settings.invertDirection, #selector(toggleInvert)))
        menu.addItem(.separator())

        let m = settings.hotkeyModifier.symbol
        menu.addItem(header(L("menu.hotkeys")))
        menu.addItem(check(L("menu.hotkeys.digits", m), on: settings.hotkeyDigits, #selector(toggleDigits), indent: 1))
        menu.addItem(check(L("menu.hotkeys.arrows", m), on: settings.hotkeyArrows, #selector(toggleArrows), indent: 1))
        let modifierItem = NSMenuItem(title: L("menu.hotkeys.modifier", settings.hotkeyModifier.title), action: nil, keyEquivalent: "")
        modifierItem.indentationLevel = 1
        let modifierMenu = NSMenu()
        for modifier in HotkeyModifier.allCases {
            let mi = check(modifier.title, on: modifier == settings.hotkeyModifier, #selector(setModifier(_:)))
            mi.representedObject = modifier.rawValue
            modifierMenu.addItem(mi)
        }
        modifierItem.submenu = modifierMenu
        menu.addItem(modifierItem)
        menu.addItem(.separator())

        menu.addItem(header(L("menu.followApp")))
        menu.addItem(check(L("menu.followApp.toggle"), on: settings.followActivatedApp, #selector(toggleFollowApp), indent: 1))
        if settings.followActivatedApp && SystemGestureCheck.systemSwitchOnActivateEnabled() {
            menu.addItem(header(L("menu.followApp.systemOn")))
            menu.addItem(header(L("menu.followApp.hint1")))
            menu.addItem(header(L("menu.followApp.hint2")))
            menu.addItem(action(L("menu.followApp.openSettings"), #selector(openDesktopSettings), indent: 1))
        }
        menu.addItem(.separator())

        menu.addItem(header(L("menu.indicator")))
        menu.addItem(check(L("menu.indicator.show"), on: settings.indicatorEnabled, #selector(toggleIndicator), indent: 1))
        let cornerItem = NSMenuItem(title: L("menu.indicator.position", settings.indicatorCorner.title), action: nil, keyEquivalent: "")
        cornerItem.indentationLevel = 1
        let cornerMenu = NSMenu()
        for corner in IndicatorCorner.allCases {
            let mi = check(corner.title, on: corner == settings.indicatorCorner, #selector(setCorner(_:)))
            mi.representedObject = corner.rawValue
            cornerMenu.addItem(mi)
        }
        cornerItem.submenu = cornerMenu
        menu.addItem(cornerItem)
        menu.addItem(.separator())

        menu.addItem(check(L("menu.launchAtLogin"), on: LoginItem.isEnabled, #selector(toggleLoginItem)))
        menu.addItem(.separator())
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
    }

    // MARK: Actions

    @objc private func toggleEnabled() { settings.enabled.toggle(); changed() }
    @objc private func toggleInvert() { settings.invertDirection.toggle(); changed() }
    @objc private func toggleDigits() { settings.hotkeyDigits.toggle(); changed() }
    @objc private func toggleArrows() { settings.hotkeyArrows.toggle(); changed() }

    @objc private func toggleIndicator() { settings.indicatorEnabled.toggle(); changed() }
    @objc private func toggleFollowApp() { settings.followActivatedApp.toggle(); changed() }
    @objc private func openDesktopSettings() { SystemGestureCheck.openDesktopAndDockSettings() }

    @objc private func setCorner(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let corner = IndicatorCorner(rawValue: raw) {
            settings.indicatorCorner = corner
            changed()
        }
    }

    @objc private func setModifier(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let modifier = HotkeyModifier(rawValue: raw) {
            settings.hotkeyModifier = modifier
            changed()
        }
    }
    @objc private func openTrackpadSettings() { SystemGestureCheck.openTrackpadSettings() }
    @objc private func openAccessibility() {
        // Re-asking puts Quicker back into the Accessibility list if its entry was removed.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        SystemGestureCheck.openAccessibilitySettings()
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = L("alert.loginItem.title")
            alert.informativeText = L("alert.loginItem.message", error.localizedDescription)
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
