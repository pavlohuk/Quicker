import AppKit
import ApplicationServices
import CShims

/// Makes a click on the Dock icon of an app whose windows are all on another space instant.
///
/// Left alone, the click activates the app first, and only then can Quicker follow it to its
/// space: a noticeable delay, and macOS may give focus to another app on that space. Instead, the
/// mouse-down on such an icon is held back. If the button comes up without the pointer moving,
/// Quicker switches to the app's space instantly and replays the click to the Dock. A drag (to
/// reorder icons) or a long press (the Dock menu) gets its mouse-down back at once, untouched. The Dock finds the app's windows on the current
/// space and simply activates it, exactly as for an app on the current desktop.
final class DockClickInterceptor {
    private let switcher: SpaceSwitcher
    private let systemWide = AXUIElementCreateSystemWide()
    private var orientation: (value: String, at: Date)?
    private var dock: (app: NSRunningApplication, element: AXUIElement)?

    /// Called once the held click has been dealt with, so the app can be given focus if the
    /// click did not do it.
    var onClickHandled: ((_ app: NSRunningApplication, _ target: Int, _ replayed: Bool) -> Void)?

    private struct Pending {
        let app: NSRunningApplication
        let location: CGPoint
        let flags: CGEventFlags
        let target: Int
        let window: UInt32
        /// Set once the button came up and the switch started.
        var switching = false
        var upReceived = false
    }
    private var pending: Pending?
    private var replayWork: DispatchWorkItem?
    private var holdWork: DispatchWorkItem?

    /// A press held this long without moving is left to the Dock (its menu).
    private let longPress: TimeInterval = 0.35
    /// Moving farther than this while pressed is a drag, left to the Dock.
    private let dragSlop: CGFloat = 4

    /// Clicks farther than this from the Dock's screen edge are never inspected.
    private let edgeBand: CGFloat = 180
    /// Longest wait for the switch to land before the click is replayed anyway.
    private let replayTimeout: TimeInterval = 0.4
    /// Time between focusing the app's window and switching to its Space (see `SpaceSwitcher.prefocusLead`).
    private let prefocusLead = SpaceSwitcher.prefocusLead

    init(switcher: SpaceSwitcher) {
        self.switcher = switcher
    }

    /// Left mouse events from the event tap (`kind` 0 down, 1 up, 2 drag). Returns true to
    /// swallow the event.
    ///
    /// Runs inside the event tap: until it returns, no input reaches any app, so the cheap
    /// checks come first and nothing here may wait on another app.
    func handle(kind: Int32, location: CGPoint, flags rawFlags: UInt64) -> Bool {
        switch kind {
        case 0: return mouseDown(at: location, flags: CGEventFlags(rawValue: rawFlags))
        case 1: return mouseUp()
        default: return mouseDragged(to: location)
        }
    }

    private func mouseDown(at location: CGPoint, flags: CGEventFlags) -> Bool {
        if pending != nil { return true }

        let settings = Settings.shared
        guard settings.enabled, settings.followActivatedApp, is_ds_tap_installed() else { return false }
        // ⌘-click (show in Finder), ⌥-click (hide others), ⌃-click (menu): leave to the Dock.
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              isNearDockEdge(location),
              !SystemGestureCheck.systemSwitchOnActivateEnabled(),
              let app = appForDockIcon(at: location),
              let state = switcher.snapshot() else { return false }

        var buffer = [Int32](repeating: 0, count: 64)
        var windows = [UInt32](repeating: 0, count: 64)
        let found = Int(is_spaces_app_window_indexes(app.processIdentifier, app.isHidden, &buffer, &windows, Int32(buffer.count)))
        let indexes = buffer.prefix(found).map(Int.init)
        guard let target = indexes.first, !indexes.contains(state.current) else { return false }

        pending = Pending(app: app, location: location, flags: flags, target: target, window: windows[0])
        let work = DispatchWorkItem { [weak self] in self?.giveBack(dragTo: nil) }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPress, execute: work)
        return true
    }

    private func mouseUp() -> Bool {
        // A real mouse-up that comes after a replay passes through untouched.
        guard var held = pending else { return false }
        held.upReceived = true
        if held.switching {
            pending = held
            return true
        }
        holdWork?.cancel()
        holdWork = nil

        // Put the app's window on top of its Space before going there, so the Space does not
        // first appear with another app's window in front.
        // Not for a hidden app: its windows are not shown until the Dock gets the click.
        let focused = !held.app.isHidden && is_focus_window(held.app.processIdentifier, held.window)
        let name = held.app.localizedName ?? "pid \(held.app.processIdentifier)"
        // The WindowServer needs a moment to reorder the window before the Space appears.
        guard switcher.jump(toSpaceIndex: held.target, reason: "dock \(name)\(focused ? "" : " (no prefocus)")",
                            after: focused ? prefocusLead : 0) else {
            pending = nil
            post(.leftMouseDown, at: held.location, flags: held.flags)
            post(.leftMouseUp, at: held.location, flags: held.flags)
            return true
        }
        held.switching = true
        pending = held
        scheduleReplay(after: replayTimeout)
        return true
    }

    private func mouseDragged(to location: CGPoint) -> Bool {
        guard let held = pending else { return false }
        if held.switching { return true }
        // Small wobble of a click: keep it from the Dock, which has not seen the mouse-down.
        if hypot(location.x - held.location.x, location.y - held.location.y) <= dragSlop { return true }
        giveBack(dragTo: location)
        return true
    }

    /// Hands a press that is not a plain click back to the Dock: its mouse-down, then the drag
    /// that revealed it, so the Dock starts the drag (or shows its menu) as usual.
    private func giveBack(dragTo location: CGPoint?) {
        holdWork?.cancel()
        holdWork = nil
        guard let held = pending, !held.switching else { return }
        pending = nil
        post(.leftMouseDown, at: held.location, flags: held.flags)
        if let location { post(.leftMouseDragged, at: location, flags: held.flags) }
    }

    /// Every active-space change; replays the held click once the target space is reached.
    func spaceDidChange(to index: Int) {
        guard let held = pending, held.switching, held.target == index else { return }
        scheduleReplay(after: 0.03)
    }

    // MARK: Private

    private func scheduleReplay(after delay: TimeInterval) {
        replayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.replay() }
        replayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func replay() {
        replayWork?.cancel()
        replayWork = nil
        guard let held = pending else { return }
        // A real mouse-up that has not arrived yet passes through untouched from now on.
        pending = nil
        // An auto-hidden Dock can be out of the way right after the switch. A click replayed then
        // would land in whatever window is under the pointer, so only replay it onto the icon.
        let iconStillThere = appForDockIcon(at: held.location)?.processIdentifier == held.app.processIdentifier
        // A click replayed at the icon would pull the pointer back there. Once the hand has
        // moved on, the app is focused directly instead and the pointer is left alone.
        let pointer = CGEvent(source: nil)?.location ?? held.location
        let moved = hypot(pointer.x - held.location.x, pointer.y - held.location.y) > dragSlop
        let replayed = iconStillThere && !moved
        if replayed {
            post(.leftMouseDown, at: held.location, flags: held.flags)
            if held.upReceived { post(.leftMouseUp, at: held.location, flags: held.flags) }
        } else if moved {
            log.info("pointer left the dock icon during the switch; focusing \(held.app.localizedName ?? "the app", privacy: .public) directly")
        } else {
            log.notice("dock icon gone after the switch; focusing \(held.app.localizedName ?? "the app", privacy: .public) directly")
        }
        onClickHandled?(held.app, held.target, replayed)
    }

    private func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Int64(IS_REPLAY_MARKER))
        event.post(tap: .cghidEventTap)
    }

    /// Cheap filter so the Accessibility hit-test only runs for clicks near the Dock.
    private func isNearDockEdge(_ point: CGPoint) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return false }
        let bounds = CGDisplayBounds(display)
        switch dockOrientation() {
        case "left": return point.x <= bounds.minX + edgeBand
        case "right": return point.x >= bounds.maxX - edgeBand
        default: return point.y >= bounds.maxY - edgeBand
        }
    }

    private func dockOrientation() -> String {
        if let cached = orientation, Date().timeIntervalSince(cached.at) < 10 { return cached.value }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let value = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        orientation = (value, Date())
        return value
    }

    /// The running Dock and its Accessibility element; refreshed when the Dock restarts.
    private func dockProcess() -> (app: NSRunningApplication, element: AXUIElement)? {
        if let dock, !dock.app.isTerminated { return dock }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        dock = (app, element)
        return dock
    }

    private enum DockVisibility {
        case hidden
        case shown
        /// Shown, but a window above it (a menu, a popover) covers the point.
        case covered
    }

    /// Whether the Dock is on screen at `point`. Its window spans the whole screen at the Dock
    /// level and is off screen while an auto-hidden Dock is hidden.
    private func dockVisibility(at point: CGPoint, dockPID: pid_t) -> DockVisibility {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return .hidden }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var covered = false
        for info in list {  // front to back
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t
            if pid == dockPID, layer == dockLevel { return covered ? .covered : .shown }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if layer > dockLevel, pid != ownPID, alpha > 0 { covered = true }
        }
        return .hidden
    }

    /// The running app whose Dock icon is under `point`, or nil.
    ///
    /// The hit-test asks the Dock itself. A system-wide hit-test asks whatever app is under the
    /// point, for every click near the bottom of the screen (chat input fields live there): a
    /// busy app stalls it for the whole timeout while all input waits, and Electron apps switch
    /// on their accessibility tree when asked, which slows them down for good.
    private func appForDockIcon(at point: CGPoint) -> NSRunningApplication? {
        guard let dock = dockProcess() else { return nil }
        var hit: AXUIElement?
        switch dockVisibility(at: point, dockPID: dock.app.processIdentifier) {
        case .hidden:
            return nil
        case .covered:
            // Something is on top of the Dock here; only a system-wide hit-test tells what.
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        case .shown:
            let result = AXUIElementCopyElementAtPosition(dock.element, Float(point.x), Float(point.y), &hit)
            if result == .noValue { return nil }
            if result != .success,
               AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) != .success { return nil }
        }
        guard let element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == dock.app.processIdentifier else { return nil }

        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == "AXApplicationDockItem" else { return nil }

        var urlValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlValue) == .success,
              let raw = urlValue, CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        return Self.runningApp(at: (raw as! CFURL) as URL)
    }

    /// Matches by location, not bundle identifier: copies of one app (for example "Telegram" and
    /// "Telegram Work") share an identifier but are separate processes with separate windows.
    static func runningApp(at url: URL) -> NSRunningApplication? {
        let path = Self.canonicalPath(url)
        if let match = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleURL.map(Self.canonicalPath) == path
        }) {
            return match
        }
        // Fall back to the identifier only when it is unambiguous.
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
