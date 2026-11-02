import AppKit
import ApplicationServices
import CShims

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reachable from the C swipe handler, which cannot capture context.
    private static weak var current: AppDelegate?

    private var statusBar: StatusBarController?
    private let switcher = SpaceSwitcher()
    private let indicator = SpaceIndicator()
    private let videoMenuBar = VideoMenuBar()
    /// Target of our own switch, shown once the Dock has actually landed there.
    private var pendingIndicator: SpaceSnapshot?
    private var pendingFallback: DispatchWorkItem?
    private lazy var dockClicks = DockClickInterceptor(switcher: switcher)
    private let activationGuard = ActivationGuard()
    /// App picked with ⌘Tab or in the Dock whose space we jumped to; it must end up frontmost there.
    private var pendingFocus: (app: NSRunningApplication, target: Int)?
    private var focusWork: DispatchWorkItem?
    private let switcherSelection = SwitcherSelection()
    /// ⌘ was released on a full-screen Space after ⌘Tab, and the release is held back until
    /// Quicker has switched to the picked app's Space.
    private var heldRelease: (app: NSRunningApplication, target: Int)?
    private var releaseWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("Quicker launched, pid \(ProcessInfo.processInfo.processIdentifier)")
        AppDelegate.current = self

        guard is_spaces_available() else {
            fail(L("alert.fatal.skylight"))
            return
        }

        // Applies to every Accessibility call Quicker makes. The main thread also serves the
        // event tap, so an app that does not answer must not hold it for the default 6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)

        is_ds_set_swipe_handler { direction, extra in
            AppDelegate.current?.handleNativeSwipe(direction: Int(direction), extra: extra)
        }
        is_ds_set_key_handler { keycode, flags, isRepeat in
            AppDelegate.current?.handleKey(keycode: keycode, flags: flags, isRepeat: isRepeat) ?? false
        }
        is_ds_set_flags_handler { flags in
            AppDelegate.current?.handleFlags(CGEventFlags(rawValue: flags)) ?? false
        }
        is_ds_set_mouse_handler { down, x, y, flags in
            AppDelegate.current?.dockClicks.handle(down: down, location: CGPoint(x: x, y: y), flags: flags) ?? false
        }
        is_ds_set_intercept(Settings.shared.enabled)

        let statusBar = StatusBarController()
        statusBar.onSettingsChanged = { [weak self] in
            is_ds_set_intercept(Settings.shared.enabled)
            self?.videoMenuBar.update(self?.switcher.snapshot(usePrediction: false))
        }
        statusBar.isAccessibilityGranted = { AXIsProcessTrusted() }
        statusBar.isInterceptActive = { is_ds_tap_installed() }
        self.statusBar = statusBar

        switcher.onShowSpace = { [weak self] snapshot, switched in
            self?.spaceRequested(snapshot, switched: switched)
        }
        dockClicks.onClickHandled = { [weak self] app, target, replayed in
            // The replayed click activates the app itself; check a little later that it did.
            self?.expectFocus(app, on: target, after: replayed ? 0.3 : 0.05)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        installSignalHandlers()
        startInterception()
        videoMenuBar.update(switcher.snapshot(usePrediction: false))
    }

    func applicationWillTerminate(_ notification: Notification) {
        videoMenuBar.restore()
    }

    // MARK: Follow the activated app

    /// ⌘Tab or anything else activated an app. If none of its windows is on the current space,
    /// jump instantly to the space with its most recent window, which is what the system's own
    /// (animated) "switch to a Space with open windows" option would do. Activations macOS makes
    /// on its own are not followed (see `ActivationGuard`).
    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        // Taken for every activation, so a ⌘Tab pick can never be spent on a later one.
        let picked = activationGuard.takeSwitcherPick()

        let settings = Settings.shared
        guard settings.enabled, settings.followActivatedApp, is_ds_tap_installed() else { return }
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

        let name = app.localizedName ?? "pid \(app.processIdentifier)"
        if case .skip(let reason) = activationGuard.verdict(for: app, picked: picked, switching: switcher.isLanding) {
            log.notice("not following \(name, privacy: .public) to space \(target + 1): \(reason, privacy: .public)")
            return
        }

        // Put the app's window on top of its Space before going there; otherwise the Space first
        // appears with another app's window in front and the picked one rises a moment later.
        let focused = is_focus_window(app.processIdentifier, windows[0])
        // The WindowServer needs a moment to reorder the window before the Space appears.
        guard switcher.jump(toSpaceIndex: target, reason: "app \(name)\(picked ? " (⌘Tab)" : "")\(focused ? "" : " (no prefocus)")",
                            after: focused ? SpaceSwitcher.prefocusLead : 0) else { return }
        activationGuard.didFollow()
        expectFocus(app, on: target, after: 0.6)
    }

    /// Every modifier change, from the event tap. Returns true to hold the event back.
    private func handleFlags(_ flags: CGEventFlags) -> Bool {
        // Later modifier changes wait behind the held release, so they reach apps in order.
        if heldRelease != nil { return true }
        let closing = activationGuard.isSwitcherOpen && !flags.contains(.maskCommand)
        activationGuard.flagsChanged(flags)
        return closing && preemptSwitcherPick()
    }

    /// ⌘ is being released after ⌘Tab. Leaving a full-screen Space this way makes macOS slide to
    /// the picked app's Space as soon as it activates the app, whatever the system option says,
    /// and following the activation afterwards is too late to stop that slide. So the release is
    /// held back: Quicker reads the selected app from the switcher, switches to its Space
    /// instantly, and only then lets ⌘ go. macOS then finds the app on the current Space and
    /// simply activates it. Returns true when the release is held.
    private func preemptSwitcherPick() -> Bool {
        let settings = Settings.shared
        guard settings.enabled, settings.followActivatedApp, is_ds_tap_installed(),
              !SystemGestureCheck.systemSwitchOnActivateEnabled(),
              let state = switcher.snapshot(), state.types[state.current] == 4,
              let app = switcherSelection.selectedApp(steps: activationGuard.switcherSteps),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        var buffer = [Int32](repeating: 0, count: 64)
        var windows = [UInt32](repeating: 0, count: 64)
        let found = Int(is_spaces_app_window_indexes(app.processIdentifier, &buffer, &windows, Int32(buffer.count)))
        let indexes = buffer.prefix(found).map(Int.init)
        guard let target = indexes.first, !indexes.contains(state.current) else { return false }

        let name = app.localizedName ?? "pid \(app.processIdentifier)"
        if case .skip(let reason) = activationGuard.verdict(for: app, picked: true, switching: switcher.isLanding) {
            log.notice("not following \(name, privacy: .public) to space \(target + 1): \(reason, privacy: .public)")
            return false
        }
        let focused = is_focus_window(app.processIdentifier, windows[0])
        guard switcher.jump(toSpaceIndex: target, reason: "app \(name) (⌘Tab from full screen)\(focused ? "" : " (no prefocus)")",
                            after: focused ? SpaceSwitcher.prefocusLead : 0) else { return false }
        activationGuard.didFollow()
        heldRelease = (app, target)
        scheduleRelease(after: 0.4)
        return true
    }

    private func scheduleRelease(after delay: TimeInterval) {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.releaseHeldFlags() }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func releaseHeldFlags() {
        releaseWork?.cancel()
        releaseWork = nil
        guard let held = heldRelease else { return }
        heldRelease = nil
        is_ds_release_held_flags()
        // If the switcher closed during the switch, ⌘ activates nothing; give the app focus then.
        expectFocus(held.app, on: held.target, after: 0.3)
    }

    /// After a switch made for `app`, make sure it ends up frontmost on `target`. Checked once
    /// the switch lands, or after `delay` at the latest.
    private func expectFocus(_ app: NSRunningApplication, on target: Int, after delay: TimeInterval) {
        pendingFocus = (app, target)
        scheduleFocusCheck(after: delay)
    }

    private func scheduleFocusCheck(after delay: TimeInterval) {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.completeFocus() }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The user switched by other means: whatever focus was owed to an earlier pick is void.
    private func dropPendingFocus() {
        focusWork?.cancel()
        focusWork = nil
        pendingFocus = nil
    }

    /// Landing on a space makes macOS activate the app with the topmost window there, which may
    /// not be the app the user picked. Give focus back to the picked app, but only on the space
    /// we went to: activating it anywhere else would pull the user back to its space.
    private func completeFocus() {
        focusWork = nil
        guard let focus = pendingFocus else { return }
        pendingFocus = nil
        let pid = focus.app.processIdentifier
        guard !focus.app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              let landed = switcher.snapshot(usePrediction: false), landed.current == focus.target else { return }
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
        activationGuard.spaceDidChange()
        guard let landed = switcher.snapshot(usePrediction: false) else { return }
        log.info("active space changed to \(landed.current + 1) of \(landed.count)")
        switcher.spaceDidChange(landed)
        videoMenuBar.update(landed)
        dockClicks.spaceDidChange(to: landed.current)
        if let held = heldRelease, held.target == landed.current {
            scheduleRelease(after: 0.03)
        }
        if let focus = pendingFocus, focus.target == landed.current {
            // Let macOS finish its own activation for the new space first.
            scheduleFocusCheck(after: 0.12)
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
    private func handleNativeSwipe(direction: Int, extra: Bool) {
        if extra && !Settings.shared.longSwipeSkipsMore { return }
        var step: SpaceStep = direction > 0 ? .next : .previous
        if Settings.shared.invertDirection { step = step == .next ? .previous : .next }
        dropPendingFocus()
        switcher.perform(step)
    }

    /// modifier+←/→ and modifier+1…9. Returns true when the key was ours and must be swallowed.
    private func handleKey(keycode: Int32, flags: UInt64, isRepeat: Bool) -> Bool {
        activationGuard.keyDown(keycode: keycode, flags: CGEventFlags(rawValue: flags), isRepeat: isRepeat)

        let settings = Settings.shared
        guard settings.enabled, Hotkeys.modifiersMatch(flags, settings.hotkeyModifier) else { return false }
        // While the ⌘Tab switcher is open, arrows move its selection.
        guard !activationGuard.isSwitcherOpen else { return false }

        if settings.hotkeyArrows, keycode == Hotkeys.leftArrow || keycode == Hotkeys.rightArrow {
            // Auto-repeat would fire a burst of switches; swallow it without acting.
            if !isRepeat {
                dropPendingFocus()
                switcher.perform(keycode == Hotkeys.rightArrow ? .next : .previous)
            }
            return true
        }

        if settings.hotkeyDigits, let number = Hotkeys.digits[keycode] {
            // No such space: let the key through so the app's own shortcut still works.
            if isRepeat { return switcher.hasSpace(at: number) }
            let jumped = switcher.jump(toPosition: number)
            if jumped { dropPendingFocus() }
            return jumped
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
        // `kill`/`pkill` skip applicationWillTerminate; put the menu bar setting back first.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.videoMenuBar.restore()
                exit(0)
            }
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
