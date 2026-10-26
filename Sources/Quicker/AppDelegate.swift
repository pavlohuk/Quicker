import AppKit
import ApplicationServices
import CShims

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reachable from the C swipe handler, which cannot capture context.
    private static weak var current: AppDelegate?

    private var statusBar: StatusBarController?
    private let switcher = SpaceSwitcher()
    private let indicator = SpaceIndicator()
    /// Target of our own switch, shown once the Dock has actually landed there.
    private var pendingIndicator: SpaceSnapshot?
    private var pendingFallback: DispatchWorkItem?
    private lazy var dockClicks = DockClickInterceptor(switcher: switcher)
    /// App activated with ⌘Tab whose space we jumped to; it must end up frontmost there.
    private var pendingFocus: (app: NSRunningApplication, target: Int)?
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("Quicker launched, pid \(ProcessInfo.processInfo.processIdentifier)")
        AppDelegate.current = self

        guard is_spaces_available() else {
            fail(L("alert.fatal.skylight"))
            return
        }

        is_ds_set_swipe_handler { direction in
            AppDelegate.current?.handleNativeSwipe(direction: Int(direction))
        }
        is_ds_set_key_handler { keycode, flags, isRepeat in
            AppDelegate.current?.handleKey(keycode: keycode, flags: flags, isRepeat: isRepeat) ?? false
        }
        is_ds_set_mouse_handler { down, x, y, flags in
            AppDelegate.current?.dockClicks.handle(down: down, location: CGPoint(x: x, y: y), flags: flags) ?? false
        }
        is_ds_set_intercept(Settings.shared.enabled)

        let statusBar = StatusBarController()
        statusBar.onSettingsChanged = { is_ds_set_intercept(Settings.shared.enabled) }
        statusBar.isAccessibilityGranted = { AXIsProcessTrusted() }
        statusBar.isInterceptActive = { is_ds_tap_installed() }
        self.statusBar = statusBar

        switcher.onShowSpace = { [weak self] snapshot, switched in
            self?.spaceRequested(snapshot, switched: switched)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        installSignalHandlers()
        startInterception()
    }

    // MARK: Follow the activated app

    /// ⌘Tab, a Dock click or anything else activated an app. If none of its windows is on the
    /// current space, jump instantly to the space with its most recent window, which is what the
    /// system's own (animated) "switch to a Space with open windows" option would do.
    @objc private func appDidActivate(_ notification: Notification) {
        let settings = Settings.shared
        guard settings.enabled, settings.followActivatedApp, is_ds_tap_installed(),
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        // With the system option on, the Dock is already sliding there; a second switch would collide.
        guard !SystemGestureCheck.systemSwitchOnActivateEnabled() else { return }
        guard let state = switcher.snapshot() else { return }

        var buffer = [Int32](repeating: 0, count: 64)
        var windows = [UInt32](repeating: 0, count: 64)
        let found = Int(is_spaces_app_window_indexes(app.processIdentifier, &buffer, &windows, Int32(buffer.count)))
        let indexes = buffer.prefix(found).map(Int.init)
        // No windows on this display, or already visible here (includes the app that macOS
        // activates on its own after one of our switches lands).
        guard let target = indexes.first, !indexes.contains(state.current) else { return }

        // Put the app's window on top of its Space before going there; otherwise the Space first
        // appears with another app's window in front and the picked one rises a moment later.
        let focused = is_focus_window(app.processIdentifier, windows[0])
        let name = app.localizedName ?? "pid \(app.processIdentifier)"
        // The WindowServer needs a moment to reorder the window before the Space appears.
        guard switcher.jump(toSpaceIndex: target, reason: "app \(name)\(focused ? "" : " (no prefocus)")",
                            after: focused ? SpaceSwitcher.prefocusLead : 0) else { return }
        pendingFocus = (app, target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.completeFocus() }
    }

    /// Landing on a space makes macOS activate the app with the topmost window there, which may
    /// not be the app the user picked with ⌘Tab. Give focus back to the picked app.
    private func completeFocus() {
        guard let focus = pendingFocus else { return }
        pendingFocus = nil
        let pid = focus.app.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, !focus.app.isTerminated else { return }
        let element = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        log.info("refocused \(focus.app.localizedName ?? "pid \(pid)", privacy: .public): \(result.rawValue)")
    }

    // MARK: Indicator

    /// Our own switch. Showing the indicator right away would put it on screen while the Dock is
    /// still moving between spaces, so wait until it lands on the target.
    private func spaceRequested(_ snapshot: SpaceSnapshot, switched: Bool) {
        guard switched else {
            showIndicator(snapshot)
            return
        }
        pendingIndicator = snapshot
        pendingFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in self?.showPendingIndicator() }
        pendingFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: fallback)
    }

    /// Any space change, including ones Quicker did not make (Mission Control, Dock clicks,
    /// the animated system switch when Quicker is turned off).
    @objc private func activeSpaceDidChange() {
        guard let landed = switcher.snapshot(usePrediction: false) else { return }
        log.info("active space changed to \(landed.current + 1) of \(landed.count)")
        dockClicks.spaceDidChange(to: landed.current)
        if let focus = pendingFocus, focus.target == landed.current {
            // Let macOS finish its own activation for the new space first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.completeFocus() }
        }
        if let pending = pendingIndicator {
            // Intermediate hops of a multi-space jump are skipped.
            if landed.current == pending.current { showPendingIndicator() }
            return
        }
        // Late notifications from our own burst of swipes.
        guard !switcher.isPredicting else { return }
        showIndicator(landed)
    }

    private func showPendingIndicator() {
        pendingFallback?.cancel()
        pendingFallback = nil
        guard let pending = pendingIndicator else { return }
        pendingIndicator = nil
        showIndicator(pending)
    }

    private func showIndicator(_ snapshot: SpaceSnapshot) {
        let settings = Settings.shared
        guard settings.indicatorEnabled else { return }
        indicator.show(snapshot, corner: settings.indicatorCorner)
    }

    // MARK: Interception

    /// Installs the event tap once Accessibility is granted; until then, asks once and polls.
    private func startInterception() {
        if AXIsProcessTrusted() {
            installTap()
            return
        }
        log.notice("Accessibility permission missing, asking")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            log.notice("Accessibility permission granted")
            self?.installTap()
        }
    }

    private func installTap() {
        if is_ds_tap_install() {
            log.notice("swipe interception active")
        } else {
            log.error("could not create the event tap")
        }
        statusBar?.updateIcon()
    }

    /// Native swipe intercepted: +1 means the user swiped towards the next space.
    private func handleNativeSwipe(direction: Int) {
        var step: SpaceStep = direction > 0 ? .next : .previous
        if Settings.shared.invertDirection { step = step == .next ? .previous : .next }
        switcher.perform(step)
    }

    /// modifier+←/→ and modifier+1…9. Returns true when the key was ours and must be swallowed.
    private func handleKey(keycode: Int32, flags: UInt64, isRepeat: Bool) -> Bool {
        let settings = Settings.shared
        guard settings.enabled, Hotkeys.modifiersMatch(flags, settings.hotkeyModifier) else { return false }

        if settings.hotkeyArrows, keycode == Hotkeys.leftArrow || keycode == Hotkeys.rightArrow {
            // Auto-repeat would fire a burst of switches; swallow it without acting.
            if !isRepeat { switcher.perform(keycode == Hotkeys.rightArrow ? .next : .previous) }
            return true
        }

        if settings.hotkeyDigits, let number = Hotkeys.digits[keycode] {
            // No such desktop: let the key through so the app's own shortcut still works.
            if isRepeat { return switcher.hasDesktop(number) }
            return switcher.jump(toDesktop: number)
        }
        return false
    }

    // MARK: Misc

    /// `kill -USR1 <pid>` switches to the next space, `kill -USR2` to the previous one (handy for testing from a shell).
    private func installSignalHandlers() {
        let mapping: [(Int32, SpaceStep)] = [(SIGUSR1, .next), (SIGUSR2, .previous)]
        for (sig, step) in mapping {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.switcher.perform(step) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = L("alert.fatal.title")
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}
