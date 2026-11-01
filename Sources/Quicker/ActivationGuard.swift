import AppKit

/// Decides whether an app activation should make Quicker follow the app to its Space.
///
/// macOS activates apps on its own all the time: the topmost app of every Space a switch lands
/// on (including the Spaces a multi-Space jump passes through), Finder on an empty desktop or
/// after a click on the wallpaper, the previous app after unlocking the screen. Following those
/// as if the user had picked the app sends Quicker to another Space, where macOS activates
/// another app, and so on: an endless loop of switches. So an activation is followed only when
/// it is the user's ⌘Tab pick, or when nothing else can explain it, and a burst of follows is
/// cut off whatever its cause.
final class ActivationGuard: NSObject {
    enum Verdict {
        case follow
        case skip(String)
    }

    /// ⌘ is held after a ⌘Tab: the app switcher is open.
    private var switcherOpen = false
    /// How far Tab and ⇧Tab moved the switcher's selection; nil once it moved some other way.
    private var steps: Int? = 0
    /// When ⌘ was released after a ⌘Tab; the pick is activated right after that.
    private var switcherClosedAt: Date?
    private var lastSpaceChange = Date.distantPast
    private var quietUntil = Date.distantPast
    private var pausedUntil = Date.distantPast
    private var recentFollows: [Date] = []

    /// How long after ⌘ is released the activation of the picked app is expected.
    private let pickWindow: TimeInterval = 1.0
    /// Activations this soon after a Space change are macOS activating that Space's topmost app.
    private let afterSpaceChange: TimeInterval = 0.5
    /// After unlocking, waking or a display change, macOS reactivates apps and rearranges
    /// Spaces for a few seconds.
    private let afterWake: TimeInterval = 4
    /// More follows than this within `burstWindow` can only be a loop: pause following.
    private let burstLimit = 6
    private let burstWindow: TimeInterval = 3
    private let burstPause: TimeInterval = 10

    private static let finder = "com.apple.finder"

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(systemWoke), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemWoke), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemWoke), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Input

    /// The ⌘Tab app switcher is on screen; ⌘←/→ and ⌘1…9 belong to it then.
    var isSwitcherOpen: Bool { switcherOpen }
    /// Apps the ⌘Tab selection moved past, counted from the frontmost one, if known.
    var switcherSteps: Int? { steps }

    /// Every key-down, from the event tap.
    func keyDown(keycode: Int32, flags: CGEventFlags, isRepeat: Bool) {
        if isRepeat {
            // A held Tab keeps moving the selection.
            if switcherOpen { steps = nil }
            return
        }
        if !flags.contains(.maskCommand) {
            // ⌘ was released without us seeing it (the tap was off for a moment).
            switcherOpen = false
        } else if keycode == Hotkeys.tab {
            if !switcherOpen { steps = 0 }
            steps = steps.map { $0 + (flags.contains(.maskShift) ? -1 : 1) }
            switcherOpen = true
            switcherClosedAt = nil
        } else if keycode == Hotkeys.escape, switcherOpen {
            // ⌘Esc closes the switcher without picking anything.
            switcherOpen = false
        } else if switcherOpen {
            // Arrows and other keys move the selection in ways not tracked here.
            steps = nil
        }
    }

    /// Every modifier change, from the event tap.
    func flagsChanged(_ flags: CGEventFlags) {
        guard switcherOpen, !flags.contains(.maskCommand) else { return }
        switcherOpen = false
        switcherClosedAt = Date()
    }

    func spaceDidChange() {
        lastSpaceChange = Date()
    }

    @objc private func systemWoke() {
        quietUntil = Date().addingTimeInterval(afterWake)
    }

    // MARK: Decision

    /// True once for the activation that follows a ⌘Tab: the app the user picked.
    func takeSwitcherPick() -> Bool {
        if switcherOpen {
            // Picked with the mouse while ⌘ is still held.
            switcherOpen = false
            return true
        }
        guard let closed = switcherClosedAt else { return false }
        switcherClosedAt = nil
        return Date().timeIntervalSince(closed) < pickWindow
    }

    /// `picked`: the activation is the ⌘Tab pick. `switching`: Quicker's own switch has not
    /// landed yet.
    func verdict(for app: NSRunningApplication, picked: Bool, switching: Bool) -> Verdict {
        let now = Date()
        if now < pausedUntil { return .skip("paused after a burst of switches") }
        if picked { return .follow }
        if app.bundleIdentifier == Self.finder {
            // Finder owns the desktop, which is on every Space.
            return .skip("Finder is activated by macOS on an empty desktop")
        }
        if now < quietUntil { return .skip("the screen was just unlocked or woken") }
        if switching { return .skip("Quicker's own switch is still landing") }
        if now.timeIntervalSince(lastSpaceChange) < afterSpaceChange { return .skip("the Space has just changed") }
        return .follow
    }

    /// Call after every switch made to follow an app.
    func didFollow() {
        let now = Date()
        recentFollows = recentFollows.filter { now.timeIntervalSince($0) < burstWindow } + [now]
        guard recentFollows.count >= burstLimit else { return }
        recentFollows.removeAll()
        pausedUntil = now.addingTimeInterval(burstPause)
        log.error("\(self.burstLimit) app switches within \(Int(self.burstWindow)) s: not following apps for \(Int(self.burstPause)) s")
    }
}
