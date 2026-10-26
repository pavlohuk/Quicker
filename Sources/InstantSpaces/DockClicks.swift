import AppKit
import ApplicationServices
import CShims

/// Makes a click on the Dock icon of an app whose windows are all on another space instant.
///
/// Left alone, the click activates the app first, and only then can InstantSpaces follow it to its
/// space: a noticeable delay, and macOS may give focus to another app on that space. Instead, the
/// mouse-down on such an icon is held back, InstantSpaces switches to the app's space instantly,
/// and the click is then replayed to the Dock. The Dock finds the app's windows on the current
/// space and simply activates it, exactly as for an app on the current desktop.
final class DockClickInterceptor {
    private let switcher: SpaceSwitcher
    private let systemWide = AXUIElementCreateSystemWide()
    private var orientation: (value: String, at: Date)?

    private struct Pending {
        let location: CGPoint
        let flags: CGEventFlags
        let target: Int
        var upReceived = false
    }
    private var pending: Pending?
    private var replayWork: DispatchWorkItem?

    /// Clicks farther than this from the Dock's screen edge are never inspected.
    private let edgeBand: CGFloat = 180
    /// Longest wait for the switch to land before the click is replayed anyway.
    private let replayTimeout: TimeInterval = 0.4
    /// Time between focusing the app's window and switching to its Space (see `SpaceSwitcher.prefocusLead`).
    private let prefocusLead = SpaceSwitcher.prefocusLead

    init(switcher: SpaceSwitcher) {
        self.switcher = switcher
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
    }

    /// Left mouse events from the event tap. Returns true to swallow the event.
    func handle(down: Bool, location: CGPoint, flags rawFlags: UInt64) -> Bool {
        if !down {
            // The mouse-up of a held click is replayed together with its mouse-down.
            guard var held = pending else { return false }
            held.upReceived = true
            pending = held
            return true
        }
        if pending != nil { return true }

        let settings = Settings.shared
        guard settings.enabled, settings.followActivatedApp, is_ds_tap_installed(),
              !SystemGestureCheck.systemSwitchOnActivateEnabled() else { return false }
        // ⌘-click (show in Finder), ⌥-click (hide others), ⌃-click (menu): leave to the Dock.
        let flags = CGEventFlags(rawValue: rawFlags)
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
        guard isNearDockEdge(location), let app = appForDockIcon(at: location),
              let state = switcher.snapshot() else { return false }

        var buffer = [Int32](repeating: 0, count: 64)
        var windows = [UInt32](repeating: 0, count: 64)
        let found = Int(is_spaces_app_window_indexes(app.processIdentifier, &buffer, &windows, Int32(buffer.count)))
        let indexes = buffer.prefix(found).map(Int.init)
        guard let target = indexes.first, !indexes.contains(state.current) else { return false }

        // Put the app's window on top of its Space before going there, so the Space does not
        // first appear with another app's window in front.
        let focused = is_focus_window(app.processIdentifier, windows[0])
        let name = app.localizedName ?? "pid \(app.processIdentifier)"
        // The WindowServer needs a moment to reorder the window before the Space appears.
        guard switcher.jump(toSpaceIndex: target, reason: "dock \(name)\(focused ? "" : " (no prefocus)")",
                            after: focused ? prefocusLead : 0) else { return false }
        pending = Pending(location: location, flags: flags, target: target)
        scheduleReplay(after: replayTimeout)
        return true
    }

    /// Every active-space change; replays the held click once the target space is reached.
    func spaceDidChange(to index: Int) {
        guard let held = pending, held.target == index else { return }
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
        post(.leftMouseDown, at: held.location, flags: held.flags)
        if held.upReceived { post(.leftMouseUp, at: held.location, flags: held.flags) }
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

    /// The running app whose Dock icon is under `point`, or nil.
    private func appForDockIcon(at point: CGPoint) -> NSRunningApplication? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" else { return nil }

        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == "AXApplicationDockItem" else { return nil }

        var urlValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlValue) == .success,
              let raw = urlValue, CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        return runningApp(at: (raw as! CFURL) as URL)
    }

    /// Matches by location, not bundle identifier: copies of one app (for example "Telegram" and
    /// "Telegram Work") share an identifier but are separate processes with separate windows.
    private func runningApp(at url: URL) -> NSRunningApplication? {
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
